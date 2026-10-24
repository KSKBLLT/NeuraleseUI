from __future__ import annotations

from types import SimpleNamespace

import numpy as np
import pytest

from neuralese_local.dataset_store import ArrayDataset
from neuralese_local import training_profile
from neuralese_local.training_profile import (
    WorkloadEstimate,
    SessionProfile,
    build_session_options,
    estimate_workload,
    select_profile,
    select_batch_candidates,
    select_calibrated_batch,
    select_calibrated_training_profile,
    calibration_is_stable,
    interleaved_calibration_order,
    SESSION_OPTION_VARIANTS,
    session_option_settings,
)


def _model():
    weight = SimpleNamespace(name="weight", dims=[4, 8])
    node = SimpleNamespace(op_type="Gemm", input=["input", "weight"])
    return SimpleNamespace(graph=SimpleNamespace(initializer=[weight], node=[node]))


def _conv_model():
    weight = SimpleNamespace(name="conv_weight", dims=[4, 1, 3, 3])
    node = SimpleNamespace(op_type="Conv", input=["input", "conv_weight"])
    return SimpleNamespace(graph=SimpleNamespace(initializer=[weight], node=[node]))


def test_profile_is_independent_of_dataset_name():
    x = np.zeros((100, 4), dtype=np.float32)
    y = np.zeros((100,), dtype=np.int64)
    first = estimate_workload(ArrayDataset("iris", x, y), _model())
    second = estimate_workload(ArrayDataset("anything-user-named", x, y), _model())

    assert first == second
    assert select_profile(first) == select_profile(second)


def test_tiny_profile_uses_one_sequential_thread():
    profile = select_profile(WorkloadEstimate(20, 16, 100, 2_000, 1))
    options = build_session_options(profile)

    assert profile.name == "tiny"
    assert options.intra_op_num_threads == 1
    assert options.inter_op_num_threads == 1
    assert options.execution_mode.name == "ORT_SEQUENTIAL"
    assert options.graph_optimization_level.name == "ORT_ENABLE_ALL"
    assert options.enable_mem_pattern is True
    assert options.enable_cpu_mem_arena is True


def test_fixed_batch_profiles_are_selected_from_workload_not_dataset_name(monkeypatch):
    monkeypatch.setattr("neuralese_local.training_profile.os.cpu_count", lambda: 8)
    select_fixed_batch_size = training_profile.select_fixed_batch_size

    tiny = WorkloadEstimate(120, 16, 100, 2_000, 1)
    tabular = WorkloadEstimate(5_400, 32, 1_000, 100_000_000, 3)
    image_dense = WorkloadEstimate(60_000, 3_136, 20_000, 2_000_000_000, 2)
    image_conv = estimate_workload(
        ArrayDataset(
            "not-mnist",
            np.zeros((600, 1, 28, 28), dtype=np.float32),
            np.zeros((600,), dtype=np.int64),
        ),
        _conv_model(),
    )

    assert select_fixed_batch_size(tiny) == 120
    assert select_fixed_batch_size(tabular) == 512
    assert select_fixed_batch_size(image_dense) == 256
    assert select_fixed_batch_size(image_conv) == 128
    assert select_profile(tiny).intra_op_threads == 1
    assert select_profile(tabular).intra_op_threads == 1
    assert select_profile(image_dense).intra_op_threads == 2
    # Two threads at most for anything (school computers).
    assert select_profile(image_conv).intra_op_threads == 2


def test_explicit_batch_bypasses_fixed_default():
    estimate = WorkloadEstimate(60_000, 3_136, 20_000, 2_000_000_000, 2)

    assert training_profile.select_fixed_batch_size(estimate, explicit_batch_size=96) == 96


def test_batch_candidates_depend_on_workload_not_dataset_name():
    first = ArrayDataset("mnist", np.zeros((600, 8), np.float32), np.zeros(600, np.int64))
    second = ArrayDataset("renamed", first.x.copy(), first.y.copy())
    estimate = WorkloadEstimate(600, 32, 1000, 5_000_000, 2)

    assert select_batch_candidates(estimate, first) == select_batch_candidates(estimate, second)
    assert select_batch_candidates(estimate, first) == [64, 128, 256, 512]


