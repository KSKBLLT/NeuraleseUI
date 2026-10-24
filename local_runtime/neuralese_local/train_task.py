from __future__ import annotations

import json
import os
import shutil
import tempfile
import traceback
from pathlib import Path
from time import perf_counter
from typing import Any, Callable, Dict, Optional

import numpy as np
import onnx
import onnxruntime as ort

ort_train, artifacts = None, None

from .dataset_store import ArrayDataset, load_builtin_dataset, load_godot_json_dataset
from .onnx_compiler import build_onnx_model_from_graph
from .runtime_errors import UserFacingRuntimeError, error_payload
from .training_artifact_cache import ArtifactCache, artifact_fingerprint, default_capability
from .training_timing import StageTimer

Emit = Callable[[Dict[str, Any]], None]
DEFAULT_BATCH_SIZE = 128
EXPORT_EVAL_INTERVAL = 5
EVAL_MAX_SAMPLES = 2048
TRAINING_OUTPUT_CONTRACT = "train_loss_only_eval_predictions_v1"


def _load_ort_training_api():
    """Load ORT Training API without importing its legacy Torch-facing package init."""
    global ort_train, artifacts
    if ort_train is not None and artifacts is not None:
        return ort_train, artifacts

    import sys
    import types
    from importlib import import_module

    training_dir = Path(ort.__file__).resolve().parent / "training"
    if "onnxruntime.training" not in sys.modules:
        pkg = types.ModuleType("onnxruntime.training")
        pkg.__path__ = [str(training_dir)]
        sys.modules["onnxruntime.training"] = pkg

    api_mod = import_module("onnxruntime.training.api")
    artifacts_mod = import_module("onnxruntime.training.artifacts")

    class _OrtTrain:
        CheckpointState = api_mod.CheckpointState
        Module = api_mod.Module
        Optimizer = api_mod.Optimizer

    ort_train = _OrtTrain
    artifacts = artifacts_mod
    return ort_train, artifacts


def run_training(request: Dict[str, Any], emit: Emit, stop) -> Dict[str, Any]:
    """One-shot compatibility adapter over the reusable prepared-session path."""
    from .prepared_training import PreparedSession
    from .training_dataset_cache import TrainingDatasetCache

    runtime_root = request.get("runtime_root") or str(Path(__file__).resolve().parents[1])
    job_dir = Path(request["job_dir"])
    dataset_cache = TrainingDatasetCache(runtime_root)
    artifact_cache = ArtifactCache(
        request.get("artifact_cache_dir") or job_dir.parent / ".artifact_cache"
    )
    try:
        prepared = PreparedSession.prepare(request, dataset_cache, artifact_cache, emit=emit)
    except (UserFacingRuntimeError, ValueError):
        # Shape and dataset contract errors historically surface synchronously so
        # callers can localize them before any training lifecycle starts.
        raise
    except Exception as exc:
        traceback.print_exc()
        emit({"phase": "error", "error": error_payload(exc, "training")})
        return {"status": "error", "error": str(exc)}

    try:
        run_config = dict(request)
        run_config.setdefault("path_class", "cold")
        return prepared.start(run_config, emit, stop)
    except Exception as exc:
        traceback.print_exc()
        emit({"phase": "error", "error": error_payload(exc, "training")})
        return {"status": "error", "error": str(exc)}


