import numpy as np
import onnx
from onnx import numpy_helper
import onnxruntime as ort
import pytest

from neuralese_local.language.model_bundle import load_bundle, file_hash


@pytest.fixture(scope="module")
def session():
    from neuralese_local.language.onnx_session import LanguageSession
    return LanguageSession(load_bundle())


def test_tracing_does_not_change_real_logits_or_weights(session):
    before = file_hash(session.bundle.decoder)
    result = session.forward([21, 32, 43], layers=[0, 9])
    original = ort.InferenceSession(str(session.bundle.decoder), providers=["CPUExecutionProvider"])
    feed = {"input_ids": np.array([[21, 32, 43]], np.int64), "attention_mask": np.ones((1, 3), np.int64), "position_ids": np.arange(3, dtype=np.int64)[None]}
    for name in original.get_inputs()[3:]:
        feed[name.name] = np.zeros((1, 2, 0, 64), np.float32)
    expected = original.run(["logits"], feed)[0]
    np.testing.assert_allclose(result["logits"], expected, rtol=4e-4, atol=4e-4)
    assert file_hash(session.bundle.decoder) == before


def test_attention_is_real_causal_probability_and_has_four_query_heads(session):
    result = session.forward([21, 32, 43, 54], layers=[0, 9])
    assert set(result["attention"]) == {0, 9}
    for attention in result["attention"].values():
        assert attention.shape == (1, 4, 4, 4)
        np.testing.assert_allclose(attention.sum(-1), 1, atol=1e-5)
        assert np.max(np.triu(attention, 1)) == 0
        assert np.isfinite(attention).all()
    assert not np.allclose(result["attention"][0], result["attention"][9])
    assert result["head_outputs"][0].shape == (1, 4, 4, 64)


def test_cached_decode_equals_full_prefix(session):
    prefix = session.forward([21, 32, 43])
    cached = session.forward([54, 65], cache=prefix["cache"])
    full = session.forward([21, 32, 43, 54, 65])
    np.testing.assert_allclose(cached["logits"], full["logits"][:, -2:], rtol=4e-4, atol=4e-4)
    assert cached["cache"][0].shape == (1, 2, 5, 64)


def test_embedding_values_come_from_checkpoint_table(session):
    model = onnx.load(session.bundle.decoder)
    table = next(numpy_helper.to_array(x) for x in model.graph.initializer if list(x.dims) == [20002, 256])
    result = session.forward([21, 32, 43])
    np.testing.assert_array_equal(result["embeddings"][0], table[[21, 32, 43]])


def test_checkpoint_tokenizer_preserves_unicode_offsets(session):
    value = session.tokenize("мама")
    assert value["ids"] == [142, 122, 9539, 142, 122, 9539]
    assert [(t["start"], t["end"]) for t in value["tokens"]] == [(0, 1), (0, 1), (1, 2), (2, 3), (2, 3), (3, 4)]
    for text in ["Қазақша мәтін", "Привет 👋", "a\nb"]:
        assert session.decode(session.tokenize(text)["ids"]) == text


def test_context_limit_uses_total_cached_length(session):
    with pytest.raises(ValueError, match="512"):
        session.forward([21] * 513)


def test_preview_never_samples_and_step_appends_one_real_token(session):
    prefix = session.tokenize("Add 26 and 49.")["ids"]
    preview = session.preview(prefix, [])
    assert preview["generated_ids"] == []
    first = session.step(prefix, [], temperature=0, top_k=5)
    prompt = session.tokenizer.encode("<|im_start|>user\nAdd 26 and 49.<|im_end|>\n<|im_start|>assistant\n", add_special_tokens=False).ids
    golden = int(session.forward(prompt)["logits"][0, -1].argmax())
    assert first["generated_ids"] == [golden]
    assert first["decoded_text"] == session.decode([golden])
    second = session.step(prefix, first["generated_ids"], temperature=0, top_k=5)
    assert len(second["generated_ids"]) == 2


def test_two_sessions_have_independent_generation_state(session):
    from neuralese_local.language.onnx_session import LanguageSession
    other = LanguageSession(session.bundle, seed=42)
    ids = session.tokenize("The cat")["ids"]
    a = session.step(ids, [], temperature=.7, top_k=5)
    b = other.step(ids, [], temperature=.7, top_k=5)
    # Reset seeds explicitly: prior tests may have used the module session.
    session.rng = np.random.default_rng(42)
    assert session.step(ids, [], temperature=.7, top_k=5)["generated_ids"] == b["generated_ids"]
    assert other.preview(ids, [])["generated_ids"] == []


def test_real_checkpoint_eos_finishes_without_printing_special_token(session):
    prefix = session.tokenize("Copy exactly: red cup")["ids"]
    generated = []
    for _ in range(4):
        result = session.step(prefix, generated, temperature=0, top_k=5)
        generated = result["generated_ids"]
        if result["finished"]:
            break
    assert result["finished"] and result["stop_reason"] == "eos"
    assert generated == [768, 7700]
    assert result["decoded_text"] == "red cup"
    assert session.bundle.config["eos_token_id"] not in generated
    # Godot sorts equal probabilities by ID. Every visible candidate needs its
    # checkpoint label, including zero-probability ties after a certain EOS.
    ui_top = sorted(range(len(result["scores"])), key=lambda i: (-result["scores"][i], i))[:20]
    assert all(str(i) in result["labels"] for i in ui_top)


def test_empty_prompt_does_not_start_generation(session):
    with pytest.raises(ValueError, match="текст"):
        session.preview([], [])


def test_attention_preview_keeps_all_visible_tokens_for_word_scrolling(session):
    from neuralese_local.language.graph_mapping import resolve_graph
    previous = session.mapping
    session.mapping = resolve_graph({"nodes":[{"id":"a","op":"attention_head","config":{}}],"edges":[]}, {})
    try:
        prefix = session.tokenize("мама папа король королева ана әке патша патшайым hello world")["ids"]
        result = session.preview(prefix)
        data = result["nodes"]["a"]["preview"]
        assert len(data["tokens"]) > 8
        assert np.asarray(data["matrix"]).shape == (len(data["tokens"]), len(data["tokens"]))
        assert result["generated_ids"] == []
    finally:
        session.mapping = previous


def test_equal_probability_labels_follow_ui_id_order(session, monkeypatch):
    forward = session.forward
    def certain_eos(*args, **kwargs):
        result = forward(*args, **kwargs)
        result["logits"].fill(-1000)
        result["logits"][..., 20001] = 1000
        return result
    monkeypatch.setattr(session, "forward", certain_eos)
    result = session.preview(session.tokenize("hello")["ids"])
    assert all(str(i) in result["labels"] for i in [20001, *range(19)])
