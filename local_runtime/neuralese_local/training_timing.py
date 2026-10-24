from __future__ import annotations

from time import perf_counter
from typing import Callable, Dict


class StageTimer:
    """Collect monotonic training-stage durations without global state."""

    def __init__(self, clock: Callable[[], float] = perf_counter) -> None:
        self._clock = clock
        self._created_at = clock()
        self._starts: Dict[str, float] = {}
        self._durations_ms: Dict[str, float] = {}

    def begin(self, name: str) -> None:
        self._starts[name] = self._clock()

    def end(self, name: str) -> float:
        if name not in self._starts:
            raise KeyError(f"unknown stage '{name}'")
        elapsed_ms = (self._clock() - self._starts.pop(name)) * 1000.0
        self._durations_ms[name] = elapsed_ms
        return elapsed_ms

    def mark(self, name: str) -> float:
        elapsed_ms = (self._clock() - self._created_at) * 1000.0
        self._durations_ms[name] = elapsed_ms
        return elapsed_ms

    def snapshot(self) -> Dict[str, float]:
        return dict(self._durations_ms)