def test_calibrated_batch_compares_projected_epoch_time_and_requires_margin():
    candidates = [128, 256, 512]
    timings = {
        128: [0.0010, 0.0011, 0.0009],
        256: [0.0017, 0.0016, 0.0018],
        512: [0.0036, 0.0035, 0.0037],
    }

    selected = select_calibrated_batch(60_000, candidates, timings, baseline=128)

    assert selected == 256


def test_calibrated_batch_keeps_baseline_when_gain_is_noise():
    timings = {128: [0.0010, 0.0010, 0.0010], 256: [0.0019, 0.0019, 0.0019]}

    assert select_calibrated_batch(60_000, [128, 256], timings, baseline=128) == 128


def test_training_profile_selects_batch_and_threads_from_projected_epoch_cost():
    timings = {
        (1, 128): [0.0010, 0.0010, 0.0010],
        (2, 128): [0.0008, 0.0008, 0.0008],
        (1, 256): [0.0017, 0.0017, 0.0017],
        (2, 256): [0.0013, 0.0013, 0.0013],
    }

    assert select_calibrated_training_profile(
        60_000, timings, baseline=(1, 128)
    ) == (2, 256)


def test_calibration_order_alternates_forward_and_reverse():
    candidates = [(1, 128), (2, 128), (1, 256)]

    assert interleaved_calibration_order(candidates, 2) == [
        (1, 128), (2, 128), (1, 256),
        (1, 256), (2, 128), (1, 128),
    ]


def test_calibration_rejects_normalized_runtime_drift():
    stable = [((1, 128), 1.0), ((2, 128), 0.8), ((2, 128), 0.82), ((1, 128), 1.01)]
    drifting = [((1, 128), 0.7), ((2, 128), 0.5), ((2, 128), 1.1), ((1, 128), 1.4)]

    assert calibration_is_stable(stable)
    assert not calibration_is_stable(drifting)


def test_candidate_memory_budget_includes_model_training_state():
    dataset = ArrayDataset("x", np.zeros((1000, 8), np.float32), np.zeros(1000, np.int64))
    estimate = WorkloadEstimate(1000, 32, 1_000_000, 1, 1)

    assert select_batch_candidates(estimate, dataset, memory_budget_bytes=8_000_000) == [128]


def test_training_thread_tie_prefers_one_thread():
    timings = {
        (4, 128): [0.001, 0.001, 0.001],
        (2, 128): [0.001, 0.001, 0.001],
        (1, 128): [0.001, 0.001, 0.001],
    }

    assert select_calibrated_training_profile(
        1000, timings, baseline=(1, 128), minimum_gain=0.0
    ) == (1, 128)


@pytest.mark.parametrize("variant", tuple(SESSION_OPTION_VARIANTS))
def test_session_option_variants_set_every_relevant_field(variant):
    profile = SessionProfile("test", 2)
    settings = session_option_settings(variant)
    options = build_session_options(profile, variant)

    expected_level = {
        "disabled": "ORT_DISABLE_ALL",
        "basic": "ORT_ENABLE_BASIC",
        "extended": "ORT_ENABLE_EXTENDED",
        "all": "ORT_ENABLE_ALL",
    }[settings["graph_optimization"]]
    assert options.execution_mode.name == "ORT_SEQUENTIAL"
    assert options.inter_op_num_threads == 1
    assert options.intra_op_num_threads == 2
    assert options.graph_optimization_level.name == expected_level
    assert options.enable_mem_pattern is settings["memory_pattern"]
    assert options.enable_cpu_mem_arena is settings["cpu_arena"]
    expected_spinning = "1" if settings["spinning"] else "0"
    assert options.get_session_config_entry("session.intra_op.allow_spinning") == expected_spinning
    assert options.get_session_config_entry("session.inter_op.allow_spinning") == expected_spinning


def test_unknown_session_option_variant_is_rejected():
    with pytest.raises(ValueError, match="unknown training SessionOptions"):
        build_session_options(SessionProfile("test", 1), "mystery")
