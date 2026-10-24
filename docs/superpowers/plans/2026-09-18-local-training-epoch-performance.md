# Local Training Epoch Performance Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce prepared-session training epoch time across tiny tabular, medium tabular, MNIST MLP, and MNIST Conv workloads without weakening training quality or changing user-visible graph semantics.

**Architecture:** Keep the resident prepared runtime, but isolate its hot batch loop in an `EpochRunner`. Generate loss-only training artifacts while retaining prediction outputs in evaluation artifacts, replace unconditional random gathers with a tested batch schedule, capability-gate reusable OrtValue bindings, and select batch/thread profiles from short real training measurements rather than dataset names or inference probes.

**Tech Stack:** Python 3.11, NumPy 1.26.4, ONNX, ONNX Runtime Training 1.19.2, pytest, cProfile, existing prepared worker protocol.

**Spec:** `docs/superpowers/specs/2026-09-18-local-training-epoch-performance-design.md`

## Global Constraints

- Scope starts at the first training batch of an already prepared session and ends after the epoch state packet.
- Do not optimize or benchmark Python startup, imports, artifact lookup/generation, session construction, final export, or checkpoint persistence in this plan.
- Report train-only and validation time separately; never make validation less frequent to claim a faster epoch.
- Use graph/tensor/work estimates, never built-in dataset names, to select behavior.
- Explicit user batch size and seed remain authoritative.
- Keep current exact sample shuffle and NumPy module calls as safe fallbacks until each fast path passes quality and capability tests.
- Preserve cancellation checks, fresh/reset behavior, resume optimizer state, final export, and checkpoint contracts.
- Do not accept a speed result without raw samples, p50/p95, interleaved order, and correctness/quality data.
- Stage only named files. Do not include existing `.pyc`, binaries, `.uid`, logs, or unrelated worktree changes.
- Every task ends with focused verification and a named commit.

## File map

- `tests/local_runtime/benchmark_training_epochs.py`: dedicated prepared-session epoch matrix, raw JSONL, cProfile mode, and summaries.
- `tests/local_runtime/training_benchmark_scenarios.py`: reusable Iris, Titanic, Car, MNIST MLP, and MNIST Conv graph/request factories.
- `local_runtime/neuralese_local/train_task.py`: train/eval artifact output contracts.
- `local_runtime/neuralese_local/training_artifact_cache.py`: output-contract cache schema and invalidation.
- `local_runtime/neuralese_local/dataset_store.py`: contiguous and indexed batch access.
- `local_runtime/neuralese_local/batch_schedule.py`: deterministic batch-order policies.
- `local_runtime/neuralese_local/epoch_runner.py`: hot training loop, timing hooks, progress limiter, and bound-input fallback.
- `local_runtime/neuralese_local/prepared_training.py`: owns and invokes the epoch runner.
- `local_runtime/neuralese_local/training_profile.py`: real training-step batch/thread calibration and profile cache keys.
- `tests/local_runtime/test_training_artifact_outputs.py`: train/eval output contract coverage.
- `tests/local_runtime/test_batch_schedule.py`: coverage and deterministic schedule tests.
- `tests/local_runtime/test_epoch_runner.py`: full/tail batches, cancellation, progress, loss, and fast-path fallback tests.
- `tests/local_runtime/test_training_quality.py`: fixed-seed learning-quality parity matrix.
- `tests/local_runtime/test_training_profile.py`: calibration robustness and dataset-name independence.
- `docs/performance/local-training-epochs.md`: reproducible baseline, final comparison, hardware, and rollback notes.

---

### Task 1: Split epoch benchmarking from startup benchmarking

**Files:**
- Create: `tests/local_runtime/training_benchmark_scenarios.py`
- Create: `tests/local_runtime/benchmark_training_epochs.py`
- Modify: `tests/local_runtime/benchmark_training_startup.py`
- Modify: `docs/performance/local-training-epochs.md`

**Interfaces:**
- Produces: `scenario_request(name, root, epochs, batch_size, seed) -> dict`.
- Produces: CLI `benchmark_training_epochs.py --scenario ... --runs ... --epochs ... --batch-size ... --profile-epoch ... --output ...`.
- JSONL rows include `scenario`, graph fingerprint, shapes/dtypes, epoch, batches, train-only/eval milliseconds, loss, batch size, threads, runtime versions, CPU identity, and RSS.

- [ ] **Step 1: Move scenario graph/request factories into a side-effect-free module**

