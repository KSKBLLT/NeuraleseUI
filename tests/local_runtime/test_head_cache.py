"""The final layer trained on cached features learns exactly as ORT would.

neuralese_local/head_cache.py trains the last Dense layer in NumPy once every
layer before it is frozen. Its step must match onnxruntime-training's step
(same loss, AdamW defaults), the weights it writes back must be the ones the
ORT session then uses, and a frozen network's features must be what reaches
that layer.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np
import onnx
from onnx import TensorProto, helper, numpy_helper

from neuralese_local.dataset_store import ArrayDataset
from neuralese_local.head_cache import NumpyHead, compute_features, find_head_layer
from neuralese_local.train_task import _load_ort_training_api


def head_model(inputs: int, outputs: int, rng) -> onnx.ModelProto:
    w = (rng.standard_normal((outputs, inputs)) * 0.3).astype(np.float32)
    b = (rng.standard_normal(outputs) * 0.1).astype(np.float32)
    graph = helper.make_graph(
        [helper.make_node("Gemm", ["features", "w_head", "b_head"], ["out"], transB=1)],
        "head",
        [helper.make_tensor_value_info("features", TensorProto.FLOAT, ["n", inputs])],
        [helper.make_tensor_value_info("out", TensorProto.FLOAT, ["n", outputs])],
        [numpy_helper.from_array(w, "w_head"), numpy_helper.from_array(b, "b_head")],
    )
    return helper.make_model(graph, opset_imports=[helper.make_opsetid("", 15)], ir_version=8)


class HeadCacheTests(unittest.TestCase):
    def ort_steps(self, model, x, y, loss, lr, steps):
        api, artifacts = _load_ort_training_api()
        directory = tempfile.mkdtemp(prefix="neuralese_head_")
        artifacts.generate_artifacts(model, requires_grad=["w_head", "b_head"], loss=loss,
                                     optimizer=artifacts.OptimType.AdamW, artifact_directory=directory)
        state = api.CheckpointState.load_checkpoint(str(Path(directory) / "checkpoint"))
        module = api.Module(str(Path(directory) / "training_model.onnx"), state,
                            str(Path(directory) / "eval_model.onnx"))
        optimizer = api.Optimizer(str(Path(directory) / "optimizer_model.onnx"), module)
        optimizer.set_learning_rate(lr)
        module.train()
        losses = []
        for _ in range(steps):
            module.lazy_reset_grad()
            losses.append(float(module(x, y)))
            optimizer.step()
        return state, module, losses

    def check(self, cross_entropy: bool):
        rng = np.random.default_rng(3)
        model = head_model(6, 4, rng)
        x = rng.standard_normal((16, 6)).astype(np.float32)
        if cross_entropy:
            y = rng.integers(0, 4, 16).astype(np.int64)
            loss_name, loss = "cross_entropy", _load_ort_training_api()[1].LossType.CrossEntropyLoss
        else:
            y = rng.standard_normal((16, 4)).astype(np.float32)
            loss_name, loss = "mse", _load_ort_training_api()[1].LossType.MSELoss
        layer = find_head_layer(model, ("w_head", "b_head"), loss_name)
        self.assertIsNotNone(layer)
        init = {i.name: numpy_helper.to_array(i) for i in model.graph.initializer}
        head = NumpyHead(layer, init["w_head"], init["b_head"], loss_name=loss_name, optimizer="adamw")
        numpy_losses = [head.step(x, y, 0.01) for _ in range(3)]
        state, module, ort_losses = self.ort_steps(model, x, y, loss, 0.01, 3)
        np.testing.assert_allclose(numpy_losses, ort_losses, rtol=1e-4)
        np.testing.assert_allclose(head.w, np.asarray(state.parameters["w_head"].data), atol=1e-5)
        np.testing.assert_allclose(head.b, np.asarray(state.parameters["b_head"].data), atol=1e-5)

        # Weights written back are what the ORT session computes with.
        head.w += 0.5
        head.write_back(state)
        module.eval()
        expected = x @ head.w.T + head.b
        api, _ = _load_ort_training_api()
        with tempfile.TemporaryDirectory() as directory:
            exported = Path(directory) / "inference.onnx"
            module.export_model_for_inferencing(str(exported), ["out"])
            import onnxruntime as ort
            got = ort.InferenceSession(str(exported), providers=["CPUExecutionProvider"]).run(None, {"features": x})[0]
        np.testing.assert_allclose(got, expected, atol=1e-4)

    def test_cross_entropy_step_matches_ort(self):
        self.check(cross_entropy=True)

    def test_mse_step_matches_ort(self):
        self.check(cross_entropy=False)

    def test_only_a_final_dense_layer_qualifies(self):
        rng = np.random.default_rng(0)
        model = head_model(6, 4, rng)
        self.assertIsNone(find_head_layer(model, ("w_head",), "cross_entropy"))
        self.assertIsNone(find_head_layer(model, ("w_head", "b_head"), "binary"))
        model.graph.node.append(helper.make_node("Relu", ["out"], ["relu"]))
        model.graph.output[0].name = "relu"
        self.assertIsNone(find_head_layer(model, ("w_head", "b_head"), "cross_entropy"))

    def test_features_are_what_reaches_the_head(self):
        rng = np.random.default_rng(1)
        w1 = rng.standard_normal((5, 3)).astype(np.float32)
        w2 = rng.standard_normal((2, 5)).astype(np.float32)
        graph = helper.make_graph(
            [helper.make_node("Gemm", ["input", "w_a"], ["hidden"], transB=1),
             helper.make_node("Relu", ["hidden"], ["act"]),
             helper.make_node("Gemm", ["act", "w_b"], ["out"], transB=1)],
            "two", [helper.make_tensor_value_info("input", TensorProto.FLOAT, ["n", 3])],
            [helper.make_tensor_value_info("out", TensorProto.FLOAT, ["n", 2])],
            [numpy_helper.from_array(w1, "w_a"), numpy_helper.from_array(w2, "w_b")])
        model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 15)], ir_version=8)
        layer = find_head_layer(model, ("w_b",), "cross_entropy")
        self.assertEqual(layer.feature_tensor, "act")
        x = rng.standard_normal((700, 3)).astype(np.float32)
        dataset = ArrayDataset("toy", x, np.zeros(700, dtype=np.int64))
        changed = {"w_a": w1 * 2.0}  # current weights, not the initial ones
        features = compute_features(model, changed, dataset, layer, batch_size=256)
        np.testing.assert_allclose(features, np.maximum(x @ (w1 * 2.0).T, 0.0), atol=1e-5)


if __name__ == "__main__":
    unittest.main()
