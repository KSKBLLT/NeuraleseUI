"""Convolutions train with correct gradients.

onnxruntime-training computes wrong weight gradients for Conv with
auto_pad=SAME_UPPER (the forward pass is right, the gradients are not, some
even of the wrong sign). Every image model in the app was compiled that way and
trained badly: CIFAR-10 stalled near 50% and fell apart after a few epochs.
The compiler now writes the same padding out as explicit pads; these tests keep
it that way and check the gradients the training session computes against
finite differences.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np
import onnxruntime as ort
from onnx import numpy_helper

from neuralese_local.onnx_compiler import build_onnx_model_from_graph
from neuralese_local.train_task import _load_ort_training_api


def conv_graph(rows: int, columns: int, window: int, stride: int, keep_size: bool = True) -> dict:
    return {
        "nodes": {
            "input": {"type": "InputNode", "data": {"rows": rows, "columns": columns, "channels": 3}},
            "conv": {"type": "NeuronLayer", "data": {"type": "conv2d", "filters": 4, "window": window,
                                                     "stride": stride, "keep_size": keep_size}},
        },
        "connections": [{"from_node": "input", "from_port": "input_out", "to_node": "conv", "to_port": "layer_in"}],
    }


def run(model, x):
    session = ort.InferenceSession(model.SerializeToString(), providers=["CPUExecutionProvider"])
    return session.run(None, {"input": x})[0]


def with_weight(model, name, value):
    changed = type(model)()
    changed.CopyFrom(model)
    for index, initializer in enumerate(changed.graph.initializer):
        if initializer.name == name:
            changed.graph.initializer[index].CopyFrom(numpy_helper.from_array(value.astype(np.float32), name))
    return changed


CASES = [(8, 8, 3, 1), (8, 8, 3, 2), (7, 9, 3, 2), (6, 6, 5, 1)]


class ConvPaddingTests(unittest.TestCase):
    def test_keep_size_is_explicit_padding_with_the_same_result(self):
        rng = np.random.default_rng(0)
        for rows, columns, window, stride in CASES:
            with self.subTest(rows=rows, columns=columns, window=window, stride=stride):
                model, _ = build_onnx_model_from_graph(conv_graph(rows, columns, window, stride))
                conv = next(node for node in model.graph.node if node.op_type == "Conv")
                attributes = {attribute.name for attribute in conv.attribute}
                self.assertNotIn("auto_pad", attributes)
                self.assertIn("pads", attributes)

                reference = type(model)()
                reference.CopyFrom(model)
                node = next(node for node in reference.graph.node if node.op_type == "Conv")
                kept = [a for a in node.attribute if a.name != "pads"]
                del node.attribute[:]
                node.attribute.extend(kept)
                from onnx import helper
                node.attribute.append(helper.make_attribute("auto_pad", "SAME_UPPER"))

                x = rng.standard_normal((2, 3, rows, columns)).astype(np.float32)
                out = run(model, x)
                self.assertEqual(out.shape[2:], (-(-rows // stride), -(-columns // stride)))
                np.testing.assert_allclose(out, run(reference, x), atol=1e-5)


class ConvGradientTests(unittest.TestCase):
    def test_training_gradients_match_finite_differences(self):
        api, artifacts = _load_ort_training_api()
        rng = np.random.default_rng(1)
        for rows, columns, window, stride in CASES:
            with self.subTest(rows=rows, columns=columns, window=window, stride=stride):
                np.random.seed(3)
                model, params = build_onnx_model_from_graph(conv_graph(rows, columns, window, stride))
                weight_name = next(name for name in params if name.startswith("w_"))
                weight = next(numpy_helper.to_array(i) for i in model.graph.initializer if i.name == weight_name)
                x = rng.standard_normal((2, 3, rows, columns)).astype(np.float32)
                target = rng.standard_normal(run(model, x).shape).astype(np.float32)

                with tempfile.TemporaryDirectory(prefix="neuralese_conv_grad_") as directory:
                    artifacts.generate_artifacts(model, requires_grad=list(params), loss=artifacts.LossType.MSELoss,
                                                 optimizer=artifacts.OptimType.AdamW, artifact_directory=directory)
                    state = api.CheckpointState.load_checkpoint(str(Path(directory) / "checkpoint"))
                    module = api.Module(str(Path(directory) / "training_model.onnx"), state,
                                        str(Path(directory) / "eval_model.onnx"))
                    module.train()
                    module.lazy_reset_grad()
                    module(x, target)
                    gradient = np.array(state.parameters[weight_name].grad, copy=True)

                def loss(value):
                    return float(np.mean((run(with_weight(model, weight_name, value), x) - target) ** 2))

                for index in [(0, 0, 0, 0), (1, 2, 1, 1), (3, 1, window - 1, 0), (2, 0, 0, window - 1)]:
                    plus, minus = weight.copy(), weight.copy()
                    plus[index] += 1e-3
                    minus[index] -= 1e-3
                    numeric = (loss(plus) - loss(minus)) / 2e-3
                    self.assertAlmostEqual(float(gradient[index]), numeric, delta=2e-3 + 0.02 * abs(numeric))


if __name__ == "__main__":
    unittest.main()
