from __future__ import annotations

import pytest

from neuralese_local.training_timing import StageTimer


class FakeClock:
    def __init__(self) -> None:
        self.now = 10.0

    def __call__(self) -> float:
        return self.now

    def advance(self, seconds: float) -> None:
        self.now += seconds


def test_stage_timer_records_monotonic_durations_in_milliseconds() -> None:
    clock = FakeClock()
    timer = StageTimer(clock=clock)

    timer.begin("dataset")
    clock.advance(0.012)
    elapsed = timer.end("dataset")

    assert elapsed == pytest.approx(12.0)
    assert timer.snapshot()["dataset"] == pytest.approx(12.0)


def test_stage_timer_marks_time_since_creation_without_exposing_mutable_state() -> None:
    clock = FakeClock()
    timer = StageTimer(clock=clock)

    clock.advance(0.025)
    timer.mark("first_step")
    snapshot = timer.snapshot()
    snapshot["first_step"] = -1

    assert timer.snapshot()["first_step"] == pytest.approx(25.0)


def test_stage_timer_rejects_unmatched_end() -> None:
    timer = StageTimer(clock=FakeClock())

    with pytest.raises(KeyError, match="unknown stage"):
        timer.end("missing")
