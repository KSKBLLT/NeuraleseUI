from __future__ import annotations

from dataclasses import dataclass
from math import ceil, cos, isfinite, pi
from typing import Any, Mapping, Sequence

import numpy as np


_GRU_PARAMETER_PREFIXES = (
    "gru_w_zr_",
    "gru_u_zr_",
    "gru_b_zr_",
    "gru_w_n_",
    "gru_u_n_",
    "gru_b_n_",
)


@dataclass(frozen=True)
class FreezeStage:
    name: str
    start_epoch: int
    trainable_params: tuple[str, ...]


def _parameter_owner(name: str) -> str:
    value = str(name)
    for prefix in _GRU_PARAMETER_PREFIXES:
        if value.startswith(prefix):
            return value[len(prefix) :]
    if value.startswith(("w_", "b_")):
        return value[2:]
    return value


def parameter_groups(model: Any, trainable_params: Sequence[str]) -> list[tuple[str, ...]]:
    """Return trainable parameters grouped by their forward graph layer."""
    params = {str(value) for value in trainable_params}
    positions: dict[str, tuple[int, int]] = {}
    for node_index, node in enumerate(model.graph.node):
        for input_index, input_name in enumerate(node.input):
            name = str(input_name)
            if name in params and name not in positions:
                positions[name] = (node_index, input_index)

    grouped: dict[str, list[str]] = {}
    for name in params:
        grouped.setdefault(_parameter_owner(name), []).append(name)

    missing_position = len(model.graph.node) + 1

    def parameter_key(name: str) -> tuple[int, int, str]:
        node_index, input_index = positions.get(name, (missing_position, 0))
        return node_index, input_index, name

    ordered_groups = sorted(
        grouped.values(),
        key=lambda values: min(parameter_key(value) for value in values),
    )
    return [tuple(sorted(values, key=parameter_key)) for values in ordered_groups]


def freeze_schedule(
    groups: Sequence[Sequence[str]],
    epochs: int,
    *,
    enabled: bool = True,
    mode: str = "progressive",
    start: float = 0.15,
) -> tuple[FreezeStage, ...]:
    """When which layers stop learning.

    "progressive" (FreezeOut, Brock et al. 2017), for models of 4+ layers,
    freezes layers front to back: the first stops at `start` of the run (not
    before epoch 2), the next ones at even steps up to 75%, where only the head
    keeps learning ("head"). The first layers are the dearest to train (full
    resolution, and everything behind them needs their input gradient) and
    settle first. Freezing the first layer of a CIFAR CNN cut a step by a third.
    "suffix", and every model of 2-3 layers, where one layer is a large share
    of the model: all but the last two layers stop at 40%, all but the last at
    75% (40% with two layers).
    """
    normalized = [tuple(str(value) for value in group) for group in groups if group]
    full = tuple(value for group in normalized for value in group)
    stages = [FreezeStage("full", 0, full)]
    epochs = max(1, int(epochs))
    if not enabled or len(normalized) < 2 or epochs < 4:
        return tuple(stages)

    if mode == "progressive" and len(normalized) >= 4:
        # Deep enough for the first layers to be a small share of the model.
        # The head alone starts at 75% as before; the layers ahead of it
        # freeze one by one from `start`, never in the first two epochs.
        layers = len(normalized)
        head_begin = int(ceil(epochs * 0.75))
        for frozen in range(1, layers - 1):
            fraction = float(start) + (0.75 - float(start)) * (frozen - 1) / (layers - 2)
            begin = min(head_begin, max(2, int(ceil(epochs * fraction))))
            stages.append(FreezeStage(f"prefix{frozen}", begin, tuple(v for group in normalized[frozen:] for v in group)))
        stages.append(FreezeStage("head", head_begin, normalized[-1]))
        # Stages that would start on the same epoch: keep the most frozen one.
        kept: list[FreezeStage] = []
        for stage in stages:
            if kept and kept[-1].start_epoch == stage.start_epoch and kept[-1].name != "full":
                kept[-1] = stage
            else:
                kept.append(stage)
        return tuple(kept)

    if len(normalized) >= 3:
        stages.append(
            FreezeStage(
                "suffix2",
                int(ceil(epochs * 0.40)),
                tuple(value for group in normalized[-2:] for value in group),
            )
        )
    stages.append(
        FreezeStage(
            "head",
            int(ceil(epochs * (0.75 if len(normalized) >= 3 else 0.40))),
            normalized[-1],
        )
    )

    unique: list[FreezeStage] = []
    seen: set[tuple[str, ...]] = set()
    for stage in stages:
        if stage.trainable_params in seen:
            continue
        seen.add(stage.trainable_params)
        unique.append(stage)
    return tuple(unique)