Move the five scenario definitions from `benchmark_training_startup.py` without changing their graph topology: Iris Dense, Titanic Dense, Car Dense MSE, MNIST MLP, and MNIST Conv. Import the shared factories back into the startup benchmark so there is one definition per scenario.

- [ ] **Step 2: Write a smoke test for row completeness and phase exclusion**

Add a pytest test in `benchmark_training_epochs.py` that runs a mocked prepared session and asserts every row has `train_only_ms`, `eval_ms`, `epoch`, `batches`, `loss`, and hardware/runtime metadata, and that setup/export timings are absent.

- [ ] **Step 3: Implement the dedicated epoch CLI**

Prepare once per run, discard a warm-up epoch, record every later epoch, preserve raw samples, summarize p50/p95, and optionally cProfile exactly one non-validation epoch. Never include session construction or final export in `train_only_ms`.

- [ ] **Step 4: Add interleaved comparison mode**

Accept two named configurations and alternate `A, B, B, A` per repetition. Emit the execution order and seed so thermal drift and background load remain visible.

- [ ] **Step 5: Run the complete baseline matrix**

Run each scenario for at least seven repetitions and seven epochs at batch 128. Confirm the report reproduces the 2026-09-18 baseline within normal machine noise and preserve raw JSONL beside the report.

- [ ] **Step 6: Commit the benchmark boundary**

```bash
git add tests/local_runtime/training_benchmark_scenarios.py tests/local_runtime/benchmark_training_epochs.py tests/local_runtime/benchmark_training_startup.py docs/performance/local-training-epochs.md
git commit -m "perf: isolate local training epoch benchmark"
```

### Task 2: Generate loss-only training artifacts

**Files:**
- Modify: `local_runtime/neuralese_local/train_task.py`
- Modify: `local_runtime/neuralese_local/training_artifact_cache.py`
- Create: `tests/local_runtime/test_training_artifact_outputs.py`
- Modify: `tests/local_runtime/test_training_eval_export.py`

**Interfaces:**
- Produces: `_generate_training_artifacts(..., output_contract: str)` where schema `train_loss_only_eval_predictions_v1` creates loss-only train fetches and prediction-preserving eval fetches.
- Adds output-contract version to artifact fingerprint/manifest.

- [ ] **Step 1: Write failing artifact-output tests**

Generate a tiny Dense classification artifact and assert the training model exposes one scalar loss output while the eval model exposes loss plus every original model output. Run the test for both ONNX artifacts and ORT-format capability when available.

- [ ] **Step 2: Write failing evaluation-parity coverage**

Train the tiny graph for one fixed-seed epoch, call `evaluate_module()`, and assert prediction shape, finite metrics, and train-mode restoration remain unchanged.

- [ ] **Step 3: Split train and eval output contracts during artifact creation**

Use ORT artifact-generation capabilities or a validated post-generation graph transformation to remove original-model fetches from the training graph only. Do not remove them from the eval graph or exported inference model.

- [ ] **Step 4: Version and invalidate the structural cache**

Include `train_loss_only_eval_predictions_v1` in `artifact_fingerprint()` and the manifest. Assert an old cache entry is rebuilt exactly once and never loaded under the new contract.

- [ ] **Step 5: Benchmark before/after interleaved**

Run Car Dense, MNIST MLP, and MNIST Conv with identical seeds, batch sizes, and thread profiles. Accept only if output parity passes and no scenario regresses by more than 3% p50 or 5% p95.

- [ ] **Step 6: Run focused tests and commit**

Run: `python -m pytest tests/local_runtime/test_training_artifact_outputs.py tests/local_runtime/test_training_eval_export.py tests/local_runtime/test_training_artifact_cache.py -v`

```bash
git add local_runtime/neuralese_local/train_task.py local_runtime/neuralese_local/training_artifact_cache.py tests/local_runtime/test_training_artifact_outputs.py tests/local_runtime/test_training_eval_export.py
git commit -m "perf: fetch only loss during training steps"
```

### Task 3: Extract a testable hot epoch runner

**Files:**
- Create: `local_runtime/neuralese_local/epoch_runner.py`
- Create: `tests/local_runtime/test_epoch_runner.py`
- Modify: `local_runtime/neuralese_local/prepared_training.py`

**Interfaces:**
- Produces: `EpochConfig(batch_size, seed, progress_interval_s, profile_breakdown)`.
- Produces: `EpochResult(average_loss, batches, train_seconds, breakdown)`.
- Produces: `EpochRunner.run_epoch(epoch, epochs, config, cancel, progress) -> EpochResult`.

