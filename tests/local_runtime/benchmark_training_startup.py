from __future__ import annotations

import argparse
import json
import os
import statistics
import subprocess
import sys
import tempfile
from pathlib import Path
from time import perf_counter

sys.path.insert(0, str(Path(__file__).resolve().parent))
from training_benchmark_scenarios import RUNTIME_ROOT, SCENARIOS, scenario_graph, scenario_request



class NeverStop:
    closed = False

    def on_kill(self, _callback) -> None:
        return


def _result_record(
    scenario: str,
    path_class: str,
    iteration: int,
    result: dict,
    events: list[dict],
    total_ms: float,
    batch_size: int,
    prepare_ms: float = 0.0,
    prepared_session_reused: bool = False,
) -> dict:
    from neuralese_local.dataset_store import load_builtin_dataset

    dataset = load_builtin_dataset(RUNTIME_ROOT, SCENARIOS[scenario]["dataset"])
    epoch_events = [packet.get("data", {}).get("data", {}) for packet in events if packet.get("phase") == "state"]
    last_epoch = epoch_events[-1] if epoch_events else {}
    epoch_records = [
        {
            "epoch": int(packet.get("data", {}).get("epoch", index)),
            "evaluated": bool(epoch.get("evaluated", False)),
            "epoch_ms": float(epoch.get("epoch_seconds", 0.0)) * 1000.0,
            "eval_ms": float(epoch.get("eval_seconds", 0.0)) * 1000.0,
            "train_only_ms": max(
                0.0,
                float(epoch.get("epoch_seconds", 0.0)) * 1000.0
                - float(epoch.get("eval_seconds", 0.0)) * 1000.0,
            ),
            "batches": int(epoch.get("length", 0)),
        }
        for index, (packet, epoch) in enumerate(zip(
            [packet for packet in events if packet.get("phase") == "state"], epoch_events
        ))
    ]
    steady_epochs = [row["train_only_ms"] for row in epoch_records[1:-1]]
    if not steady_epochs:
        steady_epochs = [row["train_only_ms"] for row in epoch_records]
    timings = result.get("timings_ms", {})
    return {
        "scenario": scenario,
        "iteration": iteration,
        "path_class": path_class,
        "samples": len(dataset),
        "batch_size": batch_size,
        "epochs": len(epoch_records),
        "graph_nodes": len(scenario_graph(scenario)["nodes"]),
        "prepare_ms": prepare_ms,
        "click_to_first_step_ms": timings.get("first_step"),
        "epoch_ms": float(last_epoch.get("epoch_seconds", 0.0)) * 1000.0,
        "eval_ms": float(last_epoch.get("eval_seconds", 0.0)) * 1000.0,
        "steady_train_epoch_ms": statistics.median(steady_epochs) if steady_epochs else None,
        "epoch_records": epoch_records,
        "export_ms": timings.get("export"),
        "total_ms": total_ms,
        "artifact_cache_hit": result.get("artifact_cache_hit"),
        "prepared_session_reused": prepared_session_reused,
        "session_profile": result.get("session_profile", {}),
        "peak_rss_mib": _peak_rss_mib(),
        "status": result.get("status"),
    }


def _run_one_shot(
    scenario: str,
    root: Path,
    artifact_cache: Path,
    iteration: int,
    epochs: int,
    batch_size: int,
) -> dict:
    from neuralese_local.train_task import run_training

    events: list[dict] = []
    started = perf_counter()
    result = run_training(
        scenario_request(
            scenario, root, epochs=epochs, batch_size=batch_size, seed=17,
            artifact_cache=artifact_cache,
        ),
        events.append,
        NeverStop(),
    )
    return _result_record(
        scenario, "cold", iteration, result, events, (perf_counter() - started) * 1000.0,
        batch_size,
    )


def benchmark_cold(scenario: str, repeats: int, epochs: int, batch_size: int) -> list[dict]:
    records = []
    for iteration in range(repeats):
        with tempfile.TemporaryDirectory(prefix="neuralese_cold_parent_") as root_s:
            command = [
                sys.executable, str(Path(__file__).resolve()), "--child-one",
                "--scenario", scenario, "--iteration", str(iteration), "--work-root", root_s,
                "--epochs", str(epochs), "--batch-size", str(batch_size),
            ]
            started = perf_counter()
            completed = subprocess.run(command, check=True, capture_output=True, text=True)
            record_line = next(
                line for line in reversed(completed.stdout.splitlines()) if line.startswith("BENCH_JSON=")
            )
            record = json.loads(record_line.removeprefix("BENCH_JSON="))
            record["process_total_ms"] = (perf_counter() - started) * 1000.0
            records.append(record)
    return records


