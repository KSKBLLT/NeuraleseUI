# Algorithmic Training Acceleration Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Reduce steady-state epoch time with progressive suffix freezing and selective block backpropagation while enforcing bounded accuracy/loss regression.

**Architecture:** A pure policy module derives workload eligibility, ordered parameter groups, freeze stages, and deterministic block selection. `PreparedSession` owns ORT artifact variants and epoch-boundary runtime switches; `EpochRunner` only executes selected stable blocks and reports coverage.

**Tech Stack:** Python 3.11, NumPy, ONNX Runtime Training 1.19.2, pytest.

**Spec:** `docs/superpowers/specs/2026-09-18-algorithmic-training-acceleration-design.md`

## Global Constraints

- Never select behavior from a dataset name.
- Preserve the existing full-training path behind request flags.
- Switch freeze stages only between epochs and never reset learned weights.
- Treat absolute validation-accuracy regression above 0.15 or relative loss regression above 0.35 as a failed candidate.
- Do not add custom sparse kernels, structured pruning, or early stopping in this plan.

---

### Task 1: Pure acceleration policy

**Files:**
- Create: `local_runtime/neuralese_local/training_acceleration.py`
- Create: `tests/local_runtime/test_training_acceleration.py`

**Interfaces:**
- Produces: `parameter_groups(model, trainable_params) -> list[tuple[str, ...]]`
- Produces: `freeze_schedule(groups, epochs, enabled=True) -> tuple[FreezeStage, ...]`
- Produces: `SelectiveBlockPolicy.select(epoch, epochs, losses, rng) -> set[int]`

- [x] **Step 1: Write failing tests for grouping, two/three-stage schedules, tiny-job fallback, deterministic hard-block selection, exploration, and full refresh epochs.**
- [x] **Step 2: Run the focused test and confirm failure is caused by the missing `training_acceleration` module.**
- [x] **Step 3: Implement immutable policy types and pure functions with the exact 40%/75% freeze boundaries and 80% selective coverage from the spec.**
- [x] **Step 4: Re-run the focused tests and `tests/local_runtime/test_batch_schedule.py` (30 passed).**
- [x] **Step 5: Commit only the policy, tests, spec, and plan.**

### Task 2: Selective block execution

**Files:**
- Modify: `local_runtime/neuralese_local/epoch_runner.py`
- Modify: `tests/local_runtime/test_epoch_runner.py`

**Interfaces:**
- Consumes: `SelectiveBlockPolicy`
- Produces: `EpochResult.available_batches`, `EpochResult.coverage`, and persistent `EpochRunner.block_losses`

- [x] **Step 1: Add failing runner tests proving two warm-up epochs are full, an eligible selective epoch executes 80% of stable blocks, final/refresh epochs are full, seeds reproduce selection, and lazy datasets remain supported.**
- [x] **Step 2: Run the focused test and verify failure is the missing `selective_policy` interface.**
- [x] **Step 3: Make stable block descriptors available for eligible jobs, select descriptors before materializing batches, and update loss by descriptor identity after a successful optimizer step.**
- [x] **Step 4: Emit executed and available batch counts without allocating progress packets when throttled.**
- [x] **Step 5: Run epoch-runner and batch-schedule tests (34 passed); record the pre-existing nondeterministic quality-test failures before wiring the new path.**
- [x] **Step 6: Commit the selective runner change.**

### Task 3: ORT progressive freeze artifacts

**Files:**
- Modify: `local_runtime/neuralese_local/prepared_training.py`
- Modify: `tests/local_runtime/test_prepared_training.py`
- Modify: `tests/local_runtime/test_training_artifact_cache.py`

**Interfaces:**
- Consumes: `freeze_schedule` and `parameter_groups`
- Produces: cached `ArtifactEntry` per stage and `_switch_freeze_stage(stage) -> bool`

- [x] **Step 1: Add failing integration tests proving artifact keys differ by trainable suffix, duplicate stages are omitted, and switching preserves the complete parameter buffer.**
- [x] **Step 2: Run the focused tests and verify failure before production edits.**
- [x] **Step 3: Prepare every stage through the existing artifact cache with stage trainable parameters in the fingerprint/spec.**
- [x] **Step 4: Implement epoch-boundary runtime switching by snapshotting the full contiguous parameter buffer, creating the narrower Module/Optimizer, and copying that buffer back with `trainable_only=False`.**
- [x] **Step 5: On unsupported transfer, retain the current runtime, emit a fallback reason, and never overwrite weights.**
- [x] **Step 6: Publish freeze stage, optimizer reset, coverage, and executed/available batches in state events and manifest.**
- [x] **Step 7: Run prepared-session, artifact-cache, checkpoint, and quality tests (43 focused tests and 8 quality scenarios passed).**
- [x] **Step 8: Commit progressive freezing.**

### Task 4: Benchmark and quality gate

**Files:**
- Modify: `tests/local_runtime/benchmark_training_epochs.py`
- Modify: `tests/local_runtime/test_training_epoch_benchmark.py`
- Modify: `tests/local_runtime/test_training_quality.py`
- Modify: `docs/performance/local-training-runtime.md`

**Interfaces:**
- Produces: `--algorithmic-acceleration on|off` A/B benchmark rows with stage, coverage, final accuracy, and final loss.

- [x] **Step 1: Add failing benchmark-parser tests for the new row fields and quality comparison.**
- [x] **Step 2: Implement the benchmark flag and summary fields without changing scenario definitions.**
- [x] **Step 3: Run the five-scenario baseline/optimized matrix with paired seeds and six measured steady-state epochs per scenario.**
- [x] **Step 4: Gate jobs with fewer than eight batches through structural policy, never through a dataset-name exception.**
- [x] **Step 5: Record p50/p95, coverage, and accuracy/loss deltas in the performance document.**
- [x] **Step 6: Run the local-runtime suite (159 passed; 3 documented pre-existing auto-batch quality failures), repo Python suites (117 passed, 42 subtests), and node registry check (21 nodes).**
- [x] **Step 7: Commit benchmark evidence and final policy thresholds.**
