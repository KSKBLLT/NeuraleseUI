from __future__ import annotations

import copy
import hashlib
import json
import shutil
import tempfile
import threading
import uuid
from pathlib import Path
from time import perf_counter
from typing import Any, Callable, Dict

import numpy as np

from .training_artifact_cache import ArtifactCache, ArtifactEntry, artifact_fingerprint, default_capability
from .training_dataset_cache import TrainingDatasetCache
from .epoch_runner import EpochResult, EpochRunner
from .head_cache import NumpyHead, compute_features, features_fit, find_head_layer
from .training_timing import StageTimer
from .training_profile import (
    build_session_options,
    estimate_workload,
    profile_dict,
    select_fixed_batch_size,
    select_profile,
)
from .training_capabilities import load_capabilities, probe_capabilities
from .training_acceleration import (
    FreezeStage,
    SelectiveBlockPolicy,
    algorithmic_acceleration_eligible,
    cosine_learning_rate,
    freeze_schedule,
    parameter_groups,
)


Emit = Callable[[Dict[str, Any]], None]


# Long enough for freeze_schedule to give every stage its own epoch.
PREPARED_STAGE_EPOCHS = 40


def _freeze_options(request: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "mode": str(request.get("freeze_mode") or "progressive"),
        # CIFAR-10, 10 epochs: 0.15 matched the old all-at-once schedule's
        # accuracy 12-15% faster; 0.3 and 0.5 trade time back for accuracy.
        "start": float(request.get("freeze_start", 0.15)),
    }


class StalePreparedSessionError(RuntimeError):
    pass


class _CancellationView:
    def __init__(self, cancel: Any, killed: Callable[[], bool]) -> None:
        self._cancel = cancel
        self._killed = killed

    @property
    def closed(self) -> bool:
        return self._killed() or bool(getattr(self._cancel, "closed", False))


