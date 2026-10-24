from __future__ import annotations

import argparse
import hashlib
import json
import os
import platform
import statistics
import sys
import tempfile
import threading
import time
from pathlib import Path
from typing import Any

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
from training_benchmark_scenarios import RUNTIME_ROOT, SCENARIOS, scenario_request
sys.path.insert(0, str(RUNTIME_ROOT))


class NeverStop:
    closed = False

    def on_kill(self, _callback) -> None:
        return


class ResponsivenessProbe:
    def __init__(self, interval_s: float = 0.002) -> None:
        self.interval_s = interval_s
        self.max_gap_ms = 0.0
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        def run() -> None:
            previous = time.perf_counter()
            while not self._stop.wait(self.interval_s):
                now = time.perf_counter()
                self.max_gap_ms = max(self.max_gap_ms, (now - previous) * 1000.0)
                previous = now

        self._thread = threading.Thread(target=run, name="epoch-benchmark-responsiveness", daemon=True)
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()
        if self._thread is not None:
            self._thread.join(timeout=1.0)


def interleaved_order(repetitions: int) -> list[str]:
    return [name for _ in range(max(0, int(repetitions))) for name in ("A", "B", "B", "A")]


def execution_seed(base_seed: int, execution_index: int, *, paired: bool) -> int:
    offset = int(execution_index) // 2 if paired else int(execution_index)
    return int(base_seed) + offset


def _percentile(values: list[float], fraction: float) -> float:
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, round((len(ordered) - 1) * fraction)))
    return float(ordered[index])


def _rss_mib() -> float:
    try:
        import psutil

        return psutil.Process().memory_info().rss / (1024.0 * 1024.0)
    except (ImportError, OSError):
        return 0.0


def runtime_metadata() -> dict[str, Any]:
    import onnxruntime as ort

    return {
        "python_version": platform.python_version(),
        "numpy_version": np.__version__,
        "ort_version": ort.__version__,
        "cpu": platform.processor() or platform.machine(),
        "logical_cpus": int(os.cpu_count() or 1),
        "platform": platform.platform(),
    }


def epoch_rows_from_events(
    events: list[dict[str, Any]],
    metadata: dict[str, Any],
    *,
    discard_warmup: bool = True,
) -> list[dict[str, Any]]:
    rows: list[dict[str, Any]] = []
    states = [packet for packet in events if packet.get("phase") == "state"]
    if discard_warmup and states:
        states = states[1:]
    for packet in states:
        outer = packet.get("data") or {}
        data = outer.get("data") or {}
        epoch_ms = float(data.get("epoch_seconds", 0.0)) * 1000.0
        eval_ms = float(data.get("eval_seconds", 0.0)) * 1000.0
        rows.append({
            **metadata,
            "record_type": "epoch",
            "epoch": int(outer.get("epoch", len(rows))),
            "batches": int(data.get("length", 0)),
            "available_batches": int(data.get("available_batches", data.get("length", 0))),
            "coverage": float(data.get("coverage", 1.0)),
            "freeze_stage": str(data.get("freeze_stage") or "full"),
            "loss": float(data.get("train_loss", 0.0)),
            "val_loss": float(data.get("val_loss", data.get("train_loss", 0.0))),
            "val_acc": float(data.get("val_acc", 0.0)),
            "train_only_ms": max(0.0, epoch_ms - eval_ms),
            "eval_ms": eval_ms,
            "train_cpu_ms": float(data.get("train_cpu_seconds", 0.0)) * 1000.0,
            "evaluated": bool(data.get("evaluated", False)),
        })
    return rows


def _configuration(name: str, batch_size: int, option_variant: str) -> dict[str, Any]:
    if name == "safe":
        return {
            "batch_size": batch_size if batch_size > 0 else 128,
            "schedule_policy": "exact",
            "use_ortvalue_inputs": False,
            "session_option_variant": "safe",
        }
    if name == "numpy":
        return {
            "batch_size": batch_size,
            "schedule_policy": "auto",
            "use_ortvalue_inputs": False,
            "session_option_variant": option_variant,
        }
    return {
        "batch_size": batch_size,
        "schedule_policy": "auto",
        "use_ortvalue_inputs": True,
        "session_option_variant": option_variant,
    }


