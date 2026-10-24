"""One robot session: find, pair, connect, inspect, drive -- a process Godot keeps open.

The job-dir pattern of ``infer_loop.py`` and ``run_robot.py``: Godot creates a
job directory, spawns ``robot_session.py <job_dir>``, and then

* writes ``request.json`` = ``{"seq": n, "command": ..., "args": {...}}`` with a
  growing ``seq``; each request is handled once;
* reads ``response.json`` = ``{"seq": n, "ok": ..., "result" | "error"}`` (the
  same packet is also appended to ``progress.jsonl``, so none is lost);
* tails ``progress.jsonl`` for events: ``stage`` (connecting, pairing...),
  ``telemetry`` (every tick while driving, 20 per second), ``link_lost``, ``drive_stopped``;
* reads ``status.json`` for the current state at any time;
* creates ``estop`` to stop the motors at once (checked every loop turn, not
  queued behind a request), or ``stop`` to end the session. The session also
  ends when Godot's process dies (``parent_pid``).

The model runs in this process, next to the robot link, so Godot is never in
the 20 Hz control loop (see ``runtime.py``). Scanning and connecting take
seconds (the EV3 waits for the child to confirm pairing on the brick), so they
run on a worker thread while the loop keeps answering the emergency stop.

Commands
--------
``scan``        {"seconds"?}                 robots nearby: the Dummy, EV3s with real distance
``connect``     {"robot_id", "pin"?, "world"?, "seed"?}
``describe_model`` {"dataset_meta", ...}     what the model's neurons mean; may it run on a robot
``save_profile`` {"robot"}                   remember the robot's name and geometry
``save_mapping`` / ``load_mapping`` {"key", "mapping"}  remember what the child connected for a model
``inventory``   {}                           ask the robot what is plugged in where
``read``        {"channels"}                 current values, e.g. to show sensor bars
``beep``        {}
``spin_motor``  {"channel", "power"?, "seconds"?}   turn one wheel so the child sees which it is
``start``       {"model_path", "config", "max_seconds"?}
``stop``        {}                           stop driving, stay connected
``estop``       {}                           same as the ``estop`` file
``disconnect``  {}
``quit``        {}
"""

from __future__ import annotations

import json
import os
import sys
import threading
import time
import traceback
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from neuralese_local.progress_jsonl import ProgressJsonl
from neuralese_local.robot import bluetooth as bt
from neuralese_local.robot import profiles as profiles_mod
from neuralese_local.robot.config import compile_config, validate_config
from neuralese_local.robot.drivers.dummy import DummyDriver
from neuralese_local.robot.drivers.ev3_direct import Ev3DirectDriver, Ev3Error
from neuralese_local.robot.errors import RobotError
from neuralese_local.robot.ir import Geometry
from neuralese_local.robot.model_contract import describe_model
from neuralese_local.robot.model_meta import read_model_meta
from neuralese_local.robot.runtime import MIN_SLEEP_S, TICK_S, DataLog, DriveLoop, hold_motor, live_robot
from neuralese_local.stop_flag import StopFlag

POLL_S = 0.01                 # how often requests and the estop file are checked
STATUS_INTERVAL_S = 0.5

STATE_IDLE = "idle"           # no robot connected
STATE_SCANNING = "scanning"
STATE_CONNECTING = "connecting"
STATE_CONNECTED = "connected"
STATE_DRIVING = "driving"

LONG_COMMANDS = ("scan", "connect")
#: Answered even while a long command runs.
ALWAYS_COMMANDS = ("estop", "stop", "quit")


class SessionError(Exception):
    def __init__(self, code: str, message: str) -> None:
        super().__init__(message)
        self.code = code
        self.message = message


