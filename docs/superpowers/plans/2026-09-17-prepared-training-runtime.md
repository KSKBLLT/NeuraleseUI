# Prepared Training Runtime Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make FullyLocal training enter its first real batch in at most 50 ms on the prepared fast path while retaining a tested one-shot fallback.

**Architecture:** A Python worker starts asynchronously with Godot, imports the training stack once, caches built-in and parsed user datasets, and owns one prepared ORT training session. Godot communicates through authenticated length-prefixed loopback TCP frames, identifies graph generations explicitly, and falls back to the current job-directory process when preparation is unavailable. Structural artifacts, run state, dataset state, and exported checkpoints remain separate.

**Tech Stack:** Godot 4.7.1/GDScript, Python 3.11, NumPy, ONNX, ONNX Runtime Training 1.19.2, loopback TCP, pytest, current marker-based Godot tests, optional C++17 ORT Training C API sidecar.

**Spec:** `docs/superpowers/specs/2026-09-17-prepared-training-runtime-design.md`

## Global Constraints

- Keep `local_runtime/neuralese_local/train_entry.py` and the current JSONL job path as an automatic fallback until parity is proven.
- Start worker warm-up asynchronously; it must not block startup dialogs or the Godot main thread.
- Keep all installed built-in datasets resident after warm-up.
- Keep user `dataset.json`; cache parsed arrays by canonical path, declared revision, size, and mtime.
- Permit only one active training job and one prepared session in the initial implementation.
- Never silently reuse trained weights or optimizer state for a fresh run.
- Remote training, authentication, localized errors, and checkpoint manifest fields remain compatible.
- Stage only named files and never add existing untracked DLL, EXE, log, or UID artifacts.
- Every task leaves the repository runnable and ends with focused tests plus a named commit.

## File map

- `local_runtime/neuralese_local/training_timing.py`: monotonic stage timing and hot/warm/cold summaries.
- `local_runtime/neuralese_local/train_protocol.py`: framed JSON codec, token and request validation.
- `local_runtime/neuralese_local/training_dataset_cache.py`: resident built-ins and bounded user-JSON cache.
- `local_runtime/neuralese_local/training_artifact_cache.py`: canonical keys, atomic cache entries, manifests, and locking.
- `local_runtime/neuralese_local/prepared_training.py`: prepared session lifecycle, fresh/reset state, training loop, eval, export.
- `local_runtime/neuralese_local/train_worker.py`: resident process, TCP server, command dispatch, parent watchdog.
- `local_runtime/neuralese_local/train_task.py`: compatibility wrapper delegating shared behavior to prepared training.
- `scripts/local_training_worker.gd`: worker process lifecycle, bootstrap, framing, generations, and restart/fallback state.
- `scripts/run_manager.gd`: snapshot creation, prepare debounce, hot start integration, progress routing.
- `scripts/fully_local_config.gd`: feature flags and tunable limits.
- `local_runtime/native_training/`: optional C++17 protocol-compatible worker.
- `tests/local_runtime/test_training_*.py`: unit/integration coverage for each Python boundary.
- `tests/godot/test_local_training_worker.gd`: GDScript lifecycle, generation, and framing tests.
- `tests/local_runtime/benchmark_training_startup.py`: reproducible cold/warm/hot benchmark report.

---

### Task 1: Stage timing and baseline benchmark

**Files:**
- Create: `local_runtime/neuralese_local/training_timing.py`
- Create: `tests/local_runtime/test_training_timing.py`
- Create: `tests/local_runtime/benchmark_training_startup.py`
- Modify: `local_runtime/neuralese_local/train_task.py`

**Interfaces:**
- Produces: `StageTimer.begin(name)`, `StageTimer.end(name)`, `StageTimer.mark(name)`, and `StageTimer.snapshot() -> dict`.
- Produces: progress packets with `data.timings_ms` and `data.path_class`.

- [ ] **Step 1: Write the failing timer contract test**

