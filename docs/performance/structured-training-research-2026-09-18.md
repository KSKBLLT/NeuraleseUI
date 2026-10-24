# Single-thread structured training research

Date: 2026-09-18

## Question

Can large MNIST MLP and convolution graphs be trained materially faster from
the first epoch by reducing backward work, rather than by using more CPU
threads or hiding fixed runtime overhead?

This is an algorithmic research spike. It does not change the production graph
compiler or silently enable a new training policy.

## Benchmark boundary

- bundled Python 3.11.9, NumPy 1.26.4, ONNX Runtime Training 1.19.2;
- full 60,000-example MNIST training split;
- batch size 128, exact per-sample shuffle, Adam, learning rate 0.001;
- ORT sequential execution, `intra_op_num_threads = 1`,
  `inter_op_num_threads = 1`, spinning disabled;
- only `EpochRunner.run_epoch()` TrainStep time is measured;
- artifact generation, session creation, validation, export, and checkpoint IO
  are outside the epoch timer;
- four initialization/shuffle seeds in ABBA execution order;
- the final winner check evaluates all 10,000 validation images after each of
  two epochs.

The MLP is `784 -> 1024 -> 1024 -> 10`. The CNN is
`Conv(1,32,3) -> Pool -> Conv(32,64,3) -> Pool -> Dense(3136,128) -> 10`.
These intentionally expensive graphs represent the workloads that remain slow
after the generic hot-loop work.

Raw results and the research harness are preserved in:

- `tests/local_runtime/_research_single_thread_structures.py`;
- `tests/local_runtime/_research_screening.json`;
- `tests/local_runtime/_research_confirm_mlp.json`;
- `tests/local_runtime/_research_confirm_cnn.json`;
- `tests/local_runtime/_research_full_validation.json`.

## Confirmed result: train a readout/suffix from epoch one

The winning mode keeps the user's forward graph intact but does not request
gradients for the expensive feature extractor during a short fresh run:

- MLP: freeze both 1024-wide hidden layers and train the 10-class readout;
- CNN: freeze the two convolution layers and train the 128-wide dense head and
  readout.

ORT can terminate gradient construction at the frozen boundary, so inference
still traverses every user-created node while Conv/large-Dense backward kernels
and their parameter updates disappear.

The table reports the median of each run's two epoch times, then p50/p95 across
the four runs. Accuracy is the median after epoch two on the complete 10,000
image validation split.

| Graph | Trainable policy | Epoch p50 | Epoch p95 | Speedup | Validation accuracy | Delta |
|---|---|---:|---:|---:|---:|---:|
| MLP | all layers | 21.244 s | 23.266 s | 1.00x | 79.08% | -- |
| MLP | output readout only | 4.759 s | 5.677 s | **4.46x** | 80.11% | **+1.03 pp** |
| CNN | all layers | 71.737 s | 98.109 s | 1.00x | 86.40% | -- |
| CNN | dense head + output | 20.166 s | 31.548 s | **3.56x** | 88.18% | **+1.78 pp** |

This result is not proof that frozen random features are universally better.
It establishes a useful product fact: for the application's common one- or
two-epoch educational run, full backward through a large randomly initialized
extractor did not repay its CPU cost on this workload. The result must not be
extrapolated to long convergence runs or arbitrary datasets.

## Other measured techniques

Screening used the same one-thread 60,000-example epoch path. The first table
below uses four seeds and two epochs; the structural operator screening used
two seeds and one epoch before rejecting clear losers.

| Candidate | Measured outcome | Decision |
|---|---|---|
| Freeze first MLP layer, train last hidden + output | 1.48x; -0.37 pp after two epochs | Valid conservative fallback, but much weaker than readout-only |
| Rank-128 MLP factorization | 2.95x; -4.96 pp at lr 1e-3 | Reject as default: second-epoch instability |
| Rank-128 MLP at lr 5e-4 | 5.52 s p50; accuracy 77.12% | More stable but still worse than dense/readout-only |
| Tucker-2 second convolution | 1.30x; -0.95 pp | Real but modest benefit; inferior to freezing |
| Depthwise convolution + rank-64 dense head | 1.45x; no median accuracy loss | Viable architecture option, not the best transparent optimization |
| Monarch-like block products | 0.93x | Reject: 7% slower than Dense |
| Pixelated/Monarch + low-rank residual | 0.66x | Reject: about 52% slower than Dense |

