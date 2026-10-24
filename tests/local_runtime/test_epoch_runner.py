from __future__ import annotations

import numpy as np
import pytest

from neuralese_local.epoch_runner import EpochRunner, OrtValueTrainingError, RateLimitedProgress
from neuralese_local.training_acceleration import SelectiveBlockPolicy


class FakeDataset:
    def __init__(self, size: int, width: int = 1):
        self.x = np.arange(size * width, dtype=np.float32).reshape(size, width)
        self.y = np.arange(size, dtype=np.int64)
        self.seen: list[int] = []
        self.gather_calls = 0
        self.materialize_x = True

    def __len__(self):
        return len(self.x)

    def batch_indices(self, indices, out_x, out_y):
        self.gather_calls += 1
        self.seen.extend(int(value) for value in indices)
        np.take(self.x, indices, axis=0, out=out_x)
        np.take(self.y, indices, axis=0, out=out_y)
        return out_x, out_y

    def batch_view(self, start, end):
        self.seen.extend(range(int(start), int(end)))
        return self.x[start:end], self.y[start:end]


class FakeModule:
    def __init__(self, clock=None):
        self.reset_calls = 0
        self.train_calls = 0
        self.clock = clock

    def train(self):
        self.train_calls += 1

    def lazy_reset_grad(self):
        self.reset_calls += 1

    def __call__(self, x, _y):
        if self.clock is not None:
            self.clock.advance(0.001)
        return np.asarray(float(np.mean(x)), dtype=np.float32)


class FakeOptimizer:
    def __init__(self):
        self.steps = 0

    def step(self):
        self.steps += 1


class NeverCancel:
    closed = False


class CancelAfterSteps:
    def __init__(self, optimizer, steps):
        self.optimizer = optimizer
        self.steps = steps

    @property
    def closed(self):
        return self.optimizer.steps >= self.steps


class FakeClock:
    def __init__(self):
        self.value = 0.0

    def __call__(self):
        return self.value

    def advance(self, seconds: float):
        self.value += seconds


def test_epoch_runner_trains_every_sample_once_and_handles_tail():
    dataset = FakeDataset(10)
    module = FakeModule()
    optimizer = FakeOptimizer()
    runner = EpochRunner(dataset, module, optimizer, batch_size=4, seed=11)

    result = runner.run_epoch(0, 2, NeverCancel(), lambda _packet: None)

    assert sorted(dataset.seen) == list(range(10))
    assert result.batches == 3
    assert module.train_calls == 1
    assert module.reset_calls == 3
    assert optimizer.steps == 3
    assert np.isfinite(result.average_loss)
    assert dataset.gather_calls == 3
    assert result.breakdown["batch_loop_seconds"] == result.train_seconds


class RecordingModule(FakeModule):
    """Keeps the labels of every batch as the module received it."""

    def __init__(self):
        super().__init__()
        self.labels: list[int] = []

    def __call__(self, x, y):
        self.labels.extend(int(value) for value in y)
        return super().__call__(x, y)


@pytest.mark.parametrize("materialize_x", [True, False])
def test_epoch_runner_trains_on_each_batch_not_the_last_one_again(materialize_x):
    # Batches gathered into the shared batch buffers must reach the module one
    # at a time: gathering the whole epoch first left every batch showing the
    # last one (pictures kept as bytes, and any dataset under eight batches).
    dataset = FakeDataset(10)
    dataset.materialize_x = materialize_x
    module = RecordingModule()
    runner = EpochRunner(dataset, module, FakeOptimizer(), batch_size=4, seed=11)

    runner.run_epoch(0, 2, NeverCancel(), lambda _packet: None)

    assert sorted(module.labels) == list(range(10))


def test_epoch_runner_seed_makes_sample_order_deterministic():
    first = FakeDataset(32)
    second = FakeDataset(32)

    EpochRunner(first, FakeModule(), FakeOptimizer(), batch_size=7, seed=91).run_epoch(
        0, 1, NeverCancel(), lambda _packet: None
    )
    EpochRunner(second, FakeModule(), FakeOptimizer(), batch_size=7, seed=91).run_epoch(
        0, 1, NeverCancel(), lambda _packet: None
    )

    assert first.seen == second.seen


def test_epoch_runner_cancels_before_the_next_batch_without_extra_optimizer_step():
    dataset = FakeDataset(20)
    optimizer = FakeOptimizer()
    runner = EpochRunner(dataset, FakeModule(), optimizer, batch_size=4, seed=2)

    result = runner.run_epoch(
        0, 1, CancelAfterSteps(optimizer, 2), lambda _packet: None
    )

    assert result.stopped is True
    assert result.batches == 2
    assert optimizer.steps == 2


def test_epoch_runner_throttles_before_batch_packet_allocation():
    clock = FakeClock()
    dataset = FakeDataset(469)
    packets = []
    packet_builds = []
    runner = EpochRunner(
        dataset,
        FakeModule(clock),
        FakeOptimizer(),
        batch_size=1,
        seed=7,
        progress_interval_s=0.1,
        clock=clock,
        batch_packet_observer=lambda: packet_builds.append(1),
    )

    runner.run_epoch(0, 1, NeverCancel(), packets.append)

    batch_packets = [item for item in packets if item["data"]["stage"] == "batch"]
    assert 4 <= len(batch_packets) <= 6
    assert len(packet_builds) == len(batch_packets)
    assert batch_packets[0]["data"]["batch"] == 1
    assert batch_packets[-1]["data"]["batch"] == 469
    elapsed = [item["data"]["epoch_elapsed_seconds"] for item in batch_packets]
    assert elapsed == sorted(elapsed)
    assert elapsed[0] == pytest.approx(0.001)
    assert elapsed[-1] == pytest.approx(0.469)