```python
def test_stage_timer_records_monotonic_durations(fake_clock):
    timer = StageTimer(clock=fake_clock)
    timer.begin("dataset")
    fake_clock.advance(0.012)
    timer.end("dataset")
    assert timer.snapshot()["dataset"] == pytest.approx(12.0)
```

- [ ] **Step 2: Run the focused test and confirm `StageTimer` is missing**

Run: `python -m pytest tests/local_runtime/test_training_timing.py -v`

- [ ] **Step 3: Implement the timer without global mutable state**

```python
class StageTimer:
    def __init__(self, clock=perf_counter):
        self._clock = clock
        self._starts = {}
        self._durations = {}

    def begin(self, name): self._starts[name] = self._clock()
    def end(self, name):
        self._durations[name] = (self._clock() - self._starts.pop(name)) * 1000.0
    def snapshot(self): return dict(self._durations)
```

- [ ] **Step 4: Instrument request read, dataset, model build, artifacts, checkpoint, module, optimizer, first step, eval, export, and save**

Pass one `StageTimer` through `run_training`; do not print per-stage logs. Attach a snapshot to lifecycle packets and the final manifest.

- [ ] **Step 5: Add a benchmark script with Iris-size and MNIST-size modes**

The script must emit one JSON object per run containing `path_class`, stage timings, graph size, sample count, batch size, and total time. It must not assert machine-specific latency.

- [ ] **Step 6: Run tests and record a baseline**

Run: `python -m pytest tests/local_runtime/test_training_timing.py tests/local_runtime/test_classification_training_e2e.py -v`

- [ ] **Step 7: Commit**

```bash
git add local_runtime/neuralese_local/training_timing.py local_runtime/neuralese_local/train_task.py tests/local_runtime/test_training_timing.py tests/local_runtime/benchmark_training_startup.py
git commit -m "perf: instrument local training startup"
```

### Task 2: Authenticated framed protocol

**Files:**
- Create: `local_runtime/neuralese_local/train_protocol.py`
- Create: `tests/local_runtime/test_train_protocol.py`

**Interfaces:**
- Produces: `encode_frame(packet: dict) -> bytes`.
- Produces: `FrameDecoder.feed(data: bytes) -> list[dict]`.
- Produces: `validate_command(packet, token, last_request_id) -> int`.

- [ ] **Step 1: Write failing fragmentation, coalescing, size-limit, token, and replay tests**

```python
def test_decoder_handles_fragmented_and_coalesced_frames():
    raw = encode_frame({"a": 1}) + encode_frame({"b": 2})
    decoder = FrameDecoder(max_frame_bytes=1024)
    assert decoder.feed(raw[:3]) == []
    assert decoder.feed(raw[3:]) == [{"a": 1}, {"b": 2}]
```

- [ ] **Step 2: Run the test and confirm the module is absent**

Run: `python -m pytest tests/local_runtime/test_train_protocol.py -v`

- [ ] **Step 3: Implement a four-byte big-endian length prefix and strict dictionary JSON**

Reject zero-length frames, frames above 8 MiB, non-dictionaries, invalid UTF-8, wrong tokens, and non-increasing request ids with typed protocol errors.

- [ ] **Step 4: Run the focused tests**

Run: `python -m pytest tests/local_runtime/test_train_protocol.py -v`

- [ ] **Step 5: Commit**

```bash
git add local_runtime/neuralese_local/train_protocol.py tests/local_runtime/test_train_protocol.py
git commit -m "feat: add local training worker protocol"
```

### Task 3: Resident dataset cache

**Files:**
- Create: `local_runtime/neuralese_local/training_dataset_cache.py`
- Create: `tests/local_runtime/test_training_dataset_cache.py`
- Modify: `local_runtime/neuralese_local/dataset_store.py`

**Interfaces:**
- Produces: `DatasetRevision(kind, name, path, revision, size, mtime_ns)`.
- Produces: `TrainingDatasetCache.warm_builtins(runtime_root) -> dict`.
- Produces: `TrainingDatasetCache.get(dataset_ref) -> ArrayDataset`.
- Produces: `TrainingDatasetCache.evict_user_lru()`.

