# Prepared Training Runtime

Date: 2026-09-17

## Purpose

Reduce FullyLocal training click-to-first-batch latency to an effectively
instantaneous fast path while preserving the existing training semantics,
checkpoint contract, error contract, remote-training fallback, and Godot UI
responsiveness.

The fast path is allowed to keep a resident Python worker, imported NumPy,
ONNX, and ONNX Runtime modules, all built-in datasets, and one prepared
training session in memory from application startup. A resident footprint of
several hundred megabytes is acceptable. User datasets keep the existing
`dataset.json` representation; the worker caches their parsed arrays in memory
and invalidates them using a stable revision rather than requiring a new file
format.

## Performance targets

Measurements use monotonic clocks and report p50 and p95 separately for hot,
warm, and cold paths.

| Path | Definition | Click to first `TrainStep` target |
|---|---|---:|
| Hot | worker, dataset, artifacts, and session prepared | p95 <= 50 ms |
| Warm | worker ready; session must be prepared | p95 <= 400 ms for small graphs |
| Cold | worker process and imports are not resident | measured baseline; no hard guarantee |

Cold process startup cannot be made instantaneous without moving work earlier
or replacing the Python runtime. The UI must not fake readiness: `training_ready`
means the session is genuinely able to enter its first training step.

## Current bottlenecks

`scripts/run_manager.gd::_start_train_fully_local()` creates a job directory,
writes request and dataset JSON, and starts a new Python process for every
training request. `local_runtime/neuralese_local/train_task.py::run_training()`
then imports the training API, loads the dataset, compiles the model, generates
all training artifacts, constructs the checkpoint, module, and optimizer, and
only then enters the batch loop.

Progress and cancellation also use the filesystem. Python opens, appends,
flushes, and closes `progress.jsonl` per event; Godot reopens and parses the
file during `_process()`. `StopFlag` checks the stop file and the parent process
from the batch loop. Intermediate validation exports an inference model and
creates a separate inference session.

## Architecture

### Resident worker

`train_worker.py` is a long-lived process started asynchronously during normal
application startup after the startup UI has rendered. It receives the Godot
parent PID, a runtime root, a cache root, a random authentication token, and an
idle policy. Import and built-in dataset warm-up must never block the Godot main
thread or startup dialogs.

The worker state machine is:

```
COLD -> RUNTIME_READY -> DATASETS_READY -> ARTIFACTS_READY
     -> SESSION_READY -> TRAINING -> SESSION_READY
```

It supports the commands:

- `PING` and `STATUS`
- `PREPARE`
- `START`
- `STOP`
- `SAVE`
- `EVICT`
- `SHUTDOWN`

Only one training job may execute at a time. At most one prepared session is
retained initially. Preparing a new generation evicts the older session after
active users release it. Built-in datasets remain cached for the worker's
lifetime. Parsed user datasets use an LRU cache with a bounded configurable
size.

The existing per-job `train_entry.py` remains as a compatibility fallback
behind a runtime feature flag until the resident path passes the full local
runtime suite.

### Worker startup and recovery

Godot starts the worker without awaiting readiness. Readiness is observed in
the background and exposed through diagnostics. If training is requested before
the worker is ready, the request is queued and uses the warm path as soon as the
worker accepts commands.

The worker checks its parent PID no more than once per second. EOF on its
control connection, parent death, or `SHUTDOWN` terminates it. Godot restarts it
once after an unexpected crash and invalidates all prepared handles. A second
crash for the same request falls back to the legacy one-shot worker and reports
diagnostics without duplicating a training run.

### Control plane

The primary control plane is a loopback TCP connection using unsigned
32-bit big-endian length-prefixed UTF-8 JSON frames. The worker binds only to
`127.0.0.1` on an ephemeral port and writes the selected port plus a random
128-bit token to a small bootstrap file. Every command carries the token and a
monotonic request id.

Bulk datasets and model artifacts are not transmitted through JSON frames.
They remain in stable files or worker memory. Progress is coalesced to at most
10 updates per second, while lifecycle events, epoch boundaries, errors,
stops, and completion are never dropped.

The filesystem JSONL control path remains available only for the one-shot
fallback. The resident worker does not poll request files, write per-batch
progress files, or use a stop file.

### Generation and request identity

Godot assigns a monotonically increasing `generation_id` to the training
snapshot. A prepared handle contains:

