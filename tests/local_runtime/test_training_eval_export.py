from __future__ import annotations

from pathlib import Path

import numpy as np

from neuralese_local.dataset_store import ArrayDataset
from neuralese_local.prepared_training import PreparedSession
from neuralese_local.training_artifact_cache import ArtifactCache
from neuralese_local.training_dataset_cache import TrainingDatasetCache
from neuralese_local import train_task


class NeverCancel:
    closed = False

    def on_kill(self, _callback):
        return


class RequestedCancel:
    def __init__(self):
        self.closed = False
        self._callbacks = []

    def on_kill(self, callback):
        self._callbacks.append(callback)

    def request(self):
        if self.closed:
            return
        self.closed = True
        for callback in self._callbacks:
            callback()


class FakeModule:
    def __init__(self):
        self.mode = "train"
        self.eval_calls = 0
        self.train_calls = 0

    def eval(self):
        self.mode = "eval"
        self.eval_calls += 1

    def train(self):
        self.mode = "train"
        self.train_calls += 1

    def __call__(self, x, _y):
        logits = np.stack((x[:, 0], -x[:, 0]), axis=1).astype(np.float32)
        return np.asarray(0.25, dtype=np.float32), logits


def _request(tmp_path: Path):
    runtime_root = Path(__file__).resolve().parents[2] / "local_runtime"
    return {
        "graph": {
            "nodes": {
                "input": {"type": "InputNode", "data": {"shape": 4}},
                "hidden": {"type": "NeuronLayer", "data": {"units": 5, "activation": "relu"}},
                "output": {"type": "NeuronLayer", "data": {"units": 3, "activation": "none"}},
            },
            "connections": [
                {"from_node": "input", "from_port": "input_out", "to_node": "hidden", "to_port": "layer_in"},
                {"from_node": "hidden", "from_port": "layer_out", "to_node": "output", "to_port": "layer_in"},
            ],
        },
        "graph_generation": 1,
        "train_graph": {"pages": {"0": {"train": {
            "type": "TrainInput",
            "props": {"config": {"optimizer": "adam", "loss": "cross_entropy", "lr": 0.001}},
        }}}},
        "epochs": 5,
        "batch_size": 128,
        "runtime_root": str(runtime_root),
        "job_dir": str(tmp_path / "job"),
        "checkpoint_dir": str(tmp_path / "checkpoint"),
        "dataset_ref": {"kind": "builtin_numpy", "name": "iris"},
        "initialization_seed": 5,
    }


def test_evaluate_module_restores_train_mode():
    module = FakeModule()
    x = np.asarray([[2.0], [-2.0], [1.0], [-1.0]], dtype=np.float32)
    y = np.asarray([0, 1, 0, 1], dtype=np.int64)
    dataset = ArrayDataset("fake", x, y)

    metrics = train_task.evaluate_module(module, dataset, "cross_entropy", batch_size=2)

    assert metrics["val_acc"] == 1.0
    assert module.eval_calls == 1
    assert module.train_calls == 1
    assert module.mode == "train"


def test_five_epochs_export_only_once(monkeypatch, tmp_path):
    request = _request(tmp_path)
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )
    real_export = train_task.export_model_from_state
    calls = []

    def counted_export(*args, **kwargs):
        calls.append(1)
        return real_export(*args, **kwargs)

    monkeypatch.setattr(train_task, "export_model_from_state", counted_export)
    monkeypatch.setattr(
        train_task,
        "_evaluate",
        lambda *_args, **_kwargs: (_ for _ in ()).throw(AssertionError("inference session used")),
    )

    result = prepared.start(
        {"graph_generation": 1, "epochs": 5, "seed": 5},
        lambda _packet: None,
        NeverCancel(),
    )

    assert result["status"] == "ok"
    assert len(calls) == 1
    assert (Path(result["checkpoint_dir"]) / "inference.onnx").is_file()


def test_stop_after_reported_metrics_publishes_inference_model(tmp_path):
    request = _request(tmp_path)
    request["epochs"] = 100
    prepared = PreparedSession.prepare(
        request,
        TrainingDatasetCache(request["runtime_root"]),
        ArtifactCache(tmp_path / "artifacts"),
    )
    cancel = RequestedCancel()
    events = []

    def emit(packet):
        events.append(packet)
        if packet.get("phase") == "state":
            cancel.request()

    result = prepared.start(
        {"graph_generation": 1, "epochs": 100, "seed": 5},
        emit,
        cancel,
    )

    checkpoint_dir = Path(request["checkpoint_dir"])
    assert any(packet.get("phase") == "state" for packet in events)
    assert result["status"] == "stopped"
    assert events[-1]["phase"] == "stopped"
    assert (checkpoint_dir / "inference.onnx").is_file()
    assert (checkpoint_dir / "checkpoint").is_file()
    assert (checkpoint_dir / "manifest.json").is_file()
