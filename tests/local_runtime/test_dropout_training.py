"""A model with the app's Dropout node trains, drops while training and not
while answering.

The compiler emits Dropout in its answering form (no training_mode, one
output). ORT could not build its gradient (it needs the mask output), so any
model with a Dropout node failed to train; train_task.dropout_for_training
switches it on in the copy training artifacts are built from.
"""
from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort

from neuralese_local.onnx_compiler import build_onnx_model_from_graph
from neuralese_local.train_task import _load_ort_training_api, dropout_for_training, run_training

RUNTIME_ROOT = Path(__file__).resolve().parents[2] / "local_runtime"


def dropout_graph(features: int, classes: int) -> dict:
    return {
        "nodes": {
            "input": {"type": "InputNode", "data": {"shape": features}},
            "h": {"type": "NeuronLayer", "data": {"units": 32, "activation": "relu"}},
            "drop": {"type": "NeuronLayer", "data": {"type": "dropout", "p": 0.5}},
            "o": {"type": "NeuronLayer", "data": {"units": classes, "activation": "none"}},
        },
        "connections": [
            {"from_node": "input", "from_port": "input_out", "to_node": "h", "to_port": "layer_in"},
            {"from_node": "h", "from_port": "layer_out", "to_node": "drop", "to_port": "layer_in"},
            {"from_node": "drop", "from_port": "layer_out", "to_node": "o", "to_port": "layer_in"},
        ],
    }


class _Stop:
    closed = False

    def on_kill(self, callback):
        pass


class DropoutTrainingTests(unittest.TestCase):
    def test_dropout_is_active_in_the_training_graph(self):
        api, artifacts = _load_ort_training_api()
        model, params = build_onnx_model_from_graph(dropout_graph(20, 3), loss_name="cross_entropy")
        with tempfile.TemporaryDirectory() as directory:
            artifacts.generate_artifacts(dropout_for_training(model), requires_grad=list(params),
                                         loss=artifacts.LossType.CrossEntropyLoss,
                                         optimizer=artifacts.OptimType.AdamW, artifact_directory=directory)
            state = api.CheckpointState.load_checkpoint(str(Path(directory) / "checkpoint"))
            module = api.Module(str(Path(directory) / "training_model.onnx"), state,
                                str(Path(directory) / "eval_model.onnx"))
            module.train()
            rng = np.random.default_rng(0)
            x = rng.standard_normal((64, 20)).astype(np.float32)
            y = rng.integers(0, 3, 64).astype(np.int64)
            losses = set()
            for _ in range(3):
                module.lazy_reset_grad()
                losses.add(round(float(module(x, y)), 6))
        self.assertGreater(len(losses), 1, "the same weights gave the same loss: nothing was dropped")
        # The compiled (published) graph itself stays in answering form.
        dropout = next(node for node in model.graph.node if node.op_type == "Dropout")
        self.assertEqual(len(dropout.output), 1)
        self.assertLess(len([name for name in dropout.input if name]), 3)

    def test_a_model_with_dropout_trains_and_answers_the_same_twice(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            result = run_training({
                "graph": dropout_graph(4, 3),
                "train_graph": {"pages": {"0": {"t": {"type": "TrainInput",
                                                      "props": {"config": {"optimizer": "adam", "lr": "3e-3"}}}}}},
                "epochs": 3, "batch_size": 16, "runtime_root": str(RUNTIME_ROOT),
                "job_dir": str(root / "job"), "checkpoint_dir": str(root / "ck"),
                "dataset_ref": {"kind": "builtin_numpy", "name": "iris"},
            }, lambda event: None, _Stop())
            self.assertEqual(result["status"], "ok", result)
            published = onnx.load(str(root / "ck" / "inference.onnx"))
            self.assertNotIn("dropout_training_mode", {i.name for i in published.graph.initializer})
            session = ort.InferenceSession(str(root / "ck" / "inference.onnx"), providers=["CPUExecutionProvider"])
            x = np.random.default_rng(1).standard_normal((10, 4)).astype(np.float32)
            name = session.get_inputs()[0].name
            np.testing.assert_array_equal(session.run(None, {name: x})[0], session.run(None, {name: x})[0])


if __name__ == "__main__":
    unittest.main()
