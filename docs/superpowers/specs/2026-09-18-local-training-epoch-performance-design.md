# Local Training Epoch Performance

Date: 2026-09-18

## Purpose

Minimize the wall-clock duration of FullyLocal training epochs on ordinary
Intel Core i5-class laptops without changing the meaning of the user's graph,
silently weakening training, or coupling optimizations to dataset names.

This work begins after a `PreparedSession` is ready. Worker startup, Python
imports, dataset discovery, artifact generation, session construction, final
ONNX export, and checkpoint persistence are outside this scope. Validation is
timed separately from the training batches so a faster benchmark cannot hide
work by moving it between phases.

## Current baseline

The baseline was collected on 2026-09-18 with the bundled Python 3.11 runtime,
NumPy 1.26.4, and ONNX Runtime Training 1.19.2. Every scenario used an already
prepared session, seven runs of seven epochs, batch size 128, and reported only
non-validation epochs. Raw JSONL and cProfile files are under
`docs/performance/epoch-profiles-2026-09-18/`.

| Scenario | Graph | Batches | Train-only epoch p50 | p95 |
|---|---|---:|---:|---:|
| Iris Dense | 4 -> 16 -> 3 | 1 | 0.32 ms | 0.77 ms |
| Titanic Dense | 8 -> 16 -> 2 | 6 | 1.91 ms | 8.29 ms |
| Car Dense | 8 -> 32 -> 16 -> 2 | 43 | 13.29 ms | 19.23 ms |
| MNIST MLP | Flatten -> 16 -> 10 | 469 | 291.09 ms | 353.86 ms |
| MNIST Conv | Conv 4 -> Flatten -> 16 -> 10 | 469 | 701.61 ms | 786.95 ms |

The benchmark machine is a development reference, not the target floor. The
same matrix must be repeated on at least one four-thread i5-class laptop before
shipping tuned defaults.

## Measured bottlenecks

### Unused ORT training outputs

`train_task._generate_training_artifacts()` currently passes every model output
as `additional_output_names`. During training, `PreparedSession.start()` uses
only the loss. The ORT Python `Module` nevertheless materializes every fetch and
converts it to NumPy on every batch.

Directional cProfile totals for a single non-validation epoch were about 47 ms
for output conversion on MNIST MLP and 78 ms on MNIST Conv. cProfile adds
per-call overhead, so wall-clock benchmarks, not these component totals, are
the acceptance metric.

The training graph should expose only scalar loss. The evaluation graph must
continue to expose loss plus predictions because `evaluate_module()` needs the
model output for metrics.

### Random gather copies

Every epoch shuffles one sample-index array. Every batch then calls
`ArrayDataset.batch_indices()`, which uses `np.take()` into reusable buffers.
For MNIST this copies the complete 179 MiB materialized input once per epoch.
The measured directional cost was about 74 ms for MLP and 94 ms for Conv.

The optimized data path must preserve stochastic ordering without requiring a
full random gather for every batch. Candidate policies must be compared for
both wall time and learning quality:

- shuffle batch blocks and use contiguous views within each block;
- pre-permute the dataset once into a reusable epoch buffer, then train through
  contiguous views;
- refresh a full sample permutation less frequently while rotating block
  boundaries between epochs.

No policy is accepted solely because it is faster. Fixed-seed loss/accuracy or
MAE must remain within a declared tolerance against the current sample shuffle.

### NumPy-to-OrtValue wrapper work

The NumPy `Module.__call__` path builds an `OrtValueVector` for every batch and
converts all fetched values back to NumPy. The training loop already owns
stable full-batch and tail-batch buffers. It should bind reusable CPU OrtValues
to those buffers when the installed ORT API proves that updates are observed
without reallocating or retaining stale memory.

The implementation needs separate bindings for full and tail shapes. It must
fall back to the NumPy call path when capability probing fails.

### Batch size

The current default of 128 is not optimal across the measured workload shapes.
A controlled sweep on the reference machine found:

| Scenario | 64 | 128 | 256 | 512 | 1024 | Best measured |
|---|---:|---:|---:|---:|---:|---:|
| Car Dense | 20.09 ms | 11.08 ms | 8.32 ms | 4.48 ms | 5.15 ms | 512 |
| MNIST MLP | 490.88 ms | 287.91 ms | 215.13 ms | 322.91 ms | 337.74 ms | 256 |
| MNIST Conv | 805.89 ms | 704.27 ms | 657.42 ms | 767.61 ms | 738.41 ms | 256 |

Automatic selection must use graph and tensor cost, available memory, and
short real `TrainStep` measurements. It must never inspect the dataset name.
An explicit user batch size always wins. Because batch size changes optimizer
dynamics, automatic candidates must pass fixed-budget quality checks.

