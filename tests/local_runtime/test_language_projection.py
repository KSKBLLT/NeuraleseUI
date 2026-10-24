import numpy as np
import pytest

from neuralese_local.language.model_bundle import load_bundle


@pytest.fixture(scope="module")
def prepared():
    from neuralese_local.language.word_embeddings import ModelWordEmbeddings
    from neuralese_local.language.projection import build_projection
    view = ModelWordEmbeddings.from_bundle(load_bundle())
    return view, build_projection(view)


def test_projection_preserves_the_requested_relation_without_collapsing(prepared):
    from neuralese_local.language.projection import project_words
    view, basis = prepared
    points = project_words(view.words("мама папа король королева"), basis)
    coordinates = {p["text"]: np.array([p["x"],p["y"],p["z"]]) for p in points}
    first = coordinates["папа"]-coordinates["мама"]
    second = coordinates["король"]-coordinates["королева"]
    assert np.linalg.norm(first)>1e-4
    assert first@second/(np.linalg.norm(first)*np.linalg.norm(second))>=.9
    assert .8 <= np.linalg.norm(first)/np.linalg.norm(second) <= 1.25
    assert all(len(p["vector"])==256 for p in points)


def test_word_coordinates_are_stable_across_context_case_and_repetition(prepared):
    from neuralese_local.language.projection import project_words
    view, basis = prepared
    first = project_words(view.words("Мама папа"), basis)
    second = project_words(view.words("кот мама собака мама"), basis)
    np.testing.assert_allclose([first[0][k] for k in ("x","y","z")], [second[1][k] for k in ("x","y","z")], atol=1e-7)
    np.testing.assert_allclose(second[1]["vector"], second[3]["vector"], atol=0)


def test_projection_uses_vector_values_not_word_labels(prepared):
    from neuralese_local.language.projection import project_words
    view, basis = prepared
    a = view.words("мама")[0]
    b = {**a, "text": "a completely different label", "piece": "another"}
    p, q = project_words([a,b],basis)
    assert [p[k] for k in ("x","y","z")] == [q[k] for k in ("x","y","z")]
    assert basis["metrics"]["heldout_relations"]
    assert 0 <= basis["metrics"]["neighbour_recall_at_10"] <= 1


def test_real_preview_contains_words_with_full_vectors_and_linked_token_positions():
    from neuralese_local.language.onnx_session import LanguageSession
    session = LanguageSession(load_bundle(), {"node_mapping":{"e":{"op":"embedding","layer":0}}})
    prefix = session.tokenize("Мама папа")["ids"]
    preview = session.preview(prefix,[])["nodes"]["e"]["preview"]
    assert preview["points_are_words"]
    assert [p["text"] for p in preview["points"]] == ["Мама","папа"]
    assert len(preview["points"][0]["vector"]) == 256
    assert len(preview["points"][0]["positions"]) > 1


def test_projection_cache_round_trips_unicode_with_windows_default_encoding(tmp_path, monkeypatch):
    from pathlib import Path
    from types import SimpleNamespace
    from neuralese_local.language import projection

    original_open = Path.open

    def windows_open(path, mode="r", buffering=-1, encoding=None, errors=None, newline=None):
        if "b" not in mode and encoding in (None, "locale"):
            encoding = "cp1252"
        return original_open(path, mode, buffering, encoding, errors, newline)

    monkeypatch.setattr(Path, "open", windows_open)
    monkeypatch.setenv("NEURALESE_LANGUAGE_CACHE_DIR", str(tmp_path / "Пустой профиль"))
    view = SimpleNamespace(source_hash="test-checkpoint")
    expected = {"version": projection.VERSION, "source_hash": view.source_hash,
                "anchors": [["мама", "папа", "әке"]]}
    monkeypatch.setattr(projection, "build_projection", lambda _: expected)
    assert projection.load_or_build_projection(view) == expected
    monkeypatch.setattr(projection, "build_projection", lambda _: pytest.fail("Cache was not reused"))
    assert projection.load_or_build_projection(view) == expected
