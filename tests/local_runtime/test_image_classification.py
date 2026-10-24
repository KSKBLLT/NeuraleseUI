"""Colour image inputs, the shipped picture datasets (built by
local_runtime/tools/build_builtin_datasets.py), and datasets of the child's own
pictures reaching training (after Berdibek's image classification work on the
omario branch)."""
from __future__ import annotations

import gzip
import hashlib
import json
import struct
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np
import onnx
import onnxruntime as ort

from neuralese_local.dataset_store import load_builtin_dataset
from neuralese_local.image_datasets import _download, materialize, read_cifar_batch, read_idx
from neuralese_local.onnx_compiler import build_onnx_model_from_graph
from neuralese_local.train_task import run_training


class _StopToken:
    closed = False

    def on_kill(self, callback):
        self.callback = callback


def picture_graph(rows: int, columns: int, channels: int, classes: int) -> dict:
    return {
        "nodes": {
            "input": {"type": "InputNode", "data": {"rows": rows, "columns": columns, "channels": channels}},
            "flatten": {"type": "Flatten", "data": {}},
            "output": {"type": "NeuronLayer", "data": {"units": classes, "activation": "none"}},
        },
        "connections": [
            {"from_node": "input", "from_port": "input_out", "to_node": "flatten", "to_port": "layer_in"},
            {"from_node": "flatten", "from_port": "layer_out", "to_node": "output", "to_port": "layer_in"},
        ],
    }


class ImageClassificationTests(unittest.TestCase):
    def test_grey_input_shape_and_invalid_channels(self):
        graph = {"nodes": {"input": {"type": "InputNode", "data": {"rows": 28, "columns": 28}}}, "connections": []}
        model, _ = build_onnx_model_from_graph(graph)
        shape = model.graph.input[0].type.tensor_type.shape.dim
        self.assertEqual([dimension.dim_value for dimension in shape[1:]], [1, 28, 28])
        graph["nodes"]["input"]["data"]["channels"] = 2
        with self.assertRaisesRegex(ValueError, "channels"):
            build_onnx_model_from_graph(graph)

    def test_colour_rectangular_input_runs_through_conv_pool_flatten(self):
        graph = {
            "nodes": {
                "input": {"type": "InputNode", "data": {"rows": 12, "columns": 16, "channels": 3}},
                "conv": {"type": "NeuronLayer", "data": {"type": "conv2d", "filters": 4, "window": 3}},
                "pool": {"type": "NeuronLayer", "data": {"type": "maxpool2d", "group": 2}},
                "flat": {"type": "Flatten", "data": {}},
            },
            "connections": [
                {"from_node": "input", "from_port": "input_out", "to_node": "conv", "to_port": "layer_in"},
                {"from_node": "conv", "from_port": "layer_out", "to_node": "pool", "to_port": "layer_in"},
                {"from_node": "pool", "from_port": "layer_out", "to_node": "flat", "to_port": "layer_in"},
            ],
        }
        model, _ = build_onnx_model_from_graph(graph)
        onnx.checker.check_model(model)
        session = ort.InferenceSession(model.SerializeToString(), providers=["CPUExecutionProvider"])
        self.assertEqual(session.get_inputs()[0].shape, ["batch_size", 3, 12, 16])
        result = session.run(None, {"input": np.ones((1, 3, 12, 16), dtype=np.float32)})[0]
        self.assertEqual(result.shape, (1, 4 * 6 * 8))

    def test_idx_keeps_bytes_and_rejects_truncated_data(self):
        blob = gzip.compress(struct.pack(">IIII", 2051, 1, 2, 3) + bytes(range(6)))
        images = read_idx(blob, True)
        self.assertEqual(images.shape, (1, 1, 2, 3))
        self.assertEqual(images.dtype, np.uint8)
        with self.assertRaises(ValueError):
            read_idx(gzip.compress(struct.pack(">IIII", 2051, 1, 2, 3)), True)

    def test_cifar_keeps_channel_order(self):
        record = bytes([7]) + bytes([10]) * 1024 + bytes([20]) * 1024 + bytes([30]) * 1024
        images, labels = read_cifar_batch(record)
        self.assertEqual(images.shape, (1, 3, 32, 32))
        self.assertEqual(labels.tolist(), [7])
        self.assertEqual(images[0, :, 0, 0].tolist(), [10, 20, 30])
        with self.assertRaises(ValueError):
            read_cifar_batch(record[:-1])

    def test_shipped_byte_pictures_stay_bytes_and_train_as_zero_to_one(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root) / "datasets" / "cifar10"
            base.mkdir(parents=True)
            np.savez_compressed(base / "train.npz", x=np.full((4, 3, 32, 32), 255, dtype=np.uint8), y=[0, 1, 2, 3],
                                val_x=np.full((2, 3, 32, 32), 51, dtype=np.uint8), val_y=[0, 1])
            dataset = load_builtin_dataset(root, "cifar10")
            # Bytes in memory: 184 MB for CIFAR-10 rather than 737 MB of float32.
            self.assertEqual(dataset.x.dtype, np.uint8)
            batch_x, _ = dataset.batch_indices(np.array([0, 1]))
            self.assertEqual(batch_x.dtype, np.float32)
            self.assertEqual(float(batch_x.max()), 1.0)
            val_x, _ = dataset.validation_arrays()
            self.assertEqual(val_x.dtype, np.float32)
            self.assertAlmostEqual(float(val_x.max()), 0.2, places=5)

    def test_build_download_keeps_bytes_and_is_read_once(self):
        images = gzip.compress(struct.pack(">IIII", 2051, 1, 2, 2) + bytes([0, 64, 128, 255]))
        labels = gzip.compress(struct.pack(">II", 2049, 1) + bytes([2]))
        with tempfile.TemporaryDirectory() as root:
            with patch("neuralese_local.image_datasets._download", side_effect=[images, labels, images, labels]) as download:
                materialize("fashion_mnist", Path(root))
                materialize("fashion_mnist", Path(root))
                self.assertEqual(download.call_count, 4)
            with np.load(Path(root) / "train.npz", allow_pickle=False) as arrays:
                self.assertEqual(arrays["x"].dtype, np.uint8)
                self.assertEqual(arrays["val_y"].tolist(), [2])
            self.assertEqual([p.name for p in Path(root).iterdir()], ["train.npz"])

    def test_checksum_mismatch_is_refused(self):
        with patch("urllib.request.urlopen") as response:
            response.return_value.__enter__.return_value.read.return_value = b"corrupt"
            with self.assertRaisesRegex(ValueError, "checksum"):
                _download("https://example.invalid/data", hashlib.md5(b"correct").hexdigest(), 100)