- generation id;
- canonical graph fingerprint;
- dataset revision;
- artifact fingerprint;
- process generation;
- opaque prepared session id.

Responses for a stale generation or an earlier worker process are ignored.
`START` is idempotent by request id. Reconnecting must never start the same
training job twice.

## Preparation pipeline

### Triggering preparation

Preparation is requested when the graph has been valid and unchanged for
400 ms and a dataset is selected. The debounce is reset by topology, shape,
loss, optimizer, trainable-parameter, or dataset changes. Epoch count, batch
size, and learning rate update run configuration but do not invalidate
structural artifacts unless the installed ORT API requires it.

Startup may preload built-in datasets immediately. Session preparation starts
only after a concrete graph and dataset snapshot exists.

### Prepared session

`PREPARE` performs:

1. dataset lookup or parse;
2. canonical model compilation;
3. structural artifact lookup or generation;
4. checkpoint state construction;
5. `SessionOptions` selection;
6. `Module` creation;
7. `Optimizer` creation;
8. deterministic fresh-parameter initialization;
9. a readiness response carrying timing stages.

`START` validates all handle fields, applies run-only configuration, and enters
the first batch without rebuilding artifacts or recreating the session.

## Caches

### Structural artifact cache

The content-addressed key contains:

- cache schema version;
- actual ORT version and training ABI;
- operating system and architecture;
- relevant CPU capability class;
- canonical graph topology and tensor shapes;
- tensor dtypes;
- trainable and frozen parameter names;
- loss type;
- optimizer type;
- artifact format and optimization settings.

The cache contains training, evaluation, and optimizer models, a nominal or
template checkpoint, and a manifest with file hashes. Entries are built in a
temporary directory, validated, and atomically renamed. A per-key lock prevents
duplicate generation. Corrupt, partial, or incompatible entries are deleted
and regenerated.

The cache never silently reuses optimizer state or trained weights. Fresh
training and resume training are separate operations.

### Parameter and checkpoint state

Fresh training initializes parameters from an explicit seed and copies them
into a prepared session using the ORT contiguous parameter-buffer API where
available. Resume training loads the user checkpoint and optimizer state by an
explicit command. The original one-shot semantics remain the default until the
UI exposes a separate resume action.

Nominal checkpoints and ORT-format artifacts are enabled only after runtime
capability detection and benchmark validation. ONNX artifacts remain the safe
fallback.

### Dataset cache

All installed built-in datasets are loaded by the worker during background
warm-up and remain in memory. Dataset names do not select performance profiles;
profiles use sample count, bytes per sample, tensor shapes, graph operation
types, and parameter count.

User datasets keep `dataset.json`. Godot supplies a dataset revision derived
from its dataset identity and content/version metadata. The worker cache key is
`(canonical_path, revision)`. On a miss it parses the JSON once, normalizes the
arrays, and retains them in an LRU. File size and modification metadata are
checked defensively so a stale revision cannot silently reuse changed data.

The initial implementation does not introduce a revisioned `.npy` store for
user datasets. That is an optional future migration, not a prerequisite for
the resident fast path.

Built-in image datasets may use separate `.npy` arrays. A batch-oriented
dataset implementation must preserve memory mapping and source dtype rather
than eagerly converting the entire array in `ArrayDataset.__post_init__`.
Image bytes remain `uint8` until copied and normalized into a reusable
`float32` batch buffer. Small tabular datasets remain fully materialized.

## Training loop

The loop reuses a shuffle index and random generator, shuffles in place, and
reuses batch buffers where shape permits. Cancellation is an in-memory flag set
by the control reader. It is checked between batches and expensive phases.

Progress packets are coalesced. Batch loss is accumulated numerically without
allocating a UI packet for every batch. The worker always sends `epoch_start`,
`epoch_end`, `training_ready`, `done`, `stopped`, and `error`.

Intermediate validation uses the existing training `Module` in evaluation
mode. It does not export an inference model or create a second inference
session. Inference export, output post-processing, checkpoint save, and manifest
write occur at final completion, explicit save, or recoverable stop.

All final files are written through temporary files/directories and atomically
replaced. A stopped or failed job cannot leave a manifest pointing at an
incomplete checkpoint.

## Runtime tuning

`Module` receives explicit `SessionOptions`:

