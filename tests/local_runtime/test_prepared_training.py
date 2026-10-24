from __future__ import annotations

from pathlib import Path

import numpy as np
import pytest

from neuralese_local.prepared_training import PreparedSession, StalePreparedSessionError
from neuralese_local.training_artifact_cache import ArtifactCache
from neuralese_local.training_dataset_cache import TrainingDatasetCache


class NeverCancel:
    closed = False

    def on_kill(self, _callback):
        return


def _graph():
    return {
        "nodes": {
            "input": {"type": "InputNode", "data": {"shape": 4}},
            "hidden": {"type": "NeuronLayer", "data": {"units": 5, "activation": "relu"}},
            "output": {"type": "NeuronLayer", "data": {"units": 3, "activation": "none"}},
        },
        "connections": [
            {"from_node": "input", "from_port": "input_out", "to_node": "hidden", "to_port": "layer_in"},
            {"from_node": "hidden", "from_port": "layer_out", "to_node": "output", "to_port": "layer_in"},
        ],
    }


def _request(tmp_path: Path):
    runtime_root = Path(__file__).resolve().parents[2] / "local_runtime"
    return {
        "graph": _graph(),
        "graph_generation": 3,
        "train_graph": {"pages": {"0": {
            "train": {"type": "TrainInput", "props": {"config": {
                "optimizer": "adam", "loss": "cross_entropy", "lr": 0.001,
            }}},
        }}},
        "epochs": 1,
        "batch_size": 128,
        "runtime_root": str(runtime_root),
        "job_dir": str(tmp_path / "job"),
        "checkpoint_dir": str(tmp_path / "checkpoint"),
        "dataset_ref": {"kind": "builtin_numpy", "name": "iris"},
        "initialization_seed": 17,
    }


def _prepare(tmp_path):
    request = _request(tmp_path)
    datasets = TrainingDatasetCache(request["runtime_root"])
    artifacts = ArtifactCache(tmp_path / "artifacts")
    return PreparedSession.prepare(request, datasets, artifacts)


def test_prepare_once_start_and_fresh_reset(tmp_path):
    prepared = _prepare(tmp_path)
    initial = prepared.initial_snapshot()

    result = prepared.start(
        {"graph_generation": 3, "epochs": 1, "seed": 17},
        lambda _packet: None,
        NeverCancel(),
    )

    assert result["status"] == "ok"
    assert not np.allclose(prepared.parameter_snapshot(), initial)

    prepared.reset_fresh(17)
    np.testing.assert_allclose(prepared.parameter_snapshot(), initial)
    assert prepared.optimizer_state_is_resumed is False


def test_second_fresh_start_does_not_continue_previous_optimizer_state(tmp_path):
    prepared = _prepare(tmp_path)
    first = prepared.start(
        {"graph_generation": 3, "epochs": 1, "seed": 17},
        lambda _packet: None,
        NeverCancel(),
    )
    first_weights = prepared.parameter_snapshot()
    second = prepared.start(
        {"graph_generation": 3, "epochs": 1, "seed": 17},
        lambda _packet: None,
        NeverCancel(),
    )

    assert first["status"] == second["status"] == "ok"
    np.testing.assert_allclose(prepared.parameter_snapshot(), first_weights, rtol=1e-5, atol=1e-6)


def test_start_rejects_stale_graph_generation(tmp_path):
    prepared = _prepare(tmp_path)

    with pytest.raises(StalePreparedSessionError):
        prepared.start(
            {"graph_generation": 2, "epochs": 1},
            lambda _packet: None,
            NeverCancel(),
        )


def test_start_applies_nonstructural_learning_rate_change(tmp_path):
    prepared = _prepare(tmp_path)
    updated_train_graph = _request(tmp_path)["train_graph"]
    updated_train_graph["pages"]["0"]["train"]["props"]["config"]["lr"] = 0.0005

    result = prepared.start(
        {
            "graph_generation": 3,
            "epochs": 1,
            "seed": 17,
            "train_graph": updated_train_graph,
        },
        lambda _packet: None,
        NeverCancel(),
    )

    assert result["status"] == "ok"
    assert prepared.learning_rate == pytest.approx(0.0005)


def test_resume_is_explicit(tmp_path):
    prepared = _prepare(tmp_path)
    result = prepared.start(
        {"graph_generation": 3, "epochs": 1, "seed": 17},
        lambda _packet: None,
        NeverCancel(),
    )
    trained = prepared.parameter_snapshot()

    prepared.load_resume_checkpoint(Path(result["checkpoint_dir"]) / "checkpoint")

    assert prepared.optimizer_state_is_resumed is True
    np.testing.assert_allclose(prepared.parameter_snapshot(), trained, rtol=1e-5, atol=1e-6)


def test_prepare_uses_fixed_profile_and_creates_runtime_once(monkeypatch, tmp_path):
    request = _request(tmp_path)
    request["batch_size"] = 0
    calls = 0
    original = PreparedSession._create_runtime

    def count_runtime_creation(self, *args, **kwargs):
        nonlocal calls
        calls += 1
        return original(self, *args, **kwargs)

    monkeypatch.setattr(PreparedSession, "_create_runtime", count_runtime_creation)
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )

    assert calls == 1
    assert prepared.auto_batch_size == 120
    assert prepared.session_profile.intra_op_threads == 1
    assert prepared.batch_calibration == {
        "strategy": "fixed",
        "explicit": False,
        "selected": 120,
        "selected_threads": 1,
    }
    assert not (tmp_path / "epoch_batch_profiles.json").exists()


