import numpy as np


def test_byte_fragments_share_character_weight_before_pooling():
    from neuralese_local.language.word_embeddings import pool_words
    tokens = [{"id": i, "start": a, "end": b, "position": i} for i, (a, b) in enumerate([(0,1),(0,1),(1,2),(2,3),(2,3),(3,4)])]
    words = pool_words("мама", tokens, np.array([[2,0],[4,0],[0,4],[6,0],[8,0],[0,8]], np.float32))
    assert len(words) == 1 and words[0]["text"] == "мама"
    np.testing.assert_allclose(words[0]["vector"], [2.5,3.])
    assert words[0]["positions"] == [0,1,2,3,4,5]


def test_unicode_words_keep_original_spans_and_repeated_occurrences():
    from neuralese_local.language.word_embeddings import pool_words
    text = "Мама 👋 әке, мама!"
    tokens = [{"id": i, "start": i, "end": i+1, "position": i} for i in range(len(text))]
    words = pool_words(text, tokens, np.ones((len(text), 3)))
    assert [w["text"] for w in words] == ["Мама", "әке", "мама"]
    assert [(w["start"], w["end"]) for w in words] == [(0,4),(7,10),(12,16)]
    assert words[0]["positions"] != words[2]["positions"]


def test_combining_marks_and_apostrophes_stay_with_the_word():
    from neuralese_local.language.word_embeddings import word_spans
    assert [(a,b) for a,b in word_spans("e\u0301lan don't")] == [(0,5),(6,11)]
