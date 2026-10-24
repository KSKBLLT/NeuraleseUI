from __future__ import annotations

import unicodedata
import numpy as np
import onnx
from onnx import numpy_helper
from tokenizers import Tokenizer


def word_spans(text: str):
    start = None
    for index, character in enumerate(text):
        letter = unicodedata.category(character)[0] in {"L", "N", "M"}
        joining = character in "'’-" and start is not None and index + 1 < len(text) and unicodedata.category(text[index + 1])[0] in {"L", "N"}
        if letter or joining:
            if start is None:
                start = index
        elif start is not None:
            yield start, index
            start = None
    if start is not None:
        yield start, len(text)


def pool_words(text: str, tokens: list[dict], embeddings: np.ndarray) -> list[dict]:
    vectors = np.asarray(embeddings, dtype=np.float64)
    if vectors.ndim != 2 or len(vectors) != len(tokens):
        raise ValueError("Every token needs its actual embedding vector")
    words = []
    for start, end in word_spans(text):
        weights = np.zeros(len(tokens), np.float64)
        for character in range(start, end):
            covering = [i for i, token in enumerate(tokens) if int(token["start"]) <= character < int(token["end"])]
            if covering:
                weights[covering] += 1 / len(covering)
        total = weights.sum()
        if total == 0:
            continue
        indices = np.flatnonzero(weights)
        positions = [int(tokens[i].get("position", i)) for i in indices]
        words.append({"text": text[start:end], "piece": text[start:end], "start": start, "end": end, "positions": positions, "position": positions[0], "id": int(tokens[int(indices[0])]["id"]), "vector": (weights @ vectors / total).tolist()})
    return words


class ModelWordEmbeddings:
    """Canonical words use the same checkpoint table, independent of whitespace.

    Input token positions remain attached for selection. Case-folding is solely
    the word visualisation's documented normalisation, never model inference.
    """
    def __init__(self, tokenizer: Tokenizer, table: np.ndarray, source_hash: str):
        self.tokenizer, self.table, self.source_hash = tokenizer, table, source_hash
        self._vectors = {}

    @classmethod
    def from_bundle(cls, bundle):
        model = onnx.load(bundle.decoder)
        table = next(numpy_helper.to_array(value).copy() for value in model.graph.initializer if list(value.dims) == [bundle.vocab_size, bundle.width])
        return cls(Tokenizer.from_file(str(bundle.tokenizer)), table, bundle.source_hash)

    def vector(self, word: str) -> tuple[list[float], list[int]]:
        canonical = word.casefold()
        if canonical not in self._vectors:
            encoding = self.tokenizer.encode(canonical, add_special_tokens=False)
            tokens = [{"id": token, "start": start, "end": end, "position": i} for i, (token, (start, end)) in enumerate(zip(encoding.ids, encoding.offsets))]
            pooled = pool_words(canonical, tokens, self.table[encoding.ids])
            if len(pooled) != 1:
                raise ValueError("Expected a single Unicode word")
            self._vectors[canonical] = (pooled[0]["vector"], encoding.ids)
        return self._vectors[canonical]

    def words(self, text: str, tokens: list[dict] | None = None) -> list[dict]:
        if tokens is None:
            encoding = self.tokenizer.encode(text, add_special_tokens=False)
            tokens = [{"id": token, "start": start, "end": end, "position": i} for i, (token, (start, end)) in enumerate(zip(encoding.ids, encoding.offsets))]
        pooled = pool_words(text, tokens, self.table[[int(t["id"]) for t in tokens]]) if tokens else []
        for point in pooled:
            point["vector"], point["token_ids"] = self.vector(point["text"])
            point["normalization"] = "casefold"
        return pooled