def algorithmic_acceleration_eligible(
    groups: Sequence[Sequence[str]],
    *,
    epochs: int,
    samples: int,
    batch_size: int,
    minimum_batches: int = 8,
) -> bool:
    """Keep approximation out of short jobs where it cannot repay its quality cost."""
    available_batches = int(ceil(max(0, int(samples)) / max(1, int(batch_size))))
    return (
        any(group for group in groups)
        and int(epochs) >= 3
        and available_batches >= max(1, int(minimum_batches))
    )


def cosine_learning_rate(base: float, progress: float, floor: float = 0.05) -> float:
    """The learning rate `progress` (0..1) of the way through a run: cosine
    decay from `base` to `floor * base`. A short run then ends with small,
    careful steps instead of jumping around the minimum at full speed."""
    p = min(1.0, max(0.0, float(progress)))
    return float(base) * (floor + (1.0 - floor) * 0.5 * (1.0 + cos(pi * p)))


@dataclass(frozen=True)
class SelectiveBlockPolicy:
    keep_fraction: float = 0.80
    exploration_fraction: float = 0.15
    warmup_epochs: int = 2
    refresh_interval: int = 5
    # The kept share falls linearly from keep_fraction (after warm-up) to this
    # by the last selective epoch: late in a run most blocks are already easy.
    final_keep_fraction: float = 0.80

    def keep_share(self, epoch: int, epochs: int) -> float:
        first = max(0, int(self.warmup_epochs))
        last = max(first + 1, int(epochs) - 2)
        t = min(1.0, max(0.0, (int(epoch) - first) / max(1, last - first)))
        return float(self.keep_fraction) + (float(self.final_keep_fraction) - float(self.keep_fraction)) * t

    def select(
        self,
        epoch: int,
        epochs: int,
        losses: Mapping[int, float],
        rng: np.random.Generator,
    ) -> set[int]:
        available = sorted(int(block) for block in losses)
        all_blocks = set(available)
        if (
            not available
            or int(epoch) < max(0, int(self.warmup_epochs))
            or int(epoch) == max(1, int(epochs)) - 1
            or (
                int(self.refresh_interval) > 0
                and (int(epoch) + 1) % int(self.refresh_interval) == 0
            )
        ):
            return all_blocks

        # A block never trained yet (its loss unknown) must be measured.
        unknown = {block for block in available if not isfinite(float(losses[block]))}
        known = [block for block in available if block not in unknown]
        keep_count = min(
            len(available),
            max(1, int(ceil(len(available) * self.keep_share(epoch, epochs)))),
        )
        if len(unknown) >= keep_count or not known:
            return all_blocks
        available = known
        keep_count -= len(unknown)
        exploration_count = min(
            keep_count,
            max(0, int(ceil(len(available) * float(self.exploration_fraction)))),
        )
        hard_count = max(0, keep_count - exploration_count)
        ranked = sorted(
            available,
            key=lambda block: (
                -(float(losses[block]) if isfinite(float(losses[block])) else float("-inf")),
                block,
            ),
        )
        selected = set(ranked[:hard_count])
        candidates = np.asarray(
            [block for block in available if block not in selected], dtype=np.int64
        )
        if exploration_count > 0 and len(candidates) > 0:
            count = min(exploration_count, len(candidates))
            selected.update(
                int(value)
                for value in rng.choice(candidates, size=count, replace=False).tolist()
            )
        return selected | unknown