def test_epoch_runner_uses_zero_copy_block_shuffle_for_large_samples():
    dataset = FakeDataset(32, width=512)
    runner = EpochRunner(
        dataset, FakeModule(), FakeOptimizer(), batch_size=4, seed=7,
        schedule_policy="blocks",
    )

    result = runner.run_epoch(0, 1, NeverCancel(), lambda _packet: None)

    assert result.batches == 8
    assert dataset.gather_calls == 0


def test_epoch_runner_prepermuted_schedule_gathers_once_per_epoch():
    dataset = FakeDataset(32, width=8)
    runner = EpochRunner(
        dataset, FakeModule(), FakeOptimizer(), batch_size=4, seed=7,
        schedule_policy="prepermuted",
    )

    runner.run_epoch(0, 1, NeverCancel(), lambda _packet: None)

    assert dataset.gather_calls == 1


def test_ortvalue_binding_creation_failure_falls_back_before_first_step(monkeypatch):
    dataset = FakeDataset(8)
    optimizer = FakeOptimizer()
    runner = EpochRunner(
        dataset, FakeModule(), optimizer, batch_size=4, seed=7,
        use_ortvalue_inputs=True,
    )
    monkeypatch.setattr(
        runner._bound_inputs, "bind", lambda *_args: (_ for _ in ()).throw(RuntimeError("bind"))
    )

    result = runner.run_epoch(0, 1, NeverCancel(), lambda _packet: None)

    assert result.batches == 2
    assert optimizer.steps == 2
    assert result.binding_failure == "RuntimeError: bind"


def test_ortvalue_module_failure_is_not_replayed_with_numpy(monkeypatch):
    dataset = FakeDataset(8)
    optimizer = FakeOptimizer()
    module = FakeModule()
    runner = EpochRunner(
        dataset, module, optimizer, batch_size=4, seed=7,
        use_ortvalue_inputs=True,
    )
    monkeypatch.setattr(runner._bound_inputs, "bind", lambda x, y: (x, y))
    monkeypatch.setattr(module, "__call__", lambda *_args: (_ for _ in ()).throw(RuntimeError("live")))

    class FailingModule(FakeModule):
        def __call__(self, *_args):
            raise RuntimeError("live")

    runner.module = FailingModule()
    with pytest.raises(OrtValueTrainingError, match="live"):
        runner.run_epoch(0, 1, NeverCancel(), lambda _packet: None)
    assert optimizer.steps == 0


def test_rate_limiter_forces_first_and_final_batch():
    limiter = RateLimitedProgress(interval_s=0.1)

    assert limiter.due(10.0, batch=1, batches=100)
    assert not limiter.due(10.01, batch=2, batches=100)
    assert limiter.due(10.02, batch=100, batches=100)


def test_selective_runner_warms_up_then_executes_eighty_percent_and_finishes_full():
    dataset = FakeDataset(100)
    optimizer = FakeOptimizer()
    runner = EpochRunner(
        dataset,
        FakeModule(),
        optimizer,
        batch_size=10,
        seed=17,
        selective_policy=SelectiveBlockPolicy(),
    )

    warmup_a = runner.run_epoch(0, 8, NeverCancel(), lambda _packet: None)
    warmup_b = runner.run_epoch(1, 8, NeverCancel(), lambda _packet: None)
    selective = runner.run_epoch(2, 8, NeverCancel(), lambda _packet: None)
    refresh = runner.run_epoch(4, 8, NeverCancel(), lambda _packet: None)
    final = runner.run_epoch(7, 8, NeverCancel(), lambda _packet: None)

    assert warmup_a.batches == warmup_b.batches == 10
    assert selective.batches == 8
    assert selective.available_batches == 10
    assert selective.coverage == pytest.approx(0.8)
    assert refresh.batches == 10
    assert final.batches == 10


def test_selective_runner_is_reproducible_and_keeps_high_loss_blocks():
    first_dataset = FakeDataset(100)
    second_dataset = FakeDataset(100)
    first = EpochRunner(
        first_dataset,
        FakeModule(),
        FakeOptimizer(),
        batch_size=10,
        seed=23,
        selective_policy=SelectiveBlockPolicy(),
    )
    second = EpochRunner(
        second_dataset,
        FakeModule(),
        FakeOptimizer(),
        batch_size=10,
        seed=23,
        selective_policy=SelectiveBlockPolicy(),
    )
    for epoch in (0, 1):
        first.run_epoch(epoch, 8, NeverCancel(), lambda _packet: None)
        second.run_epoch(epoch, 8, NeverCancel(), lambda _packet: None)

    first_dataset.seen.clear()
    second_dataset.seen.clear()
    first.run_epoch(2, 8, NeverCancel(), lambda _packet: None)
    second.run_epoch(2, 8, NeverCancel(), lambda _packet: None)

    assert first_dataset.seen == second_dataset.seen
    assert any(sample >= 90 for sample in first_dataset.seen)
    assert len(first_dataset.seen) == 80


def test_selective_runner_keeps_lazy_dataset_batches_supported():
    dataset = FakeDataset(100)
    dataset.materialize_x = False
    runner = EpochRunner(
        dataset,
        FakeModule(),
        FakeOptimizer(),
        batch_size=10,
        seed=31,
        selective_policy=SelectiveBlockPolicy(),
    )

    runner.run_epoch(0, 8, NeverCancel(), lambda _packet: None)
    runner.run_epoch(1, 8, NeverCancel(), lambda _packet: None)
    result = runner.run_epoch(2, 8, NeverCancel(), lambda _packet: None)

    assert result.batches == 8
    assert dataset.gather_calls == 28
