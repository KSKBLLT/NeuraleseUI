from __future__ import annotations

import json
import os
import platform
import statistics
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any, Mapping

import numpy as np


@dataclass(frozen=True)
class WorkloadEstimate:
    samples: int
    bytes_per_sample: int
    parameters: int
    macs_per_epoch: int
    heavy_ops: int
    conv_ops: int = 0


@dataclass(frozen=True)
class SessionProfile:
    name: str
    intra_op_threads: int
    inter_op_threads: int = 1
    sequential: bool = True
    allow_spinning: bool = False


@dataclass(frozen=True)
class BatchProfile:
    explicit: bool
    selected: int
    selected_threads: int
    candidates: tuple[int, ...]
    memory_limit_bytes: int
    timings: Mapping[str, tuple[float, ...]]
    stable: bool = True


SESSION_OPTION_VARIANTS: dict[str, dict[str, Any]] = {
    "safe": {
        "graph_optimization": "all",
        "memory_pattern": True,
        "cpu_arena": True,
        "spinning": False,
    },
    "basic_optimizations": {
        "graph_optimization": "basic",
        "memory_pattern": True,
        "cpu_arena": True,
        "spinning": False,
    },
    "no_memory_pattern": {
        "graph_optimization": "all",
        "memory_pattern": False,
        "cpu_arena": True,
        "spinning": False,
    },
    "no_cpu_arena": {
        "graph_optimization": "all",
        "memory_pattern": True,
        "cpu_arena": False,
        "spinning": False,
    },
    "spinning": {
        "graph_optimization": "all",
        "memory_pattern": True,
        "cpu_arena": True,
        "spinning": True,
    },
}


def session_option_settings(name: str) -> dict[str, Any]:
    if name not in SESSION_OPTION_VARIANTS:
        raise ValueError(f"unknown training SessionOptions variant '{name}'")
    return dict(SESSION_OPTION_VARIANTS[name])


def estimate_workload(dataset: Any, model: Any) -> WorkloadEstimate:
    samples = max(0, int(len(dataset)))
    x = np.asarray(dataset.x)
    # What a sample takes in a training batch (float32), whatever it is stored as.
    bytes_per_sample = int(np.prod(x.shape[1:])) * 4 if samples and x.ndim else 4
    parameters = 0
    heavy_ops = 0
    conv_ops = 0
    macs_per_sample = 0
    initializers = {item.name: item for item in getattr(model.graph, "initializer", [])}
    for initializer in initializers.values():
        size = 1
        for dim in initializer.dims:
            size *= int(dim)
        parameters += size
    for node in getattr(model.graph, "node", []):
        op_type = str(node.op_type)
        if op_type in {"Gemm", "MatMul", "Conv"}:
            heavy_ops += 1
        if op_type == "Conv":
            conv_ops += 1
        if op_type in {"Gemm", "MatMul"} and len(node.input) >= 2:
            weight = initializers.get(node.input[1])
            if weight is not None and len(weight.dims) >= 2:
                macs_per_sample += int(np.prod(weight.dims))
        elif op_type == "Conv" and len(node.input) >= 2:
            weight = initializers.get(node.input[1])
            if weight is not None:
                spatial_positions = int(np.prod(x.shape[2:])) if x.ndim > 2 else 1
                macs_per_sample += int(np.prod(weight.dims)) * max(1, spatial_positions)
    if macs_per_sample <= 0:
        macs_per_sample = max(1, parameters)
    return WorkloadEstimate(
        samples=samples,
        bytes_per_sample=bytes_per_sample,
        parameters=parameters,
        macs_per_epoch=macs_per_sample * samples,
        heavy_ops=heavy_ops,
        conv_ops=conv_ops,
    )


def select_profile(
    estimate: WorkloadEstimate,
    calibration: Mapping[str, Any] | None = None,
) -> SessionProfile:
    available = max(1, int(os.cpu_count() or 1))
    if estimate.conv_ops > 0:
        # Two threads at most: school computers have at least two cores, and the
        # app must leave the rest of the machine usable.
        return SessionProfile("conv", min(2, available))
    if estimate.macs_per_epoch <= 20_000_000 and estimate.parameters <= 100_000:
        return SessionProfile("tiny", 1)
    if estimate.bytes_per_sample >= 1024:
        return SessionProfile("image_dense", min(2, available))
    return SessionProfile("tabular", 1)