Monarch and Pixelated Butterfly reduce arithmetic on paper, but the generic ORT
CPU graph expands them into reshape/transpose and small batched MatMul kernels.
Without fused structured-matrix kernels, dispatch and memory traffic erase the
MAC reduction. This is why the research papers' accelerator results do not
transfer automatically to this runtime.

The first attempted Monarch graph also used `Einsum`; ORT Training 1.19.2 has
no registered gradient builder for that operator. The benchmark therefore used
an equivalent `Unsqueeze -> MatMul -> Squeeze -> Transpose` construction. It
trained correctly but remained slower than Dense.

## Recommended production design

Add a graph-derived `short_run_random_features_v1` policy, not a dataset-name
special case.

Eligibility should require all of the following:

1. classification with a differentiable dense readout;
2. a fresh one- or two-epoch run, not an explicit long convergence run;
3. a feed-forward graph whose trainable parameters can be partitioned into an
   extractor prefix and classifier suffix;
4. enough estimated backward MACs in the prefix to repay a second artifact;
5. no explicit user request to train every layer.

Policy selection should use graph topology, parameter ownership, requested
epoch count, tensor shapes, and estimated backward MACs. It must never inspect
`dataset.name`.

Prepare both the full and short-run artifacts in the resident worker. For the
short run, start directly in the suffix artifact. If the user continues
training or requests more than two epochs, copy the complete parameter buffer
into the full artifact and continue with full gradients. Existing staged
artifact switching in `prepared_training.py` is the correct mechanism; the
current schedule merely freezes too late to help one- and two-epoch jobs.

For a first production version:

- MLP suffix: the final parameter group only;
- CNN suffix: start at the first Dense layer after convolution/pooling;
- keep exact shuffle and the same optimizer/loss/export contracts;
- record the active policy in progress/final metadata;
- expose an internal rollback flag that forces full gradients;
- fall back to full training when graph partitioning or artifact generation is
  unsupported;
- preserve the normal full model on export: frozen weights remain ordinary
  initializers, not a different user-visible architecture.

## Techniques not suitable for the current ORT path

- **meProp/top-k gradients:** useful only when gradient sparsity reaches a
  kernel that avoids dense backward work. Adding `TopK` after a dense gradient
  has already been computed saves no MACs. It needs a custom fused gradient and
  sparse update kernel before it is an honest candidate.
- **unstructured dynamic sparse training:** the current CPU MatMul/Conv kernels
  remain dense, so zero-valued weights alone do not improve wall time.
- **activation checkpointing:** reduces memory but recomputes activations and
  normally increases epoch time; it addresses a different bottleneck.
- **generic low-rank substitution:** it changes optimization dynamics and was
  less stable than suffix training in the measured two-epoch budget.
- **structured Monarch/Pixelated layers through standard ONNX operators:** do
  not enable without a fused CPU kernel; the measured versions regressed.

## Research basis

- [FreezeOut](https://arxiv.org/abs/1706.04983) demonstrates wall-time savings
  by excluding frozen layers from backward, with architecture-dependent quality.
- [Random-feature networks](https://proceedings.mlr.press/v202/li23aa.html)
  formalize the regime where hidden parameters stay random and only the output
  layer is optimized.
- [What Makes Freezing Layers Effective?](https://proceedings.mlr.press/v293/coil25a.html)
  specifically studies untrained frozen representations on MNIST and other
  image datasets.
- [Monarch](https://arxiv.org/abs/2204.00595) and
  [Pixelated Butterfly](https://openreview.net/forum?id=Nfl-iXa-y7R) motivate
  structured matrices, while also relying on hardware-efficient implementations.
- [MobileNets](https://arxiv.org/abs/1704.04861) motivates the measured
  depthwise-separable convolution candidate.
- [Selective Backprop](https://arxiv.org/abs/1910.00762) and
  [meProp](https://arxiv.org/abs/1706.06197) remain future candidates, but both
  require savings before or inside backward rather than masking already-computed
  dense gradients.

## Bottom line

The useful single-thread acceleration is not more parallelism and not a test
hardcode. It is a graph-level choice to avoid computing gradients that do not
repay their cost in a one- or two-epoch run. On the tested large MLP and CNN,
that reduced epoch wall time by 3.56--4.46x without an accuracy regression in
the measured budget. Production rollout still needs graph-independent
eligibility, full-artifact continuation, checkpoint/export parity, and tests on
non-MNIST image and tabular classification data.
