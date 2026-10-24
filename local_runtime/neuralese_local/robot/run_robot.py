"""Job-dir entry that runs a live robot link, for the Godot client to launch.

Mirrors ``infer_loop.py``: Godot creates a job directory, writes ``control.json``
into it, spawns this module, tails ``progress.jsonl`` for telemetry, and asks it
to quit by creating a ``stop`` file.

Crucially, Godot is *not* in the control loop. This process owns both the link
and the onnxruntime session, so the 20-50 Hz sensor-to-motor path never crosses a
process boundary. Godot only starts it, watches it, and stops it. The existing
``infer_loop.py`` polls a request file every 10 ms, which is fine for a child
pressing a button and is not fine for something with motors.

``control.json``::

    {
      "model_path": "C:/.../model.onnx",
      "config": { ...robot mapping config... },
      "parent_pid": 1234,
      "max_seconds": null
    }
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path
from typing import Any, Dict

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from neuralese_local.progress_jsonl import ProgressJsonl
from neuralese_local.robot.bridge import RobotBridge
from neuralese_local.robot.config import compile_config, config_hash
from neuralese_local.robot.errors import RobotError
from neuralese_local.robot.model_meta import OnnxEngine, read_model_meta
from neuralese_local.robot.transport import build_transport
from neuralese_local.stop_flag import StopFlag

#: How often the running link publishes a status line. Every frame would be
#: hundreds of lines a second for a UI that only needs to show a health light.
STATUS_INTERVAL_S = 0.5


def _write_json_atomic(path: Path, payload: Dict[str, Any]) -> None:
    tmp_path = path.with_name(path.name + ".tmp")
    tmp_path.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    tmp_path.replace(path)


def main(argv: list) -> int:
    if len(argv) != 2:
        print("usage: run_robot.py <job_dir>", file=sys.stderr)
        return 2

    job_dir = Path(argv[1]).resolve()
    job_dir.mkdir(parents=True, exist_ok=True)
    control_path = job_dir / "control.json"
    status_path = job_dir / "status.json"
    progress = ProgressJsonl(job_dir / "progress.jsonl")
    stop = StopFlag(job_dir / "stop", parent_pid=None)

    try:
        control = json.loads(control_path.read_text(encoding="utf-8-sig"))
    except Exception as exc:
        progress.emit({"phase": "error", "ok": False, "error": {"code": "bad_control", "message": str(exc)}})
        return 1

    stop.parent_pid = int(control.get("parent_pid") or 0)

    bridge = None
    try:
        config = control["config"]
        model_path = control["model_path"]
        meta = read_model_meta(model_path)
        plan = compile_config(config, meta)
        engine = OnnxEngine(model_path, meta)
        transport = build_transport(config)

        progress.emit({
            "phase": "starting",
            "ok": True,
            "platform": plan.platform.id,
            "config_hash": config_hash(config),
            "model": meta,
        })

        bridge = RobotBridge(
            plan,
            engine,
            transport,
            on_event=lambda payload: progress.emit({"phase": "link", "ok": True, **payload}),
            strict_config_hash=bool(control.get("strict_config_hash", True)),
        )
        bridge.start()

        max_seconds = control.get("max_seconds")
        started = time.monotonic()
        last_status = 0.0
        idle_sleep = min(0.005, 1.0 / max(1, plan.rate_hz) / 4.0)

        while not stop.closed:
            if max_seconds is not None and (time.monotonic() - started) >= float(max_seconds):
                break
            if bridge.state in ("error", "stopped"):
                break
            if not bridge.poll():
                time.sleep(idle_sleep)
            now = time.monotonic()
            if now - last_status >= STATUS_INTERVAL_S:
                last_status = now
                _write_json_atomic(status_path, bridge.status())

    except RobotError as exc:
        progress.emit({"phase": "error", "ok": False, "error": exc.to_dict()})
        _write_json_atomic(status_path, {"state": "error", "error": exc.to_dict()})
        if bridge is not None:
            bridge.stop("error")
        return 1
    except Exception as exc:
        payload = {"code": "link_failed", "message": str(exc)}
        progress.emit({"phase": "error", "ok": False, "error": payload})
        _write_json_atomic(status_path, {"state": "error", "error": payload})
        if bridge is not None:
            bridge.stop("error")
        return 1

    # Whatever ended the loop -- a stop file, a dead parent, a time limit -- the
    # robot is brought to a stop before this process exits.
    bridge.stop("shutdown")
    status = bridge.status()
    _write_json_atomic(status_path, status)
    progress.emit({"phase": "closed", "ok": bridge.error is None, **status})
    return 0 if bridge.error is None else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