- [ ] **Step 1: Write failing built-in identity and user invalidation tests**

```python
first = cache.get(user_ref(path, revision="7"))
second = cache.get(user_ref(path, revision="7"))
assert first is second
path.write_text(changed_json, encoding="utf-8")
third = cache.get(user_ref(path, revision="7"))
assert third is not first
```

- [ ] **Step 2: Run the focused tests and confirm failure**

Run: `python -m pytest tests/local_runtime/test_training_dataset_cache.py -v`

- [ ] **Step 3: Implement resident built-ins and LRU user JSON entries**

Keep strong references to all successful built-in loads. Key user entries by resolved path, revision, size, and nanosecond mtime. Bound only user entries by estimated array bytes, default 512 MiB.

- [ ] **Step 4: Add batch-oriented image storage without breaking `ArrayDataset` callers**

Introduce a `batch_indices(indices, out_x=None, out_y=None)` method. Preserve `uint8` or mmap sources when requested and normalize only the selected batch into reusable `float32` buffers. Existing `x` and `y` behavior remains for small/materialized datasets.

- [ ] **Step 5: Run dataset and training tests**

Run: `python -m pytest tests/local_runtime/test_training_dataset_cache.py tests/local_runtime/test_classification_training_e2e.py tests/local_runtime/test_simulation_training_e2e.py -v`

- [ ] **Step 6: Commit**

```bash
git add local_runtime/neuralese_local/training_dataset_cache.py local_runtime/neuralese_local/dataset_store.py tests/local_runtime/test_training_dataset_cache.py
git commit -m "perf: cache local training datasets in memory"
```

### Task 4: Structural artifact cache

**Files:**
- Create: `local_runtime/neuralese_local/training_artifact_cache.py`
- Create: `tests/local_runtime/test_training_artifact_cache.py`
- Modify: `local_runtime/neuralese_local/train_task.py`

**Interfaces:**
- Produces: `artifact_fingerprint(model, trainable_params, loss, optimizer, capability) -> str`.
- Produces: `ArtifactCache.get_or_create(spec, builder) -> ArtifactEntry`.
- `ArtifactEntry` exposes validated training, eval, optimizer, checkpoint, and manifest paths.

- [ ] **Step 1: Write failing determinism, invalidation, corruption, and atomicity tests**

Hashing two dictionaries with different key order must match. Loss, optimizer, tensor shape, ORT version, or trainable names must change the key. A mismatched file hash must rebuild exactly once.

- [ ] **Step 2: Run the tests and confirm failure**

Run: `python -m pytest tests/local_runtime/test_training_artifact_cache.py -v`

- [ ] **Step 3: Implement canonical JSON fingerprinting and cache manifest**

Use SHA-256, sorted keys, compact separators, explicit schema version, actual `ort.__version__`, platform, architecture, and conservative CPU capability tags.

- [ ] **Step 4: Implement lock, temporary build, validation, and atomic rename**

Use exclusive lock-file creation with stale-owner recovery. Write under `<key>.building.<pid>`, hash every output, fsync the manifest, then replace the final entry. Never expose partial entries.

- [ ] **Step 5: Route artifact generation through the cache while retaining temporary fallback**

The one-shot path uses the same cache. On cache failure it generates artifacts in its job directory and reports `artifact_cache_hit=false`.

- [ ] **Step 6: Run focused and e2e tests**

Run: `python -m pytest tests/local_runtime/test_training_artifact_cache.py tests/local_runtime/test_classification_training_e2e.py -v`

- [ ] **Step 7: Commit**

```bash
git add local_runtime/neuralese_local/training_artifact_cache.py local_runtime/neuralese_local/train_task.py tests/local_runtime/test_training_artifact_cache.py
git commit -m "perf: cache ORT training artifacts"
```

### Task 5: Prepared training session and fresh-state contract

**Files:**
- Create: `local_runtime/neuralese_local/prepared_training.py`
- Create: `tests/local_runtime/test_prepared_training.py`
- Modify: `local_runtime/neuralese_local/train_task.py`

