from __future__ import annotations

import argparse
import json
import os
import secrets
import socket
import sys
import threading
import time
import traceback
from pathlib import Path
from typing import Any, Callable, Dict

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
    __package__ = "neuralese_local"

from . import TRAINING_WORKER_PROTOCOL_VERSION
from .prepared_training import PreparedSession, StalePreparedSessionError
from .stop_flag import StopFlag
from .train_protocol import (
    AuthenticationError,
    FrameDecoder,
    ProtocolError,
    ReplayError,
    encode_frame,
    validate_command,
)
from .training_artifact_cache import ArtifactCache
from .training_dataset_cache import TrainingDatasetCache
from .training_profile import profile_dict


class WorkerCancellation:
    def __init__(self) -> None:
        self._event = threading.Event()
        self._callbacks: list[Callable[[], None]] = []
        self._lock = threading.Lock()

    @property
    def closed(self) -> bool:
        return self._event.is_set()

    def on_kill(self, callback: Callable[[], None]) -> None:
        with self._lock:
            self._callbacks.append(callback)
            already_closed = self._event.is_set()
        if already_closed:
            callback()

    def request(self) -> None:
        if self._event.is_set():
            return
        self._event.set()
        with self._lock:
            callbacks = list(self._callbacks)
        for callback in callbacks:
            callback()