def benchmark_resident(
    scenario: str,
    path_class: str,
    repeats: int,
    epochs: int,
    batch_size: int,
    profile_output: Path | None = None,
    intra_op_threads: int | None = None,
) -> list[dict]:
    from neuralese_local.prepared_training import PreparedSession
    from neuralese_local.training_artifact_cache import ArtifactCache
    from neuralese_local.training_dataset_cache import TrainingDatasetCache

    records = []
    with tempfile.TemporaryDirectory(prefix=f"neuralese_{path_class}_") as root_s:
        root = Path(root_s)
        datasets = TrainingDatasetCache(RUNTIME_ROOT)
        datasets.warm_builtins()
        artifacts = ArtifactCache(root / "cache" / "artifacts")
        prepared = None
        if path_class == "hot":
            prepare_started = perf_counter()
            prepared = PreparedSession.prepare(
                scenario_request(
                    scenario, root, epochs=epochs, batch_size=batch_size, seed=17,
                    artifact_cache=artifacts.root,
                ),
                datasets,
                artifacts,
            )
            initial_prepare_ms = (perf_counter() - prepare_started) * 1000.0
            if intra_op_threads is not None:
                from dataclasses import replace

                prepared.session_profile = replace(
                    prepared.session_profile, intra_op_threads=max(1, intra_op_threads)
                )
                prepared._create_runtime(prepared.artifact_entry.checkpoint, resumed=False)
                prepared._initial_parameters = prepared.parameter_snapshot()
        else:
            initial_prepare_ms = 0.0

        for iteration in range(repeats):
            run_root = root / f"run-{iteration}"
            request = scenario_request(
                scenario, run_root, epochs=epochs, batch_size=batch_size, seed=17,
                artifact_cache=artifacts.root,
            )
            prepare_ms = initial_prepare_ms if iteration == 0 else 0.0
            if path_class == "warm":
                prepare_started = perf_counter()
                prepared = PreparedSession.prepare(request, datasets, artifacts)
                prepare_ms = (perf_counter() - prepare_started) * 1000.0
                if intra_op_threads is not None:
                    from dataclasses import replace

                    prepared.session_profile = replace(
                        prepared.session_profile, intra_op_threads=max(1, intra_op_threads)
                    )
                    prepared._create_runtime(prepared.artifact_entry.checkpoint, resumed=False)
                    prepared._initial_parameters = prepared.parameter_snapshot()
            else:
                prepared.request["job_dir"] = request["job_dir"]
                prepared.request["checkpoint_dir"] = request["checkpoint_dir"]
            events: list[dict] = []
            started = perf_counter()
            if profile_output is not None and iteration == 0:
                import cProfile

                profiler = cProfile.Profile()
                profile_epoch = 1 if epochs > 2 else 0

                def capture_profiled_epoch(packet: dict) -> None:
                    data = packet.get("data", {}) if isinstance(packet.get("data"), dict) else {}
                    if (
                        packet.get("phase") == "progress"
                        and data.get("stage") == "epoch_start"
                        and int(data.get("epoch", -1)) == profile_epoch
                    ):
                        profiler.enable()
                    elif (
                        packet.get("phase") == "state"
                        and int(data.get("epoch", -1)) == profile_epoch
                    ):
                        profiler.disable()
                    events.append(packet)

                result = prepared.start(request, capture_profiled_epoch, NeverStop())
                profile_output.parent.mkdir(parents=True, exist_ok=True)
                profiler.dump_stats(str(profile_output))
            else:
                result = prepared.start(request, events.append, NeverStop())
            records.append(_result_record(
                scenario, path_class, iteration, result, events,
                (perf_counter() - started) * 1000.0, batch_size, prepare_ms,
                prepared_session_reused=path_class == "hot",
            ))
    return records


def _percentile(values: list[float], fraction: float) -> float | None:
    if not values:
        return None
    ordered = sorted(values)
    index = min(len(ordered) - 1, max(0, int(round((len(ordered) - 1) * fraction))))
    return ordered[index]


