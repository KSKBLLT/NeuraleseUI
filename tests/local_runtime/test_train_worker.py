from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import onnxruntime as ort
import pytest

from neuralese_local.train_protocol import FrameDecoder, encode_frame
from neuralese_local.train_worker import TrainingWorker


RUNTIME_ROOT = Path(__file__).resolve().parents[2] / "local_runtime"


def _wait_for(predicate, timeout=10.0):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value:
            return value
        time.sleep(0.025)
    raise TimeoutError("worker did not become ready")


class WorkerClient:
    def __init__(self, bootstrap):
        self.token = bootstrap["token"]
        self.socket = socket.create_connection(("127.0.0.1", bootstrap["port"]), timeout=3)
        self.socket.settimeout(5)
        self.decoder = FrameDecoder()
        self.pending = []

    def send(self, request_id, command, payload=None, token=None):
        self.socket.sendall(encode_frame({
            "token": self.token if token is None else token,
            "request_id": request_id,
            "command": command,
            "payload": payload or {},
        }))

    def receive(self, predicate=lambda _packet: True, timeout=8.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, packet in enumerate(self.pending):
                if predicate(packet):
                    return self.pending.pop(index)
            data = self.socket.recv(65536)
            if not data:
                raise ConnectionError("worker closed the socket")
            self.pending.extend(self.decoder.feed(data))
        raise TimeoutError("expected worker packet was not received")

    def close(self):
        self.socket.close()


@pytest.fixture
def worker_process(tmp_path):
    bootstrap_path = tmp_path / "bootstrap.json"
    env = os.environ.copy()
    env["PYTHONPATH"] = str(RUNTIME_ROOT)
    process = subprocess.Popen(
        [
            sys.executable,
            str(RUNTIME_ROOT / "neuralese_local" / "train_worker.py"),
            "--bootstrap",
            str(bootstrap_path),
            "--runtime-root",
            str(RUNTIME_ROOT),
            "--cache-root",
            str(tmp_path / "cache"),
            "--parent-pid",
            str(os.getpid()),
        ],
        env=env,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )

    def read_bootstrap():
        if not bootstrap_path.is_file():
            return None
        try:
            return json.loads(bootstrap_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return None

    bootstrap = _wait_for(read_bootstrap, timeout=15)
    yield process, bootstrap, tmp_path
    if process.poll() is None:
        try:
            client = WorkerClient(bootstrap)
            client.send(999_999, "SHUTDOWN")
            client.close()
        except OSError:
            pass
        try:
            process.wait(timeout=5)
        except subprocess.TimeoutExpired:
            process.kill()


def test_worker_auth_ping_duplicate_and_shutdown(worker_process):
    process, bootstrap, _ = worker_process
    assert bootstrap["protocol_version"] == 1
    assert bootstrap["pid"] == process.pid
    client = WorkerClient(bootstrap)

    client.send(1, "PING", token="wrong")
    rejected = client.receive(lambda packet: packet.get("request_id") == 1)
    assert rejected["event"] == "ERROR"
    assert rejected["error"]["code"] == "authentication_failed"

    client.send(1, "PING")
    first = client.receive(lambda packet: packet.get("request_id") == 1 and packet.get("event") == "PONG")
    client.send(1, "PING")
    duplicate = client.receive(lambda packet: packet.get("request_id") == 1 and packet.get("event") == "PONG")
    assert duplicate == first

    client.send(2, "SHUTDOWN")
    assert client.receive(lambda packet: packet.get("request_id") == 2)["event"] == "ACK"
    client.close()
    assert process.wait(timeout=5) == 0


def test_worker_prepares_and_hot_starts_real_training(worker_process):
    _, bootstrap, tmp_path = worker_process
    client = WorkerClient(bootstrap)
    request = {
        "graph": {
            "nodes": {
                "input": {"type": "InputNode", "data": {"shape": 4}},
                "output": {"type": "NeuronLayer", "data": {"units": 3, "activation": "none"}},
            },
            "connections": [{
                "from_node": "input", "from_port": "input_out",
                "to_node": "output", "to_port": "layer_in",
            }],
        },
        "graph_generation": 7,
        "train_graph": {"pages": {"0": {
            "train": {"type": "TrainInput", "props": {"config": {"optimizer": "adam"}}},
        }}},
        "runtime_root": str(RUNTIME_ROOT),
        "job_dir": str(tmp_path / "job"),
        "checkpoint_dir": str(tmp_path / "checkpoint"),
        "dataset_ref": {"kind": "builtin_numpy", "name": "iris"},
        "initialization_seed": 5,
    }

    client.send(1, "PREPARE", {"request": request})
    prepared = client.receive(lambda packet: packet.get("request_id") == 1, timeout=10)
    assert prepared["event"] == "PREPARED", prepared
    prepared_id = prepared["data"]["prepared_id"]

    client.send(2, "START", {
        "prepared_id": prepared_id,
        "graph_generation": 6,
        "run_config": {"epochs": 1, "batch_size": 128},
    })
    stale = client.receive(lambda packet: packet.get("request_id") == 2)
    assert stale["event"] == "ERROR"
    assert stale["error"]["code"] == "stale_generation"

    client.send(3, "START", {
        "prepared_id": prepared_id,
        "graph_generation": 7,
        "run_config": {"epochs": 1, "batch_size": 128},
    })
    assert client.receive(lambda packet: packet.get("request_id") == 3)["event"] == "ACK"
    done = client.receive(
        lambda packet: packet.get("request_id") == 3 and packet.get("event") == "PROGRESS"
        and packet.get("data", {}).get("phase") == "done",
        timeout=10,
    )
    assert done["data"]["data"]["status"] == "ok"
    assert (tmp_path / "checkpoint" / "checkpoint").is_file()

    time.sleep(0.05)
    client.send(4, "STATUS")
    assert not client.receive(lambda packet: packet.get("request_id") == 4)["data"]["training"]
    client.send(5, "START", {
        "prepared_id": prepared_id,
        "graph_generation": 7,
        "run_config": {"epochs": 10_000, "batch_size": 1},
    })
    assert client.receive(lambda packet: packet.get("request_id") == 5)["event"] == "ACK"
    client.send(6, "STOP")
    assert client.receive(lambda packet: packet.get("request_id") == 6)["event"] == "ACK"
    stopped = client.receive(
        lambda packet: packet.get("request_id") == 5
        and packet.get("event") == "PROGRESS"
        and packet.get("data", {}).get("phase") == "stopped",
        timeout=5,
    )
    assert stopped["data"]["phase"] == "stopped"
    assert stopped["data"]["data"]["status"] == "stopped"
    inference_path = tmp_path / "checkpoint" / "inference.onnx"
    assert inference_path.is_file()
    assert (tmp_path / "checkpoint" / "checkpoint").is_file()
    assert (tmp_path / "checkpoint" / "manifest.json").is_file()
    inference = ort.InferenceSession(str(inference_path), providers=["CPUExecutionProvider"])
    output = inference.run(
        None,
        {inference.get_inputs()[0].name: np.zeros((1, 4), dtype=np.float32)},
    )[0]
    assert output.shape == (1, 3)
    assert np.isfinite(output).all()
    client.close()


def test_worker_defensive_throttle_never_drops_final_batch(monkeypatch, tmp_path):
    worker = TrainingWorker(tmp_path, tmp_path / "cache", tmp_path / "bootstrap.json")
    sent = []
    monkeypatch.setattr(worker, "_send", sent.append)
    moments = iter([10.0, 10.01, 10.02])
    monkeypatch.setattr("neuralese_local.train_worker.time.monotonic", lambda: next(moments))

    for batch in (1, 2, 3):
        worker._emit_progress(9, {
            "phase": "progress",
            "data": {"stage": "batch", "batch": batch, "batches": 3},
        })

    assert [packet["data"]["data"]["batch"] for packet in sent] == [1, 3]