def select_fixed_batch_size(
    estimate: WorkloadEstimate,
    *,
    explicit_batch_size: int | None = None,
) -> int:
    """Choose the production batch without executing trial TrainSteps."""
    if explicit_batch_size is not None and int(explicit_batch_size) > 0:
        return int(explicit_batch_size)

    samples = max(1, int(estimate.samples))
    if samples <= 128:
        return samples
    if estimate.conv_ops > 0:
        return min(128, samples)
    if estimate.bytes_per_sample >= 1024:
        return min(256, samples)
    if samples >= 2048:
        return min(512, samples)
    return min(128, samples)


def select_batch_candidates(
    estimate: WorkloadEstimate,
    dataset: Any,
    memory_budget_bytes: int = 256 * 1024 * 1024,
) -> list[int]:
    samples = max(1, int(len(dataset)))
    per_sample = max(1, int(estimate.bytes_per_sample))
    fixed_training_bytes = max(0, int(getattr(estimate, "parameters", 0))) * 16
    candidates: list[int] = []
    for candidate in (64, 128, 256, 512):
        if candidate > samples:
            continue
        # The fixed-budget quality matrix accepts 256 but not 512 for large
        # image tensors. Keep the larger candidate for cheap tabular work.
        if per_sample >= 1024 and candidate > 256:
            continue
        # Training activations and gradients normally require several times
        # the raw input footprint. Keep calibration candidates conservative.
        if fixed_training_bytes + per_sample * candidate * 8 > max(1, int(memory_budget_bytes)):
            continue
        candidates.append(candidate)
    if samples < 64:
        candidates.append(samples)
    elif not candidates:
        candidates.append(min(128, samples))
    return sorted(set(candidates))


def select_calibrated_batch(
    samples: int,
    candidates: list[int],
    timings: Mapping[int, list[float]],
    *,
    baseline: int = 128,
    minimum_gain: float = 0.05,
) -> int:
    projected: dict[int, float] = {}
    for candidate in candidates:
        values = [float(value) for value in timings.get(candidate, []) if value > 0.0]
        if values:
            batches = (max(1, int(samples)) + candidate - 1) // candidate
            projected[candidate] = statistics.median(values) * batches
    if not projected:
        return int(baseline)
    baseline_candidate = baseline if baseline in projected else min(projected)
    winner = min(projected, key=projected.get)
    if winner == baseline_candidate:
        return int(winner)
    required = projected[baseline_candidate] * (1.0 - max(0.0, float(minimum_gain)))
    return int(winner if projected[winner] < required else baseline_candidate)


def select_calibrated_training_profile(
    samples: int,
    timings: Mapping[tuple[int, int], list[float]],
    *,
    baseline: tuple[int, int] = (1, 128),
    minimum_gain: float = 0.05,
) -> tuple[int, int]:
    projected: dict[tuple[int, int], float] = {}
    for (threads, batch_size), raw_values in timings.items():
        values = [float(value) for value in raw_values if value > 0.0]
        if values:
            batches = (max(1, int(samples)) + int(batch_size) - 1) // int(batch_size)
            projected[(int(threads), int(batch_size))] = statistics.median(values) * batches
    if not projected:
        return baseline
    baseline_candidate = baseline if baseline in projected else min(projected)
    winner = min(projected, key=lambda item: (projected[item], item[0], item[1]))
    if winner == baseline_candidate:
        return winner
    required = projected[baseline_candidate] * (1.0 - max(0.0, float(minimum_gain)))
    return winner if projected[winner] < required else baseline_candidate


def interleaved_calibration_order(
    candidates: list[tuple[int, int]], repetitions: int = 2
) -> list[tuple[int, int]]:
    ordered = list(candidates)
    result: list[tuple[int, int]] = []
    for repetition in range(max(1, int(repetitions))):
        result.extend(ordered if repetition % 2 == 0 else reversed(ordered))
    return result


def calibration_is_stable(
    observations: list[tuple[tuple[int, int], float]],
    *,
    maximum_normalized_drift: float = 0.20,
) -> bool:
    if len(observations) < 4:
        return True
    medians: dict[tuple[int, int], float] = {}
    for candidate, _ in observations:
        values = [value for item, value in observations if item == candidate and value > 0]
        if values:
            medians[candidate] = statistics.median(values)
    normalized = [
        value / medians[candidate]
        for candidate, value in observations
        if candidate in medians and medians[candidate] > 0
    ]
    if len(normalized) < 4:
        return True
    middle = len(normalized) // 2
    first = statistics.median(normalized[:middle])
    second = statistics.median(normalized[middle:])
    return abs(second - first) <= max(0.0, float(maximum_normalized_drift))