def run_configuration(
    scenario: str,
    configuration_name: str,
    *,
    execution_index: int,
    epochs: int,
    batch_size: int,
    seed: int,
    option_variant: str,
    algorithmic_acceleration: bool = True,
    profile_epoch: int | None = None,
    profile_output: Path | None = None,
) -> list[dict[str, Any]]:
    from neuralese_local.prepared_training import PreparedSession
    from neuralese_local.training_artifact_cache import ArtifactCache
    from neuralese_local.training_dataset_cache import TrainingDatasetCache

    config = _configuration(configuration_name, batch_size, option_variant)
    config["benchmark_session_options"] = True
    config["algorithmic_acceleration"] = bool(algorithmic_acceleration)
    with tempfile.TemporaryDirectory(prefix="neuralese_epoch_bench_") as root_s:
        root = Path(root_s)
        request = scenario_request(
            scenario,
            root,
            epochs=max(2, int(epochs) + 1),
            batch_size=int(config["batch_size"]),
            seed=seed,
            artifact_cache=root / "cache" / "artifacts",
        )
        request.update(config)
        datasets = TrainingDatasetCache(RUNTIME_ROOT)
        datasets.warm_builtins()
        artifacts = ArtifactCache(root / "cache" / "artifacts")
        prepared = PreparedSession.prepare(request, datasets, artifacts)
        events: list[dict[str, Any]] = []

        responsiveness = ResponsivenessProbe()
        responsiveness.start()
        if profile_output is None:
            prepared.start(request, events.append, NeverStop())
        else:
            import cProfile

            profiler = cProfile.Profile()

            def emit(packet: dict[str, Any]) -> None:
                data = packet.get("data") or {}
                epoch = int(data.get("epoch", -1))
                if packet.get("phase") == "progress" and data.get("stage") == "epoch_start" and epoch == profile_epoch:
                    profiler.enable()
                elif packet.get("phase") == "state" and epoch == profile_epoch:
                    profiler.disable()
                events.append(packet)

            prepared.start(request, emit, NeverStop())
            profile_output.parent.mkdir(parents=True, exist_ok=True)
            profiler.dump_stats(str(profile_output))
        responsiveness.stop()

        actual_batch = int(prepared.auto_batch_size if int(config["batch_size"]) <= 0 else config["batch_size"])
        graph_bytes = prepared.model_proto.SerializeToString(deterministic=True)
        metadata = {
            "scenario": scenario,
            "configuration": configuration_name,
            "execution_index": execution_index,
            "seed": seed,
            "graph_fingerprint": hashlib.sha256(graph_bytes).hexdigest(),
            "input_shape": list(prepared.dataset.x.shape),
            "input_dtype": str(prepared.dataset.x.dtype),
            "target_shape": list(prepared.dataset.y.shape),
            "target_dtype": str(prepared.dataset.y.dtype),
            "batch_size": actual_batch,
            "threads": int(prepared.session_profile.intra_op_threads),
            "schedule_policy": str(config["schedule_policy"]),
            "ortvalue_inputs": bool(config["use_ortvalue_inputs"]),
            "session_option_variant": str(config["session_option_variant"]),
            "algorithmic_acceleration": bool(config["algorithmic_acceleration"]),
            "session_options": __import__(
                "neuralese_local.training_profile", fromlist=["session_option_settings"]
            ).session_option_settings(str(config["session_option_variant"])),
            "responsiveness_max_gap_ms": responsiveness.max_gap_ms,
            "rss_mib": _rss_mib(),
            **runtime_metadata(),
        }
        return epoch_rows_from_events(events, metadata, discard_warmup=True)