**Interfaces:**
- Produces: `PreparedSession.prepare(request, dataset_cache, artifact_cache) -> PreparedSession`.
- Produces: `PreparedSession.start(run_config, emit, cancel) -> dict`.
- Produces: `PreparedSession.reset_fresh(seed) -> None` and `load_resume_checkpoint(path) -> None`.

- [ ] **Step 1: Write failing tests for prepare-once/start-twice, fresh reset, explicit resume, and stale generation**

```python
prepared = PreparedSession.prepare(request, datasets, artifacts)
prepared.start({"seed": 11}, emit, cancel)
weights_a = prepared.parameter_snapshot()
prepared.reset_fresh(11)
assert_allclose(prepared.parameter_snapshot(), prepared.initial_snapshot())
assert not prepared.optimizer_state_is_resumed
```

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `python -m pytest tests/local_runtime/test_prepared_training.py -v`

- [ ] **Step 3: Move model/session construction into `PreparedSession.prepare`**

Keep the checkpoint state alive longer than the Module. Use nominal checkpoint and contiguous parameter buffers only when capability probes pass; otherwise load a complete template checkpoint.

- [ ] **Step 4: Implement explicit deterministic fresh reset and explicit resume**

Seed all graph initializer generation and ORT training seed. A normal `START` always restores the fresh snapshot captured after preparation. Resume requires `resume_checkpoint` and never happens implicitly.

- [ ] **Step 5: Make `run_training` a one-shot adapter over the shared session code**

The public signature and result manifest remain unchanged. This prevents resident and fallback paths from diverging.

- [ ] **Step 6: Run checkpoint and e2e tests**

Run: `python -m pytest tests/local_runtime/test_prepared_training.py tests/local_runtime/test_checkpoint_contract.py tests/local_runtime/test_classification_training_e2e.py tests/local_runtime/test_simulation_training_e2e.py -v`

- [ ] **Step 7: Commit**

```bash
git add local_runtime/neuralese_local/prepared_training.py local_runtime/neuralese_local/train_task.py tests/local_runtime/test_prepared_training.py
git commit -m "feat: prepare reusable ORT training sessions"
```

### Task 6: Resident Python worker

**Files:**
- Create: `local_runtime/neuralese_local/train_worker.py`
- Create: `tests/local_runtime/test_train_worker.py`
- Modify: `local_runtime/neuralese_local/__init__.py`

**Interfaces:**
- Consumes: protocol, dataset cache, artifact cache, and prepared session APIs.
- Produces: commands `PING`, `STATUS`, `PREPARE`, `START`, `STOP`, `SAVE`, `EVICT`, `SHUTDOWN`.
- Produces: bootstrap JSON `{port, token, pid, process_generation, protocol_version}`.

- [ ] **Step 1: Write subprocess tests for ready, token rejection, prepare, hot start, stop, stale generation, shutdown, and parent watchdog**

Use a tiny fake prepared-session factory for protocol tests so they do not import ORT. Add one opt-in integration test with the real factory.

- [ ] **Step 2: Run focused tests and confirm failure**

Run: `python -m pytest tests/local_runtime/test_train_worker.py -v`

- [ ] **Step 3: Implement loopback server and bootstrap handshake**

Bind `127.0.0.1:0`, generate `secrets.token_hex(16)`, atomically write bootstrap, accept one Godot controller, and reject unauthenticated frames before dispatch.

- [ ] **Step 4: Implement command serialization and one-job invariant**

Preparation may run only while idle. `START` validates process generation, graph generation, artifact fingerprint, dataset revision, and prepared id. Duplicate request ids return the prior acknowledgement without rerunning.

- [ ] **Step 5: Implement progress throttling and in-memory cancellation**

Lifecycle and epoch packets bypass throttling. Batch packets replace the pending batch update and flush at 10 Hz. `STOP` sets a thread-safe event checked between batches.

- [ ] **Step 6: Implement parent watchdog and single crash-safe shutdown path**

Check parent liveness once per second. Close sockets, cancel active work, save only when requested, and remove bootstrap on clean exit.