- [ ] **Step 1: Write failing runner contract tests with fake module and optimizer**

Cover full batch, tail batch, average loss, `lazy_reset_grad()` before every step, one optimizer step per batch, deterministic order, and cancellation before the next batch.

- [ ] **Step 2: Write failing progress tests**

Use a fake clock for 469 batches. Assert batch progress is constructed/emitted no more than ten times per second while epoch start/end, stop, and completion remain lossless.

- [ ] **Step 3: Implement `EpochRunner` with no ORT-specific optimization**

Move the existing loop verbatim behind the new interface first. Keep the indexed-copy dataset path and NumPy module call so this commit changes ownership, not behavior.

- [ ] **Step 4: Replace the inline loop in `PreparedSession.start()`**

Keep validation cadence and state packet fields unchanged. Populate `epoch_seconds` and `eval_seconds` from the runner/evaluator and retain the first-step timing marker.

- [ ] **Step 5: Prove behavioral parity**

Run fixed-seed one- and five-epoch tests and compare final parameter snapshots, metrics, progress lifecycle, cancellation, export, and checkpoint paths against the pre-extraction behavior.

- [ ] **Step 6: Run tests and commit**

Run: `python -m pytest tests/local_runtime/test_epoch_runner.py tests/local_runtime/test_prepared_training.py tests/local_runtime/test_training_eval_export.py tests/local_runtime/test_checkpoint_contract.py -v`

```bash
git add local_runtime/neuralese_local/epoch_runner.py local_runtime/neuralese_local/prepared_training.py tests/local_runtime/test_epoch_runner.py
git commit -m "refactor: isolate prepared training epoch loop"
```

### Task 4: Move progress throttling before packet allocation

**Files:**
- Modify: `local_runtime/neuralese_local/epoch_runner.py`
- Modify: `local_runtime/neuralese_local/train_worker.py`
- Modify: `tests/local_runtime/test_epoch_runner.py`
- Modify: `tests/local_runtime/test_train_worker.py`

**Interfaces:**
- Produces: `RateLimitedProgress.due(now) -> bool` and `emit_batch(...)`.
- Worker remains a defensive transport throttle but no longer carries the primary hot-loop policy.

- [ ] **Step 1: Add allocation-count coverage**

Inject a packet factory into the fake runner and assert a 469-batch epoch at 300 ms creates at most four batch packets, rather than 469 packets later discarded by the worker.

- [ ] **Step 2: Implement monotonic pre-allocation throttling**

Check the limiter before calculating UI-only average loss and before constructing the nested dictionary. Force the first and final batch update, and preserve immediate stop visibility.

- [ ] **Step 3: Retain worker-side protection**

Keep `_emit_progress()` tolerant of legacy producers and duplicate bursts, but test that normal `EpochRunner` output is forwarded without extra delay.

- [ ] **Step 4: Benchmark tiny and MNIST workloads**

Verify Iris/Titanic do not regress and record the smaller but measurable MLP/Conv change. Reject any implementation that changes loss accumulation or progress endpoint values.

- [ ] **Step 5: Run tests and commit**

Run: `python -m pytest tests/local_runtime/test_epoch_runner.py tests/local_runtime/test_train_worker.py -v`

```bash
git add local_runtime/neuralese_local/epoch_runner.py local_runtime/neuralese_local/train_worker.py tests/local_runtime/test_epoch_runner.py tests/local_runtime/test_train_worker.py
git commit -m "perf: throttle training progress before allocation"
```

### Task 5: Add deterministic contiguous batch schedules

**Files:**
- Create: `local_runtime/neuralese_local/batch_schedule.py`
- Modify: `local_runtime/neuralese_local/dataset_store.py`
- Modify: `local_runtime/neuralese_local/epoch_runner.py`
- Create: `tests/local_runtime/test_batch_schedule.py`
- Create: `tests/local_runtime/test_training_quality.py`

**Interfaces:**
- Produces: `BatchSlice(start, stop)` and `BatchIndices(indices)` descriptors.
- Produces: `ExactSampleShuffle`, `ShuffledBlockSchedule`, and `PrePermutedEpochSchedule`.
- Produces: `ArrayDataset.batch_view(start, stop)` and retains `batch_indices(...)` fallback.

- [ ] **Step 1: Write schedule invariants**