class PreparedSession:
    def __init__(self) -> None:
        self.prepared_id = ""
        self.generation = 0
        self.request: Dict[str, Any] = {}
        self.dataset = None
        self.artifact_cache: ArtifactCache | None = None
        self.artifact_entry: ArtifactEntry | None = None
        self.artifact_entries: dict[str, ArtifactEntry] = {}
        self.model_proto = None
        self.model_output_names: list[str] = []
        self.trainable_params: list[str] = []
        self.parameter_group_order: list[tuple[str, ...]] = []
        self.freeze_stages: tuple[FreezeStage, ...] = ()
        self.active_freeze_stage: FreezeStage | None = None
        self.freeze_fallback_reason = ""
        self.algorithmic_acceleration = False
        self.loss_name = "cross_entropy"
        self.optimizer_name = "adam"
        self.actual_optimizer_name = "adamw"
        self.optimizer_type = None
        self.learning_rate: float | None = None
        self.initialization_seed: int | None = None
        self.ort_train_api = None
        self.ort_artifacts = None
        self.state = None
        self.module = None
        self.optimizer = None
        self.cache_hit = False
        self.artifact_format = "onnx"
        self.nominal_checkpoint = False
        self.reusable_cpu_ortvalue_inputs = False
        self.auto_batch_size = 128
        self.batch_calibration: Dict[str, Any] = {}
        self.workload_estimate = None
        self.session_profile = None
        self.session_option_variant = "safe"
        self._initial_parameters: np.ndarray | None = None
        self._dirty = False
        self._optimizer_state_is_resumed = False
        self._start_lock = threading.Lock()

    @classmethod
    def prepare(
        cls,
        request: Dict[str, Any],
        dataset_cache: TrainingDatasetCache,
        artifact_cache: ArtifactCache,
        emit: Emit | None = None,
    ) -> "PreparedSession":
        if "language_graph" in request:
            from .language.prepared import PreparedLanguageSession
            return PreparedLanguageSession.prepare(request, emit)
        from . import train_task as task

        prepared = cls()
        prepared.request = copy.deepcopy(request)
        prepared.session_option_variant = (
            str(request.get("session_option_variant") or "safe")
            if bool(request.get("benchmark_session_options", False))
            else "safe"
        )
        prepared.generation = int(request.get("graph_generation", 0))
        raw_initialization_seed = request.get("initialization_seed")
        prepared.initialization_seed = (
            int(raw_initialization_seed) if raw_initialization_seed is not None else None
        )
        prepared.artifact_cache = artifact_cache
        prepared.ort_train_api, prepared.ort_artifacts = task._load_ort_training_api()

        if emit is not None:
            emit({"phase": "progress", "data": {"stage": "loading_dataset"}})
        prepared.dataset = dataset_cache.get(request.get("dataset_ref") or {})
        if len(prepared.dataset) <= 0:
            raise ValueError(f"Dataset '{prepared.dataset.name}' is empty")
        if emit is not None:
            emit({
                "phase": "progress",
                "data": {
                    "stage": "dataset_ready",
                    "samples": len(prepared.dataset),
                    "dataset": prepared.dataset.name,
                },
            })

        training_config = task._extract_training_config(request.get("train_graph", {}))
        prepared.loss_name = training_config.get("loss", "cross_entropy")
        prepared.optimizer_name = training_config.get("optimizer", "adam")
        prepared.learning_rate = task._parse_float(training_config.get("lr"), None)
        task._coerce_targets_for_loss(prepared.dataset, prepared.loss_name)
        (
            prepared.optimizer_type,
            prepared.actual_optimizer_name,
            _,
            optimizer_fallback,
        ) = task._resolve_optimizer_type(prepared.optimizer_name)
        if optimizer_fallback and prepared.learning_rate is not None and prepared.learning_rate > 1e-3:
            prepared.learning_rate = 1e-3

        prepared._compile_and_select_artifacts(prepared.initialization_seed, emit)
        requested_batch = int(request.get("batch_size", 0))
        prepared.auto_batch_size = select_fixed_batch_size(
            prepared.workload_estimate,
            explicit_batch_size=requested_batch if requested_batch > 0 else None,
        )
        prepared.batch_calibration = {
            "strategy": "fixed",
            "explicit": requested_batch > 0,
            "selected": prepared.auto_batch_size,
            "selected_threads": prepared.session_profile.intra_op_threads,
        }
        prepared._create_runtime(prepared.artifact_entry.checkpoint, resumed=False)
        prepared._initial_parameters = prepared.parameter_snapshot()
        prepared.prepared_id = f"{prepared.artifact_entry.key}:{prepared.generation}:{uuid.uuid4().hex}"
        return prepared

    @property
    def optimizer_state_is_resumed(self) -> bool:
        return self._optimizer_state_is_resumed

    def parameter_snapshot(self) -> np.ndarray:
        value = self.module.get_contiguous_parameters(trainable_only=False)
        return np.asarray(value.numpy()).copy()

    def initial_snapshot(self) -> np.ndarray:
        if self._initial_parameters is None:
            raise RuntimeError("prepared session has no initial parameter snapshot")
        return self._initial_parameters.copy()

    def reset_fresh(self, seed: int | None) -> None:
        seed = int(seed) if seed is not None else None
        if seed != self.initialization_seed:
            self._compile_and_select_artifacts(seed, emit=None)
            self.initialization_seed = seed
            self._initial_parameters = None
        full_stage = self.freeze_stages[0]
        full_entry = self.artifact_entries[full_stage.name]
        self._create_runtime(
            full_entry.checkpoint,
            resumed=False,
            artifact_entry=full_entry,
            freeze_stage=full_stage,
        )
        if self._initial_parameters is None:
            self._initial_parameters = self.parameter_snapshot()
        self.freeze_fallback_reason = ""
        self._dirty = False

    def load_resume_checkpoint(self, path: str | Path) -> None:
        checkpoint = Path(path)
        if not checkpoint.is_file():
            raise FileNotFoundError(f"resume checkpoint does not exist: {checkpoint}")
        full_stage = self.freeze_stages[0]
        self._create_runtime(
            checkpoint,
            resumed=True,
            artifact_entry=self.artifact_entries[full_stage.name],
            freeze_stage=full_stage,
        )
        self._dirty = False

    def start(self, run_config: Dict[str, Any], emit: Emit, cancel) -> Dict[str, Any]:
        from . import train_task as task

        requested_generation = int(run_config.get("graph_generation", self.generation))
        if requested_generation != self.generation:
            raise StalePreparedSessionError(
                f"prepared generation {self.generation} cannot run generation {requested_generation}"
            )
        if not self._start_lock.acquire(blocking=False):
            raise RuntimeError("prepared session is already training")

        try:
            timer = StageTimer()
            request = copy.deepcopy(self.request)
            request.update(run_config)
            current_training_config = task._extract_training_config(request.get("train_graph", {}))
            requested_optimizer = current_training_config.get("optimizer", self.optimizer_name)
            if requested_optimizer != self.optimizer_name:
                raise StalePreparedSessionError(
                    f"prepared optimizer {self.optimizer_name} cannot run optimizer {requested_optimizer}"
                )
            requested_learning_rate = task._parse_float(
                current_training_config.get("lr"), self.learning_rate
            )
            _, _, _, optimizer_fallback = task._resolve_optimizer_type(requested_optimizer)
            if (
                optimizer_fallback
                and requested_learning_rate is not None
                and requested_learning_rate > 1e-3
            ):
                requested_learning_rate = 1e-3
            self.learning_rate = requested_learning_rate

            raw_seed = run_config.get(
                "seed", run_config.get("initialization_seed", self.initialization_seed)
            )
            seed = int(raw_seed) if raw_seed is not None else None
            resume_checkpoint = run_config.get("resume_checkpoint")
            if resume_checkpoint:
                self.load_resume_checkpoint(resume_checkpoint)
            elif self._dirty or self._optimizer_state_is_resumed or seed != self.initialization_seed:
                self.reset_fresh(seed)
            task._apply_learning_rate(self.optimizer, self.learning_rate)

            path_class = str(run_config.get("path_class") or "hot")
            epochs = max(1, int(request.get("epochs", 1)))
            requested_batch_size = int(request.get("batch_size", 0))
            batch_size = requested_batch_size or self.auto_batch_size
            # Decided by this run's epochs: the app prepares a session once
            # (its fingerprint leaves epochs out) and starts it with any count.
            algorithmic_enabled = (
                self.algorithmic_acceleration
                and bool(request.get("algorithmic_acceleration", True))
                and algorithmic_acceleration_eligible(
                    self.parameter_group_order,
                    epochs=epochs,
                    samples=len(self.dataset),
                    batch_size=batch_size,
                )
            )
            effective_learning_rate = self.learning_rate
            if requested_batch_size <= 0 and effective_learning_rate is not None:
                effective_learning_rate *= min(4.0, max(0.5, batch_size / 128.0))
            task._apply_learning_rate(self.optimizer, effective_learning_rate)
            job_dir = Path(request["job_dir"])
            artifact_dir = job_dir / "artifacts"
            checkpoint_dir = Path(request.get("checkpoint_dir") or artifact_dir)
            artifact_dir.mkdir(parents=True, exist_ok=True)
            checkpoint_dir.mkdir(parents=True, exist_ok=True)
            killed = False

            def on_kill() -> None:
                nonlocal killed
                killed = True

            if hasattr(cancel, "on_kill"):
                cancel.on_kill(on_kill)

            emit({
                "phase": "start",
                "mode": "train",
                "backend": "fullylocal_ort",
                "data": {
                    "prepared_id": self.prepared_id,
                    "path_class": path_class,
                    "artifact_cache_hit": self.cache_hit,
                    "session_profile": profile_dict(self.session_profile),
                    "batch_calibration": dict(self.batch_calibration),
                    "effective_learning_rate": effective_learning_rate,
                },
            })

            total_batches = (len(self.dataset) + batch_size - 1) // batch_size
            emit({
                "phase": "progress",
                "data": {
                    "stage": "training_ready",
                    "epochs": epochs,
                    "batches": total_batches,
                    "prepared_id": self.prepared_id,
                    "path_class": path_class,
                    "artifact_cache_hit": self.cache_hit,
                    "session_profile": profile_dict(self.session_profile),
                },
            })

            cancel_view = _CancellationView(cancel, lambda: killed)
            selective_keep_final = float(request.get("selective_keep_final", 0.80))

            def make_epoch_runner(size: int, runner_seed: int | None) -> EpochRunner:
                return EpochRunner(
                    self.dataset,
                    self.module,
                    self.optimizer,
                    batch_size=size,
                    seed=runner_seed,
                    use_ortvalue_inputs=(
                        self.reusable_cpu_ortvalue_inputs
                        and bool(request.get("use_ortvalue_inputs", True))
                    ),
                    schedule_policy=str(request.get("schedule_policy") or "auto"),
                    selective_policy=(
                        SelectiveBlockPolicy(final_keep_fraction=selective_keep_final)
                        if algorithmic_enabled
                        and bool(request.get("selective_backprop", True))
                        else None
                    ),
                )

            epoch_runner = make_epoch_runner(batch_size, seed)
            # Learning rate: cosine decay over the run for runs long enough to
            # have an end worth slowing down for; a constant rate otherwise.
            base_rate = effective_learning_rate
            if base_rate is None:
                get_rate = getattr(self.optimizer, "get_learning_rate", None)
                base_rate = float(get_rate()) if callable(get_rate) else None
            # Measured on CIFAR-10: cosine decay cost accuracy with freezing.
            lr_schedule = str(request.get("lr_schedule") or "constant")
            rate_scale = 1.0

            def rate_at(progress: float) -> float | None:
                if base_rate is None:
                    return None
                if lr_schedule == "cosine":
                    return cosine_learning_rate(base_rate * rate_scale, progress)
                return base_rate * rate_scale

            # Accelerated runs double the batch at each freeze stage: fewer,
            # larger steps once the early layers have settled.
            # Off by default: no faster on CIFAR-10, and no more accurate.
            batch_growth = algorithmic_enabled and bool(request.get("batch_growth", False))
            max_grown_batch = max(batch_size, min(512, len(self.dataset) // 8))
            head_feature_cache = algorithmic_enabled and bool(request.get("head_feature_cache", True))
            head: NumpyHead | None = None
            head_features: np.ndarray | None = None
            head_rng = np.random.default_rng(None if seed is None else int(seed) + 7919)
            feature_seconds = 0.0
            run_freeze_stages = freeze_schedule(
                self.parameter_group_order,
                epochs,
                enabled=algorithmic_enabled,
                **_freeze_options(request),
            )
            last_metrics: Dict[str, float] = {}
            last_eval_epoch = -1
            first_step_recorded = False
            final_inference_path: Path | None = None
            optimizer_state_resets = 0
            self._dirty = True

            with tempfile.TemporaryDirectory(prefix="neuralese_prepared_run_") as temp_dir_s:
                temp_dir = Path(temp_dir_s)
                for epoch in range(epochs):
                    if killed or bool(getattr(cancel, "closed", False)):
                        break
                    desired_stage = run_freeze_stages[0]
                    for candidate in run_freeze_stages:
                        if candidate.start_epoch <= epoch:
                            desired_stage = candidate
                    if (
                        not self.freeze_fallback_reason
                        and self.active_freeze_stage is not None
                        and desired_stage.name != self.active_freeze_stage.name
                    ):
                        if desired_stage.name not in self.artifact_entries:
                            self.freeze_fallback_reason = (
                                f"artifact '{desired_stage.name}' was not prepared"
                            )
                            emit({
                                "phase": "progress",
                                "data": {
                                    "stage": "freeze_stage_fallback",
                                    "requested_freeze_stage": desired_stage.name,
                                    "reason": self.freeze_fallback_reason,
                                },
                            })
                        elif self._switch_freeze_stage(desired_stage, emit):
                            optimizer_state_resets += 1
                            grown = min(max_grown_batch, batch_size * 2) if batch_growth else batch_size
                            if grown != batch_size:
                                rate_scale *= float(np.sqrt(grown / batch_size))
                                batch_size = grown
                                total_batches = (len(self.dataset) + batch_size - 1) // batch_size
                                epoch_runner = make_epoch_runner(
                                    batch_size, None if seed is None else int(seed) + epoch
                                )
                            else:
                                epoch_runner.module = self.module
                                epoch_runner.optimizer = self.optimizer
                            layer = (
                                find_head_layer(self.model_proto, desired_stage.trainable_params, self.loss_name)
                                if head_feature_cache and desired_stage.name == "head"
                                else None
                            )
                            if layer is not None and features_fit(len(self.dataset), layer):
                                feature_started = perf_counter()
                                parameters = {
                                    name: np.asarray(parameter.data)
                                    for name, parameter in self.state.parameters
                                }
                                head_features = compute_features(
                                    self.model_proto,
                                    parameters,
                                    self.dataset,
                                    layer,
                                    threads=self.session_profile.intra_op_threads,
                                )
                                head = NumpyHead(
                                    layer,
                                    parameters[layer.weight],
                                    parameters.get(layer.bias) if layer.bias else None,
                                    loss_name=self.loss_name,
                                    optimizer=self.actual_optimizer_name,
                                )
                                feature_seconds = perf_counter() - feature_started
                                emit({
                                    "phase": "progress",
                                    "data": {
                                        "stage": "head_feature_cache",
                                        "features": int(layer.in_features),
                                        "seconds": feature_seconds,
                                    },
                                })
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

                    def record_first_step() -> None:
                        nonlocal first_step_recorded
                        if not first_step_recorded:
                            timer.mark("first_step")
                            first_step_recorded = True

                    def epoch_rate(batch_index: int, batches: int, epoch: int = epoch) -> float | None:
                        return rate_at((epoch + batch_index / max(1, batches)) / epochs)

                    if head is not None and head_features is not None:
                        # Everything before the head is frozen: train it on the
                        # features computed once at the start of this stage.
                        head_loss, head_batches = head.train_epoch(
                            head_features,
                            self.dataset.y,
                            batch_size=batch_size,
                            rng=head_rng,
                            lr_at=lambda index, batches: epoch_rate(index, batches) or 1e-3,
                        )
                        head.write_back(self.state)
                        epoch_result = EpochResult(
                            average_loss=head_loss,
                            batches=head_batches,
                            train_seconds=perf_counter() - epoch_started,
                            available_batches=head_batches,
                            coverage=1.0,
                        )
                    else:
                        epoch_runner.learning_rate_at = (
                            epoch_rate if base_rate is not None else None
                        )
                        epoch_result = epoch_runner.run_epoch(
                            epoch,
                            epochs,
                            cancel_view,
                            emit,
                            record_first_step if not first_step_recorded else None,
                        )

                    if epoch_result.stopped or killed or bool(getattr(cancel, "closed", False)):
                        break

                    average_loss = epoch_result.average_loss
                    batches_count = epoch_result.batches
                    should_evaluate = (
                        epoch == 0
                        or (epoch + 1) % task.EXPORT_EVAL_INTERVAL == 0
                        or epoch == epochs - 1
                    )
                    metrics = last_metrics
                    eval_seconds = 0.0
                    if should_evaluate:
                        eval_started = perf_counter()
                        max_eval = None if epoch == epochs - 1 else task.EVAL_MAX_SAMPLES
                        metrics = task.evaluate_module(
                            self.module,
                            self.dataset,
                            self.loss_name,
                            max_samples=max_eval,
                            batch_size=batch_size,
                        )
                        last_metrics = metrics
                        last_eval_epoch = epoch
                        eval_seconds = perf_counter() - eval_started

                    emit({
                        "phase": "state",
                        "data": {
                            "epoch": epoch,
                            "left": epochs - epoch - 1,
                            "type": "loss",
                            "data": {
                                "train_loss": average_loss,
                                "val_loss": metrics.get("val_loss", average_loss),
                                "train_acc": metrics.get("train_acc", 0.0),
                                "val_acc": metrics.get("val_acc", 0.0),
                                "length": batches_count,
                                "available_batches": epoch_result.available_batches,
                                "coverage": epoch_result.coverage,
                                "batch_size": batch_size,
                                "freeze_stage": (
                                    self.active_freeze_stage.name
                                    if self.active_freeze_stage is not None
                                    else "full"
                                ),
                                "evaluated": should_evaluate,
                                "last_evaluated_epoch": last_eval_epoch,
                                "head_feature_cache": head is not None,
                                "learning_rate": rate_at((epoch + 1) / epochs),
                                "epoch_seconds": perf_counter() - epoch_started,
                                "eval_seconds": eval_seconds,
                                "train_cpu_seconds": float(
                                    (epoch_result.breakdown or {}).get("process_cpu_seconds", 0.0)
                                ),
                            },
                        },
                    })

            stopped = killed or bool(getattr(cancel, "closed", False))

            timer.begin("export")
            inference_path = temp_dir / "inference.onnx"
            task.export_model_from_state(self.model_proto, self.state, inference_path)
            task._restore_visual_output_softmax_for_inference(
                inference_path, self.request["graph"], self.loss_name
            )
            final_inference_path = artifact_dir / "inference.onnx"
            artifact_publish = artifact_dir / f".inference.{uuid.uuid4().hex}.tmp"
            shutil.copy2(inference_path, artifact_publish)
            artifact_publish.replace(final_inference_path)
            checkpoint_inference_path = checkpoint_dir / "inference.onnx"
            if final_inference_path.resolve() != checkpoint_inference_path.resolve():
                checkpoint_publish = checkpoint_dir / f".inference.{uuid.uuid4().hex}.tmp"
                shutil.copy2(final_inference_path, checkpoint_publish)
                checkpoint_publish.replace(checkpoint_inference_path)
            timer.end("export")
            task._save_required_checkpoint(self.ort_train_api, self.state, checkpoint_dir)
            result = {
                "status": "stopped" if stopped else "ok",
                "backend": "fullylocal_ort",
                "artifact": str(checkpoint_dir / "inference.onnx") if final_inference_path else "",
                "checkpoint_dir": str(checkpoint_dir),
                "dataset": self.dataset.name,
                "prepared_id": self.prepared_id,
                "path_class": path_class,
                "artifact_cache_hit": self.cache_hit,
                "session_profile": profile_dict(self.session_profile),
                "batch_calibration": dict(self.batch_calibration),
                "effective_learning_rate": effective_learning_rate,
                "algorithmic_acceleration": algorithmic_enabled,
                "freeze_stage": (
                    self.active_freeze_stage.name
                    if self.active_freeze_stage is not None
                    else "full"
                ),
                "freeze_schedule": [
                    {
                        "name": stage.name,
                        "start_epoch": stage.start_epoch,
                        "trainable_parameters": len(stage.trainable_params),
                    }
                    for stage in run_freeze_stages
                ],
                "optimizer_state_resets": optimizer_state_resets,
                "freeze_fallback_reason": self.freeze_fallback_reason,
                "lr_schedule": lr_schedule,
                "final_batch_size": batch_size,
                "head_feature_cache": head is not None,
                "head_feature_seconds": feature_seconds,
                "workload_estimate": {
                    "samples": self.workload_estimate.samples,
                    "bytes_per_sample": self.workload_estimate.bytes_per_sample,
                    "parameters": self.workload_estimate.parameters,
                    "macs_per_epoch": self.workload_estimate.macs_per_epoch,
                    "heavy_ops": self.workload_estimate.heavy_ops,
                },
            }
            timer.mark("total")
            result["timings_ms"] = timer.snapshot()
            manifest = {
                **result,
                "context": request.get("context", ""),
                "scene_id": request.get("scene_id", ""),
                "model_outputs": self.model_output_names,
                "loss": self.loss_name,
                "optimizer": self.optimizer_name,
                "actual_optimizer": self.actual_optimizer_name,
                "learning_rate": self.learning_rate,
                "initialization_seed": seed,
                "resumed": self._optimizer_state_is_resumed,
                "export_eval_interval": task.EXPORT_EVAL_INTERVAL,
            }
            (checkpoint_dir / "manifest.json").write_text(
                json.dumps(manifest, indent=2), encoding="utf-8"
            )
            (job_dir / "result.json").write_text(
                json.dumps(result, indent=2), encoding="utf-8"
            )
            emit({"phase": "stopped" if stopped else "done", "data": result})
            return result
        finally:
            self._start_lock.release()

    def _compile_and_select_artifacts(self, seed: int | None, emit: Emit | None) -> None:
        from . import train_task as task

        if emit is not None:
            emit({"phase": "progress", "data": {"stage": "building_model"}})
        random_state = np.random.get_state() if seed is not None else None
        try:
            if seed is not None:
                np.random.seed(int(seed))
            self.model_proto, params = task.build_onnx_model_from_graph(
                self.request["graph"], loss_name=self.loss_name
            )
        finally:
            if random_state is not None:
                np.random.set_state(random_state)
        self.trainable_params = list(params)
        self.parameter_group_order = parameter_groups(self.model_proto, self.trainable_params)
        task._validate_training_shapes(self.dataset, self.model_proto, self.loss_name)
        if not self.trainable_params:
            raise task.UserFacingRuntimeError(
                "training_no_trainable_parameters", "The graph has no trainable parameters"
            )
        self.model_output_names = [out.name for out in self.model_proto.graph.output]
        if emit is not None:
            emit({
                "phase": "progress",
                "data": {
                    "stage": "model_ready",
                    "operators": len(self.model_proto.graph.node),
                    "trainable_parameters": len(self.trainable_params),
                },
            })

        capability = default_capability()
        capabilities_path = self.artifact_cache.root.parent / "training_capabilities.json"
        training_capabilities = load_capabilities(
            capabilities_path, capability["ort_version"]
        )
        if training_capabilities is None:
            training_capabilities = probe_capabilities(capabilities_path)
        self.artifact_format = training_capabilities.artifact_format
        self.nominal_checkpoint = training_capabilities.nominal_checkpoint
        # Reusable wrappers were an epoch win only for Conv training in the
        # interleaved matrix; small Dense workloads were faster through NumPy.
        # Select by graph operators, never by dataset name.
        has_convolution = any(
            str(node.op_type) == "Conv" for node in self.model_proto.graph.node
        )
        self.reusable_cpu_ortvalue_inputs = bool(
            training_capabilities.reusable_cpu_ortvalue_inputs and has_convolution
        )
        capability["artifact_format"] = self.artifact_format
        capability["checkpoint_mode"] = (
            "nominal" if self.nominal_checkpoint else "complete"
        )
        capability["training_output_contract"] = task.TRAINING_OUTPUT_CONTRACT
        self.workload_estimate = estimate_workload(self.dataset, self.model_proto)
        self.session_profile = select_profile(self.workload_estimate)
        requested_batch = int(self.request.get("batch_size", 0))
        policy_batch = select_fixed_batch_size(
            self.workload_estimate,
            explicit_batch_size=requested_batch if requested_batch > 0 else None,
        )
        # Prepared before the run's epochs are known (the app prepares once and
        # starts with any count): prepare every stage a long run would use;
        # start() decides from its own epochs whether to use them.
        stage_epochs = max(PREPARED_STAGE_EPOCHS, int(self.request.get("epochs", 1)))
        self.algorithmic_acceleration = bool(
            self.request.get("algorithmic_acceleration", True)
        ) and algorithmic_acceleration_eligible(
            self.parameter_group_order,
            epochs=stage_epochs,
            samples=len(self.dataset),
            batch_size=policy_batch,
        )
        self.freeze_stages = freeze_schedule(
            self.parameter_group_order,
            stage_epochs,
            enabled=self.algorithmic_acceleration,
            **_freeze_options(self.request),
        )
        if seed is None:
            capability["initialization_seed"] = "ambient"
            capability["initializer_hash"] = hashlib.sha256(
                self.model_proto.SerializeToString(deterministic=True)
            ).hexdigest()
        else:
            capability["initialization_seed"] = str(int(seed))
        if emit is not None:
            emit({"phase": "progress", "data": {"stage": "preparing_training"}})
        self.artifact_entries = {}
        for stage in self.freeze_stages:
            stage_capability = dict(capability)
            stage_capability["freeze_stage"] = stage.name
            key = artifact_fingerprint(
                self.model_proto,
                stage.trainable_params,
                self.loss_name,
                self.actual_optimizer_name,
                stage_capability,
            )
            spec = {
                "fingerprint": key,
                "loss": self.loss_name,
                "optimizer": self.actual_optimizer_name,
                "trainable_params": sorted(stage.trainable_params),
                "frozen_params": sorted(
                    set(self.trainable_params) - set(stage.trainable_params)
                ),
                "capability": stage_capability,
                "artifact_format": self.artifact_format,
                "checkpoint_mode": capability["checkpoint_mode"],
                "training_output_contract": task.TRAINING_OUTPUT_CONTRACT,
                "freeze_stage": stage.name,
            }
            stage_params = list(stage.trainable_params)
            frozen_params = sorted(
                set(self.trainable_params) - set(stage.trainable_params)
            )
            self.artifact_entries[stage.name] = self.artifact_cache.get_or_create(
                spec,
                lambda target, params=stage_params, frozen=frozen_params: (
                    task._generate_training_artifacts(
                        target,
                        self.ort_artifacts,
                        self.model_proto,
                        params,
                        self.loss_name,
                        self.optimizer_type,
                        self.artifact_format,
                        self.nominal_checkpoint,
                        frozen_params=frozen,
                    )
                ),
            )
        self.active_freeze_stage = self.freeze_stages[0]
        self.artifact_entry = self.artifact_entries[self.active_freeze_stage.name]
        self.cache_hit = all(entry.cache_hit for entry in self.artifact_entries.values())
        self.freeze_fallback_reason = ""

    def _build_runtime(self, artifact_entry: ArtifactEntry, checkpoint: Path):
        from . import train_task as task

        state = self.ort_train_api.CheckpointState.load_checkpoint(str(checkpoint))
        module = self.ort_train_api.Module(
            str(artifact_entry.training_model),
            state,
            str(artifact_entry.eval_model),
            device="cpu",
            session_options=build_session_options(
                self.session_profile, self.session_option_variant
            ),
        )
        optimizer = self.ort_train_api.Optimizer(
            str(artifact_entry.optimizer_model), module
        )
        task._apply_learning_rate(optimizer, self.learning_rate)
        return state, module, optimizer

    def _create_runtime(
        self,
        checkpoint: Path,
        resumed: bool,
        *,
        artifact_entry: ArtifactEntry | None = None,
        freeze_stage: FreezeStage | None = None,
    ) -> None:
        artifact_entry = artifact_entry or self.artifact_entry
        if artifact_entry is None:
            raise RuntimeError("prepared session has no artifact entry")
        self.state, self.module, self.optimizer = self._build_runtime(
            artifact_entry, checkpoint
        )
        self.artifact_entry = artifact_entry
        if freeze_stage is not None:
            self.active_freeze_stage = freeze_stage
        self._optimizer_state_is_resumed = bool(resumed)

    def _switch_freeze_stage(self, stage: FreezeStage, emit: Emit) -> bool:
        if (
            self.active_freeze_stage is not None
            and stage.name == self.active_freeze_stage.name
        ):
            return True
        artifact_entry = self.artifact_entries.get(stage.name)
        if artifact_entry is None:
            self.freeze_fallback_reason = f"artifact '{stage.name}' was not prepared"
            return False

        try:
            parameter_buffer = self.module.get_contiguous_parameters(trainable_only=False)
            state, module, optimizer = self._build_runtime(
                artifact_entry, artifact_entry.checkpoint
            )
            module.copy_buffer_to_parameters(parameter_buffer, trainable_only=False)
        except Exception as exc:
            self.freeze_fallback_reason = f"{type(exc).__name__}: {exc}"
            emit({
                "phase": "progress",
                "data": {
                    "stage": "freeze_stage_fallback",
                    "requested_freeze_stage": stage.name,
                    "reason": self.freeze_fallback_reason,
                },
            })
            return False

        self.state = state
        self.module = module
        self.optimizer = optimizer
        self.artifact_entry = artifact_entry
        self.active_freeze_stage = stage
        self._optimizer_state_is_resumed = False
        emit({
            "phase": "progress",
            "data": {
                "stage": "freeze_stage",
                "freeze_stage": stage.name,
                "trainable_parameters": len(stage.trainable_params),
                "optimizer_state_reset": True,
            },
        })
        return True