- [ ] **Step 7: Run worker and e2e tests**

Run: `python -m pytest tests/local_runtime/test_train_worker.py tests/local_runtime/test_prepared_training.py -v`

- [ ] **Step 8: Commit**

```bash
git add local_runtime/neuralese_local/train_worker.py local_runtime/neuralese_local/__init__.py tests/local_runtime/test_train_worker.py
git commit -m "feat: add resident local training worker"
```

### Task 7: Godot worker client and startup warm-up

**Files:**
- Create: `scripts/local_training_worker.gd`
- Create: `tests/godot/test_local_training_worker.gd`
- Modify: `scripts/fully_local_config.gd`
- Modify: `scripts/run_manager.gd`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Produces: `LocalTrainingWorker.start_warm()`, `prepare(snapshot)`, `start_prepared(handle, config)`, `stop(request_id)`, `shutdown()`.
- Emits: `worker_ready`, `prepared(handle)`, `packet_received(packet)`, `worker_failed(details)`.

- [ ] **Step 1: Write a marker-based Godot test with fake TCP server and fragmented frames**

The test verifies non-blocking startup, token inclusion, generation rejection, one restart, fallback state, and exact marker `PASS test_local_training_worker`.

- [ ] **Step 2: Register the test and run it to confirm failure**

Run through Godot MCP using an isolated probe scene or the repository Godot runner. Expected failure: script/class missing.

- [ ] **Step 3: Add feature flags and limits**

```gdscript
const RESIDENT_TRAINING_WORKER := true
const RESIDENT_TRAINING_FALLBACK := true
const TRAINING_PREPARE_DEBOUNCE_S := 0.4
const TRAINING_PROGRESS_HZ := 10.0
const TRAINING_USER_DATASET_CACHE_MIB := 512
```

- [ ] **Step 4: Implement process launch, bootstrap polling, TCP framing, and asynchronous reconnect**

Use `OS.create_process` once. Never await worker readiness inside startup UI. Poll bootstrap with a deadline, connect `StreamPeerTCP`, parse multiple/partial frames, and attach monotonically increasing request ids.

- [ ] **Step 5: Start warm-up from `RunManager._ready` after the first rendered frame**

Schedule it deferred and return immediately. On shutdown call `SHUTDOWN`, wait only a bounded interval, then kill the worker PID if still alive.

- [ ] **Step 6: Run the focused Godot test through Godot MCP**

Expected marker: `PASS test_local_training_worker`.

- [ ] **Step 7: Commit**

```bash
git add scripts/local_training_worker.gd scripts/fully_local_config.gd scripts/run_manager.gd tests/godot/test_local_training_worker.gd tests/godot/run_all.sh
git commit -m "feat: warm local training worker at startup"
```

### Task 8: Graph snapshots, debounce, and hot start integration

**Files:**
- Modify: `scripts/run_manager.gd`
- Modify: `scripts/graph_manager.gd`
- Create: `tests/godot/test_training_prepare_flow.gd`
- Modify: `tests/godot/run_all.sh`

**Interfaces:**
- Produces: `_training_snapshot(train_input) -> Dictionary` with generation, canonical graph, dataset ref/revision, and run config.
- Produces: `_schedule_training_prepare(train_input)` and `_start_train_prepared(...)`.

- [ ] **Step 1: Write failing tests for debounce, invalidation fields, stale prepared responses, and fallback**

Topology, tensor shape, loss, optimizer, trainable params, and dataset revision must increment generation. Epochs, batch size, and learning rate must update run config without changing structural fingerprint.

- [ ] **Step 2: Register and run the test to confirm failure**

Expected missing marker: `PASS test_training_prepare_flow`.

- [ ] **Step 3: Add one graph-change notification boundary**

Emit a lightweight training-snapshot-invalidated signal from existing mutation completion points rather than polling the whole graph every frame.

- [ ] **Step 4: Implement 400 ms debounce and canonical snapshot caching**

