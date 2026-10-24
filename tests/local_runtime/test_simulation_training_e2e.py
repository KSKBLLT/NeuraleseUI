from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

import numpy as np
import onnxruntime as ort

from neuralese_local.dataset_store import load_builtin_dataset
from neuralese_local.train_task import run_training


class _StopToken:
    closed = False

    def on_kill(self, callback) -> None:
        self._callback = callback


def _graph() -> dict:
    return {
        "nodes": {
            "input": {"type": "InputNode", "data": {"shape": 8}},
            "dense_1": {
                "type": "NeuronLayer",
                "data": {"type": "dense", "units": 32, "activation": "relu"},
            },
            "dense_2": {
                "type": "NeuronLayer",
                "data": {"type": "dense", "units": 16, "activation": "relu"},
            },
            "output": {
                "type": "NeuronLayer",
                "data": {"type": "dense", "units": 2, "activation": "none"},
            },
        },
        "connections": [
            {"from_node": "input", "from_port": "input_out", "to_node": "dense_1", "to_port": "layer_in"},
            {"from_node": "dense_1", "from_port": "layer_out", "to_node": "dense_2", "to_port": "layer_in"},
            {"from_node": "dense_2", "from_port": "layer_out", "to_node": "output", "to_port": "layer_in"},
        ],
    }


def _train_graph() -> dict:
    return {
        "pages": {
            "0": {
                "run": {
                    "type": "RunModel",
                    "props": {"config": {"branch_losses": {"control": "mse"}}},
                },
                "train": {
                    "type": "TrainInput",
                    "props": {"config": {"optimizer": "adam", "lr": 0.001}},
                },
            }
        }
    }


class SimulationTrainingE2ETests(unittest.TestCase):
    def test_dataset_train_checkpoint_inference_beats_constant_baseline(self) -> None:
        runtime_root = Path(__file__).resolve().parents[2] / "local_runtime"
        events: list[dict] = []
        with tempfile.TemporaryDirectory(prefix="neuralese_sim_e2e_") as directory:
            root = Path(directory)
            result = run_training(
                {
                    "graph": _graph(),
                    "train_graph": _train_graph(),
                    "epochs": 12,
                    "batch_size": 128,
                    "runtime_root": str(runtime_root),
                    "job_dir": str(root / "job"),
                    "checkpoint_dir": str(root / "checkpoint"),
                    "dataset_ref": {"kind": "builtin_numpy", "name": "car_track"},
                    "context": "simulation-e2e",
                },
                events.append,
                _StopToken(),
            )

            checkpoint_dir = root / "checkpoint"
            inference_path = checkpoint_dir / "inference.onnx"
            manifest_path = checkpoint_dir / "manifest.json"
            checkpoint_path = checkpoint_dir / "checkpoint"
            self.assertEqual(result.get("status"), "ok", result)
            self.assertTrue(inference_path.is_file())
            self.assertTrue(manifest_path.is_file())
            self.assertTrue(checkpoint_path.is_file())
            self.assertEqual(events[-1].get("phase"), "done")

            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            self.assertEqual(manifest.get("dataset"), "car_track")
            self.assertEqual(manifest.get("loss"), "mse")

            dataset = load_builtin_dataset(runtime_root, "car_track")
            x_eval, y_eval = dataset.validation_arrays()
            session = ort.InferenceSession(str(inference_path), providers=["CPUExecutionProvider"])
            prediction = session.run(None, {session.get_inputs()[0].name: x_eval})[0]
            model_mae = float(np.mean(np.abs(prediction - y_eval)))
            constant = np.mean(dataset.y, axis=0, keepdims=True)
            baseline_mae = float(np.mean(np.abs(constant - y_eval)))
            self.assertLess(
                model_mae,
                baseline_mae * 0.9,
                f"trained model MAE {model_mae:.5f} must beat baseline {baseline_mae:.5f}",
            )


if __name__ == "__main__":
    unittest.main()
