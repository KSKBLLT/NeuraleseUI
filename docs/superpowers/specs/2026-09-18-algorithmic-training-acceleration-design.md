# Algorithmic Training Acceleration Design

## Goal

Reduce median training epoch time on weak Intel-class CPUs while allowing a
small, bounded quality regression. Success is measured as epoch wall time plus
an accuracy/loss sanity check, not time to reach 100% accuracy.

## Scope

The first implementation contains two complementary optimizations:

1. Progressive suffix freezing. Training starts with every parameter
   trainable, then switches to cached ORT artifacts that train the last two
   parameter groups and finally the output group.
2. Selective block backpropagation. After full warm-up epochs, later epochs
   train the highest-loss blocks plus a deterministic exploration sample and
   periodically run a full refresh epoch.

Early stopping is recorded as a follow-up because it reduces total training
time, not the requested time per epoch. Unstructured sparsity, meProp, RigL,
and gradient masks are out of scope: the current dense ORT CPU kernels would
still execute the dense backward MACs.

## Safety and activation

- The policy is based on graph structure, requested epoch count, sample count,
  and estimated work. Dataset names are never consulted.
- Tiny jobs keep the existing exact behavior. Progressive freezing requires at
  least two trainable parameter groups and at least four epochs. Selective
  blocks require at least eight batches and at least three epochs.
- Explicit request flags can disable either optimization for diagnostics and
  benchmarks.
- The full-precision baseline remains available through those flags and is
  used for every quality comparison.
- Stage changes happen only between epochs. Cancellation never switches a
  session in the middle of an optimizer step.

## Progressive freezing

The compiler exposes ordered parameter groups corresponding to trainable graph
nodes. A group contains every weight and bias owned by one Dense, Conv, or GRU
node. The order is the model's forward topological order.

For two groups, the schedule is `full -> head`. For three or more groups, it is
`full -> suffix2 -> head`. Full training occupies the first 40% of epochs, the
two-group suffix continues until 75%, and the output head finishes the run.
Duplicate stages are removed.

Each unique trainable set has its own artifact-cache fingerprint because ORT
builds `requires_grad` into the gradient graph. Artifact variants are prepared
before START. At a stage boundary the new runtime is created from its nominal
artifact checkpoint, then receives the complete parameter buffer from the
previous Module. Optimizer moments are intentionally reset at a stage boundary;
weights are never reset. A stage-change event records the reset so the behavior
is observable.

If complete-buffer transfer is unsupported or the parameter layout differs,
the run continues with the current broader stage and reports a non-fatal
fallback. It must never silently reset model weights.

## Selective block backpropagation

The epoch runner uses stable contiguous block identities. Warm-up and refresh
epochs train every block and record scalar batch loss. A selective epoch keeps
80% of blocks: the highest-loss 65% plus a seeded random 15% from the
remainder. Every fifth epoch is a full refresh, and the last requested epoch is
also full so final metrics cover the whole dataset.

The event contract reports both executed and available batches. Average loss is
computed only from executed batches and is explicitly tagged with the coverage
fraction. Fixed seeds reproduce the same selection.

## Measurements and acceptance

The benchmark matrix remains Iris Dense, Titanic Dense, Car Dense, MNIST MLP,
and MNIST Conv. Each optimized run is compared with the full baseline using the
same initialization seed and requested epoch count.

- Record warm-up separately; compare optimized steady-state epoch p50/p95.
- Record executed/available batches, freeze stage, train loss, and validation
  accuracy for every epoch.
- A candidate is acceptable when final loss is finite, absolute validation
  accuracy regression is at most 0.15, and relative loss regression is at most
  0.35 versus the baseline.
- Tiny jobs may remain unchanged; an optimization that does not reduce epoch
  time for its eligible workload is disabled for that workload class.

## Files and boundaries

- `training_acceleration.py`: pure policy, parameter grouping, stage schedule,
  and selective-block decisions.
- `epoch_runner.py`: executes the selected descriptors and reports coverage;
  it does not decide whether the workload is eligible.
- `prepared_training.py`: prepares artifact variants, switches runtimes between
  epochs, and publishes stage/coverage metrics.
- `benchmark_training_epochs.py`: A/B flags and quality/performance summaries.
- Unit tests exercise pure policy and runner behavior; ORT integration tests
  verify parameter preservation and bounded quality regression.