For dataset sizes 1, 127, 128, 129, and 60,000, assert every sample appears exactly once per epoch, no descriptor overlaps, tail shapes are correct, fixed seeds reproduce order, and different epochs change order.

- [ ] **Step 2: Add zero-copy contiguous view tests**

Assert `batch_view()` shares memory with materialized float32 arrays and that lazy uint8/scaled datasets still normalize safely through reusable output buffers.

- [ ] **Step 3: Implement all three policies behind one interface**

Keep `ExactSampleShuffle` as default. Let the runner consume either slice views or indexed buffers without branching on dataset name.

- [ ] **Step 4: Add fixed-budget learning-quality tests**

For Iris, Titanic, Car, MNIST MLP, and MNIST Conv, compare candidate policies against exact shuffle with fixed initialization and sample budget. Assert finite loss and final accuracy/MAE within scenario-specific tolerances recorded in the test.

- [ ] **Step 5: Select the fastest quality-safe policy by workload class**

Enable a contiguous policy only when it passes both the quality test and an interleaved benchmark with at least a 5% median benefit. Otherwise retain exact shuffle for that workload class.

- [ ] **Step 6: Run tests and commit**

Run: `python -m pytest tests/local_runtime/test_batch_schedule.py tests/local_runtime/test_training_quality.py tests/local_runtime/test_epoch_runner.py -v`

```bash
git add local_runtime/neuralese_local/batch_schedule.py local_runtime/neuralese_local/dataset_store.py local_runtime/neuralese_local/epoch_runner.py tests/local_runtime/test_batch_schedule.py tests/local_runtime/test_training_quality.py
git commit -m "perf: train through contiguous shuffled batches"
```

### Task 6: Reuse OrtValue bindings for stable batch buffers

**Files:**
- Modify: `local_runtime/neuralese_local/training_capabilities.py`
- Modify: `local_runtime/neuralese_local/epoch_runner.py`
- Modify: `local_runtime/neuralese_local/prepared_training.py`
- Create: `tests/local_runtime/test_training_ortvalue_binding.py`
- Modify: `tests/local_runtime/test_epoch_runner.py`

**Interfaces:**
- Adds capability `reusable_cpu_ortvalue_inputs` with a probe result and failure reason.
- Produces: `BoundBatchInputs` for full-batch and tail-batch shapes.
- Falls back to `module(bx, by)` when the capability is absent or invalid.

- [ ] **Step 1: Write a live capability probe test**

Create one CPU OrtValue backed by a reusable NumPy array, mutate the array between two training calls, and assert the second call observes the new values. Verify ownership remains valid after local temporary objects are released.

- [ ] **Step 2: Write full/tail binding tests**

Exercise dataset sizes 128, 129, and 300. Assert a full-batch binding is reused, a separate tail binding has the exact tail shape, and no stale rows leak into the loss.

- [ ] **Step 3: Implement the capability-gated binding path**

Create bindings once per prepared session/batch shape and invoke the installed module's OrtValue training path. Convert only the scalar loss fetch to NumPy.

- [ ] **Step 4: Implement failure fallback without restarting the epoch**

If binding creation fails before the first step, record the capability failure and use NumPy calls. If the live call fails, surface a typed training error rather than silently replaying an optimizer step.

- [ ] **Step 5: Benchmark wrapper savings**

Run Car Dense, MNIST MLP, and MNIST Conv interleaved with identical output contracts and batch schedules. Keep the fast path only when p50 improves and p95 does not regress beyond 3%.

- [ ] **Step 6: Run tests and commit**

Run: `python -m pytest tests/local_runtime/test_training_ortvalue_binding.py tests/local_runtime/test_epoch_runner.py tests/local_runtime/test_training_capabilities.py -v`

```bash
git add local_runtime/neuralese_local/training_capabilities.py local_runtime/neuralese_local/epoch_runner.py local_runtime/neuralese_local/prepared_training.py tests/local_runtime/test_training_ortvalue_binding.py tests/local_runtime/test_epoch_runner.py
git commit -m "perf: reuse ORT batch input bindings"
```

### Task 7: Calibrate batch size with real training steps

**Files:**
- Modify: `local_runtime/neuralese_local/training_profile.py`
- Modify: `local_runtime/neuralese_local/prepared_training.py`
- Modify: `local_runtime/neuralese_local/epoch_runner.py`
- Modify: `tests/local_runtime/test_training_profile.py`
- Modify: `tests/local_runtime/test_training_quality.py`