def error_payload(exc: BaseException) -> Dict[str, Any]:
    """Every failure in one shape: code, message, and child texts when there are some."""
    if isinstance(exc, Ev3Error):
        return exc.to_dict()
    if isinstance(exc, RobotError):
        return exc.to_dict()
    if isinstance(exc, SessionError):
        return {"code": exc.code, "message": exc.message}
    return {"code": "internal", "message": "%s: %s" % (type(exc).__name__, exc),
            "detail": traceback.format_exc(limit=5)}


def _write_json_atomic(path: Path, payload: Dict[str, Any]) -> None:
    tmp = path.with_name(path.name + ".tmp")
    tmp.write_text(json.dumps(payload, ensure_ascii=False, default=str), encoding="utf-8")
    for _ in range(20):
        try:
            tmp.replace(path)
            return
        except PermissionError:   # the reader has it open on Windows; try again
            time.sleep(0.005)
    tmp.replace(path)


def _read_json(path: Path) -> Optional[Dict[str, Any]]:
    try:
        data = json.loads(path.read_text(encoding="utf-8-sig"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _default_engine(model_path: str, meta: Dict[str, Any]):
    from neuralese_local.robot.model_meta import OnnxEngine

    return OnnxEngine(model_path, meta)


def _default_meta(model_path: str) -> Dict[str, Any]:
    from neuralese_local.robot.model_meta import read_model_meta

    return read_model_meta(model_path)


class RobotSession:
    """Everything one session does, independent of files (so tests drive it directly)."""

    def __init__(
        self,
        *,
        emit: Callable[[Dict[str, Any]], None],
        logs_dir: Optional[Path] = None,
        profiles_dir: Optional[str] = None,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        discover: Callable[..., List[bt.FoundRobot]] = bt.discover_ev3,
        connect_ev3: Callable[..., bt.ConnectResult] = bt.connect_ev3,
        model_meta: Callable[[str], Dict[str, Any]] = _default_meta,
        engine_factory: Callable[[str, Dict[str, Any]], Any] = _default_engine,
    ) -> None:
        self.emit = emit
        self.logs_dir = logs_dir
        self.profiles_dir = profiles_dir
        self.clock = clock
        self.sleep = sleep
        self.discover = discover
        self.connect_ev3 = connect_ev3
        self.model_meta = model_meta
        self.engine_factory = engine_factory

        self.state = STATE_IDLE
        self.driver: Any = None
        self.robot: Optional[Dict[str, Any]] = None
        self.found: Dict[str, bt.FoundRobot] = {}
        self.loop: Optional[DriveLoop] = None
        self.loop_deadline: Optional[float] = None
        self.next_tick = 0.0
        self.last_error: Optional[Dict[str, Any]] = None
        self.quit_requested = False
        self._worker: Optional[threading.Thread] = None
        self._worker_result: Optional[Dict[str, Any]] = None

    # -- status ---------------------------------------------------------------------

    def status(self) -> Dict[str, Any]:
        return {
            "state": self.state,
            "busy": self.busy,
            "robot": self.robot,
            "last_error": self.last_error,
            "driving": self.loop is not None and self.loop.running,
            "step": self.loop.step if self.loop else 0,
        }

    @property
    def busy(self) -> bool:
        return self._worker is not None and self._worker.is_alive()

    # -- requests ---------------------------------------------------------------------

    def handle(self, request: Dict[str, Any]) -> Optional[Dict[str, Any]]:
        """Answer a request now, or start it on the worker (returns None; see :meth:`poll_worker`)."""
        seq = request.get("seq")
        command = str(request.get("command", ""))
        args = request.get("args") or {}
        if self.busy and command not in ALWAYS_COMMANDS:
            return self._response(seq, command, error=SessionError("busy", "Still busy with the previous step."))
        method = getattr(self, "cmd_" + command, None)
        if method is None:
            return self._response(seq, command, error=SessionError("unknown_command", "Unknown command '%s'." % command))
        if command in LONG_COMMANDS:
            self._start_worker(seq, command, args)
            return None
        try:
            return self._response(seq, command, result=method(args))
        except BaseException as exc:  # noqa: BLE001 -- every failure becomes a response
            return self._response(seq, command, error=exc)

    def _response(self, seq: Any, command: str, *, result: Any = None, error: Optional[BaseException] = None) -> Dict[str, Any]:
        packet: Dict[str, Any] = {"event": "response", "seq": seq, "command": command, "ok": error is None}
        if error is None:
            packet["result"] = result if result is not None else {}
        else:
            packet["error"] = error_payload(error)
            self.last_error = packet["error"]
        return packet

    def _start_worker(self, seq: Any, command: str, args: Dict[str, Any]) -> None:
        self.state = STATE_SCANNING if command == "scan" else STATE_CONNECTING
        self._worker_result = None

        def work() -> None:
            try:
                result = getattr(self, "cmd_" + command)(args)
                self._worker_result = self._response(seq, command, result=result)
            except BaseException as exc:  # noqa: BLE001
                self._worker_result = self._response(seq, command, error=exc)

        self._worker = threading.Thread(target=work, name="robot-session-%s" % command, daemon=True)
        self._worker.start()

    def poll_worker(self) -> Optional[Dict[str, Any]]:
        """The long command's response once it has finished."""
        if self._worker is None or self._worker.is_alive():
            return None
        self._worker = None
        packet = self._worker_result
        if self.state in (STATE_SCANNING, STATE_CONNECTING):
            self.state = STATE_CONNECTED if self.driver is not None else STATE_IDLE
        return packet

    # -- commands -----------------------------------------------------------------------

    def _with_profile(self, robot: Dict[str, Any]) -> Dict[str, Any]:
        if not self.profiles_dir:
            return robot
        return profiles_mod.apply_profile(robot, profiles_mod.load_profile(self.profiles_dir, robot["robot_id"]))

    def cmd_scan(self, args: Dict[str, Any]) -> Dict[str, Any]:
        robots = [self._with_profile(DummyDriver().inventory().to_dict())]
        error = None
        try:
            found = self.discover(seconds=float(args.get("seconds", bt.SCAN_SECONDS)))
        except Ev3Error as exc:   # no helper: the Dummy is still there
            found, error = [], exc.to_dict()
        self.found = {robot.robot_id: robot for robot in found}
        for robot in found:
            ir = Ev3DirectDriver(robot.com_port, mac=robot.mac, name=robot.name,
                                 proximity={"rssi_dbm": robot.rssi_dbm, "distance_m": robot.distance_m}).inventory().to_dict()
            ir.update(paired=robot.paired, heard=robot.heard, last_used=robot.last_used)
            robots.append(self._with_profile(ir))
        return {"robots": robots, "scan_error": error}

    def cmd_connect(self, args: Dict[str, Any]) -> Dict[str, Any]:
        if self.driver is not None:
            raise SessionError("already_connected", "A robot is already connected; disconnect it first.")
        robot_id = str(args.get("robot_id", ""))
        if robot_id.startswith("dummy:"):
            spec = {"kind": "virtual", "seed": int(args.get("seed", 0))}
            if args.get("world"):
                spec["world"] = args["world"]
            driver = DummyDriver.from_spec(spec, None)
            driver.robot_id = robot_id
            driver.open(self.clock())
        elif robot_id.startswith("ev3:"):
            found = self.found.get(robot_id)
            if found is None:
                # Not scanned in this session: a paired robot is still reachable by its COM port.
                mac = bt.normalize_mac(robot_id[4:])
                com = bt.lego_com_ports().get(mac, "")
                found = bt.FoundRobot(mac, bt.registry_name(mac) or "EV3", paired=bool(com), com_port=com)
            result = self.connect_ev3(found, str(args.get("pin") or bt.DEFAULT_PIN),
                                      on_stage=lambda stage: self.emit({"event": "stage", "stage": stage}))
            driver = result.driver
        else:
            raise SessionError("unknown_robot", "Unknown robot '%s'." % robot_id)
        self.driver = driver
        self.robot = self._with_profile(driver.inventory().to_dict())
        return {"robot": self.robot, "warnings": list(getattr(getattr(driver, "link", None), "warnings", []) or [])}

    def _require_robot(self) -> Any:
        if self.driver is None:
            raise SessionError("not_connected", "No robot is connected.")
        return self.driver

    def _require_not_driving(self) -> None:
        if self.loop is not None and self.loop.running:
            raise SessionError("driving", "Stop the robot first.")

    def _require_profiles_dir(self) -> str:
        if not self.profiles_dir:
            raise SessionError("no_profiles_dir", "This session has nowhere to save robot settings.")
        return self.profiles_dir

    def cmd_save_profile(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Remember the connected robot's name and geometry for its next connection."""
        driver = self._require_robot()
        robot = dict(args.get("robot") or {})
        robot["robot_id"] = (self.robot or {}).get("robot_id", robot.get("robot_id", ""))
        robot["platform"] = (self.robot or {}).get("platform", robot.get("platform", ""))
        robot["ports"] = (self.robot or {}).get("ports", robot.get("ports", []))
        profile = profiles_mod.save_profile(self._require_profiles_dir(), robot)
        if hasattr(driver, "geometry"):
            driver.geometry = Geometry.from_dict(profile["geometry"])
        self.robot = self._with_profile(driver.inventory().to_dict())
        return {"profile": profile, "robot": self.robot}

    def cmd_save_mapping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        self._require_robot()
        robot_id = str((self.robot or {}).get("robot_id", ""))
        profile = profiles_mod.save_mapping(self._require_profiles_dir(), robot_id, str(args.get("key", "")),
                                            args.get("mapping") or {})
        return {"saved": True, "keys": sorted((profile.get("mappings") or {}).keys())}

    def cmd_load_mapping(self, args: Dict[str, Any]) -> Dict[str, Any]:
        self._require_robot()
        robot_id = str((self.robot or {}).get("robot_id", ""))
        mapping = profiles_mod.load_mapping(self._require_profiles_dir(), robot_id, str(args.get("key", "")))
        return {"mapping": mapping}

    def cmd_describe_model(self, args: Dict[str, Any]) -> Dict[str, Any]:
        """Meaning of the model's inputs and outputs and whether it may run on a robot.

        Needs no robot: the window asks as soon as it opens, from the dataset the
        model was trained on (see ``model_contract.py``).
        """
        return describe_model(
            args.get("dataset_meta"),
            input_width=args.get("input_width"),
            output_width=args.get("output_width"),
            model_ready=bool(args.get("model_ready", True)),
            model_widths=self._model_widths(args.get("model_path")),
        )

    @staticmethod
    def _model_widths(model_path: Any) -> Optional[Tuple[int, int]]:
        """The trained model file's input and output sizes, if it can be read."""
        if not model_path or not Path(str(model_path)).is_file():
            return None
        try:
            meta = read_model_meta(model_path)
        except RobotError:
            return None
        return int(meta.get("input_size", 0) or 0), int(meta.get("output_size", 0) or 0)

    def cmd_inventory(self, args: Dict[str, Any]) -> Dict[str, Any]:
        driver = self._require_robot()
        self._require_not_driving()
        if hasattr(driver, "refresh_ports"):
            driver.refresh_ports()
        self.robot = self._with_profile(driver.inventory().to_dict())
        return {"robot": self.robot}

    def cmd_read(self, args: Dict[str, Any]) -> Dict[str, Any]:
        driver = self._require_robot()
        self._require_not_driving()
        channels = [str(c) for c in args.get("channels") or []]
        return {"values": dict(zip(channels, driver.read(channels, self.clock())))}

    def cmd_beep(self, args: Dict[str, Any]) -> Dict[str, Any]:
        driver = self._require_robot()
        if hasattr(driver, "beep"):
            driver.beep(self.clock())
        return {}

    def cmd_spin_motor(self, args: Dict[str, Any]) -> Dict[str, Any]:
        driver = self._require_robot()
        self._require_not_driving()
        channel = str(args.get("channel", ""))
        if not channel.endswith(".power"):
            raise SessionError("bad_channel", "Only a motor's power can be spun.")
        position = channel.replace(".power", ".position_deg")

        def read_position() -> Optional[int]:
            try:
                return int(driver.read([position], self.clock())[0])
            except Exception:
                return None

        before = read_position()
        hold_motor(driver, channel, int(args.get("power", 35)), float(args.get("seconds", 1.0)),
                   clock=self.clock, sleep=self.sleep)
        self.sleep(0.3)   # let it coast to a stop before reading the encoder, as the prototype
        after = read_position()
        moved = None if before is None or after is None else after - before
        return {"channel": channel, "position_before": before, "position_after": after, "moved_deg": moved}

    def cmd_start(self, args: Dict[str, Any]) -> Dict[str, Any]:
        driver = self._require_robot()
        self._require_not_driving()
        model_path = str(args.get("model_path", ""))
        meta = self.model_meta(model_path)
        config = dict(args.get("config") or {})
        robot = live_robot(driver.inventory().to_dict(), config.get("robot"))
        config["platform"] = robot["platform"]
        config["robot"] = robot
        config["transport"] = {"kind": robot["transport"]}
        report = validate_config(config, meta)
        report.raise_if_failed()
        plan = compile_config(config, meta)
        engine = self.engine_factory(model_path, meta)
        datalog = None
        if self.logs_dir is not None:
            stamp = datetime.now().strftime("%Y%m%d_%H%M%S")
            datalog = DataLog(self.logs_dir / ("datalog_%s.jsonl" % stamp),
                              {"robot": robot, "config": config, "model_path": model_path, "model": meta})
        self.loop = DriveLoop(driver, plan, engine, clock=self.clock, datalog=datalog)
        self.loop.start()
        max_seconds = args.get("max_seconds")
        self.loop_deadline = None if max_seconds is None else self.clock() + float(max_seconds)
        self.next_tick = self.clock()
        self.state = STATE_DRIVING
        return {"datalog": str(datalog.path) if datalog else None, "warnings": report.warnings}

    def _end_drive(self, reason: str, error: Optional[BaseException] = None) -> Dict[str, Any]:
        loop, self.loop = self.loop, None
        steps = 0
        datalog = None
        if loop is not None:
            loop.halt()
            steps = loop.step
            datalog = str(loop.datalog.path) if loop.datalog else None
        if self.state == STATE_DRIVING:
            self.state = STATE_CONNECTED if self.driver is not None else STATE_IDLE
        event = {"event": "drive_stopped", "reason": reason, "steps": steps, "datalog": datalog}
        if error is not None:
            event["error"] = error_payload(error)
            self.last_error = event["error"]
        self.emit(event)
        return event

    def cmd_stop(self, args: Dict[str, Any]) -> Dict[str, Any]:
        if self.loop is None:
            if self.driver is not None:
                self.driver.stop(self.clock())
            return {"steps": 0}
        return self._end_drive("stop")

    def estop(self) -> None:
        """Motors off now, whatever is going on."""
        if self.loop is not None:
            self._end_drive("estop")
        if self.driver is not None:
            try:
                self.driver.stop(self.clock())
            except Exception:
                pass

    def cmd_estop(self, args: Dict[str, Any]) -> Dict[str, Any]:
        self.estop()
        return {}

    def cmd_disconnect(self, args: Dict[str, Any]) -> Dict[str, Any]:
        self.estop()
        driver, self.driver = self.driver, None
        self.robot = None
        if driver is not None:
            driver.close()
        self.state = STATE_IDLE
        return {}

    def cmd_quit(self, args: Dict[str, Any]) -> Dict[str, Any]:
        self.quit_requested = True
        return {}

    # -- the loop -----------------------------------------------------------------------

    def step(self) -> None:
        """One turn of the session loop: drive a tick when due, keep the link alive."""
        now = self.clock()
        if self.loop is not None and self.loop.running:
            if self.loop_deadline is not None and now >= self.loop_deadline:
                self._end_drive("time_limit")
                return
            if now + 1e-9 < self.next_tick:
                return
            try:
                record = self.loop.tick()
            except BaseException as exc:  # noqa: BLE001 -- motors already stopped by the loop
                self._end_drive("error", exc)
                self._after_link_failure(exc)
                return
            elapsed = self.clock() - now
            self.next_tick = self.clock() + max(MIN_SLEEP_S, TICK_S - elapsed)
            # Every tick: the window builds its map of the room from them.
            self.emit({"event": "telemetry", **record})
        elif self.driver is not None and not self.busy:
            try:
                self.driver.tick(now)   # heartbeat while connected and idle
            except BaseException as exc:  # noqa: BLE001
                self._after_link_failure(exc)

    def _after_link_failure(self, exc: BaseException) -> None:
        if isinstance(exc, Ev3Error) and exc.code == "LINK_LOST":
            self.emit({"event": "link_lost", "error": exc.to_dict()})
            self.last_error = exc.to_dict()
            driver, self.driver = self.driver, None
            self.robot = None
            self.state = STATE_IDLE
            try:
                driver.close()
            except Exception:
                pass

    def shutdown(self) -> None:
        """Whatever ended the session, the robot is stopped and released."""
        try:
            self.cmd_disconnect({})
        except Exception:
            pass


def main(argv: List[str]) -> int:
    if len(argv) != 2:
        print("usage: robot_session.py <job_dir>", file=sys.stderr)
        return 2
    job_dir = Path(argv[1]).resolve()
    job_dir.mkdir(parents=True, exist_ok=True)
    progress = ProgressJsonl(job_dir / "progress.jsonl")
    control = _read_json(job_dir / "control.json") or {}
    stop = StopFlag(job_dir / "stop", parent_pid=int(control.get("parent_pid") or 0))
    estop_path = job_dir / "estop"
    request_path = job_dir / "request.json"
    response_path = job_dir / "response.json"
    status_path = job_dir / "status.json"

    emit_lock = threading.Lock()

    def emit(packet: Dict[str, Any]) -> None:
        with emit_lock:   # the worker thread reports connection stages too
            progress.emit(packet)

    session = RobotSession(
        emit=emit,
        logs_dir=Path(control["logs_dir"]) if control.get("logs_dir") else job_dir / "datalogs",
        profiles_dir=control.get("profiles_dir"),
    )

    def answer(packet: Optional[Dict[str, Any]]) -> None:
        if packet is None:
            return
        _write_json_atomic(response_path, packet)
        emit(packet)

    last_seq = None
    last_status = 0.0
    emit({"event": "ready", "pid": os.getpid()})
    _write_json_atomic(status_path, session.status())
    try:
        while not stop.closed and not session.quit_requested:
            if estop_path.exists():
                session.estop()
                try:
                    estop_path.unlink()
                except OSError:
                    pass
                emit({"event": "estop"})
            request = _read_json(request_path)
            if request is not None and request.get("seq") != last_seq:
                last_seq = request.get("seq")
                answer(session.handle(request))
            answer(session.poll_worker())
            session.step()
            now = time.monotonic()
            if now - last_status >= STATUS_INTERVAL_S:
                last_status = now
                _write_json_atomic(status_path, session.status())
            time.sleep(POLL_S if not (session.loop and session.loop.running)
                       else max(0.0, min(POLL_S, session.next_tick - time.monotonic())))
    finally:
        session.shutdown()
        _write_json_atomic(status_path, dict(session.status(), state="closed"))
        emit({"event": "closed"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