def test_explicit_batch_is_never_overridden(tmp_path):
    request = _request(tmp_path)
    request["batch_size"] = 64
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )
    assert prepared.batch_calibration["explicit"] is True
    assert prepared.batch_calibration["selected"] == 64
    assert prepared.session_profile.intra_op_threads == 1
    assert not (tmp_path / "epoch_batch_profiles.json").exists()


def test_production_prepare_ignores_experimental_session_option(tmp_path):
    request = _request(tmp_path)
    request["session_option_variant"] = "spinning"

    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )

    assert prepared.session_option_variant == "safe"


def test_prepare_builds_distinct_progressive_freeze_artifacts(tmp_path):
    request = _request(tmp_path)
    request["epochs"] = 5
    request["batch_size"] = 16
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )

    assert [stage.name for stage in prepared.freeze_stages] == ["full", "head"]
    assert set(prepared.artifact_entries) == {"full", "head"}
    assert prepared.artifact_entries["full"].key != prepared.artifact_entries["head"].key
    assert prepared.active_freeze_stage.name == "full"


def test_progressive_freeze_switch_preserves_every_model_parameter(tmp_path):
    request = _request(tmp_path)
    request["epochs"] = 5
    request["batch_size"] = 16
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )
    prepared.start(
        {"graph_generation": 3, "epochs": 1, "seed": 17},
        lambda _packet: None,
        NeverCancel(),
    )
    trained = prepared.parameter_snapshot()
    events = []

    assert prepared._switch_freeze_stage(prepared.freeze_stages[-1], events.append)

    np.testing.assert_allclose(prepared.parameter_snapshot(), trained, rtol=1e-6, atol=1e-7)
    assert prepared.active_freeze_stage.name == "head"
    assert any(packet.get("data", {}).get("stage") == "freeze_stage" for packet in events)


def test_algorithmic_acceleration_can_be_disabled_without_extra_artifacts(tmp_path):
    request = _request(tmp_path)
    request["epochs"] = 8
    request["algorithmic_acceleration"] = False
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )

    assert [stage.name for stage in prepared.freeze_stages] == ["full"]
    assert set(prepared.artifact_entries) == {"full"}


def test_training_switches_to_progressive_freeze_stage_at_epoch_boundary(tmp_path):
    request = _request(tmp_path)
    request["epochs"] = 5
    request["batch_size"] = 16
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )
    events = []

    result = prepared.start(
        {"graph_generation": 3, "epochs": 5, "seed": 17},
        events.append,
        NeverCancel(),
    )

    assert result["status"] == "ok"
    assert prepared.active_freeze_stage.name == "head"
    assert any(
        packet.get("data", {}).get("stage") == "freeze_stage"
        and packet.get("data", {}).get("freeze_stage") == "head"
        for packet in events
    )
    epoch_states = [
        packet["data"]["data"]
        for packet in events
        if packet.get("phase") == "state"
    ]
    assert [state["freeze_stage"] for state in epoch_states] == [
        "full",
        "full",
        "head",
        "head",
        "head",
    ]
    assert result["optimizer_state_resets"] == 1
    assert [stage["name"] for stage in result["freeze_schedule"]] == ["full", "head"]


def test_acceleration_follows_the_run_epochs_not_the_prepared_ones(tmp_path):
    # The app prepares a session once (its fingerprint leaves epochs out) and
    # starts it with the epochs the child picked; acceleration used to be
    # decided at prepare time, where the app's job says 1 epoch, so it never ran.
    request = _request(tmp_path)
    request["epochs"] = 1
    request["batch_size"] = 16
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )
    events = []

    result = prepared.start({"graph_generation": 3, "epochs": 5, "seed": 17}, events.append, NeverCancel())

    assert result["status"] == "ok"
    assert result["algorithmic_acceleration"] is True
    stages = [p["data"]["data"]["freeze_stage"] for p in events if p.get("phase") == "state"]
    assert stages == ["full", "full", "head", "head", "head"]

    short = prepared.start({"graph_generation": 3, "epochs": 2, "seed": 17}, events.append, NeverCancel())
    assert short["algorithmic_acceleration"] is False


def test_failed_freeze_switch_keeps_current_runtime_and_weights(monkeypatch, tmp_path):
    request = _request(tmp_path)
    request["epochs"] = 5
    request["batch_size"] = 16
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )
    original_state = prepared.state
    original_module = prepared.module
    original_optimizer = prepared.optimizer
    original_parameters = prepared.parameter_snapshot()
    events = []

    def fail_runtime_build(_artifact_entry, _checkpoint):
        raise RuntimeError("unsupported transfer")

    monkeypatch.setattr(prepared, "_build_runtime", fail_runtime_build)

    assert not prepared._switch_freeze_stage(prepared.freeze_stages[-1], events.append)
    assert prepared.state is original_state
    assert prepared.module is original_module
    assert prepared.optimizer is original_optimizer
    np.testing.assert_allclose(prepared.parameter_snapshot(), original_parameters)
    assert prepared.active_freeze_stage.name == "full"
    assert any(
        packet.get("data", {}).get("stage") == "freeze_stage_fallback"
        for packet in events
    )
