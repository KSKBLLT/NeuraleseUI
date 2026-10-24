"""A CIFAR-10 model built in the app trains the way the app trains it.

fixtures/cifar10_app_request.json is the training job the app made from the
model tests/godot/test_cifar10_model.gd builds the way Axon does (Input RGB ->
two convolutions with pooling -> Flatten -> Dense -> Dense -> Softmax ->
answers, on the builtin cifar10), less the canvas pixels and the scene's ids.
To train what the app makes right now, run that Godot test with
NEURALESE_CIFAR_REQUEST_OUT=<file> and point NEURALESE_CIFAR_REQUEST at it.

Training goes through the resident worker (neuralese_local/train_worker.py)
exactly as scripts/run_manager.gd drives it: PREPARE with the job, then START
with the run config. The real dataset is the shipped
local_runtime/datasets/cifar10 (local_runtime/tools/build_builtin_datasets.py
writes it); without it only the stand-in test runs.
"""
from __future__ import annotations

import json
import os
import socket
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

import numpy as np
import onnxruntime as ort

from neuralese_local.dataset_store import load_builtin_dataset
from neuralese_local.train_protocol import FrameDecoder, encode_frame

FIXTURE = Path(__file__).resolve().parent / "fixtures" / "cifar10_app_request.json"
RUNTIME_ROOT = Path(__file__).resolve().parents[2] / "local_runtime"