Cancel older timers by generation. Build one canonical snapshot, reuse it for `PREPARE` and `START`, and include user dataset path plus revision without changing `dataset.json` storage.

- [ ] **Step 5: Change `start_train` to prefer the prepared handle**

If the matching handle is ready, send `START`. If preparation is pending, queue start against that generation. On worker failure or prepare rejection, invoke `_start_train_fully_local` exactly once.

- [ ] **Step 6: Route worker packets through the existing `_handle_train_state_dict` contract**

No UI consumer should know whether progress came from TCP, JSONL, Python resident, native, or remote training.

- [ ] **Step 7: Run Godot focused tests and Python e2e tests**

Expected markers: `PASS test_training_prepare_flow`, `PASS test_training_dataset_shape`.

- [ ] **Step 8: Commit**

```bash
git add scripts/run_manager.gd scripts/graph_manager.gd tests/godot/test_training_prepare_flow.gd tests/godot/run_all.sh
git commit -m "perf: prepare local training before start"
```

### Task 9: Eval without export and final-only persistence

**Files:**
- Modify: `local_runtime/neuralese_local/prepared_training.py`
- Modify: `local_runtime/neuralese_local/train_task.py`
- Create: `tests/local_runtime/test_training_eval_export.py`

**Interfaces:**
- Produces: `evaluate_module(module, dataset, loss_name, max_samples) -> metrics`.
- Preserves final `inference.onnx`, checkpoint, manifest, and result contracts.

- [ ] **Step 1: Write failing tests that spy on export count and inference-session creation**

For five epochs with intermediate validation, `Module.eval()` must run while inference export occurs exactly once at final completion. Recoverable stop exports at most once.

- [ ] **Step 2: Run focused tests and confirm current repeated export behavior**

Run: `python -m pytest tests/local_runtime/test_training_eval_export.py -v`

- [ ] **Step 3: Implement module-based validation and mode restoration**

Use `try/finally` to restore train mode. Limit intermediate validation samples, perform full final validation, and compute classification/regression metrics from module outputs.

- [ ] **Step 4: Implement atomic final export/checkpoint/manifest write**

Export into a sibling temporary directory, post-process Softmax once, save checkpoint, write manifest, fsync, and atomically replace final files.

- [ ] **Step 5: Run e2e tests**

Run: `python -m pytest tests/local_runtime/test_training_eval_export.py tests/local_runtime/test_checkpoint_contract.py tests/local_runtime/test_classification_training_e2e.py tests/local_runtime/test_simulation_training_e2e.py -v`

- [ ] **Step 6: Commit**

```bash
git add local_runtime/neuralese_local/prepared_training.py local_runtime/neuralese_local/train_task.py tests/local_runtime/test_training_eval_export.py
git commit -m "perf: evaluate training sessions without exporting"
```

### Task 10: Session options and workload profiles

**Files:**
- Create: `local_runtime/neuralese_local/training_profile.py`
- Create: `tests/local_runtime/test_training_profile.py`
- Modify: `local_runtime/neuralese_local/prepared_training.py`

**Interfaces:**
- Produces: `estimate_workload(dataset, model) -> WorkloadEstimate`.
- Produces: `select_profile(estimate, calibration) -> SessionProfile`.
- Produces: `build_session_options(profile) -> ort.SessionOptions`.

- [ ] **Step 1: Write tests proving profiles ignore dataset names**

Equivalent tensor sizes and graph operations with different names must select the same profile. Tiny selects one intra-op thread and one inter-op thread.

- [ ] **Step 2: Run tests and confirm failure**

Run: `python -m pytest tests/local_runtime/test_training_profile.py -v`

- [ ] **Step 3: Implement work estimation and conservative profiles**

Use samples, bytes per sample, parameter count, and weighted Conv/MatMul/Gemm operation estimates. Use sequential execution, inter-op one, intra-op one/two/four, and disabled spinning by default.

- [ ] **Step 4: Add bounded first-run calibration for heavy workloads**

Benchmark only synthetic representative matrix operations with one, two, and up to four threads, cache the result by CPU and ORT version, and cap calibration at 750 ms in the background.

