# FullyLocal training epoch profile

Date: 2026-09-18

## Scope

This report covers only work performed after an ONNX Runtime training session
is prepared. Python startup, imports, dataset discovery, model compilation,
artifact generation, session creation, export, and checkpoint persistence are
excluded.

Validation is recorded separately. `train-only` is the epoch wall time minus
the explicitly measured validation interval.

## Environment

- Windows 10 build 26200
- Intel64 Family 6 Model 140 Stepping 1, 8 logical CPUs
- bundled Python 3.11.9
- NumPy 1.26.4
- ONNX Runtime Training 1.19.2

The development CPU is faster than the intended four-thread i5-class floor.
These absolute values are a reference baseline, not target-hardware results.

## Method

Each baseline scenario used seven fresh prepared sessions and seven epochs per
session at batch size 128. Only the four middle non-validation epochs from each
run were summarized, producing 28 train-only samples per scenario. cProfile was
attached to one non-validation epoch in a separate run; its per-call overhead
makes those component totals directional rather than authoritative wall time.

Raw output is preserved under `docs/performance/epoch-profiles-2026-09-18/`.

## Baseline

| Scenario | Dataset and graph | Batches | p50 | p95 | Validation p50 |
|---|---|---:|---:|---:|---:|
| Iris Dense | 120 rows, 4 -> 16 -> 3 | 1 | 0.32 ms | 0.77 ms | 0.46 ms |
| Titanic Dense | 712 rows, 8 -> 16 -> 2 | 6 | 1.91 ms | 8.29 ms | 0.74 ms |
| Car Dense | 5,400 rows, 8 -> 32 -> 16 -> 2, MSE | 43 | 13.29 ms | 19.23 ms | 1.25 ms |
| MNIST MLP | 60,000 images, Flatten -> 16 -> 10 | 469 | 291.09 ms | 353.86 ms | 12.13 ms |
| MNIST Conv | 60,000 images, Conv 4 -> Flatten -> 16 -> 10 | 469 | 701.61 ms | 786.95 ms | 15.93 ms |

## Hot-loop findings

### MNIST MLP

The profiled epoch took about 289 ms:

- `Module.__call__`: 155 ms total;
- native ORT `train_step` within it: 97 ms;
- output-to-NumPy conversion within it: 47 ms;
- random batch gathering: 81 ms, including 74 ms in `np.take`;
- optimizer step: 35 ms;
- shuffling the index array: 1.3 ms;
- progress callback: 2.1 ms.

The components are nested where stated and must not be summed twice. The two
largest removable costs are random gather copies and unused output conversion.

### MNIST Conv

cProfile inflated the epoch from the normal roughly 702 ms to 909 ms, so only
the ordering is useful:

- native ORT `train_step` dominates at about 596 profiled ms;
- random batch gathering used about 111 ms, with 94 ms in `np.take`;
- output conversion used about 78 ms;
- optimizer step used about 58 ms.

After Python/data overhead is removed, Conv compute inside ORT remains the
primary floor.

### Dense tabular workloads

For Car Dense, the profiled 14 ms epoch was dominated by the same fixed batch
costs: about 10.3 ms in module calls, 1.2 ms gathering, and 1.1 ms optimizer
steps. Tiny Iris/Titanic workloads are already sub-millisecond to low single
digits, so changes must avoid adding abstraction overhead to their path.

## Batch sweep

Prepared-session train-only p50:

| Scenario | 64 | 128 | 256 | 512 | 1024 |
|---|---:|---:|---:|---:|---:|
| Car Dense | 20.09 ms | 11.08 ms | 8.32 ms | **4.48 ms** | 5.15 ms |
| MNIST MLP | 490.88 ms | 287.91 ms | **215.13 ms** | 322.91 ms | 337.74 ms |
| MNIST Conv | 805.89 ms | 704.27 ms | **657.42 ms** | 767.61 ms | 738.41 ms |

Relative to batch 128 in this sweep, the best measured batch reduced Car time
by about 60%, MLP by 25%, and Conv by 7%. The optimum is not monotonic, and batch
size changes optimization dynamics. Automatic selection therefore needs real
training-step calibration plus fixed-budget learning-quality checks.

## Thread sweep warning

The sequential thread sweep produced inconsistent results compared with the
earlier batch sweep and slowed as the machine accumulated sustained load. This
is itself a finding: the current inference-only MatMul calibration is not a
reliable selector for sustained training work, and a sequential sweep can
confuse thermal drift with a thread-count effect.

The replacement must use actual prepared training steps, interleave candidate
order, discard warm-up, use robust medians, reject unstable runs, and cache by
graph/batch/CPU/ORT identity. Until then, one thread is the conservative
fallback rather than publishing an unreliable universal winner.

## Priorities

1. Make the training artifact return only scalar loss; preserve predictions in
   the eval artifact.
2. Replace per-batch random gathers with a quality-tested contiguous schedule.
3. Reuse CPU OrtValue bindings for stable full and tail buffers when the live
   runtime capability probe passes.
4. Move progress throttling before packet allocation.
5. Choose batch size with bounded real training-step calibration.
6. Replace inference MatMul thread calibration with interleaved real training
   trials.