### Thread selection

`training_profile.calibrate_machine()` benchmarks an inference-only MatMul.
The thread sweep did not reliably predict sustained training performance and
was sensitive to run order and machine load. Thread calibration must therefore
use the actual prepared training graph, randomized/interleaved candidate order,
warm-up steps, robust medians, and a bounded CPU-load/drift check.

The result is cached by CPU/ORT identity, structural fingerprint, batch shape,
and workload class. One thread is the conservative fallback.

### Progress construction

The worker transmits batch progress at most ten times per second, but the
training loop still creates a nested dictionary and calls the callback for
every batch. Throttling belongs before packet construction. Epoch boundaries,
completion, stop, and errors remain lossless.

## Architecture

### Epoch runner

Move the batch loop behind a small `EpochRunner` owned by `PreparedSession`.
It receives the dataset, module, optimizer, cancellation predicate, batch
policy, bound-input capability, and a rate-limited progress sink. It returns an
`EpochResult` with average loss, batches, training seconds, data-copy seconds,
ORT step seconds, optimizer seconds, and progress seconds when profiling is
enabled.

Production timing instrumentation is sampled or disabled by default so it does
not become a new per-batch overhead.

### Train/eval output contracts

Artifact creation has two explicit contracts:

- train: scalar loss only;
- eval: scalar loss plus the original model outputs.

The artifact cache schema and fingerprint include this contract version. Old
entries are rebuilt instead of being loaded with incompatible outputs.

### Batch policy

`ArrayDataset` exposes contiguous batch views and indexed-copy batches. A
`BatchSchedule` describes the order without knowing dataset names. The default
policy remains the current exact sample shuffle until the faster policy passes
quality gates on Iris, Titanic, Car, MNIST MLP, and MNIST Conv.

### Calibration and cache

Calibration is performed only on an already prepared session and is bounded.
It tests a small candidate set around safe powers of two and thread counts
available on the machine. Candidate order is interleaved, the first step is
discarded, and the winner must beat the conservative baseline by more than the
noise threshold. Results are stored separately from structural artifacts so a
bad profile can be deleted without rebuilding the model.

## Correctness constraints

- Never choose behavior from a dataset name.
- Preserve explicit user batch sizes and seeds.
- Preserve fresh-versus-resume optimizer-state semantics.
- Preserve stop checks between batches.
- Preserve exact final export and checkpoint contracts.
- Do not make validation less frequent as an epoch-speed optimization.
- Do not claim a speedup unless median and tail latency both improve across
  interleaved before/after runs.
- Reject changes that improve speed while producing NaN/Inf, changing output
  shapes, or failing the fixed-budget learning-quality tolerance.
- Keep a capability-gated fallback for every ORT-specific fast path.

## Performance gates

On the reference machine, the first engineering milestone is:

| Scenario | Baseline p50 | Required p50 | Required p95 |
|---|---:|---:|---:|
| Car Dense | 13.29 ms | <= 8.0 ms | <= 14.0 ms |
| MNIST MLP | 291.09 ms | <= 200 ms | <= 260 ms |
| MNIST Conv | 701.61 ms | <= 600 ms | <= 690 ms |

These are combined-pipeline gates, not promised savings from any one change.
The final target-i5 report records absolute p50/p95 and relative improvement
without weakening a gate to match the result.

For tiny graphs, the requirement is no statistically meaningful regression:
Iris and Titanic p50/p95 must remain within 5% or 0.10 ms of baseline,
whichever allowance is larger.

## Verification matrix

Every accepted optimization is measured on:

- Iris classification, Dense;
- Titanic classification, Dense;
- Car simulation imitation data, Dense with MSE;
- MNIST classification, MLP;
- MNIST classification, Conv plus MLP head.

Each benchmark records graph fingerprint, dataset shapes/dtypes, batch size,
threads, ORT/NumPy/Python versions, CPU identity, epoch index, batch count,
train-only time, validation time, loss, and peak resident memory. Raw samples
are retained; summaries use p50 and p95 and never silently discard outliers.

Correctness tests cover graph output contracts, full and tail batches,
cancellation, deterministic seeds, resume behavior, capability fallback,
learning-quality parity, and exported-model parity.

## Deferred research track

Sparse training, sparse activations, progressive width, sample curricula, and
reduced-MAC educational modes can reduce compute further, especially after the
Conv `TrainStep` becomes dominant. They change the mathematical training
process rather than remove overhead, so they require a separate opt-in design,
quality study, and plan. They are intentionally not mixed into this epoch
overhead implementation.