def build_session_options(profile: SessionProfile, variant: str = "safe"):
    import onnxruntime as ort

    settings = session_option_settings(variant)
    options = ort.SessionOptions()
    options.execution_mode = ort.ExecutionMode.ORT_SEQUENTIAL
    options.inter_op_num_threads = max(1, int(profile.inter_op_threads))
    options.intra_op_num_threads = max(1, int(profile.intra_op_threads))
    spinning = "1" if settings["spinning"] else "0"
    options.add_session_config_entry("session.intra_op.allow_spinning", spinning)
    options.add_session_config_entry("session.inter_op.allow_spinning", spinning)
    optimization_levels = {
        "disabled": ort.GraphOptimizationLevel.ORT_DISABLE_ALL,
        "basic": ort.GraphOptimizationLevel.ORT_ENABLE_BASIC,
        "extended": ort.GraphOptimizationLevel.ORT_ENABLE_EXTENDED,
        "all": ort.GraphOptimizationLevel.ORT_ENABLE_ALL,
    }
    options.graph_optimization_level = optimization_levels[settings["graph_optimization"]]
    options.enable_mem_pattern = bool(settings["memory_pattern"])
    options.enable_cpu_mem_arena = bool(settings["cpu_arena"])
    return options


def calibration_key(ort_version: str) -> str:
    return "|".join(
        (
            platform.system().lower(),
            platform.machine().lower(),
            platform.processor().lower(),
            str(os.cpu_count() or 1),
            str(ort_version),
        )
    )


def load_calibration(path: str | Path, ort_version: str) -> dict[str, Any]:
    target = Path(path)
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if data.get("key") == calibration_key(ort_version) else {}


def calibrate_machine(
    path: str | Path,
    ort_version: str,
    max_seconds: float = 0.75,
) -> dict[str, Any]:
    """Bounded machine-local ORT calibration using representative matrix work."""
    target = Path(path)
    cached = load_calibration(target, ort_version)
    if cached:
        return cached
    deadline = time.perf_counter() + max(0.05, float(max_seconds))
    import onnx
    import onnxruntime as ort
    from onnx import TensorProto, helper

    rng = np.random.default_rng(7)
    left = rng.standard_normal((384, 384), dtype=np.float32)
    right = rng.standard_normal((384, 384), dtype=np.float32)
    model = helper.make_model(
        helper.make_graph(
            [helper.make_node("MatMul", ["left", "right"], ["output"])],
            "neuralese_thread_calibration",
            [
                helper.make_tensor_value_info("left", TensorProto.FLOAT, [384, 384]),
                helper.make_tensor_value_info("right", TensorProto.FLOAT, [384, 384]),
            ],
            [helper.make_tensor_value_info("output", TensorProto.FLOAT, [384, 384])],
        ),
        opset_imports=[helper.make_opsetid("", 13)],
    )
    model.ir_version = min(model.ir_version, 8)
    serialized = model.SerializeToString()
    candidates = [count for count in (1, 2, 4) if count <= max(1, int(os.cpu_count() or 1))]
    timings: dict[str, float] = {}
    # The probe uses the same ORT scheduler as training and changes no process-
    # global thread settings. Session construction is excluded from the timing.
    for count in candidates:
        if time.perf_counter() >= deadline:
            break
        profile = SessionProfile("calibration", count)
        session = ort.InferenceSession(
            serialized,
            sess_options=build_session_options(profile),
            providers=["CPUExecutionProvider"],
        )
        session.run(None, {"left": left, "right": right})
        started = time.perf_counter()
        repetitions = 0
        while repetitions < 3 and time.perf_counter() < deadline:
            session.run(None, {"left": left, "right": right})
            repetitions += 1
        if repetitions:
            timings[str(count)] = (time.perf_counter() - started) / repetitions
    best = min(timings, key=timings.get) if timings else "1"
    result = {
        "key": calibration_key(ort_version),
        "heavy_threads": int(best),
        "timings_seconds": timings,
    }
    target.parent.mkdir(parents=True, exist_ok=True)
    temporary = target.with_suffix(target.suffix + ".tmp")
    temporary.write_text(json.dumps(result, indent=2), encoding="utf-8")
    temporary.replace(target)
    return result


def profile_dict(profile: SessionProfile) -> dict[str, Any]:
    return asdict(profile)
