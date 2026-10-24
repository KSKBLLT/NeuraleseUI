import numpy as np
import pytest


def test_greedy_and_top_one_do_not_randomly_change_token():
    from neuralese_local.language.sampling import sample
    logits = np.log([.1, .3, .6])
    for seed in range(8):
        assert sample(logits, 0, 3, np.random.default_rng(seed)) == 2
        assert sample(logits, 2, 1, np.random.default_rng(seed)) == 2


def test_temperature_sampling_is_seeded_and_excludes_tokens_outside_top_k():
    from neuralese_local.language.sampling import sample, probabilities
    logits = np.log([.1, .3, .6])
    np.testing.assert_allclose(probabilities(logits), [.1, .3, .6], atol=1e-6)
    first, second = np.random.default_rng(42), np.random.default_rng(42)
    a = [sample(logits, .7, 2, first) for _ in range(30)]
    assert a == [sample(logits, .7, 2, second) for _ in range(30)]
    assert set(a) == {1, 2}


def test_invalid_sampling_values_are_rejected():
    from neuralese_local.language.sampling import sample
    for logits, temperature, top_k in [([float("nan"), 0], 1, 2), ([1, 2], -1, 2), ([1, 2], 1, 0)]:
        with pytest.raises(ValueError):
            sample(np.asarray(logits), temperature, top_k, np.random.default_rng(42))
