from __future__ import annotations

import math
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))
from training_benchmark_scenarios import RUNTIME_ROOT, SCENARIOS, scenario_request

from neuralese_local.prepared_training import PreparedSession
from neuralese_local.training_artifact_cache import ArtifactCache
from neuralese_local.training_dataset_cache import TrainingDatasetCache


class NeverCancel:
    closed = False

    def on_kill(self, _callback):
        return


def _train_once(
    tmp_path: Path,
    scenario: str,
    schedule_policy: str,
    batch_size: int = 128,
    *,
    epochs: int = 2,
    algorithmic_acceleration: bool = False,
) -> dict:
    mode = "accelerated" if algorithmic_acceleration else "full"
    root = tmp_path / f"{schedule_policy}-{mode}"
    request = scenario_request(
        scenario,
        root,
        epochs=epochs,
        batch_size=batch_size,
        seed=29,
        artifact_cache=tmp_path / "artifacts",
    )
    request["schedule_policy"] = schedule_policy
    request["algorithmic_acceleration"] = algorithmic_acceleration
    events = []
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(RUNTIME_ROOT),
        ArtifactCache(tmp_path / "artifacts"),
    )
    result = prepared.start(request, events.append, NeverCancel())
    states = [packet["data"]["data"] for packet in events if packet.get("phase") == "state"]
    assert result["status"] == "ok"
    assert states
    return states[-1]


@pytest.mark.parametrize("scenario", tuple(SCENARIOS))
def test_automatic_schedule_preserves_fixed_budget_learning_quality(tmp_path, scenario):
    exact = _train_once(tmp_path / scenario, scenario, "exact")
    candidate = _train_once(tmp_path / scenario, scenario, "auto")

    assert math.isfinite(float(exact["train_loss"]))
    assert math.isfinite(float(candidate["train_loss"]))
    scale = max(abs(float(exact["train_loss"])), 1e-6)
    assert abs(float(candidate["train_loss"]) - float(exact["train_loss"])) / scale <= 0.25
    assert abs(float(candidate.get("val_acc", 0.0)) - float(exact.get("val_acc", 0.0))) <= 0.12


@pytest.mark.parametrize("scenario", ["car_dense", "mnist_mlp", "mnist_conv"])
def test_automatic_batch_profile_preserves_fixed_budget_quality(tmp_path, scenario):
    baseline = _train_once(tmp_path / "baseline", scenario, "auto", 128)
    automatic = _train_once(tmp_path / "automatic", scenario, "auto", 0)

    assert math.isfinite(float(automatic["train_loss"]))
    scale = max(abs(float(baseline["train_loss"])), 1e-6)
    assert abs(float(automatic["train_loss"]) - float(baseline["train_loss"])) / scale <= 0.35
    assert abs(float(automatic.get("val_acc", 0.0)) - float(baseline.get("val_acc", 0.0))) <= 0.15


@pytest.mark.parametrize("scenario", tuple(SCENARIOS))
def test_algorithmic_acceleration_stays_within_quality_budget(tmp_path, scenario):
    baseline = _train_once(
        tmp_path / scenario,
        scenario,
        "auto",
        128,
        epochs=6,
        algorithmic_acceleration=False,
    )
    accelerated = _train_once(
        tmp_path / scenario,
        scenario,
        "auto",
        128,
        epochs=6,
        algorithmic_acceleration=True,
    )

    baseline_loss = float(baseline["val_loss"])
    accelerated_loss = float(accelerated["val_loss"])
    loss_scale = max(abs(baseline_loss), 1e-6)
    assert abs(accelerated_loss - baseline_loss) / loss_scale <= 0.35
    assert (
        abs(float(accelerated.get("val_acc", 0.0)) - float(baseline.get("val_acc", 0.0)))
        <= 0.15
    )
