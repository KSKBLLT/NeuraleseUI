from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Iterator

import numpy as np


@dataclass(frozen=True)
class BatchSlice:
    start: int
    stop: int


@dataclass(frozen=True)
class BatchIndices:
    indices: np.ndarray


BatchDescriptor = BatchSlice | BatchIndices


class ExactSampleShuffle:
    name = "exact"

    def __init__(self, size: int, batch_size: int) -> None:
        self.size = max(0, int(size))
        self.batch_size = max(1, int(batch_size))

    def descriptors(self, rng: Any) -> list[BatchDescriptor]:
        order = np.arange(self.size, dtype=np.int64)
        rng.shuffle(order)
        return [
            BatchIndices(order[start : min(start + self.batch_size, self.size)])
            for start in range(0, self.size, self.batch_size)
        ]


class ShuffledBlockSchedule:
    name = "blocks"

    def __init__(self, size: int, batch_size: int) -> None:
        self.size = max(0, int(size))
        self.batch_size = max(1, int(batch_size))

    def descriptors(self, rng: Any) -> list[BatchDescriptor]:
        blocks = [
            BatchSlice(start, min(start + self.batch_size, self.size))
            for start in range(0, self.size, self.batch_size)
        ]
        order = np.arange(len(blocks), dtype=np.int64)
        rng.shuffle(order)
        return [blocks[int(index)] for index in order]


class PrePermutedEpochSchedule(ExactSampleShuffle):
    name = "prepermuted"


def descriptor_indices(descriptor: BatchDescriptor) -> np.ndarray:
    if isinstance(descriptor, BatchSlice):
        return np.arange(descriptor.start, descriptor.stop, dtype=np.int64)
    return descriptor.indices


def make_schedule(policy: str, size: int, batch_size: int):
    normalized = str(policy).strip().lower()
    if normalized == "exact":
        return ExactSampleShuffle(size, batch_size)
    if normalized == "blocks":
        return ShuffledBlockSchedule(size, batch_size)
    if normalized == "prepermuted":
        return PrePermutedEpochSchedule(size, batch_size)
    raise ValueError(f"unknown batch schedule policy '{policy}'")


def select_schedule_policy(dataset: Any, batch_size: int) -> str:
    """Select a measured workload policy without consulting dataset names."""
    if not bool(getattr(dataset, "materialize_x", False)):
        return "exact"
    samples = len(dataset)
    batches = (samples + max(1, int(batch_size)) - 1) // max(1, int(batch_size))
    if batches < 8:
        return "exact"
    bytes_per_sample = int(np.asarray(dataset.x[0]).nbytes) if samples else 0
    if bytes_per_sample >= 1024:
        return "blocks"
    return "prepermuted"


class PrePermutedEpochBuffer:
    """Gather one exact sample permutation, then expose zero-copy batch views."""

    def __init__(self, dataset: Any, *, batch_size: int) -> None:
        self.dataset = dataset
        self.batch_size = max(1, int(batch_size))
        self.x = np.empty((len(dataset), *dataset.x.shape[1:]), dtype=np.float32)
        self.y = np.empty((len(dataset), *dataset.y.shape[1:]), dtype=dataset.y.dtype)

    @property
    def nbytes(self) -> int:
        return int(self.x.nbytes + self.y.nbytes)

    def prepare(self, order: np.ndarray) -> None:
        if len(order) != len(self.dataset):
            raise ValueError(
                f"epoch order has {len(order)} entries for dataset of {len(self.dataset)}"
            )
        self.dataset.batch_indices(order, self.x, self.y)

    def batches(self) -> Iterator[tuple[np.ndarray, np.ndarray]]:
        for start in range(0, len(self.dataset), self.batch_size):
            end = min(start + self.batch_size, len(self.dataset))
            yield self.x[start:end], self.y[start:end]
