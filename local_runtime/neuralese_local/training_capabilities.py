from __future__ import annotations

import inspect
import json
import platform
import tempfile
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Any

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper


CAPABILITY_SCHEMA_VERSION = 3


@dataclass(frozen=True)
class TrainingCapabilities:
    key: str
    ort_version: str
    nominal_checkpoint: bool
    ort_format_generation: bool
    ort_format_loading: bool
    artifact_format: str
    reusable_cpu_ortvalue_inputs: bool = False
    reusable_cpu_ortvalue_inputs_error: str = ""
    onnx_load_ms: float | None = None
    ort_load_ms: float | None = None
    probe_error: str = ""


def capability_key(ort_version: str) -> str:
    return "|".join(
        (
            str(CAPABILITY_SCHEMA_VERSION),
            str(ort_version),
            platform.system().lower(),
            platform.machine().lower(),
        )
    )


def choose_artifact_format(
    ort_format_generation: bool,
    ort_format_loading: bool,
    onnx_load_ms: float | None,
    ort_load_ms: float | None,
) -> str:
    if not ort_format_generation or not ort_format_loading:
        return "onnx"
    if onnx_load_ms is None or ort_load_ms is None:
        return "onnx"
    return "ort" if ort_load_ms < onnx_load_ms else "onnx"