class OwnPicturesTrainingTests(unittest.TestCase):
    """A dataset made in the Datasets tab sends each picture as one row of
    pixels; a model with a picture input must still train on it."""

    def setUp(self):
        self.directory = tempfile.TemporaryDirectory(prefix="neuralese_pictures_")
        self.addCleanup(self.directory.cleanup)
        self.root = Path(self.directory.name)

    def test_rows_of_pixels_train_a_picture_model(self):
        rng = np.random.default_rng(1)
        light = rng.uniform(0.6, 1.0, size=(20, 3 * 4))
        dark = rng.uniform(0.0, 0.3, size=(20, 3 * 4))
        path = self.root / "pets.json"
        path.write_text(json.dumps({
            "x": np.concatenate([light, dark]).tolist(),
            "y": [[0]] * 20 + [[1]] * 20,
        }))
        events = []
        result = run_training(
            {
                "graph": picture_graph(rows=3, columns=4, channels=1, classes=2),
                "train_graph": {"pages": {"0": {
                    "train": {"type": "TrainInput", "props": {"config": {"optimizer": "adam", "lr": 0.01}}},
                }}},
                "epochs": 2,
                "batch_size": 8,
                "runtime_root": str(self.root),
                "job_dir": str(self.root / "job"),
                "checkpoint_dir": str(self.root / "checkpoint"),
                "dataset_ref": {"kind": "godot_json", "name": "pets", "path": str(path)},
            },
            events.append,
            _StopToken(),
        )
        self.assertEqual(result["status"], "ok", result)
        session = ort.InferenceSession(str(self.root / "checkpoint" / "inference.onnx"), providers=["CPUExecutionProvider"])
        self.assertEqual(session.get_inputs()[0].shape[1:], [1, 3, 4])


if __name__ == "__main__":
    unittest.main()
