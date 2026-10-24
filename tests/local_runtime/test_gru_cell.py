from __future__ import annotations

import json
import unittest
import tempfile
from pathlib import Path

import numpy as np
import onnx
import onnxruntime as ort

from neuralese_local.onnx_compiler import build_onnx_model_from_graph
from neuralese_local.onnx_node_handlers import MAX_GRU_HIDDEN_SIZE, MAX_GRU_SEQUENCE_LENGTH
from neuralese_local.train_task import _load_ort_training_api, _loss_type, _optimizer_type, run_training


class _StopToken:
    closed = False

    def on_kill(self, callback) -> None:
        self.callback = callback


def _graph(hidden_size: int = 7, shape: int = 5) -> dict:
    return {
        "nodes": {
            "input": {"type": "InputNode", "data": {"shape": shape}},
            "gru": {"type": "GRUCell", "data": {"hidden_size": hidden_size}},
        },
        "connections": [
            {
                "from_node": "input",
                "from_port": "input_out",
                "to_node": "gru",
                "to_port": "layer_in",
            }
        ],
    }


class GRUCellCompilerTests(unittest.TestCase):
    def test_gru_cell_compiles_and_runs_with_layer_shape(self) -> None:
        model, trainable = build_onnx_model_from_graph(_graph())
        onnx.checker.check_model(model)

        op_types = [node.op_type for node in model.graph.node]
        self.assertIn("Split", op_types)
        self.assertIn("Sigmoid", op_types)
        self.assertIn("Tanh", op_types)
        self.assertNotIn("GRU", op_types)
        self.assertEqual(len(trainable), 6)
        self.assertLessEqual(len(model.graph.node), 14 * 5 + 10)

        session = ort.InferenceSession(model.SerializeToString(), providers=["CPUExecutionProvider"])
        values = np.arange(15, dtype=np.float32).reshape(3, 5) / 10.0
        output = session.run(None, {"input": values})[0]
        self.assertEqual(output.shape, (3, 7))
        self.assertTrue(np.isfinite(output).all())

        changed_early_step = values.copy()
        changed_early_step[:, 0] += 2.0
        changed_output = session.run(None, {"input": changed_early_step})[0]
        self.assertFalse(np.allclose(output, changed_output))

    def test_gru_cell_rejects_non_positive_hidden_size(self) -> None:
        with self.assertRaisesRegex(ValueError, "hidden_size >= 1"):
            build_onnx_model_from_graph(_graph(hidden_size=0))

    def test_gru_cell_rejects_sequences_too_large_for_local_training(self) -> None:
        with self.assertRaisesRegex(ValueError, f"at most {MAX_GRU_SEQUENCE_LENGTH} steps"):
            build_onnx_model_from_graph(_graph(shape=MAX_GRU_SEQUENCE_LENGTH + 1))

    def test_gru_cell_rejects_memory_too_large_for_local_training(self) -> None:
        with self.assertRaisesRegex(ValueError, f"at most {MAX_GRU_HIDDEN_SIZE}"):
            build_onnx_model_from_graph(_graph(hidden_size=MAX_GRU_HIDDEN_SIZE + 1))

    def test_gru_weights_are_supported_by_training_artifact_generation(self) -> None:
        model, trainable = build_onnx_model_from_graph(_graph())
        _, artifacts = _load_ort_training_api()
        with tempfile.TemporaryDirectory(prefix="neuralese_gru_artifacts_") as directory:
            artifacts.generate_artifacts(
                model,
                requires_grad=trainable,
                loss=_loss_type("mse"),
                optimizer=_optimizer_type("adam"),
                artifact_directory=directory,
            )
            root = Path(directory)
            self.assertTrue((root / "training_model.onnx").is_file())
            self.assertTrue((root / "eval_model.onnx").is_file())
            self.assertTrue((root / "optimizer_model.onnx").is_file())

    def test_gru_cell_completes_a_local_training_epoch(self) -> None:
        with tempfile.TemporaryDirectory(prefix="neuralese_gru_training_") as directory:
            root = Path(directory)
            rng = np.random.default_rng(23)
            values = rng.normal(size=(16, 5)).astype(np.float32)
            targets = np.stack((values[:, 0] + values[:, 1], values[:, -1]), axis=1)
            dataset_path = root / "dataset.json"
            dataset_path.write_text(
                json.dumps({"name": "gru-smoke", "x": values.tolist(), "y": targets.tolist()}),
                encoding="utf-8",
            )
            train_graph = {
                "pages": {
                    "0": {
                        "run": {
                            "type": "RunModel",
                            "props": {"config": {"branch_losses": {"output": "mse"}}},
                        },
                        "train": {
                            "type": "TrainInput",
                            "props": {"config": {"optimizer": "adam", "lr": 0.001}},
                        },
                    }
                }
            }
            events = []
            result = run_training(
                {
                    "graph": _graph(hidden_size=2),
                    "train_graph": train_graph,
                    "epochs": 1,
                    "batch_size": 8,
                    "runtime_root": str(Path(__file__).resolve().parents[2] / "local_runtime"),
                    "job_dir": str(root / "job"),
                    "checkpoint_dir": str(root / "checkpoint"),
                    "dataset_ref": {"kind": "godot_json", "path": str(dataset_path)},
                },
                events.append,
                _StopToken(),
            )
            self.assertEqual(result.get("status"), "ok", result)
            self.assertTrue((root / "checkpoint" / "inference.onnx").is_file())
            self.assertTrue((root / "checkpoint" / "checkpoint").is_file())
            progress = [event["data"] for event in events if event.get("phase") == "progress"]
            stages = [data.get("stage") for data in progress]
            for stage in (
                "loading_dataset",
                "dataset_ready",
                "building_model",
                "model_ready",
                "preparing_training",
                "training_ready",
                "epoch_start",
                "batch",
            ):
                self.assertIn(stage, stages)
            batches = [data for data in progress if data.get("stage") == "batch"]
            self.assertEqual([data["batch"] for data in batches], [1, 2])

    def test_gru_training_loss_decreases(self) -> None:
        with tempfile.TemporaryDirectory(prefix="neuralese_gru_convergence_") as directory:
            root = Path(directory)
            rng = np.random.default_rng(81)
            values = rng.uniform(-0.25, 0.25, size=(64, 5)).astype(np.float32)
            targets = np.stack((values[:, 0] + values[:, 1], values[:, -1]), axis=1)
            dataset_path = root / "dataset.json"
            dataset_path.write_text(
                json.dumps({"name": "gru-convergence", "x": values.tolist(), "y": targets.tolist()}),
                encoding="utf-8",
            )
            train_graph = {
                "pages": {
                    "0": {
                        "run": {
                            "type": "RunModel",
                            "props": {"config": {"branch_losses": {"output": "mse"}}},
                        },
                        "train": {
                            "type": "TrainInput",
                            "props": {"config": {"optimizer": "adam", "lr": 0.01}},
                        },
                    }
                }
            }
            events = []
            np.random.seed(81)
            result = run_training(
                {
                    "graph": _graph(hidden_size=2),
                    "train_graph": train_graph,
                    "epochs": 20,
                    "batch_size": 16,
                    "runtime_root": str(Path(__file__).resolve().parents[2] / "local_runtime"),
                    "job_dir": str(root / "job"),
                    "checkpoint_dir": str(root / "checkpoint"),
                    "dataset_ref": {"kind": "godot_json", "path": str(dataset_path)},
                },
                events.append,
                _StopToken(),
            )
            self.assertEqual(result.get("status"), "ok", result)
            losses = [
                event["data"]["data"]["train_loss"]
                for event in events
                if event.get("phase") == "state"
            ]
            self.assertEqual(len(losses), 20)
            self.assertLess(losses[-1], losses[0] * 0.7, losses)


if __name__ == "__main__":
    unittest.main()