**Interfaces:**
- Produces: `BatchProfile(explicit, selected, candidates, memory_limit_bytes, timings)`.
- Produces: `select_batch_candidates(estimate, dataset, memory_budget) -> list[int]`.
- Produces: `calibrate_batch_size(session, candidates, seed, max_seconds) -> BatchProfile`.

- [ ] **Step 1: Write candidate and memory-bound tests**

Assert candidates depend on sample count, bytes per sample, activation/parameter estimates, and memory budget; never on `dataset.name`. Assert candidates cover the current value and nearby powers of two without exceeding the dataset size or budget.

- [ ] **Step 2: Write optimizer-state isolation tests**

Snapshot parameters and optimizer state before calibration. After probing all candidates, assert the session is restored exactly and the next real epoch matches a session that was never calibrated.

- [ ] **Step 3: Implement bounded real-step calibration**

Warm each candidate, interleave candidate order, time several actual `lazy_reset_grad -> module -> optimizer.step` cycles, use a robust median, and stop at the time budget. Reject candidates with NaN/Inf or insufficient samples.

- [ ] **Step 4: Respect explicit user configuration**

Mark whether batch size came from the user. Never override an explicit value. Cache automatic results by CPU/ORT, structural fingerprint, dataset shape/dtype, schedule policy, and memory class.

- [ ] **Step 5: Add quality gates for automatic candidates**

Run the fixed-budget matrix and assert the selected Car, MNIST MLP, and MNIST Conv sizes stay within recorded quality tolerances. Keep 128 when no candidate wins beyond the noise threshold.

- [ ] **Step 6: Benchmark and commit**

Run the complete epoch matrix and confirm the selector can reproduce the reference-machine optima near 512 for Car and 256 for both MNIST graphs without using their names.

```bash
git add local_runtime/neuralese_local/training_profile.py local_runtime/neuralese_local/prepared_training.py local_runtime/neuralese_local/epoch_runner.py tests/local_runtime/test_training_profile.py tests/local_runtime/test_training_quality.py
git commit -m "perf: calibrate local training batch size"
```

### Task 8: Replace inference thread calibration with training calibration

**Files:**
- Modify: `local_runtime/neuralese_local/training_profile.py`
- Modify: `local_runtime/neuralese_local/prepared_training.py`
- Modify: `tests/local_runtime/test_training_profile.py`
- Modify: `tests/local_runtime/benchmark_training_epochs.py`

**Interfaces:**
- Replaces MatMul-only `calibrate_machine()` for training selection with `calibrate_training_threads(session_factory, candidates, max_seconds)`.
- Cache key includes CPU identity, logical CPU count, ORT version, graph fingerprint, batch shape, and schedule/output-contract versions.

- [ ] **Step 1: Add deterministic calibration tests with a fake timed session**

Prove candidate order is interleaved, warm-up samples are discarded, median rather than minimum selects the winner, a candidate must beat baseline beyond the noise margin, and one thread wins ties.

- [ ] **Step 2: Add drift and load rejection tests**

Feed monotonically worsening fake timings and assert the result is marked unstable and not cached. Preserve raw samples and select conservative one-thread fallback.

- [ ] **Step 3: Implement actual training-session trials**

Create candidate sessions from the same nominal checkpoint, batch, and seed so optimizer state cannot leak between candidates. Test only `1, 2, 4` up to available logical CPUs; do not add eight threads without evidence.

- [ ] **Step 4: Separate generic machine identity from workload results**

Retain `calibration_key()` for hardware identity, but store per-structural-fingerprint training results. Ignore and rebuild existing inference-MatMul cache entries for training profile selection.

- [ ] **Step 5: Run randomized thread sweeps**

For Car Dense, MNIST MLP, and MNIST Conv, perform multiple randomized/interleaved sweeps after a cooldown window. Report instability rather than publishing a false global winner.

- [ ] **Step 6: Run tests and commit**

Run: `python -m pytest tests/local_runtime/test_training_profile.py tests/local_runtime/test_prepared_training.py -v`

```bash
git add local_runtime/neuralese_local/training_profile.py local_runtime/neuralese_local/prepared_training.py tests/local_runtime/test_training_profile.py tests/local_runtime/benchmark_training_epochs.py
git commit -m "perf: calibrate threads on real training work"
```

### Task 9: Measure ORT session-option variants without speculative defaults