- [ ] **Step 5: Pass options to `Module` and benchmark**

Run: `python -m pytest tests/local_runtime/test_training_profile.py tests/local_runtime/test_prepared_training.py -v`

- [ ] **Step 6: Commit**

```bash
git add local_runtime/neuralese_local/training_profile.py local_runtime/neuralese_local/prepared_training.py tests/local_runtime/test_training_profile.py
git commit -m "perf: tune ORT training sessions by workload"
```

### Task 11: ORT-format and offline optimization capability rollout

**Files:**
- Create: `local_runtime/neuralese_local/training_capabilities.py`
- Create: `tests/local_runtime/test_training_capabilities.py`
- Modify: `local_runtime/neuralese_local/training_artifact_cache.py`
- Modify: `local_runtime/neuralese_local/prepared_training.py`

**Interfaces:**
- Produces: `probe_capabilities() -> TrainingCapabilities`.
- Produces: benchmark-selected artifact format recorded in cache key and manifest.

- [ ] **Step 1: Write capability fallback and cache-key tests**

An unavailable nominal checkpoint, ORT format, or optimized model loader must select ONNX/complete-checkpoint fallback without changing correctness.

- [ ] **Step 2: Run tests and confirm failure**

Run: `python -m pytest tests/local_runtime/test_training_capabilities.py -v`

- [ ] **Step 3: Implement isolated probes with no import-time side effects**

Probe actual callable signatures and create a tiny temporary graph. Cache results by ORT version. Never infer support solely from a version number.

- [ ] **Step 4: Add guarded A/B artifact generation**

Generate ORT format only when both generation and Module loading succeed. Compare prepare latency with ONNX on the first representative graph, store the winner, and keep separate cache entries.

- [ ] **Step 5: Run full local runtime tests and benchmarks**

Run: `python -m pytest tests/local_runtime -v`

- [ ] **Step 6: Commit**

```bash
git add local_runtime/neuralese_local/training_capabilities.py local_runtime/neuralese_local/training_artifact_cache.py local_runtime/neuralese_local/prepared_training.py tests/local_runtime/test_training_capabilities.py
git commit -m "perf: select optimized ORT training artifacts"
```

### Task 12: Runtime packaging coherence

**Files:**
- Modify: runtime build/packaging files discovered by `rg -n "onnxruntime-training|local_runtime/python" .github tools local_runtime`
- Create: `tests/release/test_local_runtime_packages.py`

**Interfaces:**
- Produces: one locked ORT training distribution and a machine-readable package manifest.

- [ ] **Step 1: Write a release test rejecting duplicate ORT training distributions**

The test reads `*.dist-info/METADATA`, requires exactly one installed ORT training package, requires its imported version to match metadata, and verifies hashes from the runtime manifest.

- [ ] **Step 2: Run the release test and observe the current 1.19.2/1.15.1 conflict**

Run: `python -m pytest tests/release/test_local_runtime_packages.py -v`

- [ ] **Step 3: Update the reproducible runtime build to install only the selected CPU training package**

Remove stale 1.15.1 metadata through the build recipe, never by committing an unexplained manual deletion. Record Python, NumPy, ONNX, and ORT versions and file hashes.

- [ ] **Step 4: Rebuild runtime and run release/local tests**

Run: `python -m pytest tests/release tests/local_runtime -v`

- [ ] **Step 5: Commit named packaging files and test**

Use a commit message `build: make local ORT runtime reproducible` and stage only files listed by the runtime build recipe plus the release test.

### Task 13: Native ORT Training sidecar

**Files:**
- Create: `local_runtime/native_training/CMakeLists.txt`
- Create: `local_runtime/native_training/src/main.cpp`
- Create: `local_runtime/native_training/src/protocol.hpp`
- Create: `local_runtime/native_training/src/trainer.hpp`
- Create: `local_runtime/native_training/src/trainer.cpp`
- Create: `local_runtime/native_training/README.md`
- Create: `tests/local_runtime/test_native_training_worker.py`
- Modify: `scripts/fully_local_config.gd`
- Modify: `scripts/local_training_worker.gd`