class _Worker:
    """The resident training worker as the app starts it, and its socket."""

    def __init__(self, runtime_root: Path, state: Path) -> None:
        bootstrap_path = state / "bootstrap.json"
        self.process = subprocess.Popen(
            [sys.executable, str(RUNTIME_ROOT / "neuralese_local" / "train_worker.py"),
             "--bootstrap", str(bootstrap_path), "--runtime-root", str(runtime_root),
             "--cache-root", str(state / "cache"), "--parent-pid", str(os.getpid())],
            stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
        )
        deadline = time.monotonic() + 120.0   # warming loads every builtin dataset
        bootstrap = None
        while bootstrap is None:
            if time.monotonic() > deadline or self.process.poll() is not None:
                raise TimeoutError("the training worker did not start")
            try:
                bootstrap = json.loads(bootstrap_path.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                time.sleep(0.05)
        self.builtins = bootstrap.get("builtins", [])
        self.token = bootstrap["token"]
        self.socket = socket.create_connection(("127.0.0.1", bootstrap["port"]), timeout=5)
        self.socket.settimeout(1.0)
        self.decoder = FrameDecoder()
        self.pending: list[dict] = []

    def send(self, request_id: int, command: str, payload: dict) -> None:
        self.socket.sendall(encode_frame({"token": self.token, "request_id": request_id,
                                          "command": command, "payload": payload}))

    def receive(self, wanted, timeout: float) -> dict:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            for index, packet in enumerate(self.pending):
                if wanted(packet):
                    return self.pending.pop(index)
            try:
                data = self.socket.recv(65536)
            except socket.timeout:
                continue
            if not data:
                raise ConnectionError("the training worker closed its socket")
            self.pending.extend(self.decoder.feed(data))
        raise TimeoutError("the training worker did not answer in time")

    def close(self) -> None:
        try:
            self.send(999_999, "SHUTDOWN", {})
            self.socket.close()
            self.process.wait(timeout=10)
        except (OSError, subprocess.TimeoutExpired):
            self.process.kill()


def train_like_the_app(test: unittest.TestCase, runtime_root: Path, state: Path, epochs: int,
                       timeout: float) -> tuple[float, float]:
    """PREPARE + START on the app's job; returns (accuracy on the test pictures, seconds)."""
    job = json.loads(Path(os.environ.get("NEURALESE_CIFAR_REQUEST", FIXTURE)).read_text(encoding="utf-8"))
    test.assertEqual(job["dataset_ref"], {"kind": "builtin_numpy", "name": "cifar10"})
    # _resident_prepare_request in scripts/run_manager.gd adds these.
    job.update({"runtime_root": str(runtime_root), "job_dir": str(state / "prepared"),
                "checkpoint_dir": str(state / "checkpoint"), "local_mode": "fullylocal_ort",
                "graph_generation": 1})
    worker = _Worker(runtime_root, state)
    try:
        test.assertIn("cifar10", worker.builtins)
        worker.send(1, "PREPARE", {"request": job})
        prepared = worker.receive(lambda packet: packet.get("request_id") == 1, timeout=300)
        test.assertEqual(prepared["event"], "PREPARED", prepared)
        # _start_resident_prepared: the same job plus where this run writes.
        run_config = dict(job, epochs=epochs, job_dir=str(state / "job"), graph_generation=1)
        started = time.monotonic()
        worker.send(2, "START", {"prepared_id": prepared["data"]["prepared_id"], "graph_generation": 1,
                                 "run_config": run_config})
        test.assertEqual(worker.receive(lambda packet: packet.get("request_id") == 2, timeout=30)["event"], "ACK")
        done = worker.receive(lambda packet: packet.get("request_id") == 2 and packet.get("event") == "PROGRESS"
                              and packet.get("data", {}).get("phase") in ("done", "error", "stopped"), timeout=timeout)
        seconds = time.monotonic() - started
        test.assertEqual(done["data"]["phase"], "done", done)
    finally:
        worker.close()

    session = ort.InferenceSession(str(state / "checkpoint" / "inference.onnx"), providers=["CPUExecutionProvider"])
    test.assertEqual(session.get_inputs()[0].shape[1:], [3, 32, 32])
    pictures, classes = load_builtin_dataset(runtime_root, "cifar10").validation_arrays()
    name = session.get_inputs()[0].name
    guesses = np.concatenate([
        np.argmax(session.run(None, {name: pictures[start:start + 500]})[0], axis=1)
        for start in range(0, len(pictures), 500)
    ])
    return float(np.mean(guesses == np.asarray(classes).reshape(-1))), seconds


class CifarShapedTrainingTests(unittest.TestCase):
    """Always runs: the same job on a small stand-in shipped the same way
    (bytes, channels first), ten classes told apart by their colour."""

    def test_app_built_model_trains_on_cifar_shaped_pictures(self):
        rng = np.random.default_rng(7)
        colours = rng.integers(0, 256, size=(10, 3))

        def pictures(count: int):
            classes = np.arange(count) % 10
            noise = rng.integers(-40, 41, size=(count, 3, 32, 32))
            return np.clip(colours[classes][:, :, None, None] + noise, 0, 255).astype(np.uint8), classes

        with tempfile.TemporaryDirectory(prefix="neuralese_cifar_shaped_") as directory:
            root = Path(directory)
            base = root / "runtime" / "datasets" / "cifar10"
            base.mkdir(parents=True)
            x, y = pictures(2000)
            val_x, val_y = pictures(200)
            np.savez_compressed(base / "train.npz", x=x, y=y, val_x=val_x, val_y=val_y)
            state = root / "state"
            state.mkdir()
            accuracy, seconds = train_like_the_app(self, root / "runtime", state, epochs=5, timeout=300)
        print(f"\nCIFAR-shaped stand-in through the worker: accuracy {accuracy:.1%} in {seconds:.1f} s")
        self.assertGreater(accuracy, 0.9)


@unittest.skipUnless((RUNTIME_ROOT / "datasets" / "cifar10" / "train.npz").exists(),
                     "local_runtime/datasets/cifar10 is not built (local_runtime/tools/build_builtin_datasets.py cifar10)")
class Cifar10TrainingTests(unittest.TestCase):
    def test_app_built_model_learns_cifar10(self):
        epochs = int(os.environ.get("NEURALESE_CIFAR_EPOCHS", "2"))
        with tempfile.TemporaryDirectory(prefix="neuralese_cifar10_") as directory:
            accuracy, seconds = train_like_the_app(self, RUNTIME_ROOT, Path(directory), epochs, timeout=3600)
        print(f"\nCIFAR-10 through the worker: {epochs} epochs in {seconds:.0f} s, accuracy {accuracy:.1%} "
              f"on the 10 000 test pictures (chance is 10%)")
        # Ten classes: guessing gets 10%. This model is near 56% after two epochs
        # at Adam 3e-3 (38% while convolutions trained with wrong gradients,
        # test_conv_gradients.py).
        self.assertGreater(accuracy, 0.45)
        # Old school computers, one thread: an epoch must stay short.
        limit = float(os.environ.get("NEURALESE_CIFAR_MAX_EPOCH_SECONDS", "10"))
        self.assertLess(seconds / epochs, limit)


if __name__ == "__main__":
    unittest.main()
