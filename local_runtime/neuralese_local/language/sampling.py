from __future__ import annotations
import numpy as np


def probabilities(logits: np.ndarray) -> np.ndarray:
    scores = np.asarray(logits, dtype=np.float64)
    if scores.ndim != 1 or not scores.size or not np.isfinite(scores).all():
        raise ValueError("Model scores must be finite")
    result = np.exp(scores - scores.max())
    return result / result.sum()


def sample(logits: np.ndarray, temperature: float, top_k: int, rng: np.random.Generator) -> int:
    probabilities(logits)  # validates also the greedy branch
    if not np.isfinite(temperature) or temperature < 0 or top_k < 1:
        raise ValueError("Invalid temperature/top-k")
    if temperature == 0:
        return int(np.argmax(logits))
    count = min(int(top_k), len(logits))
    indices = np.argsort(-np.asarray(logits), kind="stable")[:count]
    weights = probabilities(np.asarray(logits)[indices] / temperature)
    return int(rng.choice(indices, p=weights))