def summarize(rows: list[dict[str, Any]]) -> list[dict[str, Any]]:
    grouped: dict[tuple[str, str, str, bool], list[dict[str, Any]]] = {}
    for row in rows:
        grouped.setdefault(
            (
                row["scenario"],
                row["configuration"],
                row["session_option_variant"],
                bool(row.get("algorithmic_acceleration", False)),
            ),
            [],
        ).append(row)
    summaries = []
    for (scenario, configuration, option_variant, acceleration), values in grouped.items():
        train = [float(row["train_only_ms"]) for row in values]
        cpu = [float(row["train_cpu_ms"]) for row in values]
        responsiveness = [float(row["responsiveness_max_gap_ms"]) for row in values]
        validation = [float(row["eval_ms"]) for row in values if row["evaluated"]]
        coverage = [float(row.get("coverage", 1.0)) for row in values]
        final_by_execution: dict[int, dict[str, Any]] = {}
        for row in values:
            execution = int(row.get("execution_index", 0))
            current = final_by_execution.get(execution)
            if current is None or int(row.get("epoch", -1)) > int(current.get("epoch", -1)):
                final_by_execution[execution] = row
        final_rows = list(final_by_execution.values())
        final_accuracy = [float(row.get("val_acc", 0.0)) for row in final_rows]
        final_loss = [float(row.get("val_loss", row.get("loss", 0.0))) for row in final_rows]
        summaries.append({
            "record_type": "summary",
            "scenario": scenario,
            "configuration": configuration,
            "session_option_variant": option_variant,
            "algorithmic_acceleration": acceleration,
            "samples": len(values),
            "train_only_ms_p50": statistics.median(train),
            "train_only_ms_p95": _percentile(train, 0.95),
            "train_cpu_ms_p50": statistics.median(cpu),
            "responsiveness_max_gap_ms_p95": _percentile(responsiveness, 0.95),
            "eval_ms_p50": statistics.median(validation) if validation else 0.0,
            "eval_ms_p95": _percentile(validation, 0.95) if validation else 0.0,
            "coverage_p50": statistics.median(coverage),
            "coverage_p95": _percentile(coverage, 0.95),
            "final_val_acc_p50": statistics.median(final_accuracy),
            "final_val_loss_p50": statistics.median(final_loss),
            "freeze_stages": sorted({str(row.get("freeze_stage") or "full") for row in values}),
        })
    return summaries


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", choices=tuple(SCENARIOS), action="append")
    parser.add_argument("--runs", type=int, default=7)
    parser.add_argument("--epochs", type=int, default=7)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--seed", type=int, default=17)
    configurations = ("safe", "optimized", "numpy", "ortvalue")
    parser.add_argument("--compare", nargs=2, choices=configurations)
    parser.add_argument("--configuration", choices=configurations, default="optimized")
    parser.add_argument("--option-variant", default="safe")
    parser.add_argument(
        "--algorithmic-acceleration", choices=("on", "off"), default="on"
    )
    parser.add_argument("--compare-algorithmic", action="store_true")
    parser.add_argument(
        "--compare-options", nargs=2, choices=tuple(__import__(
            "neuralese_local.training_profile", fromlist=["SESSION_OPTION_VARIANTS"]
        ).SESSION_OPTION_VARIANTS),
    )
    parser.add_argument("--profile-epoch", type=int)
    parser.add_argument("--profile-output", type=Path)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args(argv)
    sys.path.insert(0, str(RUNTIME_ROOT))

    scenarios = args.scenario or list(SCENARIOS)
    rows: list[dict[str, Any]] = []
    execution_index = 0
    requested_acceleration = args.algorithmic_acceleration == "on"
    paired_execution = bool(
        args.compare_algorithmic or args.compare_options or args.compare
    )
    for scenario in scenarios:
        if args.compare_algorithmic:
            aliases = {"A": False, "B": True}
            executions = [
                (args.configuration, args.option_variant, aliases[name])
                for name in interleaved_order(args.runs)
            ]
        elif args.compare_options:
            aliases = {"A": args.compare_options[0], "B": args.compare_options[1]}
            executions = [
                ("optimized", aliases[name], requested_acceleration)
                for name in interleaved_order(args.runs)
            ]
        else:
            names = interleaved_order(args.runs) if args.compare else [args.configuration] * args.runs
            if args.compare:
                aliases = {"A": args.compare[0], "B": args.compare[1]}
                names = [aliases[name] for name in names]
            executions = [
                (name, args.option_variant, requested_acceleration) for name in names
            ]
        for configuration_name, execution_variant, acceleration in executions:
            rows.extend(run_configuration(
                scenario,
                configuration_name,
                execution_index=execution_index,
                epochs=args.epochs,
                batch_size=args.batch_size,
                seed=execution_seed(
                    args.seed, execution_index, paired=paired_execution
                ),
                option_variant=execution_variant,
                algorithmic_acceleration=acceleration,
                profile_epoch=args.profile_epoch,
                profile_output=args.profile_output if execution_index == 0 else None,
            ))
            execution_index += 1
    output_rows = [*rows, *summarize(rows)]
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(
        "".join(json.dumps(row, sort_keys=True) + "\n" for row in output_rows),
        encoding="utf-8",
    )
    for summary in summarize(rows):
        print(json.dumps(summary, sort_keys=True))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