class TrainingWorker:
    def __init__(
        self,
        runtime_root: str | Path,
        cache_root: str | Path,
        bootstrap_path: str | Path,
        parent_pid: int = 0,
        session_factory=PreparedSession,
    ) -> None:
        self.runtime_root = Path(runtime_root).resolve()
        self.cache_root = Path(cache_root).resolve()
        self.cache_root.mkdir(parents=True, exist_ok=True)
        self.bootstrap_path = Path(bootstrap_path).resolve()
        self.parent_pid = int(parent_pid)
        self.session_factory = session_factory
        self.token = secrets.token_hex(16)
        self.process_generation = secrets.token_hex(12)
        self.datasets = TrainingDatasetCache(self.runtime_root)
        self.artifacts = ArtifactCache(self.cache_root / "artifacts")
        self.prepared: PreparedSession | None = None
        self._shutdown = threading.Event()
        self._server: socket.socket | None = None
        self._connection: socket.socket | None = None
        self._send_lock = threading.Lock()
        self._state_lock = threading.Lock()
        self._last_request_id = -1
        self._response_cache: Dict[int, Dict[str, Any]] = {}
        self._active_thread: threading.Thread | None = None
        self._active_cancel: WorkerCancellation | None = None
        self._active_request_id: int | None = None
        self._last_batch_sent = 0.0

    def warm(self) -> Dict[str, Any]:
        # Force the heavy imports before publishing bootstrap readiness.
        from .train_task import _load_ort_training_api

        started = time.perf_counter()
        _load_ort_training_api()
        import onnxruntime as ort

        from .training_capabilities import probe_capabilities

        capabilities = probe_capabilities(
            self.cache_root / "training_capabilities.json"
        )
        builtins = self.datasets.warm_builtins()
        return {
            "builtins": sorted(builtins),
            "training_threads": 1,
            "training_artifact_format": capabilities.artifact_format,
            "warm_ms": (time.perf_counter() - started) * 1000.0,
        }

    def serve_forever(self) -> int:
        warm_data = self.warm()
        server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self._server = server
        server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        server.bind(("127.0.0.1", 0))
        server.listen(1)
        server.settimeout(0.2)
        port = int(server.getsockname()[1])
        self._write_bootstrap(port, warm_data)
        watchdog = threading.Thread(target=self._watch_parent, name="training-parent-watchdog", daemon=True)
        watchdog.start()

        try:
            while not self._shutdown.is_set():
                try:
                    connection, _ = server.accept()
                except socket.timeout:
                    continue
                except OSError:
                    break
                self._connection = connection
                connection.settimeout(0.2)
                self._serve_connection(connection)
                try:
                    connection.close()
                except OSError:
                    pass
                self._connection = None
        finally:
            self._shutdown.set()
            if self._active_cancel is not None:
                self._active_cancel.request()
            if self._active_thread is not None:
                self._active_thread.join(timeout=2.0)
            try:
                server.close()
            except OSError:
                pass
            try:
                self.bootstrap_path.unlink()
            except FileNotFoundError:
                pass
        return 0

    def _serve_connection(self, connection: socket.socket) -> None:
        decoder = FrameDecoder()
        while not self._shutdown.is_set():
            try:
                data = connection.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                break
            if not data:
                break
            try:
                packets = decoder.feed(data)
            except ProtocolError as exc:
                self._send({
                    "request_id": -1,
                    "event": "ERROR",
                    "error": {"code": "protocol_error", "message": str(exc)},
                })
                break
            for packet in packets:
                self._handle_packet(packet)

    def _handle_packet(self, packet: Dict[str, Any]) -> None:
        request_id = packet.get("request_id")
        if (
            isinstance(request_id, int)
            and not isinstance(request_id, bool)
            and request_id in self._response_cache
            and isinstance(packet.get("token"), str)
            and secrets.compare_digest(packet["token"], self.token)
        ):
            self._send(self._response_cache[request_id])
            return
        try:
            accepted_id = validate_command(packet, self.token, self._last_request_id)
            self._last_request_id = accepted_id
            self._dispatch(accepted_id, packet["command"].strip().upper(), packet.get("payload") or {})
        except AuthenticationError as exc:
            self._send_error(request_id, "authentication_failed", str(exc), cache=False)
        except ReplayError as exc:
            self._send_error(request_id, "request_replayed", str(exc), cache=False)
        except ProtocolError as exc:
            self._send_error(request_id, "protocol_error", str(exc), cache=False)
        except StalePreparedSessionError as exc:
            self._send_error(request_id, "stale_generation", str(exc))
        except Exception as exc:
            traceback.print_exc()
            self._send_error(request_id, "worker_command_failed", str(exc))

    def _dispatch(self, request_id: int, command: str, payload: Dict[str, Any]) -> None:
        if command == "PING":
            self._respond(request_id, "PONG", self._status_data())
            return
        if command == "STATUS":
            self._respond(request_id, "STATUS", self._status_data())
            return
        if command == "PREPARE":
            self._prepare(request_id, payload)
            return
        if command == "START":
            self._start(request_id, payload)
            return
        if command == "STOP":
            if self._active_cancel is not None:
                self._active_cancel.request()
            self._respond(request_id, "ACK", {"command": "STOP"})
            return
        if command == "SAVE":
            self._save(request_id, payload)
            return
        if command == "EVICT":
            self._require_idle()
            self.prepared = None
            self.datasets.clear_users()
            self._respond(request_id, "ACK", {"command": "EVICT"})
            return
        if command == "SHUTDOWN":
            if self._active_cancel is not None:
                self._active_cancel.request()
            self._respond(request_id, "ACK", {"command": "SHUTDOWN"})
            self._shutdown.set()
            return
        raise ValueError(f"unknown worker command '{command}'")

    def _prepare(self, request_id: int, payload: Dict[str, Any]) -> None:
        self._require_idle()
        request = payload.get("request")
        if not isinstance(request, dict):
            raise ValueError("PREPARE requires payload.request")
        request = dict(request)
        request.setdefault("runtime_root", str(self.runtime_root))
        self.prepared = self.session_factory.prepare(request, self.datasets, self.artifacts)
        self._respond(request_id, "PREPARED", {
            "prepared_id": self.prepared.prepared_id,
            "graph_generation": self.prepared.generation,
            "artifact_cache_hit": self.prepared.cache_hit,
            "dataset": self.prepared.dataset.name,
            "session_profile": profile_dict(self.prepared.session_profile),
        })

    def _start(self, request_id: int, payload: Dict[str, Any]) -> None:
        self._require_idle()
        if self.prepared is None:
            raise ValueError("no prepared session")
        if payload.get("prepared_id") != self.prepared.prepared_id:
            raise StalePreparedSessionError("prepared session id does not match")
        generation = int(payload.get("graph_generation", -1))
        if generation != self.prepared.generation:
            raise StalePreparedSessionError(
                f"prepared generation {self.prepared.generation} cannot run generation {generation}"
            )
        run_config = payload.get("run_config") or {}
        if not isinstance(run_config, dict):
            raise ValueError("START run_config must be a dictionary")
        run_config = dict(run_config)
        run_config["graph_generation"] = generation
        run_config["path_class"] = "hot"
        cancellation = WorkerCancellation()
        self._active_cancel = cancellation
        self._active_request_id = request_id
        self._respond(request_id, "ACK", {"command": "START", "prepared_id": self.prepared.prepared_id})

        thread = threading.Thread(
            target=self._run_training,
            args=(request_id, run_config, cancellation),
            name="prepared-training",
            daemon=True,
        )
        self._active_thread = thread
        thread.start()

    def _run_training(
        self,
        request_id: int,
        run_config: Dict[str, Any],
        cancellation: WorkerCancellation,
    ) -> None:
        try:
            self.prepared.start(
                run_config,
                lambda packet: self._emit_progress(request_id, packet),
                cancellation,
            )
        except Exception as exc:
            traceback.print_exc()
            self._send_error(request_id, "training_failed", str(exc), cache=False)
        finally:
            with self._state_lock:
                self._active_cancel = None
                self._active_thread = None
                self._active_request_id = None

    def _emit_progress(self, request_id: int, packet: Dict[str, Any]) -> None:
        stage = packet.get("data", {}).get("stage") if isinstance(packet.get("data"), dict) else None
        if packet.get("phase") == "progress" and stage == "batch":
            now = time.monotonic()
            data = packet.get("data") or {}
            final_batch = int(data.get("batch", 0)) == int(data.get("batches", -1))
            if not final_batch and now - self._last_batch_sent < 0.1:
                return
            self._last_batch_sent = now
        self._send({"request_id": request_id, "event": "PROGRESS", "data": packet})

    def _save(self, request_id: int, payload: Dict[str, Any]) -> None:
        self._require_idle()
        if self.prepared is None:
            raise ValueError("no prepared session")
        checkpoint_dir = Path(str(payload.get("checkpoint_dir") or ""))
        if not str(checkpoint_dir):
            raise ValueError("SAVE requires checkpoint_dir")
        checkpoint_dir.mkdir(parents=True, exist_ok=True)
        from .train_task import _save_required_checkpoint

        saved = _save_required_checkpoint(
            self.prepared.ort_train_api, self.prepared.state, checkpoint_dir
        )
        self._respond(request_id, "SAVED", {"checkpoint": str(saved)})

    def _require_idle(self) -> None:
        if self._active_thread is not None and self._active_thread.is_alive():
            raise RuntimeError("training worker is busy")

    def _status_data(self) -> Dict[str, Any]:
        return {
            "pid": os.getpid(),
            "process_generation": self.process_generation,
            "prepared_id": self.prepared.prepared_id if self.prepared is not None else "",
            "graph_generation": self.prepared.generation if self.prepared is not None else -1,
            "training": self._active_thread is not None and self._active_thread.is_alive(),
        }

    def _respond(self, request_id: int, event: str, data: Dict[str, Any]) -> None:
        response = {"request_id": request_id, "event": event, "data": data}
        self._response_cache[request_id] = response
        if len(self._response_cache) > 256:
            oldest = min(self._response_cache)
            self._response_cache.pop(oldest, None)
        self._send(response)

    def _send_error(
        self,
        request_id: Any,
        code: str,
        message: str,
        cache: bool = True,
    ) -> None:
        response = {
            "request_id": request_id if isinstance(request_id, int) else -1,
            "event": "ERROR",
            "error": {"code": code, "message": message},
        }
        if cache and isinstance(request_id, int):
            self._response_cache[request_id] = response
        self._send(response)

    def _send(self, packet: Dict[str, Any]) -> None:
        connection = self._connection
        if connection is None:
            return
        payload = encode_frame(packet)
        with self._send_lock:
            try:
                connection.sendall(payload)
            except OSError:
                pass

    def _write_bootstrap(self, port: int, warm_data: Dict[str, Any]) -> None:
        self.bootstrap_path.parent.mkdir(parents=True, exist_ok=True)
        data = {
            "port": port,
            "token": self.token,
            "pid": os.getpid(),
            "process_generation": self.process_generation,
            "protocol_version": TRAINING_WORKER_PROTOCOL_VERSION,
            **warm_data,
        }
        temporary = self.bootstrap_path.with_name(
            f"{self.bootstrap_path.name}.tmp.{os.getpid()}"
        )
        with temporary.open("w", encoding="utf-8") as handle:
            json.dump(data, handle, sort_keys=True)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, self.bootstrap_path)

    def _watch_parent(self) -> None:
        if self.parent_pid <= 0:
            return
        flag = StopFlag(self.cache_root / ".parent-watchdog-unused", self.parent_pid)
        while not self._shutdown.wait(1.0):
            if flag._parent_dead():
                if self._active_cancel is not None:
                    self._active_cancel.request()
                self._shutdown.set()
                if self._server is not None:
                    try:
                        self._server.close()
                    except OSError:
                        pass
                return


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--bootstrap", required=True)
    parser.add_argument("--runtime-root", required=True)
    parser.add_argument("--cache-root", required=True)
    parser.add_argument("--parent-pid", type=int, default=0)
    args = parser.parse_args(argv)
    worker = TrainingWorker(
        runtime_root=args.runtime_root,
        cache_root=args.cache_root,
        bootstrap_path=args.bootstrap,
        parent_pid=args.parent_pid,
    )
    return worker.serve_forever()


if __name__ == "__main__":
    raise SystemExit(main())