def _run_training_legacy(request: Dict[str, Any], emit: Emit, stop) -> Dict[str, Any]:
    timer = StageTimer()
    path_class = str(request.get("path_class") or "cold")
    timer.begin("runtime_api")
    ort_train_api, ort_artifacts = _load_ort_training_api()
    timer.end("runtime_api")
    emit({
        "phase": "start",
        "mode": "train",
        "backend": "fullylocal_ort",
        "data": {"path_class": path_class, "timings_ms": timer.snapshot()},
    })

    killed = False

    def _on_kill() -> None:
        nonlocal killed
        if killed:
            return
        killed = True
        emit({"phase": "stopped"})

    stop.on_kill(_on_kill)

    graph = request["graph"]
    train_graph = request.get("train_graph", {})
    epochs = max(1, int(request.get("epochs", 1)))
    batch_size = int(request.get("batch_size", 0)) or DEFAULT_BATCH_SIZE
    runtime_root = request.get("runtime_root") or str(Path(__file__).resolve().parents[1])
    job_dir = Path(request["job_dir"])
    artifact_dir = job_dir / "artifacts"
    artifact_dir.mkdir(parents=True, exist_ok=True)
    checkpoint_dir = Path(request.get("checkpoint_dir") or artifact_dir)
    checkpoint_dir.mkdir(parents=True, exist_ok=True)

    emit({"phase": "progress", "data": {"stage": "loading_dataset"}})
    timer.begin("dataset")
    dataset = _load_dataset(request, runtime_root)
    timer.end("dataset")
    if len(dataset) <= 0:
        raise ValueError(f"Dataset '{dataset.name}' is empty")
    emit({
        "phase": "progress",
        "data": {"stage": "dataset_ready", "samples": len(dataset), "dataset": dataset.name},
    })
    if killed or stop.closed:
        return {"status": "stopped"}

    training_config = _extract_training_config(train_graph)
    loss_name = training_config.get("loss", "cross_entropy")
    optimizer_name = training_config.get("optimizer", "adam")
    learning_rate = _parse_float(training_config.get("lr"), None)
    _coerce_targets_for_loss(dataset, loss_name)

    optimizer_type, actual_optimizer_name, optimizer_warning, optimizer_fallback = _resolve_optimizer_type(optimizer_name)
    if optimizer_warning:
        emit({"phase": "warning", "warning": optimizer_warning})
    if optimizer_fallback and learning_rate is not None and learning_rate > 1e-3:
        emit({
            "phase": "warning",
            "warning": (
                f"Requested optimizer '{optimizer_name}' is using AdamW fallback; "
                f"clamping learning rate from {learning_rate:g} to 0.001 for stability."
            ),
        })
        learning_rate = 1e-3

    emit({"phase": "progress", "data": {"stage": "building_model"}})
    timer.begin("model_build")
    model_proto, trainable_params = build_onnx_model_from_graph(graph, loss_name=loss_name)
    _validate_training_shapes(dataset, model_proto, loss_name)
    timer.end("model_build")
    model_output_names = [out.name for out in model_proto.graph.output]
    if not trainable_params:
        raise UserFacingRuntimeError(
            "training_no_trainable_parameters",
            "The graph has no trainable parameters",
        )
    emit({
        "phase": "progress",
        "data": {
            "stage": "model_ready",
            "operators": len(model_proto.graph.node),
            "trainable_parameters": len(trainable_params),
        },
    })
    if killed or stop.closed:
        return {"status": "stopped"}

    final_inference_path: Optional[Path] = None
    try:
        with tempfile.TemporaryDirectory(prefix="neuralese_ort_") as temp_dir_s:
            temp_dir = Path(temp_dir_s)
            emit({"phase": "progress", "data": {"stage": "preparing_training"}})
            timer.begin("artifacts")
            capability = default_capability()
            capability["training_output_contract"] = TRAINING_OUTPUT_CONTRACT
            artifact_key = artifact_fingerprint(
                model_proto,
                trainable_params,
                loss_name,
                actual_optimizer_name,
                capability,
            )
            artifact_spec = {
                "fingerprint": artifact_key,
                "loss": loss_name,
                "optimizer": actual_optimizer_name,
                "trainable_params": sorted(trainable_params),
                "capability": capability,
            }
            artifact_cache_hit = False
            try:
                cache_root = Path(
                    request.get("artifact_cache_dir") or job_dir.parent / ".artifact_cache"
                )
                entry = ArtifactCache(cache_root).get_or_create(
                    artifact_spec,
                    lambda target: _generate_training_artifacts(
                        target,
                        ort_artifacts,
                        model_proto,
                        trainable_params,
                        loss_name,
                        optimizer_type,
                    ),
                )
                checkpoint_path = entry.checkpoint
                training_model_path = entry.training_model
                optimizer_model_path = entry.optimizer_model
                eval_model_path = entry.eval_model
                artifact_cache_hit = entry.cache_hit
            except Exception as cache_error:
                emit({
                    "phase": "warning",
                    "warning": f"Training artifact cache unavailable: {cache_error}",
                })
                _generate_training_artifacts(
                    temp_dir,
                    ort_artifacts,
                    model_proto,
                    trainable_params,
                    loss_name,
                    optimizer_type,
                )
                checkpoint_path = temp_dir / "checkpoint"
                training_model_path = temp_dir / "training_model.onnx"
                optimizer_model_path = temp_dir / "optimizer_model.onnx"
                eval_model_path = temp_dir / "eval_model.onnx"
            timer.end("artifacts")

            timer.begin("checkpoint_load")
            state = ort_train_api.CheckpointState.load_checkpoint(str(checkpoint_path))
            timer.end("checkpoint_load")
            timer.begin("module")
            session = ort_train_api.Module(str(training_model_path), state, str(eval_model_path), device="cpu")
            timer.end("module")
            timer.begin("optimizer")
            optimizer = ort_train_api.Optimizer(str(optimizer_model_path), session)
            _apply_learning_rate(optimizer, learning_rate)
            timer.end("optimizer")
            last_metrics: Dict[str, float] = {}
            last_export_epoch = -1
            first_step_recorded = False
            total_batches = (len(dataset) + batch_size - 1) // batch_size
            emit({
                "phase": "progress",
                "data": {
                    "stage": "training_ready",
                    "epochs": epochs,
                    "batches": total_batches,
                    "path_class": path_class,
                    "artifact_cache_hit": artifact_cache_hit,
                    "timings_ms": timer.snapshot(),
                },
            })

            for epoch in range(epochs):
                if killed or stop.closed:
                    break

                emit({
                    "phase": "progress",
                    "data": {
                        "stage": "epoch_start",
                        "epoch": epoch,
                        "epochs": epochs,
                        "left": epochs - epoch,
                        "batches": total_batches,
                    },
                })

                epoch_started = perf_counter()
                session.train()
                epoch_loss = 0.0
                batches_count = 0
                order = np.arange(len(dataset))
                np.random.shuffle(order)

                for start in range(0, len(dataset), batch_size):
                    if killed or stop.closed:
                        break

                    end = min(start + batch_size, len(dataset))
                    batch_indices = order[start:end]
                    bx, by = dataset.batch_indices(batch_indices)
                    session.lazy_reset_grad()
                    loss = session(bx, by)
                    if not first_step_recorded:
                        timer.mark("first_step")
                        first_step_recorded = True
                    optimizer.step()
                    epoch_loss += float(np.asarray(loss).reshape(-1)[0])
                    batches_count += 1
                    emit({
                        "phase": "progress",
                        "data": {
                            "stage": "batch",
                            "epoch_elapsed_seconds": perf_counter()-epoch_started,
                            "epoch": epoch,
                            "epochs": epochs,
                            "left": epochs - epoch,
                            "batch": batches_count,
                            "batches": total_batches,
                            "train_loss_so_far": epoch_loss / batches_count,
                        },
                    })

                if killed or stop.closed:
                    break

                avg_loss = epoch_loss / max(1, batches_count)
                should_export = (
                    epoch == 0
                    or ((epoch + 1) % EXPORT_EVAL_INTERVAL == 0)
                    or epoch == epochs - 1
                )
                metrics = last_metrics
                eval_seconds = 0.0
                if should_export:
                    eval_started = perf_counter()
                    inference_path = temp_dir / "inference.onnx"
                    timer.begin("export")
                    session.export_model_for_inferencing(str(inference_path), model_output_names)
                    _restore_visual_output_softmax_for_inference(inference_path, graph, loss_name)
                    final_inference_path = artifact_dir / "inference.onnx"
                    final_inference_path.write_bytes(inference_path.read_bytes())
                    checkpoint_inference_path = checkpoint_dir / "inference.onnx"
                    if final_inference_path.resolve() != checkpoint_inference_path.resolve():
                        shutil.copy2(final_inference_path, checkpoint_inference_path)
                    timer.end("export")
                    max_eval = None if epoch == epochs - 1 else EVAL_MAX_SAMPLES
                    timer.begin("eval")
                    metrics = _evaluate(final_inference_path, dataset, loss_name, max_samples=max_eval)
                    timer.end("eval")
                    last_metrics = metrics
                    last_export_epoch = epoch
                    eval_seconds = perf_counter() - eval_started
                epoch_seconds = perf_counter() - epoch_started
                emit({
                    "phase": "state",
                    "data": {
                        "epoch": epoch,
                        "left": epochs - epoch - 1,
                        "type": "loss",
                        "data": {
                            "train_loss": avg_loss,
                            "val_loss": metrics.get("val_loss", avg_loss),
                            "train_acc": metrics.get("train_acc", 0.0),
                            "val_acc": metrics.get("val_acc", 0.0),
                            "length": batches_count,
                            "batch_size": batch_size,
                            "evaluated": should_export,
                            "last_evaluated_epoch": last_export_epoch,
                            "epoch_seconds": epoch_seconds,
                            "eval_seconds": eval_seconds,
                        },
                    },
                })

        if killed or stop.closed:
            return {"status": "stopped"}

        if final_inference_path:
            checkpoint_inference_path = checkpoint_dir / "inference.onnx"
            if final_inference_path.resolve() != checkpoint_inference_path.resolve():
                shutil.copy2(final_inference_path, checkpoint_inference_path)
        timer.begin("checkpoint_save")
        _save_required_checkpoint(ort_train_api, state, checkpoint_dir)
        timer.end("checkpoint_save")

        result = {
            "status": "ok",
            "backend": "fullylocal_ort",
            "artifact": str(checkpoint_dir / "inference.onnx") if final_inference_path else "",
            "checkpoint_dir": str(checkpoint_dir),
            "dataset": dataset.name,
            "path_class": path_class,
            "artifact_cache_hit": artifact_cache_hit,
            "timings_ms": timer.snapshot(),
        }
        manifest = {
            **result,
            "context": request.get("context", ""),
            "scene_id": request.get("scene_id", ""),
            "model_outputs": model_output_names,
            "loss": loss_name,
            "optimizer": optimizer_name,
            "actual_optimizer": actual_optimizer_name,
            "learning_rate": learning_rate,
            "export_eval_interval": EXPORT_EVAL_INTERVAL,
        }
        timer.mark("total")
        result["timings_ms"] = timer.snapshot()
        manifest["timings_ms"] = timer.snapshot()
        (checkpoint_dir / "manifest.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
        (job_dir / "result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
        emit({"phase": "done", "data": {"path_class": path_class, "timings_ms": timer.snapshot()}})
        return result

    except Exception as exc:
        traceback.print_exc()
        emit({"phase": "error", "error": error_payload(exc, "training")})
        return {"status": "error", "error": str(exc)}


def dropout_for_training(model_proto: onnx.ModelProto) -> onnx.ModelProto:
    """The model as training sees it: every Dropout switched on.

    The compiled graph keeps Dropout in its answering form (no training_mode:
    an identity), which is what the published model must do. Without
    training_mode it never drops, and without its mask output ORT cannot build
    its gradient at all: a model with a Dropout node failed to train. ORT's eval
    model switches it back off (onnxblock _disable_training_mode)."""
    if not any(node.op_type == "Dropout" for node in model_proto.graph.node):
        return model_proto
    training = type(model_proto)()
    training.CopyFrom(model_proto)
    flag = "dropout_training_mode"
    training.graph.initializer.append(onnx.numpy_helper.from_array(np.array(True), flag))
    for node in training.graph.node:
        if node.op_type != "Dropout":
            continue
        while len(node.input) < 2:
            node.input.append("")
        if len(node.input) < 3:
            node.input.append(flag)
        else:
            node.input[2] = flag
        if len(node.output) < 2:
            node.output.append(f"{node.output[0]}_mask")
    return training


def _generate_training_artifacts(
    target: Path,
    ort_artifacts: Any,
    model_proto: onnx.ModelProto,
    trainable_params: list[str],
    loss_name: str,
    optimizer_type: Any,
    artifact_format: str = "onnx",
    nominal_checkpoint: bool = False,
    frozen_params: list[str] | None = None,
    output_contract: str = TRAINING_OUTPUT_CONTRACT,
) -> None:
    if output_contract != TRAINING_OUTPUT_CONTRACT:
        raise ValueError(f"unsupported training output contract '{output_contract}'")
    target.mkdir(parents=True, exist_ok=True)
    model_proto = dropout_for_training(model_proto)
    model_outputs = [output.name for output in model_proto.graph.output]
    ort_artifacts.generate_artifacts(
        model_proto,
        requires_grad=trainable_params,
        frozen_params=frozen_params,
        loss=_loss_type(loss_name),
        optimizer=optimizer_type,
        artifact_directory=str(target),
        additional_output_names=[],
        ort_format=artifact_format == "ort",
        nominal_checkpoint=nominal_checkpoint,
    )
    if model_outputs:
        rich_eval_dir = target / ".eval_outputs"
        rich_eval_dir.mkdir()
        try:
            ort_artifacts.generate_artifacts(
                model_proto,
                requires_grad=trainable_params,
                frozen_params=frozen_params,
                loss=_loss_type(loss_name),
                optimizer=optimizer_type,
                artifact_directory=str(rich_eval_dir),
                additional_output_names=model_outputs,
                ort_format=artifact_format == "ort",
                nominal_checkpoint=False,
            )
            extension = "ort" if artifact_format == "ort" else "onnx"
            shutil.copy2(
                rich_eval_dir / f"eval_model.{extension}",
                target / f"eval_model.{extension}",
            )
        finally:
            shutil.rmtree(rich_eval_dir, ignore_errors=True)
    for path in (
        target / "training_model.onnx",
        target / "optimizer_model.onnx",
        target / "eval_model.onnx",
    ):
        if path.exists():
            model = onnx.load(path)
            model.ir_version = 7
            onnx.save(model, path)
    if artifact_format == "ort":
        for path in target.glob("*_model.onnx"):
            path.unlink()
    if nominal_checkpoint:
        complete = target / "checkpoint"
        nominal = target / "nominal_checkpoint"
        if not nominal.is_file():
            raise RuntimeError("ORT did not generate the requested nominal checkpoint")
        complete.unlink(missing_ok=True)
        nominal.replace(complete)


def _save_required_checkpoint(training_api, state: Any, checkpoint_dir: Path) -> Path:
    """Save the trainable ORT state and reject incomplete training results."""
    checkpoint_path = checkpoint_dir / "checkpoint"
    training_api.CheckpointState.save_checkpoint(state, str(checkpoint_path), False)
    if not checkpoint_path.is_file():
        raise RuntimeError(
            f"ONNX Runtime did not create the required checkpoint at '{checkpoint_path}'"
        )
    return checkpoint_path


def export_model_from_state(model_proto: onnx.ModelProto, state: Any, target: Path) -> Path:
    """Publish the original inference graph with the current ORT checkpoint parameters."""
    exported = type(model_proto)()
    exported.CopyFrom(model_proto)
    current_parameters = {name: np.asarray(parameter.data) for name, parameter in state.parameters}
    replaced = set()
    for index, initializer in enumerate(exported.graph.initializer):
        value = current_parameters.get(initializer.name)
        if value is None:
            continue
        replacement = onnx.numpy_helper.from_array(value, name=initializer.name)
        exported.graph.initializer[index].CopyFrom(replacement)
        replaced.add(initializer.name)
    missing = set(current_parameters).difference(replaced)
    if missing:
        raise RuntimeError(
            "Checkpoint parameters are absent from the inference graph: "
            + ", ".join(sorted(missing))
        )
    target.parent.mkdir(parents=True, exist_ok=True)
    onnx.save(exported, target)
    return target


def _load_dataset(request: Dict[str, Any], runtime_root: str | Path) -> ArrayDataset:
    dataset_ref = request.get("dataset_ref") or {}
    kind = str(dataset_ref.get("kind", ""))
    if kind == "builtin_numpy":
        return load_builtin_dataset(runtime_root, str(dataset_ref.get("name", "")))
    if kind == "godot_json":
        return load_godot_json_dataset(
            dataset_ref.get("path", ""),
            name=str(dataset_ref.get("name", "")),
        )
    raise ValueError(f"Unsupported FullyLocal dataset ref kind '{kind}'")


def _shape_flat_pictures(dataset: ArrayDataset, input_shape: tuple) -> None:
    """A dataset the child made from pictures arrives one row of pixels per
    sample; a model that takes pictures gets them back as channels x rows x
    columns when the counts agree."""
    if len(input_shape) < 2 or any(dim is None for dim in input_shape):
        return
    values = int(np.prod(input_shape))
    for name in ("x", "val_x"):
        array = getattr(dataset, name)
        if array is not None and array.ndim == 2 and array.shape[1] == values:
            setattr(dataset, name, array.reshape((-1, *input_shape)))


def _validate_training_shapes(dataset: ArrayDataset, model: onnx.ModelProto, loss_name: str) -> None:
    initializer_names = {value.name for value in model.graph.initializer}
    inputs = [value for value in model.graph.input if value.name not in initializer_names]
    if len(inputs) != 1 or len(model.graph.output) != 1:
        raise UserFacingRuntimeError(
            "training_graph_io_invalid",
            "Local training requires one model input and one model output",
        )

    def sample_shape(value):
        return tuple(dim.dim_value if dim.HasField("dim_value") else None
                     for dim in value.type.tensor_type.shape.dim[1:])

    def matches(actual, expected):
        return len(actual) == len(expected) and all(want is None or got == want
                                                   for got, want in zip(actual, expected))

    input_shape = sample_shape(inputs[0])
    output_shape = sample_shape(model.graph.output[0])
    regression = str(loss_name).lower() in {"mse", "mse_loss", "mean_squared_error"}
    _shape_flat_pictures(dataset, input_shape)
    splits = [("training", dataset.x, dataset.y)]
    if dataset.val_x is not None or dataset.val_y is not None:
        splits.append(("validation", dataset.val_x, dataset.val_y))
    for split, x, y in splits:
        prefix = f"Dataset '{dataset.name}' ({split})"
        if x is None or y is None or x.ndim < 2 or y.ndim < 1 or len(x) != len(y):
            raise UserFacingRuntimeError(
                "training_sample_count_mismatch",
                f"{prefix}: inputs and targets must have the same number of samples",
                {"dataset": dataset.name, "split": split},
            )
        if not matches(x.shape[1:], input_shape):
            raise UserFacingRuntimeError(
                "training_input_shape_mismatch",
                f"{prefix}: input shape is {x.shape[1:]}, but the model expects {input_shape}.",
                {"dataset": dataset.name, "actual": _shape_text(x.shape[1:]), "expected": _shape_text(input_shape)},
            )
        if regression:
            if not matches(y.shape[1:], output_shape):
                raise UserFacingRuntimeError(
                    "training_target_shape_mismatch",
                    f"{prefix}: target shape is {y.shape[1:]}, but the model output is {output_shape}.",
                    {"dataset": dataset.name, "actual": _shape_text(y.shape[1:]), "expected": _shape_text(output_shape)},
                )
        else:
            if y.ndim != 1 or len(output_shape) != 1:
                raise UserFacingRuntimeError(
                    "training_classification_shape_invalid",
                    f"{prefix}: classification requires one class index per sample and a 1D model output",
                    {"dataset": dataset.name},
                )
            if not y.size:
                continue
            if int(y.min()) < 0:
                raise UserFacingRuntimeError(
                    "training_class_indices_invalid",
                    f"{prefix}: class indices must start at 0",
                    {"dataset": dataset.name},
                )
            classes = int(y.max()) + 1
            outputs = output_shape[0]
            if outputs is not None and classes > outputs:
                raise UserFacingRuntimeError(
                    "training_output_count_mismatch",
                    f"{prefix}: class labels require {classes} outputs, but the model output has {outputs}.",
                    {"dataset": dataset.name, "expected": classes, "actual": outputs},
                )


def _shape_text(shape: Any) -> str:
    return "x".join("?" if dim is None else str(dim) for dim in tuple(shape)) or "1"


def _coerce_targets_for_loss(dataset: ArrayDataset, loss_name: str) -> None:
    normalized = str(loss_name).lower()
    if normalized in {"mse", "mse_loss", "mean_squared_error"}:
        dataset.y = _as_regression_targets(dataset.y)
        if dataset.val_y is not None:
            dataset.val_y = _as_regression_targets(dataset.val_y)
        return
    if dataset.y.ndim > 1:
        dataset.y = np.argmax(dataset.y, axis=1).astype(np.int64)
    else:
        dataset.y = dataset.y.astype(np.int64)
    if dataset.val_y is not None:
        if dataset.val_y.ndim > 1:
            dataset.val_y = np.argmax(dataset.val_y, axis=1).astype(np.int64)
        else:
            dataset.val_y = dataset.val_y.astype(np.int64)


def _as_regression_targets(targets: np.ndarray) -> np.ndarray:
    arr = np.asarray(targets, dtype=np.float32)
    if arr.ndim == 1:
        return arr.reshape((-1, 1))
    return arr


def _extract_training_config(train_graph: Dict[str, Any]) -> Dict[str, Any]:
    config: Dict[str, Any] = {"optimizer": "adam", "lr": None, "loss": "cross_entropy"}
    for page in train_graph.get("pages", {}).values():
        for node in page.values():
            ntype = str(node.get("type", ""))
            props = node.get("props", {}) or {}
            node_config = props.get("config", {}) or {}
            if ntype == "RunModel":
                branch_losses = node_config.get("branch_losses", {}) or {}
                if branch_losses:
                    first_loss = next(iter(branch_losses.values()))
                    config["loss"] = str(first_loss)
            elif ntype == "TrainInput":
                config["optimizer"] = str(node_config.get("optimizer", config["optimizer"]))
                config["lr"] = node_config.get("lr", config["lr"])
                config["weight_decay"] = node_config.get("weight_decay", "")
                config["momentum"] = node_config.get("momentum", 0.0)
    return config


def _loss_type(name: str):
    _, ort_artifacts = _load_ort_training_api()
    normalized = str(name).lower()
    if normalized in {"cross_entropy", "crossentropyloss", "ce"}:
        return ort_artifacts.LossType.CrossEntropyLoss
    if normalized in {"mse", "mse_loss", "mean_squared_error"}:
        for attr in ("MSELoss", "MeanSquaredError"):
            if hasattr(ort_artifacts.LossType, attr):
                return getattr(ort_artifacts.LossType, attr)
        raise ValueError("This onnxruntime-training build does not expose MSELoss artifacts")
    raise ValueError(f"Unsupported FullyLocal loss '{name}'")


def _optimizer_type(name: str):
    _, ort_artifacts = _load_ort_training_api()
    normalized = str(name).lower()
    if normalized in {"adam", "adamw"}:
        return ort_artifacts.OptimType.AdamW
    if normalized in {"sgd", "stochastic_gradient_descent"}:
        for attr in ("SGD", "SGDOptimizer"):
            if hasattr(ort_artifacts.OptimType, attr):
                return getattr(ort_artifacts.OptimType, attr)
        raise ValueError("This onnxruntime-training build does not expose SGD artifacts")
    raise ValueError(f"Unsupported FullyLocal optimizer '{name}'")


def _resolve_optimizer_type(name: str):
    _, ort_artifacts = _load_ort_training_api()
    normalized = str(name).lower()
    if normalized in {"adam", "adamw"}:
        return ort_artifacts.OptimType.AdamW, "adamw", "", False
    if normalized in {"sgd", "stochastic_gradient_descent"}:
        for attr in ("SGD", "SGDOptimizer"):
            if hasattr(ort_artifacts.OptimType, attr):
                return getattr(ort_artifacts.OptimType, attr), "sgd", "", False
        return (
            ort_artifacts.OptimType.AdamW,
            "adamw",
            "This onnxruntime-training build does not expose SGD artifacts; using AdamW fallback.",
            True,
        )
    raise ValueError(f"Unsupported FullyLocal optimizer '{name}'")


def _graph_has_output_softmax(graph: Dict[str, Any]) -> bool:
    for page in graph.get("pages", {}).values():
        for node in page.values():
            ntype = str(node.get("type", ""))
            props = node.get("props", {}) or {}
            config = props.get("config", {}) or {}
            if ntype in {"SoftmaxNode", "softmax"} and str(config.get("role", "")).lower() == "output":
                return True
    return False


def _restore_visual_output_softmax_for_inference(inference_path: Path, graph: Dict[str, Any], loss_name: str) -> None:
    if not _is_cross_entropy_name(loss_name) or not _graph_has_output_softmax(graph):
        return
    model = onnx.load(inference_path)
    if len(model.graph.output) != 1:
        return
    old_output = model.graph.output[0]
    logits_name = old_output.name
    softmax_name = f"{logits_name}_visual_softmax"
    if any(node.output and node.output[0] == softmax_name for node in model.graph.node):
        return
    model.graph.node.append(
        onnx.helper.make_node(
            "Softmax",
            inputs=[logits_name],
            outputs=[softmax_name],
            axis=1,
            name="visual_output_softmax",
        )
    )
    old_output.name = softmax_name
    onnx.save(model, inference_path)


def _is_cross_entropy_name(name: str) -> bool:
    return str(name).lower() in {"cross_entropy", "crossentropyloss", "ce"}


def _parse_float(value: Any, default: Optional[float]) -> Optional[float]:
    if value in (None, ""):
        return default
    try:
        return float(value)
    except Exception:
        return default


def _apply_learning_rate(optimizer: Any, learning_rate: Optional[float]) -> None:
    if learning_rate is None:
        return
    for method_name in ("set_learning_rate", "set_lr"):
        method = getattr(optimizer, method_name, None)
        if callable(method):
            method(float(learning_rate))
            return


def _evaluate(inference_path: Path, dataset: ArrayDataset, loss_name: str, max_samples: Optional[int] = None) -> Dict[str, float]:
    providers = ["CPUExecutionProvider"]
    sess = ort.InferenceSession(str(inference_path), providers=providers)
    input_name = sess.get_inputs()[0].name
    vx, vy = dataset.validation_arrays()
    if max_samples is not None and max_samples > 0 and len(vx) > max_samples:
        sample_idx = np.linspace(0, len(vx) - 1, max_samples, dtype=np.int64)
        vx = vx[sample_idx]
        vy = vy[sample_idx]
    preds = sess.run(None, {input_name: vx})[0]

    return _metrics_from_predictions(preds, vy, loss_name)


def _metrics_from_predictions(
    predictions: np.ndarray,
    targets: np.ndarray,
    loss_name: str,
) -> Dict[str, float]:
    preds = np.asarray(predictions)
    vy = np.asarray(targets)
    if str(loss_name).lower() in {"mse", "mse_loss", "mean_squared_error"}:
        target = _as_regression_targets(vy)
        if target.shape != preds.shape and target.size == preds.size:
            target = target.reshape(preds.shape)
        val_loss = float(np.mean(np.square(preds - target)))
        constant_prediction = np.mean(target, axis=0, keepdims=True)
        constant_baseline_loss = float(np.mean(np.square(target - constant_prediction)))
        regression_skill = (
            0.0
            if constant_baseline_loss <= 1e-12
            else float(np.clip(1.0 - val_loss / constant_baseline_loss, 0.0, 1.0))
        )
        return {
            "val_loss": val_loss,
            "train_acc": regression_skill,
            "val_acc": regression_skill,
            "constant_baseline_loss": constant_baseline_loss,
        }

    labels = vy
    if labels.ndim > 1:
        labels = np.argmax(labels, axis=1)
    predicted_labels = np.argmax(preds, axis=1)
    accuracy = float(np.mean(predicted_labels == labels.astype(np.int64)))
    probs = _softmax_if_needed(preds)
    ce = -np.log(np.clip(probs[np.arange(len(labels)), labels.astype(np.int64)], 1e-9, 1.0))
    return {"val_loss": float(np.mean(ce)), "train_acc": accuracy, "val_acc": accuracy}


def _module_loss_and_predictions(outputs: Any) -> tuple[np.ndarray, np.ndarray]:
    if isinstance(outputs, (tuple, list)) and len(outputs) >= 2:
        return np.asarray(outputs[0]), np.asarray(outputs[-1])
    raise RuntimeError(
        "ORT training artifacts do not expose model predictions; rebuild the structural cache"
    )


def evaluate_module(
    module: Any,
    dataset: ArrayDataset,
    loss_name: str,
    max_samples: Optional[int] = None,
    batch_size: int = 512,
) -> Dict[str, float]:
    vx, vy = dataset.validation_arrays()
    if max_samples is not None and max_samples > 0 and len(vx) > max_samples:
        sample_idx = np.linspace(0, len(vx) - 1, max_samples, dtype=np.int64)
        vx = vx[sample_idx]
        vy = vy[sample_idx]
    prediction_batches: list[np.ndarray] = []
    target_batches: list[np.ndarray] = []
    module.eval()
    try:
        for start in range(0, len(vx), max(1, int(batch_size))):
            end = min(start + max(1, int(batch_size)), len(vx))
            _, predictions = _module_loss_and_predictions(module(vx[start:end], vy[start:end]))
            prediction_batches.append(np.asarray(predictions))
            target_batches.append(np.asarray(vy[start:end]))
    finally:
        module.train()
    if not prediction_batches:
        raise ValueError("Validation dataset is empty")
    return _metrics_from_predictions(
        np.concatenate(prediction_batches, axis=0),
        np.concatenate(target_batches, axis=0),
        loss_name,
    )


def _softmax_if_needed(preds: np.ndarray) -> np.ndarray:
    sums = np.sum(preds, axis=1)
    if np.all(preds >= 0.0) and np.allclose(sums, 1.0, atol=1e-3):
        return preds
    shifted = preds - np.max(preds, axis=1, keepdims=True)
    exp = np.exp(shifted)
    return exp / np.sum(exp, axis=1, keepdims=True)
