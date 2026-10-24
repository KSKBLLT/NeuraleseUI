from __future__ import annotations

import tempfile
import unittest
import os
import json
from pathlib import Path

import numpy as np
import onnxruntime as ort

from neuralese_local.dataset_store import load_builtin_dataset
from neuralese_local.runtime_errors import UserFacingRuntimeError
from neuralese_local.train_task import run_training


class _StopToken:
    closed = False

    def on_kill(self, callback):
        self.callback = callback


def classification_graph(inputs: int, outputs: int) -> dict:
    return {
        "nodes": {
            "input": {"type": "InputNode", "data": {"shape": inputs}},
            "hidden": {"type": "NeuronLayer", "data": {"units": 16, "activation": "relu"}},
            "output": {"type": "NeuronLayer", "data": {"units": outputs, "activation": "none"}},
        },
        "connections": [
            {"from_node": "input", "from_port": "input_out", "to_node": "hidden", "to_port": "layer_in"},
            {"from_node": "hidden", "from_port": "layer_out", "to_node": "output", "to_port": "layer_in"},
        ],
    }


class ClassificationTrainingE2ETests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="neuralese_classification_")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)
        self.runtime = Path(os.environ.get("NEURALESE_TEST_RUNTIME_ROOT", Path(__file__).resolve().parents[2] / "local_runtime"))
        self.events = []

    def train(self, name, outputs, inputs=4, runtime=None, graph=None, dataset_ref=None):
        return run_training(
            {
                "graph": graph or classification_graph(inputs, outputs),
                "train_graph": {"pages": {"0": {
                    "train": {"type": "TrainInput", "props": {"config": {"optimizer": "adam", "lr": 0.001}}},
                }}},
                "epochs": 2,
                "batch_size": 128,
                "runtime_root": str(runtime or self.runtime),
                "job_dir": str(self.root / "job"),
                "checkpoint_dir": str(self.root / "checkpoint"),
                "dataset_ref": dataset_ref or {"kind": "builtin_numpy", "name": name},
            },
            self.events.append,
            _StopToken(),
        )

    def test_eco_ai_rejects_flower_classifier_before_training(self):
        with self.assertRaisesRegex(UserFacingRuntimeError, r"eco_ai.*4.*3") as raised:
            self.train("eco_ai", outputs=3)
        self.assertEqual(raised.exception.code, "training_output_count_mismatch")
        self.assertEqual(raised.exception.details, {"dataset": "eco_ai", "expected": 4, "actual": 3})
        self.assertFalse(any(e.get("data", {}).get("stage") == "training_ready" for e in self.events))
        self.assertFalse((self.root / "checkpoint" / "checkpoint").exists())

    def test_eco_ai_trains_and_exports_four_class_model(self):
        result = self.train("eco_ai", outputs=4)
        self.assertEqual(result["status"], "ok")
        self.assertEqual(self.events[-1]["phase"], "done")
        checkpoint = self.root / "checkpoint"
        self.assertTrue((checkpoint / "checkpoint").is_file())
        session = ort.InferenceSession(str(checkpoint / "inference.onnx"), providers=["CPUExecutionProvider"])
        x, _ = load_builtin_dataset(self.runtime, "eco_ai").validation_arrays()
        prediction = session.run(None, {session.get_inputs()[0].name: x})[0]
        self.assertEqual(prediction.shape, (len(x), 4))
        self.assertTrue(np.isfinite(prediction).all())
        states = [e["data"]["data"] for e in self.events if e.get("phase") == "state"]
        self.assertEqual(len(states), 2)
        self.assertTrue(all(np.isfinite(s["train_loss"]) and np.isfinite(s["val_loss"]) for s in states))

    def test_class_present_only_in_validation_is_checked_before_training(self):
        target = self.root / "datasets" / "validation_only"
        target.mkdir(parents=True)
        np.savez(target / "train.npz", x=np.zeros((3, 4)), y=[0, 1, 2], val_x=np.zeros((1, 4)), val_y=[3])
        with self.assertRaisesRegex(ValueError, r"validation_only.*4.*3"):
            self.train("validation_only", outputs=3, runtime=self.root)
        self.assertFalse(any(e.get("data", {}).get("stage") == "training_ready" for e in self.events))

    def test_incorrect_input_size_is_reported_before_training(self):
        with self.assertRaisesRegex(ValueError, r"eco_ai.*input.*4.*5"):
            self.train("eco_ai", outputs=4, inputs=5)

    def test_negative_class_index_is_rejected(self):
        target = self.root / "datasets" / "negative"
        target.mkdir(parents=True)
        np.savez(target / "train.npz", x=np.zeros((2, 4)), y=[-1, 0])
        with self.assertRaisesRegex(ValueError, r"negative.*class indices"):
            self.train("negative", outputs=4, runtime=self.root)

    def test_custom_single_target_column_can_train_multiple_classes(self):
        path = self.root / "dataset.json"
        path.write_text(json.dumps({"x": [[0.1, 0.2], [0.4, 0.5], [0.7, 0.8]], "y": [[0], [1], [2]]}))
        result = self.train("custom", outputs=3, inputs=2,
                            dataset_ref={"kind": "godot_json", "name": "custom", "path": str(path)})
        self.assertEqual(result["status"], "ok", result)
        self.assertEqual(self.events[-1]["phase"], "done")

    def test_digits_image_input_trains_through_flatten(self):
        dataset = load_builtin_dataset(self.runtime, "mnist")
        target = self.root / "datasets" / "digits_smoke"
        target.mkdir(parents=True)
        vx, vy = dataset.validation_arrays()
        np.savez(target / "train.npz", x=dataset.x[:128], y=dataset.y[:128], val_x=vx[:32], val_y=vy[:32])
        graph = classification_graph(784, 10)
        graph["nodes"]["input"]["data"].update(rows=28, columns=28)
        graph["nodes"]["flatten"] = {"type": "Flatten", "data": {}}
        graph["connections"][0]["from_node"] = "flatten"
        graph["connections"][0]["from_port"] = "layer_out"
        graph["connections"].append({"from_node": "input", "from_port": "input_out", "to_node": "flatten", "to_port": "layer_in"})
        result = self.train("digits_smoke", outputs=10, runtime=self.root, graph=graph)
        self.assertEqual(result["status"], "ok", result)
        session = ort.InferenceSession(str(self.root / "checkpoint" / "inference.onnx"), providers=["CPUExecutionProvider"])
        prediction = session.run(None, {session.get_inputs()[0].name: vx[:32]})[0]
        self.assertEqual(prediction.shape, (32, 10))
        self.assertTrue(np.isfinite(prediction).all())


if __name__ == "__main__":
    unittest.main()
