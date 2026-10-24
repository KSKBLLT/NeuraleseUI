from __future__ import annotations

from dataclasses import dataclass
from time import perf_counter, process_time
from typing import Any, Callable

import numpy as np

from .batch_schedule import BatchSlice, PrePermutedEpochBuffer, make_schedule, select_schedule_policy
from .training_acceleration import SelectiveBlockPolicy


Emit = Callable[[dict[str, Any]], None]


class OrtValueBindingError(RuntimeError):
    pass


class OrtValueTrainingError(RuntimeError):
    pass


class RateLimitedProgress:
    def __init__(self, interval_s: float = 0.1) -> None:
        self.interval_s = max(0.0, float(interval_s))
        self._last_at: float | None = None

    def due(self, now: float, *, batch: int, batches: int) -> bool:
        forced = int(batch) == 1 or int(batch) == int(batches)
        ready = self._last_at is None or now - self._last_at >= self.interval_s
        if forced or ready:
            self._last_at = float(now)
            return True
        return False


def _array_binding_key(array: np.ndarray) -> tuple[Any, ...]:
    interface = array.__array_interface__
    return (
        int(interface["data"][0]),
        tuple(array.shape),
        tuple(array.strides),
        array.dtype.str,
    )


class BoundBatchInputs:
    """Keep CPU OrtValues bound to stable NumPy batch storage."""

    def __init__(self) -> None:
        self._values: dict[tuple[Any, ...], Any] = {}
        self._arrays: dict[tuple[Any, ...], np.ndarray] = {}

    def bind(self, x: np.ndarray, y: np.ndarray) -> tuple[Any, Any]:
        return self._bind_one(x), self._bind_one(y)

    @property
    def cache_size(self) -> int:
        return len(self._values)

    def _bind_one(self, array: np.ndarray) -> Any:
        import onnxruntime as ort

        key = _array_binding_key(array)
        value = self._values.get(key)
        if value is None:
            value = ort.OrtValue.ortvalue_from_numpy(array)
            self._values[key] = value
            self._arrays[key] = array
        return value


def loss_scalar(value: Any) -> float:
    if hasattr(value, "numpy"):
        value = value.numpy()
    return float(np.asarray(value).reshape(-1)[0])


@dataclass(frozen=True)
class EpochConfig:
    batch_size: int
    seed: int | None = None
    progress_interval_s: float = 0.1
    profile_breakdown: bool = False


@dataclass(frozen=True)
class EpochResult:
    average_loss: float
    batches: int
    train_seconds: float
    stopped: bool = False
    breakdown: dict[str, float] | None = None
    binding_failure: str = ""
    available_batches: int = 0
    coverage: float = 1.0