**Files:**
- Modify: `local_runtime/neuralese_local/training_profile.py`
- Modify: `local_runtime/neuralese_local/training_capabilities.py`
- Modify: `tests/local_runtime/test_training_profile.py`
- Modify: `tests/local_runtime/benchmark_training_epochs.py`
- Modify: `docs/performance/local-training-epochs.md`

**Interfaces:**
- Produces named experimental variants for graph optimization level, memory pattern, CPU arena, and bounded spinning.
- No option becomes default unless it passes the full epoch and UI-responsiveness gates.

- [ ] **Step 1: Add exact SessionOptions tests**

Assert every named variant sets execution mode, inter-op/intra-op counts, spinning, graph optimization level, memory pattern, and CPU arena explicitly and independently.

- [ ] **Step 2: Add a benchmark matrix switch**

Allow `benchmark_training_epochs.py` to select one option variant and emit the exact settings in every raw row.

- [ ] **Step 3: Run interleaved A/B measurements**

Measure each variant on all five scenarios with the optimized batch/schedule/binding path. Capture p50, p95, CPU time, RSS, and a concurrent lightweight responsiveness probe.

- [ ] **Step 4: Promote only measured winners**

Adopt a variant per workload class only if it improves train-only p50 by at least 3%, does not regress p95 or responsiveness by more than 3%, and passes all quality tests. Otherwise document it as rejected.

- [ ] **Step 5: Run tests and commit**

Run: `python -m pytest tests/local_runtime/test_training_profile.py tests/local_runtime/test_training_capabilities.py -v`

```bash
git add local_runtime/neuralese_local/training_profile.py local_runtime/neuralese_local/training_capabilities.py tests/local_runtime/test_training_profile.py tests/local_runtime/benchmark_training_epochs.py docs/performance/local-training-epochs.md
git commit -m "perf: tune ORT training epoch sessions"
```

### Task 10: Full epoch verification and target-i5 report

**Files:**
- Modify: `tests/local_runtime/benchmark_training_epochs.py`
- Modify: `tests/local_runtime/test_training_quality.py`
- Modify: `docs/performance/local-training-epochs.md`

**Interfaces:**
- Produces a reproducible raw-data directory and final before/after report for the complete scenario matrix.

- [ ] **Step 1: Run all local-runtime correctness tests**

Run: `python -m pytest tests/local_runtime -v`

- [ ] **Step 2: Run repository Python policy suites**

Run: `python -m pytest tests/node_dev tests/jasondocs tests/release tests/integration -v`

- [ ] **Step 3: Run node-registry consistency**

Run: `python -m tools.node_dev check`

- [ ] **Step 4: Run the final reference-machine epoch matrix**

Use at least 20 measured non-validation epochs per scenario after warm-up, interleave old-safe and optimized modes, preserve every raw sample, and report p50/p95 plus relative improvement. Confirm the combined gates in the spec.

- [ ] **Step 5: Run the same matrix on a four-thread i5-class target**

Record CPU model, logical/physical cores, RAM, Windows version, power mode, Python/NumPy/ORT versions, thermal/load notes, and raw samples. Do not substitute extrapolated development-machine numbers.

- [ ] **Step 6: Verify learning and artifact parity**

Run the fixed-seed quality matrix, checkpoint reload, fresh-versus-resume tests, exported-model parity, stop behavior, and full/tail-batch coverage. Record accepted tolerances and actual deltas in the report.

- [ ] **Step 7: Document rollback controls and residual compute floor**

Document how to select exact sample shuffle, NumPy calls, explicit batch size, and conservative one-thread mode. Separate remaining ORT `TrainStep` compute from removable Python/data overhead and link a future reduced-MAC research plan rather than mixing it into this rollout.

- [ ] **Step 8: Final commit**

```bash
git add tests/local_runtime/benchmark_training_epochs.py tests/local_runtime/test_training_quality.py docs/performance/local-training-epochs.md
git commit -m "docs: verify local training epoch performance"
```

## Acceptance summary

- Car Dense p50 <= 8.0 ms and p95 <= 14.0 ms on the reference machine.
- MNIST MLP p50 <= 200 ms and p95 <= 260 ms on the reference machine.
- MNIST Conv p50 <= 600 ms and p95 <= 690 ms on the reference machine.
- Iris and Titanic stay within 5% or 0.10 ms of their baseline, whichever is larger.
- Every automatic choice is independent of dataset names and preserves explicit user configuration.
- The target-i5 matrix is measured on hardware, not inferred.
- No speedup is accepted without fixed-budget learning-quality and checkpoint/export parity.