def load_capabilities(path: str | Path, ort_version: str) -> TrainingCapabilities | None:
    target = Path(path)
    try:
        data = json.loads(target.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return None
    if data.get("schema") != CAPABILITY_SCHEMA_VERSION:
        return None
    payload = data.get("capabilities")
    if not isinstance(payload, dict) or payload.get("key") != capability_key(ort_version):
        return None
    try:
        return TrainingCapabilities(**payload)
    except (TypeError, ValueError):
        return None


def probe_capabilities(
    cache_path: str | Path | None = None,
    *,
    force: bool = False,
) -> TrainingCapabilities:
    import onnxruntime as ort

    target = Path(cache_path) if cache_path is not None else None
    if target is not None and not force:
        cached = load_capabilities(target, ort.__version__)
        if cached is not None:
            return cached

    result = _run_probe(str(ort.__version__))
    if target is not None:
        target.parent.mkdir(parents=True, exist_ok=True)
        temporary = target.with_suffix(target.suffix + ".tmp")
        temporary.write_text(
            json.dumps(
                {"schema": CAPABILITY_SCHEMA_VERSION, "capabilities": asdict(result)},
                sort_keys=True,
                indent=2,
            ),
            encoding="utf-8",
        )
        temporary.replace(target)
    return result


def _run_probe(ort_version: str) -> TrainingCapabilities:
    from . import train_task as task

    key = capability_key(ort_version)
    try:
        train_api, artifacts = task._load_ort_training_api()
        signature = inspect.signature(artifacts.generate_artifacts)
        supports_ort_argument = "ort_format" in signature.parameters
        supports_nominal_argument = "nominal_checkpoint" in signature.parameters
        with tempfile.TemporaryDirectory(prefix="neuralese_ort_capability_") as temp_s:
            root = Path(temp_s)
            model = _probe_model()
            onnx_dir = root / "onnx"
            onnx_dir.mkdir()
            artifacts.generate_artifacts(
                model,
                requires_grad=["weight", "bias"],
                loss=artifacts.LossType.CrossEntropyLoss,
                optimizer=artifacts.OptimType.AdamW,
                artifact_directory=str(onnx_dir),
                additional_output_names=["output"],
                nominal_checkpoint=supports_nominal_argument,
            )
            _normalize_onnx_ir(onnx_dir)
            onnx_load_ms = _measure_runtime_load(train_api, onnx_dir, "onnx")

            nominal_checkpoint = False
            if supports_nominal_argument and (onnx_dir / "nominal_checkpoint").is_file():
                try:
                    _, nominal_module, nominal_optimizer = _create_runtime(
                        train_api,
                        onnx_dir,
                        "onnx",
                        checkpoint_name="nominal_checkpoint",
                    )
                    _exercise_runtime(nominal_module, nominal_optimizer)
                    nominal_checkpoint = True
                except Exception:
                    nominal_checkpoint = False

            ort_generation = False
            ort_loading = False
            ort_load_ms = None
            if supports_ort_argument:
                ort_dir = root / "ort"
                ort_dir.mkdir()
                try:
                    artifacts.generate_artifacts(
                        model,
                        requires_grad=["weight", "bias"],
                        loss=artifacts.LossType.CrossEntropyLoss,
                        optimizer=artifacts.OptimType.AdamW,
                        artifact_directory=str(ort_dir),
                        additional_output_names=["output"],
                        ort_format=True,
                    )
                    ort_generation = all(
                        (ort_dir / filename).is_file()
                        for filename in (
                            "training_model.ort",
                            "eval_model.ort",
                            "optimizer_model.ort",
                        )
                    )
                    if ort_generation:
                        ort_load_ms = _measure_runtime_load(train_api, ort_dir, "ort")
                        ort_loading = True
                except Exception:
                    ort_generation = False
                    ort_loading = False
                    ort_load_ms = None

            selected = choose_artifact_format(
                ort_generation,
                ort_loading,
                onnx_load_ms,
                ort_load_ms,
            )
            reusable_cpu_ortvalue_inputs, ortvalue_error = _probe_reusable_cpu_ortvalue_inputs()
            return TrainingCapabilities(
                key=key,
                ort_version=ort_version,
                nominal_checkpoint=nominal_checkpoint,
                ort_format_generation=ort_generation,
                ort_format_loading=ort_loading,
                artifact_format=selected,
                reusable_cpu_ortvalue_inputs=reusable_cpu_ortvalue_inputs,
                reusable_cpu_ortvalue_inputs_error=ortvalue_error,
                onnx_load_ms=onnx_load_ms,
                ort_load_ms=ort_load_ms,
            )
    except Exception as exc:
        return TrainingCapabilities(
            key=key,
            ort_version=ort_version,
            nominal_checkpoint=False,
            ort_format_generation=False,
            ort_format_loading=False,
            artifact_format="onnx",
            reusable_cpu_ortvalue_inputs=False,
            probe_error=f"{type(exc).__name__}: {exc}",
        )


def _probe_model() -> onnx.ModelProto:
    rng = np.random.default_rng(11)
    weight = numpy_helper.from_array(
        rng.standard_normal((4, 3), dtype=np.float32), name="weight"
    )
    bias = numpy_helper.from_array(np.zeros((3,), dtype=np.float32), name="bias")
    graph = helper.make_graph(
        [helper.make_node("Gemm", ["input", "weight", "bias"], ["output"])],
        "neuralese_training_capability_probe",
        [helper.make_tensor_value_info("input", TensorProto.FLOAT, [None, 4])],
        [helper.make_tensor_value_info("output", TensorProto.FLOAT, [None, 3])],
        [weight, bias],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    model.ir_version = 7
    return model


def _normalize_onnx_ir(directory: Path) -> None:
    for path in directory.glob("*_model.onnx"):
        model = onnx.load(path)
        model.ir_version = 7
        onnx.save(model, path)


def _measure_runtime_load(
    train_api: Any,
    directory: Path,
    extension: str,
    *,
    checkpoint_name: str = "checkpoint",
) -> float:
    started = time.perf_counter()
    _create_runtime(
        train_api,
        directory,
        extension,
        checkpoint_name=checkpoint_name,
    )
    return (time.perf_counter() - started) * 1000.0


def _create_runtime(
    train_api: Any,
    directory: Path,
    extension: str,
    *,
    checkpoint_name: str = "checkpoint",
):
    state = train_api.CheckpointState.load_checkpoint(str(directory / checkpoint_name))
    module = train_api.Module(
        str(directory / f"training_model.{extension}"),
        state,
        str(directory / f"eval_model.{extension}"),
        device="cpu",
    )
    optimizer = train_api.Optimizer(
        str(directory / f"optimizer_model.{extension}"), module
    )
    return state, module, optimizer


def _exercise_runtime(module: Any, optimizer: Any) -> None:
    module.train()
    module.lazy_reset_grad()
    module(
        np.zeros((2, 4), dtype=np.float32),
        np.zeros((2,), dtype=np.int64),
    )
    optimizer.step()


def _probe_reusable_cpu_ortvalue_inputs() -> tuple[bool, str]:
    try:
        import onnxruntime as ort

        source = np.zeros((2, 2), dtype=np.float32)
        value = ort.OrtValue.ortvalue_from_numpy(source)
        source[:] = 7.0
        if not np.array_equal(value.numpy(), source):
            return False, "CPU OrtValue does not observe mutations to its NumPy owner"
        return True, ""
    except Exception as exc:
        return False, f"{type(exc).__name__}: {exc}"