**Interfaces:**
- Consumes the exact Task 2 framed protocol and Task 4 structural cache.
- Produces protocol-equivalent `PREPARE`, `START`, `STOP`, `SAVE`, `STATUS`, and `SHUTDOWN` behavior.

- [ ] **Step 1: Write a loader/protocol parity test that skips only when the binary is absent**

The built binary must reject a stock inference-only ORT library with `native_training_api_unavailable`, then allow Godot to choose Python before any job starts.

- [ ] **Step 2: Add CMake feature checks for `OrtApi::GetTrainingApi` and required symbols**

Build C++17, link the custom ORT training shared library, and fail configuration with a precise message when headers or libraries are missing.

- [ ] **Step 3: Implement protocol and process lifecycle parity**

Reuse the length-prefix, token, request-id, generation, bootstrap, parent-watchdog, and one-job contracts. Do not create a second incompatible protocol.

- [ ] **Step 4: Implement training API ownership with RAII**

Wrap `OrtEnv`, `OrtSessionOptions`, `OrtCheckpointState`, and `OrtTrainingSession`. Implement `TrainStep`, `EvalStep`, `OptimizerStep`, `LazyResetGrad`, `LoadCheckpointFromBuffer`, `CopyBufferToParameters`, export, and checkpoint save with explicit status-to-error mapping.

- [ ] **Step 5: Add the feature flag and pre-job fallback**

```gdscript
const NATIVE_TRAINING_WORKER := false
```

When enabled, probe the native worker first. If capability fails before `START`, select Python. Never replay a started job on another backend.

- [ ] **Step 6: Build and run parity tests**

Run the project-specific CMake build, then `python -m pytest tests/local_runtime/test_native_training_worker.py tests/local_runtime/test_train_worker.py -v`.

- [ ] **Step 7: Commit**

```bash
git add local_runtime/native_training tests/local_runtime/test_native_training_worker.py scripts/fully_local_config.gd scripts/local_training_worker.gd
git commit -m "feat: add native ORT training worker"
```

### Task 14: Full verification and performance gate

**Files:**
- Modify: `tests/local_runtime/benchmark_training_startup.py`
- Create: `docs/performance/local-training-runtime.md`

**Interfaces:**
- Produces: reproducible benchmark JSON plus a concise human report.

- [ ] **Step 1: Run all Python suites required by repository policy**

Run: `python -m pytest tests/node_dev tests/jasondocs tests/release tests/integration tests/local_runtime -v`

- [ ] **Step 2: Run node registry consistency**

Run: `python -m tools.node_dev check`

- [ ] **Step 3: Run the full Godot suite through the configured Godot 4.7.1 environment**

Run: `GODOT_BIN=/path/to/godot bash tests/godot/run_all.sh`

- [ ] **Step 4: Run generated-scene validation**

Run: `python -m tools.node_dev godot-check --godot-bin "$GODOT_BIN" --timeout 300`

- [ ] **Step 5: Benchmark cold, warm, and hot paths**

Run at least 20 hot and warm iterations for Iris-size dense, medium tabular, MNIST MLP, and a convolutional graph. Report p50/p95, cache hit state, click-to-first-step, epoch, eval, export, peak RSS, and UI frame impact. Do not discard outliers without preserving raw data.

- [ ] **Step 6: Enforce the hot-path target without weakening correctness**

The implementation is complete only when hot p95 is <= 50 ms on the target four-thread laptop or the report identifies a measured external floor and the user explicitly accepts it. Checkpoint reload and seeded output parity must pass.

- [ ] **Step 7: Document operating behavior and rollback switches**

Describe worker warm-up, memory use, cache locations, feature flags, diagnostics, fallback, and how to reproduce benchmarks.

- [ ] **Step 8: Final commit**

```bash
git add tests/local_runtime/benchmark_training_startup.py docs/performance/local-training-runtime.md
git commit -m "docs: verify prepared training runtime performance"
```