def _summary(records: list[dict]) -> dict:
    keys = (
        "process_total_ms", "prepare_ms", "click_to_first_step_ms", "epoch_ms",
        "eval_ms", "steady_train_epoch_ms", "export_ms", "total_ms", "peak_rss_mib",
    )
    summary = {"runs": len(records)}
    summary["artifact_cache_hits"] = sum(bool(row.get("artifact_cache_hit")) for row in records)
    summary["prepared_session_reuses"] = sum(bool(row.get("prepared_session_reused")) for row in records)
    for key in keys:
        values = [float(row[key]) for row in records if row.get(key) is not None]
        if values:
            summary[key] = {"p50": statistics.median(values), "p95": _percentile(values, 0.95)}
    return summary


def _peak_rss_mib() -> float:
    if os.name == "nt":
        import ctypes
        from ctypes import wintypes

        class Counters(ctypes.Structure):
            _fields_ = [
                ("cb", wintypes.DWORD), ("PageFaultCount", wintypes.DWORD),
                ("PeakWorkingSetSize", ctypes.c_size_t), ("WorkingSetSize", ctypes.c_size_t),
                ("QuotaPeakPagedPoolUsage", ctypes.c_size_t), ("QuotaPagedPoolUsage", ctypes.c_size_t),
                ("QuotaPeakNonPagedPoolUsage", ctypes.c_size_t), ("QuotaNonPagedPoolUsage", ctypes.c_size_t),
                ("PagefileUsage", ctypes.c_size_t), ("PeakPagefileUsage", ctypes.c_size_t),
            ]

        counters = Counters()
        counters.cb = ctypes.sizeof(counters)
        ctypes.windll.kernel32.GetCurrentProcess.restype = wintypes.HANDLE
        ctypes.windll.psapi.GetProcessMemoryInfo.argtypes = [
            wintypes.HANDLE, ctypes.POINTER(Counters), wintypes.DWORD,
        ]
        handle = ctypes.windll.kernel32.GetCurrentProcess()
        if ctypes.windll.psapi.GetProcessMemoryInfo(handle, ctypes.byref(counters), counters.cb):
            return counters.PeakWorkingSetSize / (1024.0 * 1024.0)
        return 0.0
    import resource

    rss = float(resource.getrusage(resource.RUSAGE_SELF).ru_maxrss)
    return rss / (1024.0 if sys.platform != "darwin" else 1024.0 * 1024.0)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scenario", choices=tuple(SCENARIOS), default="iris_dense")
    parser.add_argument("--path", choices=("cold", "warm", "hot", "all"), default="all")
    parser.add_argument("--repeats", type=int, default=20)
    parser.add_argument("--epochs", type=int, default=6)
    parser.add_argument("--batch-size", type=int, default=128)
    parser.add_argument("--profile-output", type=Path, help="Write cProfile data for the first resident run")
    parser.add_argument("--intra-op-threads", type=int, help="Override ORT intra-op threads for profiling")
    parser.add_argument("--child-one", action="store_true")
    parser.add_argument("--iteration", type=int, default=0)
    parser.add_argument("--work-root", type=Path)
    parser.add_argument("--output", type=Path, help="Write clean JSONL records and summaries to this path")
    args = parser.parse_args()
    sys.path.insert(0, str(RUNTIME_ROOT))

    if args.child_one:
        root = args.work_root.resolve()
        record = _run_one_shot(
            args.scenario, root, root / "artifact-cache", args.iteration,
            max(1, args.epochs), max(1, args.batch_size),
        )
        print("BENCH_JSON=" + json.dumps(record, sort_keys=True))
        return 0

    paths = ("cold", "warm", "hot") if args.path == "all" else (args.path,)
    all_records = []
    output_rows: list[dict] = []
    for path_class in paths:
        records = (
            benchmark_cold(
                args.scenario, max(1, args.repeats), max(1, args.epochs), max(1, args.batch_size)
            )
            if path_class == "cold"
            else benchmark_resident(
                args.scenario, path_class, max(1, args.repeats),
                max(1, args.epochs), max(1, args.batch_size), args.profile_output,
                args.intra_op_threads,
            )
        )
        for record in records:
            row = {"type": "run", **record}
            output_rows.append(row)
            print(json.dumps(row, sort_keys=True))
        summary = {
            "type": "summary", "scenario": args.scenario, "path_class": path_class,
            **_summary(records),
        }
        output_rows.append(summary)
        print(json.dumps(summary, sort_keys=True))
        all_records.extend(records)
    if args.output is not None:
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(
            "".join(json.dumps(row, sort_keys=True) + "\n" for row in output_rows),
            encoding="utf-8",
        )
    return 0 if all(row.get("status") == "ok" for row in all_records) else 1


if __name__ == "__main__":
    raise SystemExit(main())
