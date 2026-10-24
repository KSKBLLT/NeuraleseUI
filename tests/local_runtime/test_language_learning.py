import numpy as np
import pytest

from neuralese_local.language.model_bundle import load_bundle, file_hash
from neuralese_local.language.graph_mapping import resolve_graph
from neuralese_local.language.onnx_session import LanguageSession


@pytest.fixture(scope="module")
def learning():
    from neuralese_local.language.learning_session import LearningSession
    mapping = resolve_graph({"nodes":[{"id":"e","op":"embedding"},{"id":"a","op":"attention_head"},{"id":"o","op":"token_labels"}],"edges":[{"from_node":"e","to_node":"a"},{"from_node":"a","to_node":"o"}]},{})
    original = LanguageSession(load_bundle(),mapping)
    return original, LearningSession(original)


def test_initial_attention_is_uniform_causal_and_real_embeddings_are_damaged(learning):
    original, learner = learning
    before = file_hash(original.bundle.decoder)
    learner.set_progress(0)
    value = learner.forward([21,32,43,54],layers=[0,9])
    for matrix in value["attention"].values():
        expected=np.tril(np.ones((4,4))) / np.arange(1,5)[:,None]
        np.testing.assert_allclose(matrix[0,0],expected,atol=1e-6)
        np.testing.assert_allclose(matrix.sum(-1),1,atol=1e-6)
    assert not np.allclose(value["embeddings"], original.forward([21,32,43,54])["embeddings"])
    assert file_hash(original.bundle.decoder)==before


def test_restoration_is_a_real_lerp_and_reaches_the_unchanged_checkpoint(learning):
    original, learner = learning
    stages=[]
    for progress in (0,.5,1):
        learner.set_progress(progress)
        stages.append(learner.forward([21,32,43],layers=[0,9]))
    np.testing.assert_allclose(stages[1]["embeddings"], (stages[0]["embeddings"]+stages[2]["embeddings"])*.5,atol=1e-7)
    final=original.forward([21,32,43],layers=[0,9])
    np.testing.assert_array_equal(stages[2]["logits"],final["logits"])
    np.testing.assert_array_equal(stages[2]["attention"][9],final["attention"][9])
    assert not np.allclose(stages[0]["logits"],stages[1]["logits"])


def test_training_previews_follow_latest_english_text_without_sampling(learning):
    original,learner=learning
    first=learner.training_preview("Copy exactly: red cup",0,"The little cat looked out of the window.")
    final=learner.training_preview("Copy exactly: blue moon",1,"A bright sun warmed the quiet garden.")
    assert first["generated_ids"]==final["generated_ids"]==[]
    assert first["nodes"]["a"]["preview"]["source_text"]=="Copy exactly: red cup"
    assert final["nodes"]["a"]["preview"]["source_text"]=="Copy exactly: blue moon"
    assert final["teacher_agreement"]==1
    assert 0<=first["teacher_agreement"]<=1
    assert first["nodes"]["e"]["preview"]["points"][0]["vector"] != final["nodes"]["e"]["preview"]["points"][0]["vector"]
    expected=original.preview(original.tokenize("Copy exactly: blue moon")["ids"],[])
    np.testing.assert_array_equal(final["scores"],expected["scores"])


def test_reported_accuracy_scores_heldout_next_tokens_instead_of_matching_teacher(learning):
    original, learner = learning
    text = "A bright sun warmed the quiet garden. A small bird sang in the tree."
    result = learner.training_preview("Copy exactly: red cup",1,text)
    ids = original.tokenizer.encode(text,add_special_tokens=False).ids
    logits = original.forward(ids)["logits"][0][:-1]
    expected = float(np.mean(logits.argmax(-1) == ids[1:]))
    assert result["validation_accuracy"] == expected
    assert 0 < result["validation_accuracy"] < 1
    logsum = np.logaddexp.reduce(logits.astype(np.float64),axis=-1)
    loss = float(np.mean(logsum-logits[np.arange(len(ids)-1),ids[1:]]))
    assert result["validation_loss"] == pytest.approx(loss,abs=1e-5)
    assert result["validation_tokens"] == len(ids)-1


def test_learning_metrics_evaluate_rotating_heldout_batches_and_training_contexts(learning):
    _, learner = learning
    samples = ["The cat walked home. A child opened the door.", "A robot picked up a book and read a story."]
    heldout = ["The sun is bright.", "A girl watched the rain.", "A bird sat on a branch."]
    learner.prepare_corpus(samples,heldout)
    first=learner.training_preview("Copy exactly: red cup",.5,"",batch_index=0)
    second=learner.training_preview("Copy exactly: red cup",.5,"",batch_index=1)
    assert first["evaluation_passes"] == 5
    assert first["training_tokens"] == 2*127
    assert first["validation_tokens"] > 0
    assert first["validation_examples"] != second["validation_examples"]
    assert first["generated_ids"] == second["generated_ids"] == []


@pytest.mark.parametrize("value",[-.1,1.1,float("nan")])
def test_learning_progress_is_bounded(learning,value):
    with pytest.raises(ValueError,match="progress"):
        learning[1].set_progress(value)