- sequential execution;
- one inter-op thread;
- workload-derived intra-op thread count;
- disabled or bounded spinning;
- release-safe logging severity.

The initial profiles are based on estimated work, never dataset names:

- tiny: one intra-op thread;
- small: one or two threads;
- heavy: two or four threads selected by a short cached machine calibration.

CPU affinity is disabled by default. It may be enabled only by measured
machine-specific tuning. Worker priority must preserve Godot UI responsiveness.

ORT-format artifacts and offline graph optimization are benchmarked behind
capability flags. Optimized artifacts are never reused across incompatible CPU
capability classes.

## Native sidecar

After the Python resident path is stable, a native C++ sidecar is implemented
behind `FULLY_LOCAL_NATIVE_TRAINING`. It uses a custom ORT build that includes
the Training C API. Python remains responsible for artifact generation until
the native path can consume the same structural cache.

The native worker implements training-session creation, train and evaluation
steps, optimizer steps, lazy gradient reset, checkpoint loading from a buffer,
parameter-buffer copying, export, shared allocator configuration, and thread
pool configuration. It speaks the same framed protocol and returns the same
error and progress contracts. The Python worker remains the automatic fallback
on unsupported platforms or missing training symbols.

ORT is not embedded into the Godot process. The sidecar remains a crash and
resource-isolation boundary.

## Packaging

The bundled Python environment must contain one coherent ORT training
distribution. Stale metadata from `onnxruntime-training 1.15.1` is removed when
the 1.19.2 runtime is rebuilt. The build records exact package versions and
hashes.

Runtime binaries live in a stable installed directory and are not unpacked on
each launch. Release builds suppress debug tracebacks for user errors while
retaining structured diagnostics. Binary signing and installer behavior are
handled by the existing release pipeline; no runtime code attempts to modify
antivirus exclusions.

## Instrumentation

Every prepare and start request records:

- Godot request serialization;
- worker availability wait;
- command transport;
- dataset lookup/load/normalization;
- model compilation;
- artifact lookup/generation;
- checkpoint load/reset;
- module construction;
- optimizer construction;
- click-to-first-step;
- first batch;
- evaluation;
- export;
- checkpoint save.

Events include cold/warm/hot classification, cache hit flags, graph and dataset
size classes, but no user data. Diagnostics expose p50/p95 summaries locally.

## Failure handling

- Invalid or stale prepared handles trigger one transparent re-prepare.
- Worker crash invalidates all handles and may restart once.
- Cache corruption causes eviction and regeneration.
- Unsupported ORT capabilities select the ONNX/template-checkpoint fallback.
- Native backend failure selects Python before training begins; it never
  restarts an already-running job on another backend.
- Remote training behavior and authentication paths are unchanged.
- A failed startup warm-up never prevents the editor from opening.

## Verification

Python tests cover framing, authentication tokens, worker lifecycle, request
idempotency, generation invalidation, dataset cache invalidation, artifact cache
keys, corruption recovery, fresh-vs-resume state, progress throttling,
cancellation, eval without export, atomic persistence, and fallback behavior.

Godot tests cover startup non-blocking behavior, worker restart, stale response
rejection, graph debounce, hot `START`, stop semantics, error localization, and
legacy one-shot fallback.

End-to-end benchmarks cover Iris-sized dense graphs, medium tabular datasets,
MNIST MLP, and a convolutional image graph. They report cold, warm, and hot
paths separately on a four-thread target machine. Correctness checks compare
loss, exported model outputs, checkpoint reload, and deterministic seeded
initialization with the legacy implementation.

## Delivery order

1. stage timing and benchmark harness;
2. resident worker lifecycle with legacy fallback;
3. in-memory built-in and user-JSON dataset caches;
4. graph generation ids and debounced `PREPARE`;
5. structural artifact cache;
6. prepared session and explicit fresh-state reset;
7. framed TCP control plane, throttled progress, and in-memory cancellation;
8. module-based evaluation and final-only export;
9. session options, workload profiles, and machine calibration;
10. built-in image batch/memory-map path;
11. ORT-format and offline-optimization experiments with guarded rollout;
12. coherent runtime repackaging;
13. native sidecar behind a feature flag;
14. benchmark comparison and removal of the one-shot default only after parity.

Each delivery step must preserve a runnable fallback and land with its own
tests. The native backend is not allowed to delay or destabilize the Python
resident fast path.
