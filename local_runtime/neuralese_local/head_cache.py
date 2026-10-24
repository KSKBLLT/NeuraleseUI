"""Train the last layer on cached features once everything before it is frozen.

In the "head" freeze stage only the final Dense layer learns, so what reaches
it from each training sample no longer changes. Computing those features once
(one forward pass of the frozen network) and training the layer on them in
NumPy replaces a forward pass through every convolution per step with a small
matrix product. The result is the same layer the ORT step would train: the
same loss (softmax cross-entropy or mean squared error, averaged over the
batch) and the same optimizer (AdamW with ORT's defaults, or plain SGD).

Only a final Dense layer (Gemm, weights [out, in]) whose output is the model's
single output qualifies, and only when the features fit a memory budget.
"""
from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Callable

import numpy as np
import onnx

FEATURE_BUDGET_BYTES = 64 * 1024 * 1024


@dataclass(frozen=True)
class HeadLayer:
    feature_tensor: str
    weight: str
    bias: str | None
    out_features: int
    in_features: int


def find_head_layer(model: onnx.ModelProto, head_params: tuple[str, ...], loss_name: str) -> HeadLayer | None:
    if str(loss_name).lower() not in {"cross_entropy", "crossentropyloss", "ce", "mse", "mse_loss", "mean_squared_error"}:
        return None
    if len(model.graph.output) != 1:
        return None
    output = model.graph.output[0].name
    params = set(head_params)
    for node in model.graph.node:
        if node.op_type != "Gemm" or len(node.input) < 2 or node.input[1] not in params:
            continue
        attributes = {a.name: helper_value(a) for a in node.attribute}
        if attributes.get("transB", 0) != 1 or attributes.get("transA", 0) != 0:
            return None
        if attributes.get("alpha", 1.0) != 1.0 or attributes.get("beta", 1.0) != 1.0:
            return None
        if node.output[0] != output:
            return None
        bias = node.input[2] if len(node.input) > 2 and node.input[2] else None
        if set(filter(None, (node.input[1], bias))) != params:
            return None
        weight = next((i for i in model.graph.initializer if i.name == node.input[1]), None)
        if weight is None or len(weight.dims) != 2:
            return None
        return HeadLayer(node.input[0], node.input[1], bias, int(weight.dims[0]), int(weight.dims[1]))
    return None


def helper_value(attribute: onnx.AttributeProto) -> Any:
    return onnx.helper.get_attribute_value(attribute)


def features_fit(samples: int, layer: HeadLayer, budget: int = FEATURE_BUDGET_BYTES) -> bool:
    return int(samples) * int(layer.in_features) * 4 <= int(budget)


def compute_features(
    model: onnx.ModelProto,
    parameters: dict[str, np.ndarray],
    dataset: Any,
    layer: HeadLayer,
    *,
    threads: int = 1,
    batch_size: int = 512,
) -> np.ndarray:
    """What reaches the head from every training sample, with the current weights."""
    import onnxruntime as ort

    probe = type(model)()
    probe.CopyFrom(model)
    for index, initializer in enumerate(probe.graph.initializer):
        value = parameters.get(initializer.name)
        if value is not None:
            probe.graph.initializer[index].CopyFrom(onnx.numpy_helper.from_array(np.asarray(value), initializer.name))
    del probe.graph.output[:]
    probe.graph.output.append(onnx.helper.make_tensor_value_info(layer.feature_tensor, onnx.TensorProto.FLOAT, None))
    options = ort.SessionOptions()
    options.intra_op_num_threads = max(1, int(threads))
    options.inter_op_num_threads = 1
    session = ort.InferenceSession(probe.SerializeToString(), options, providers=["CPUExecutionProvider"])
    feed = session.get_inputs()[0].name
    features = np.empty((len(dataset), layer.in_features), dtype=np.float32)
    for start in range(0, len(dataset), batch_size):
        stop = min(start + batch_size, len(dataset))
        x, _ = dataset.batch_indices(np.arange(start, stop, dtype=np.int64))
        features[start:stop] = np.asarray(session.run(None, {feed: x})[0], dtype=np.float32).reshape(stop - start, -1)
    return features


class NumpyHead:
    """The final Dense layer, its loss and its optimizer, in NumPy."""

    def __init__(self, layer: HeadLayer, weight: np.ndarray, bias: np.ndarray | None, *,
                 loss_name: str, optimizer: str) -> None:
        self.layer = layer
        self.w = np.array(weight, dtype=np.float32, copy=True)
        self.b = None if bias is None else np.array(bias, dtype=np.float32, copy=True)
        self.cross_entropy = str(loss_name).lower() in {"cross_entropy", "crossentropyloss", "ce"}
        self.adam = str(optimizer).lower() not in {"sgd"}
        # onnxruntime-training's AdamW defaults (onnxblock.optim.AdamW).
        self.betas, self.eps, self.step_count = (0.9, 0.999), 1e-6, 0
        self.m = [np.zeros_like(self.w)] + ([np.zeros_like(self.b)] if self.b is not None else [])
        self.v = [np.zeros_like(value) for value in self.m]

    def _loss_and_grad(self, x: np.ndarray, y: np.ndarray) -> tuple[float, np.ndarray]:
        out = x @ self.w.T
        if self.b is not None:
            out += self.b
        n = len(x)
        if self.cross_entropy:
            out -= out.max(axis=1, keepdims=True)
            np.exp(out, out=out)
            out /= out.sum(axis=1, keepdims=True)
            labels = y.reshape(-1)
            loss = float(-np.mean(np.log(np.maximum(out[np.arange(n), labels], 1e-30))))
            out[np.arange(n), labels] -= 1.0
            return loss, out / n
        diff = out - y.reshape(n, -1)
        return float(np.mean(diff * diff)), diff * (2.0 / diff.size)

    def step(self, x: np.ndarray, y: np.ndarray, lr: float) -> float:
        loss, grad_out = self._loss_and_grad(x, y)
        grads = [grad_out.T @ x] + ([grad_out.sum(axis=0)] if self.b is not None else [])
        params = [self.w] + ([self.b] if self.b is not None else [])
        self.step_count += 1
        if self.adam:
            # AdamWOptimizer with adam_mode=1 (the HuggingFace form ORT uses):
            # eps joins the raw sqrt(v), bias correction scales the step.
            b1, b2 = self.betas
            step_size = lr * np.sqrt(1.0 - b2 ** self.step_count) / (1.0 - b1 ** self.step_count)
            for param, grad, m, v in zip(params, grads, self.m, self.v):
                m *= b1
                m += (1.0 - b1) * grad
                v *= b2
                v += (1.0 - b2) * grad * grad
                param -= step_size * m / (np.sqrt(v) + self.eps)
        else:
            for param, grad in zip(params, grads):
                param -= lr * grad
        return loss

    def train_epoch(self, features: np.ndarray, targets: np.ndarray, *, batch_size: int,
                    rng: np.random.Generator, lr_at: Callable[[int, int], float]) -> tuple[float, int]:
        order = rng.permutation(len(features))
        batches = (len(order) + batch_size - 1) // batch_size
        total = 0.0
        for index in range(batches):
            chosen = order[index * batch_size:(index + 1) * batch_size]
            total += self.step(features[chosen], targets[chosen], lr_at(index, batches))
        return total / max(1, batches), batches

    def write_back(self, state: Any) -> None:
        state.parameters[self.layer.weight] = self.w
        if self.b is not None and self.layer.bias is not None:
            state.parameters[self.layer.bias] = self.b