7. A/B explicit ORT session options only after the larger costs are removed.

The implementation and correctness gates are specified in
`docs/superpowers/plans/2026-09-18-local-training-epoch-performance.md`.

## Implemented epoch path

- training artifacts fetch scalar loss only; eval artifacts retain predictions;
- batch progress is rate-limited before packet construction;
- exact, pre-permuted, and block-shuffled schedules share one tested interface;
- large materialized tensors use zero-copy block batches, while exact shuffle is
  retained as the rollback path;
- CPU OrtValue reuse is capability-gated and enabled only for Conv graphs,
  because the interleaved sweep showed a regression for Dense graphs;
- production batch/thread selection is deterministic and depends only on graph
  operators, sample count, input size, and an explicit user batch override;
- runtime TrainStep calibration and its repeated session/checkpoint resets were
  removed from the prepare path;
- explicit batch size and seed remain authoritative.

The fixed production profiles use `512 x 1` for Car-like tabular graphs,
`256 x 2` for image MLPs, and `128 x 1` for convolution graphs. The earlier
profile sweep measured about 2.6--2.9 ms for Car Dense
(`512 x 1`), 79--83 ms for MNIST MLP (`256 x 2`), and 468--473 ms for MNIST
Conv (`128 x 1`) on this reference machine. Conv batch 256 was considered but
did not clear the measured gain threshold on this run.

## SessionOptions experiments

The epoch benchmark exposes `safe`, `basic_optimizations`,
`no_memory_pattern`, `no_cpu_arena`, and `spinning`. Every variant explicitly
sets execution mode, thread counts, graph optimization level, spinning, memory
pattern, and CPU arena. Raw ABBA samples include CPU time and a concurrent
responsiveness-gap probe in `options-*.jsonl`.

No experimental option is promoted globally. Short sweeps showed conflicting
winners across Dense and Conv workloads and substantial run-to-run noise;
therefore `safe` (sequential, full graph optimizations, memory pattern and CPU
arena enabled, spinning disabled) remains the production default. This is the
conservative result required by the promotion gate, not a missing experiment.

The 24-sample Conv confirmation rejected the apparent short-run
`no_memory_pattern` win: safe measured 441.60/494.98 ms p50/p95, while the
candidate measured 481.63/617.35 ms and had a much worse responsiveness gap.

## Final ABBA matrix

Each cell below has 24 post-warm-up epoch samples. `safe` uses exact sample
shuffle, NumPy inputs, explicit batch 128, and conservative session options.
`optimized` uses the production schedule, the same fixed batch/thread profiles
now selected without runtime trials, and the capability/workload-gated
OrtValue path. Both configurations
use the loss-only training artifact, so this comparison isolates the later
hot-loop changes rather than overstating the combined result.

| Scenario | Safe p50 / p95 | Optimized p50 / p95 | Median change |
|---|---:|---:|---:|
| Iris Dense | 0.11 / 0.23 ms | 0.18 / 0.24 ms | +0.07 ms |
| Titanic Dense | 0.56 / 0.84 ms | 0.31 / 0.57 ms | -44.6% |
| Car Dense | 6.17 / 8.98 ms | 2.55 / 3.77 ms | -58.7% |
| MNIST MLP | 181.18 / 213.04 ms | 90.08 / 104.67 ms | -50.3% |
| MNIST Conv | 508.72 / 687.10 ms | 478.65 / 754.76 ms | -5.9% median; p95 gate missed |

The Conv median passes the target, but its sustained-load optimized p95 did not
pass the 690 ms acceptance gate. A separate optimized-only run was materially
lower; the ABBA result is retained because the plan forbids hiding thermal or
background-load tails. No more aggressive option is enabled to manufacture a
better number.

## Correctness and quality verification

- `tests/local_runtime`: 136 passed;
- repository policy suites: 117 passed plus 42 subtests;
- node developer check: 21 nodes consistent;
- fixed-seed schedule quality: Iris, Titanic, Car, MNIST MLP, MNIST Conv;
- fixed batch-profile quality: Car, MNIST MLP, MNIST Conv;
- fresh/reset, resume checkpoint, export/eval, cancellation, full and tail
  batches are covered by the local-runtime suite.

The fixed large-batch defaults apply bounded linear learning-rate scaling so the
same sample budget does not silently receive fewer effective optimization
updates. Explicit batch size and learning rate are never rescaled.

## Rollback controls

- set `schedule_policy` to `exact` to restore per-sample shuffle;
- set `use_ortvalue_inputs` to `false` to force NumPy module calls;
- send an explicit positive `batch_size` to override the fixed workload default;
- use `session_option_variant: safe` for the conservative ORT configuration;
- unstable calibration is not cached and falls back to one thread.

## Target-i5 status

The available machine is an 11th Gen Intel Core i7-11370H (4 cores, 8 logical
CPUs), not the requested four-thread i5-class target. Therefore no i5 numbers
are fabricated or extrapolated. The benchmark command and raw schema are ready
to run unchanged on that hardware; target acceptance remains an external
measurement gate.