class EpochRunner:
    def __init__(
        self,
        dataset: Any,
        module: Any,
        optimizer: Any,
        *,
        batch_size: int | None = None,
        seed: int | None = None,
        config: EpochConfig | None = None,
        progress_interval_s: float = 0.1,
        clock: Callable[[], float] = perf_counter,
        batch_packet_observer: Callable[[], None] | None = None,
        epoch_buffer_budget_bytes: int = 512 * 1024 * 1024,
        use_ortvalue_inputs: bool = False,
        schedule_policy: str = "exact",
        selective_policy: SelectiveBlockPolicy | None = None,
        learning_rate_at: Callable[[int, int], float] | None = None,
    ) -> None:
        # learning_rate_at(batch index, batches this epoch) -> the step's rate;
        # the caller rebinds it each epoch. None keeps the optimizer's rate.
        self.learning_rate_at = learning_rate_at
        self.dataset = dataset
        self.module = module
        self.optimizer = optimizer
        config = config or EpochConfig(
            batch_size=128 if batch_size is None else int(batch_size),
            seed=seed,
            progress_interval_s=progress_interval_s,
        )
        self.config = config
        self.batch_size = max(1, int(config.batch_size))
        self.clock = clock
        self.progress_interval_s = max(0.0, float(config.progress_interval_s))
        self.batch_packet_observer = batch_packet_observer
        self._bound_inputs = BoundBatchInputs() if use_ortvalue_inputs else None
        self._binding_failure = ""
        self._rng = np.random.default_rng(config.seed) if config.seed is not None else None
        self._order = np.arange(len(dataset))
        available_batches = (len(dataset) + self.batch_size - 1) // self.batch_size
        self.selective_policy = (
            selective_policy if selective_policy is not None and available_batches >= 8 else None
        )
        self.schedule_policy = "blocks" if self.selective_policy is not None else (
            select_schedule_policy(dataset, self.batch_size)
            if str(schedule_policy) == "auto"
            else str(schedule_policy)
        )
        self._schedule = make_schedule(self.schedule_policy, len(dataset), self.batch_size)
        self.block_losses: dict[int, float] = {
            block: float("nan") for block in range(available_batches)
        }
        self._x_buffer = np.empty(
            (self.batch_size, *dataset.x.shape[1:]), dtype=np.float32
        )
        self._y_buffer = np.empty(
            (self.batch_size, *dataset.y.shape[1:]), dtype=dataset.y.dtype
        )
        required_epoch_bytes = (
            len(dataset) * int(np.prod(dataset.x.shape[1:])) * np.dtype(np.float32).itemsize
            + int(dataset.y.nbytes)
        )
        self._epoch_buffer = (
            PrePermutedEpochBuffer(dataset, batch_size=self.batch_size)
            if self.schedule_policy == "prepermuted"
            and required_epoch_bytes <= max(0, int(epoch_buffer_budget_bytes))
            else None
        )
        if self.schedule_policy == "prepermuted" and self._epoch_buffer is None:
            self.schedule_policy = "exact"
            self._schedule = make_schedule("exact", len(dataset), self.batch_size)

    def run_epoch(
        self,
        epoch: int,
        epochs: int,
        cancel: Any,
        emit: Emit,
        on_first_step: Callable[[], None] | None = None,
    ) -> EpochResult:
        started = self.clock()
        cpu_started = process_time()
        self.module.train()
        rng = self._rng if self._rng is not None else np.random

        available_batches = (len(self.dataset) + self.batch_size - 1) // self.batch_size
        epoch_loss = 0.0
        batches = 0
        first_step_pending = on_first_step is not None
        progress = RateLimitedProgress(self.progress_interval_s)

        if self._epoch_buffer is not None:
            rng.shuffle(self._order)
            self._epoch_buffer.prepare(self._order)
            selected_descriptors = list(enumerate(self._epoch_buffer.batches()))
            read_batch = None
        else:
            selected_descriptors = self._scheduled_batches(rng, epoch, epochs)
            read_batch = self._read_batch
        total_batches = len(selected_descriptors)
        coverage = total_batches / max(1, available_batches)

        for block_id, planned in selected_descriptors:
            if bool(getattr(cancel, "closed", False)):
                return EpochResult(
                    average_loss=epoch_loss / max(1, batches),
                    batches=batches,
                    train_seconds=self.clock() - started,
                    stopped=True,
                    breakdown={
                        "batch_loop_seconds": self.clock() - started,
                        "process_cpu_seconds": process_time() - cpu_started,
                    },
                    binding_failure=self._binding_failure,
                    available_batches=available_batches,
                    coverage=coverage,
                )
            # A planned batch is read only now: the shared batch buffers hold
            # one batch at a time, so reading the whole plan first would leave
            # every entry showing the last batch.
            bx, by = planned if read_batch is None else read_batch(planned)
            self.module.lazy_reset_grad()
            using_bound_inputs = self._bound_inputs is not None
            if using_bound_inputs:
                try:
                    inputs = self._bound_inputs.bind(bx, by)
                except Exception as exc:
                    if batches > 0:
                        raise OrtValueBindingError(
                            f"OrtValue binding failed after {batches} optimizer steps: {exc}"
                        ) from exc
                    self._binding_failure = f"{type(exc).__name__}: {exc}"
                    self._bound_inputs = None
                    using_bound_inputs = False
                    inputs = (bx, by)
            else:
                inputs = (bx, by)
            try:
                outputs = self.module(*inputs)
            except Exception as exc:
                if using_bound_inputs:
                    raise OrtValueTrainingError(
                        f"OrtValue training call failed; optimizer step was not replayed: {exc}"
                    ) from exc
                raise
            loss = outputs[0] if isinstance(outputs, (tuple, list)) else outputs
            loss_value = loss_scalar(loss)
            if first_step_pending:
                on_first_step()
                first_step_pending = False
            if self.learning_rate_at is not None:
                set_rate = getattr(self.optimizer, "set_learning_rate", None)
                if callable(set_rate):
                    set_rate(float(self.learning_rate_at(batches, total_batches)))
            self.optimizer.step()
            epoch_loss += loss_value
            if self.selective_policy is not None:
                self.block_losses[int(block_id)] = loss_value
            batches += 1

            now = self.clock()
            if progress.due(now, batch=batches, batches=total_batches):
                if self.batch_packet_observer is not None:
                    self.batch_packet_observer()
                emit({
                    "phase": "progress",
                    "data": {
                        "stage": "batch",
                        "epoch_elapsed_seconds": now-started,
                        "epoch": int(epoch),
                        "epochs": int(epochs),
                        "left": int(epochs) - int(epoch),
                        "batch": batches,
                        "batches": total_batches,
                        "available_batches": available_batches,
                        "coverage": coverage,
                        "train_loss_so_far": epoch_loss / batches,
                    },
                })

        elapsed = self.clock() - started
        return EpochResult(
            average_loss=epoch_loss / max(1, batches),
            batches=batches,
            train_seconds=elapsed,
            breakdown={
                "batch_loop_seconds": elapsed,
                "process_cpu_seconds": process_time() - cpu_started,
            },
            binding_failure=self._binding_failure,
            available_batches=available_batches,
            coverage=coverage,
        )

    def _scheduled_batches(self, rng, epoch: int, epochs: int):
        """This epoch's (block id, batch descriptor) pairs, in training order."""
        descriptors = self._schedule.descriptors(rng)
        selected: set[int] | None = None
        if self.selective_policy is not None:
            selected = self.selective_policy.select(
                epoch,
                epochs,
                self.block_losses,
                rng,
            )
        result = []
        for descriptor_index, descriptor in enumerate(descriptors):
            block_id = (
                int(descriptor.start // self.batch_size)
                if isinstance(descriptor, BatchSlice)
                else descriptor_index
            )
            if selected is not None and block_id not in selected:
                continue
            result.append((block_id, descriptor))
        return result

    def _read_batch(self, descriptor):
        if isinstance(descriptor, BatchSlice):
            if bool(getattr(self.dataset, "materialize_x", False)):
                return self.dataset.batch_view(descriptor.start, descriptor.stop)
            indices = np.arange(descriptor.start, descriptor.stop, dtype=np.int64)
        else:
            indices = descriptor.indices
        count = len(indices)
        return self.dataset.batch_indices(indices, self._x_buffer[:count], self._y_buffer[:count])
