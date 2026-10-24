from __future__ import annotations

import json
import os
import sys
import time
import traceback
from pathlib import Path
from typing import Any, Dict

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from neuralese_local.infer_once import _extract_raw_values, _find_final_node_id, _shape_input
from neuralese_local.runtime_errors import error_payload
from neuralese_local.stop_flag import StopFlag


POLL_INTERVAL_S = 0.01
IDLE_TIMEOUT_S = 60 * 30
REPLACE_RETRIES = 20
REPLACE_RETRY_SLEEP_S = 0.005


def main() -> int:
    if len(sys.argv) != 2:
        print("Usage: infer_loop.py <job_dir>", file=sys.stderr)
        return 2

    job_dir = Path(sys.argv[1]).resolve()
    control_path = job_dir / "control.json"
    request_path = job_dir / "request.json"
    response_path = job_dir / "response.json"
    stop_path = job_dir / "stop"

    try:
        import onnxruntime as ort

        control = _read_json(control_path)
        if control.get("model_kind")=="language":
            from neuralese_local.language.engine import LanguageEngine
            session=LanguageEngine(control.get("model_path") or None)
            input_info=None
        else:
            session = ort.InferenceSession(str(control["model_path"]), providers=["CPUExecutionProvider"])
            input_info = session.get_inputs()[0]
    except Exception as exc:
        traceback.print_exc()
        _write_json_atomic(response_path, {
            "phase": "error",
            "ok": False,
            "index": 0,
            "error": error_payload(exc, "inference"),
            "result": {},
        })
        return 1

    graph = control.get("graph", {}) or {}
    output_node_id = str(control.get("output_node_id") or _find_final_node_id(graph))
    stop = StopFlag(stop_path, parent_pid=control.get("parent_pid"))
    last_seq = -1
    last_activity = time.monotonic()

    _write_json_atomic(response_path, {"phase": "ready", "ok": True, "index": last_seq})

    while not stop.closed:
        if time.monotonic() - last_activity > float(control.get("idle_timeout_s", IDLE_TIMEOUT_S)):
            break
        request = _try_read_json(request_path)
        if not request:
            time.sleep(POLL_INTERVAL_S)
            continue

        seq = int(request.get("seq", request.get("index", 0)))
        if seq <= last_seq:
            time.sleep(POLL_INTERVAL_S)
            continue

        last_activity = time.monotonic()
        if "graph" in request:
            graph = request.get("graph", {}) or graph
            output_node_id = str(request.get("output_node_id") or _find_final_node_id(graph))
        else:
            output_node_id = str(request.get("output_node_id") or output_node_id)

        if control.get("model_kind")=="language":
            response=session.handle(request.get("data",{}))
            if response.get("ok"):
                from neuralese_local.language.wire import compact_snapshot
                response['result']=compact_snapshot(response['result'])
            packet={"phase":"inference","ok":True,"index":seq,"response":response}
        else:
            packet = _run_inference(session, input_info, graph, output_node_id, request, seq)
        _write_json_atomic(response_path, packet)
        last_seq = seq

    _write_json_atomic(response_path, {"phase": "closed", "ok": True, "index": last_seq})
    return 0


def _run_inference(session, input_info, graph: Dict[str, Any], output_node_id: str, request: Dict[str, Any], seq: int) -> Dict[str, Any]:
    try:
        effective_request = dict(request)
        effective_request.setdefault("graph", graph)
        raw_values = _extract_raw_values(effective_request)
        input_array = _shape_input(raw_values, input_info.shape)
        preds = session.run(None, {input_info.name: input_array})[0]
        return {
            "phase": "inference",
            "ok": True,
            "index": seq,
            "result": {
                str(output_node_id): {
                    "model_out": [preds.tolist()]
                }
            },
        }
    except Exception as exc:
        return {
            "phase": "error",
            "ok": False,
            "index": seq,
            "error": error_payload(exc, "inference"),
            "result": {},
        }


def _read_json(path: Path) -> Dict[str, Any]:
    return json.loads(path.read_text(encoding="utf-8-sig"))


def _try_read_json(path: Path) -> Dict[str, Any] | None:
    if not path.exists():
        return None
    try:
        return _read_json(path)
    except Exception:
        return None


def _write_json_atomic(path: Path, payload: Dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp_path = path.with_name(f"{path.name}.tmp.{os.getpid()}.{time.monotonic_ns()}")
    tmp_path.write_text(json.dumps(payload), encoding="utf-8")
    last_exc: Exception | None = None
    for _ in range(REPLACE_RETRIES):
        try:
            os.replace(tmp_path, path)
            return
        except PermissionError as exc:
            last_exc = exc
            time.sleep(REPLACE_RETRY_SLEEP_S)
    try:
        tmp_path.unlink(missing_ok=True)
    finally:
        if last_exc is not None:
            raise last_exc


if __name__ == "__main__":
    raise SystemExit(main())
