"""The host-side control loop: link in, model in the middle, link out.

The loop deliberately lives on the host and not on the robot. None of these
three devices can run onnxruntime, and even if one could, putting the model on
the robot would mean reflashing it every time a child retrains. Here, the robot
runs one small script forever and the model is swapped freely.

The loop is written as a non-blocking :meth:`RobotBridge.poll` driven by an
injected clock, with :meth:`RobotBridge.run` as a thin wrapper. That is what
makes the safety behaviour -- watchdogs, stale frames, inference failures --
testable as ordinary deterministic unit tests instead of something you can only
observe by breaking a real robot.

Safety rules, in the order they matter:

1. **Loss of link stops the robot.** Both ends run a watchdog. The robot stops
   its motors if the host goes quiet; the host drives everything to its safe
   value if the robot goes quiet.
2. **Newest wins, nothing queues.** A frame that arrives out of order or late is
   dropped. Acting on a stale sensor reading is acting on a world that has moved.
3. **A failure never leaves motors running.** Inference errors, bad frames and
   shutdown all route through the same safe-state path.
"""

from __future__ import annotations

import time
from typing import Any, Callable, Dict, List, Optional

from . import codec
from .codec import LineReader
from .config import MappingPlan, config_hash
from .errors import (
    ERR_ARITY_MISMATCH,
    ERR_HANDSHAKE_FAILED,
    ERR_LINK_TIMEOUT,
    ERR_PROTOCOL_MISMATCH,
    LinkError,
    ProtocolError,
    RobotError,
)
from .model_meta import InferenceEngine
from .transport import Transport

STATE_IDLE = "idle"
STATE_WAITING = "waiting_for_robot"
STATE_RUNNING = "running"
STATE_STALLED = "stalled"
STATE_STOPPED = "stopped"
STATE_ERROR = "error"

#: Give up after this many inference failures in a row. One bad frame is a
#: glitch; twenty in a row is a broken model, and silently retrying forever
#: would leave the child watching a robot that never moves with nothing said.
MAX_CONSECUTIVE_INFERENCE_ERRORS = 20

#: How long the robot may go quiet before the host assumes the link is gone,
#: expressed as a multiple of the frame period.
LINK_TIMEOUT_FRAMES = 4


class RobotBridge:
    def __init__(
        self,
        plan: MappingPlan,
        engine: InferenceEngine,
        transport: Transport,
        *,
        clock: Callable[[], float] = time.monotonic,
        on_event: Optional[Callable[[Dict[str, Any]], None]] = None,
        expected_config_hash: str = "",
        link_timeout_s: Optional[float] = None,
        strict_config_hash: bool = True,
    ) -> None:
        self.plan = plan
        self.engine = engine
        self.transport = transport
        self.clock = clock
        self.on_event = on_event
        self.expected_config_hash = expected_config_hash or config_hash(plan.config)
        self.strict_config_hash = strict_config_hash

        frame_period = 1.0 / max(1, plan.rate_hz)
        if link_timeout_s is None:
            # Whichever is more forgiving: a few frame periods, or the watchdog
            # the device itself is using. Tripping the host watchdog earlier
            # than the robot's own would be pure stutter.
            link_timeout_s = max(frame_period * LINK_TIMEOUT_FRAMES, plan.watchdog_ms / 1000.0)
        self.link_timeout_s = float(link_timeout_s)

        self.state = STATE_IDLE
        self.error: Optional[Dict[str, Any]] = None
        self.robot_info: Dict[str, Any] = {}

        self._reader = LineReader()
        self._handshaken = False
        self._last_seq = -1
        self._last_frame_at = 0.0
        self._safe_sent = False
        self._consecutive_inference_errors = 0

        self.stats = {
            "frames_received": 0,
            "frames_answered": 0,
            "frames_stale": 0,
            "frames_corrupt": 0,
            "inference_errors": 0,
            "watchdog_trips": 0,
            "frames_before_handshake": 0,
            "last_latency_ms": 0.0,
        }
        self.last_inputs: List[float] = []
        self.last_outputs: List[float] = []
        self.last_actuators: List[int] = []

    # -- lifecycle -----------------------------------------------------------

    def start(self) -> None:
        self.transport.open()
        self.state = STATE_WAITING
        self._last_frame_at = self.clock()
        self._emit({
            "event": "link_open",
            "transport": self.transport.describe(),
            "platform": self.plan.platform.id,
            "expects": {"inputs": self.plan.input_count, "outputs": self.plan.output_count},
        })

    def stop(self, reason: str = "stopped") -> None:
        """Bring the robot to a stop and close the link, best effort.

        Every path out of this class goes through here, including failures, so
        there is exactly one place that guarantees the motors are told to stop.
        """
        try:
            if self.transport.is_open:
                self._send_safe_state()
                self.transport.write(codec.encode_stop())
        except Exception:
            # The link being already dead is the common case here; the robot's
            # own watchdog covers it, so there is nothing useful to report.
            pass
        finally:
            try:
                self.transport.close()
            except Exception:
                pass
            if self.state not in (STATE_ERROR,):
                self.state = STATE_STOPPED
            self._emit({"event": "link_closed", "reason": reason, "stats": dict(self.stats)})

    def __enter__(self) -> "RobotBridge":
        self.start()
        return self

    def __exit__(self, *exc: Any) -> None:
        self.stop()

    # -- the loop ------------------------------------------------------------

    def run(self, *, max_seconds: Optional[float] = None, should_stop: Optional[Callable[[], bool]] = None) -> Dict[str, Any]:
        """Drive :meth:`poll` until told to stop. Always stops the robot."""
        started = self.clock()
        idle_sleep = min(0.005, 1.0 / max(1, self.plan.rate_hz) / 4.0)
        try:
            while True:
                if should_stop is not None and should_stop():
                    break
                if max_seconds is not None and (self.clock() - started) >= max_seconds:
                    break
                if self.state in (STATE_ERROR, STATE_STOPPED):
                    break
                did_work = self.poll()
                if not did_work:
                    time.sleep(idle_sleep)
        finally:
            self.stop()
        return self.status()

    def poll(self) -> bool:
        """One non-blocking iteration. Returns whether anything was processed."""
        if self.state in (STATE_ERROR, STATE_STOPPED):
            return False

        did_work = False
        try:
            chunk = self.transport.read()
        except LinkError as exc:
            self._fail(exc)
            return False

        newest_sensor_frame: Optional[Dict[str, Any]] = None
        for line in self._reader.feed(chunk):
            did_work = True
            try:
                frame = codec.decode_frame(line)
            except ProtocolError:
                # Expected occasionally on a physical wire. Count it and move on;
                # the next frame is 50 ms away.
                self.stats["frames_corrupt"] += 1
                continue

            kind = frame["kind"]
            if kind == codec.FRAME_HELLO:
                if not self._handle_hello(frame["fields"]):
                    return False
            elif kind == codec.FRAME_SENSORS:
                try:
                    parsed = codec.parse_values(frame["fields"])
                except ProtocolError:
                    self.stats["frames_corrupt"] += 1
                    continue
                self.stats["frames_received"] += 1
                self._last_frame_at = self.clock()
                if self._last_seq >= 0 and not codec.seq_is_newer(parsed["seq"], self._last_seq):
                    self.stats["frames_stale"] += 1
                    continue
                if newest_sensor_frame is not None:
                    # Two fresh frames in one read: the host fell behind. Only
                    # the newest describes the world the robot is in now.
                    self.stats["frames_stale"] += 1
                newest_sensor_frame = parsed
            # Unknown frame kinds are ignored rather than fatal, so a newer
            # device script can add frames without breaking an older host.

        if newest_sensor_frame is not None:
            self._handle_sensors(newest_sensor_frame)
            did_work = True

        self._check_watchdog()
        return did_work

    # -- frame handlers ------------------------------------------------------

    def _handle_hello(self, fields: List[str]) -> bool:
        try:
            hello = codec.parse_hello(fields)
        except ProtocolError as exc:
            self._fail(RobotError(str(exc), code=ERR_HANDSHAKE_FAILED))
            return False

        self.robot_info = dict(hello)

        if hello["protocol"] != codec.PROTOCOL_VERSION:
            self._reject(
                ERR_PROTOCOL_MISMATCH,
                "The program on the robot was made by a different version of Neuralese "
                "(robot speaks v%d, this app speaks v%d). Export and copy the program again."
                % (hello["protocol"], codec.PROTOCOL_VERSION),
            )
            return False

        if hello["platform"] != self.plan.platform.id:
            self._reject(
                ERR_HANDSHAKE_FAILED,
                "This is a %s, but the model was set up for a %s."
                % (hello["platform"], self.plan.platform.id),
            )
            return False

        if hello["n_in"] != self.plan.input_count or hello["n_out"] != self.plan.output_count:
            self._reject(
                ERR_ARITY_MISMATCH,
                "The program on the robot sends %d sensor value(s) and expects %d command(s), "
                "but this model uses %d and %d. Copy the new program onto the robot."
                % (hello["n_in"], hello["n_out"], self.plan.input_count, self.plan.output_count),
            )
            return False

        if self.strict_config_hash and hello["cfg_hash"] != self.expected_config_hash:
            self._reject(
                ERR_HANDSHAKE_FAILED,
                "The program on the robot is from an older export. Copy the new program "
                "onto the robot and try again.",
            )
            return False

        try:
            self.transport.write(codec.encode_ack())
        except LinkError as exc:
            self._fail(exc)
            return False

        self._handshaken = True
        self.state = STATE_RUNNING
        self._last_frame_at = self.clock()
        self._safe_sent = False
        # Motion starts from standstill on the link's own clock.
        self.plan.reset_state(self._last_frame_at)
        self._emit({"event": "handshake", "robot": self.robot_info})
        return True

    def _handle_sensors(self, parsed: Dict[str, Any]) -> None:
        if not self._handshaken:
            # Readings from a robot we have not agreed a mapping with are not
            # actionable. Adopting them would skip the fingerprint check, and an
            # older flashed script with the same number of channels but
            # different ones would then be driven with the wrong mapping and the
            # wrong scaling -- exactly what the fingerprint exists to prevent.
            # Every device script re-announces itself when its host goes away,
            # so a handshake is always reachable.
            self.stats["frames_before_handshake"] += 1
            return

        if self.state == STATE_STALLED:
            self.state = STATE_RUNNING
            self._emit({"event": "link_recovered"})

        values = parsed["values"]
        if len(values) != self.plan.input_count:
            self.stats["frames_corrupt"] += 1
            return

        started = self.clock()
        try:
            model_input = self.plan.sensors_to_model(values)
            model_output = self.engine.infer(model_input)
            actuators = self.plan.model_to_actuators(model_output, now=started, model_input=model_input)
        except Exception as exc:
            self.stats["inference_errors"] += 1
            self._consecutive_inference_errors += 1
            self._emit({"event": "inference_error", "message": str(exc), "seq": parsed["seq"]})
            self._send_safe_state()
            if self._consecutive_inference_errors >= MAX_CONSECUTIVE_INFERENCE_ERRORS:
                self._fail(RobotError(
                    "The model failed on %d readings in a row and has been stopped: %s"
                    % (self._consecutive_inference_errors, exc),
                ))
            return

        self._consecutive_inference_errors = 0
        self._last_seq = parsed["seq"]
        self.last_inputs = model_input
        self.last_outputs = model_output
        self.last_actuators = actuators

        try:
            self.transport.write(codec.encode_actuators(parsed["seq"], actuators))
        except LinkError as exc:
            self._fail(exc)
            return

        self._safe_sent = False
        self.stats["frames_answered"] += 1
        self.stats["last_latency_ms"] = (self.clock() - started) * 1000.0

    def _check_watchdog(self) -> None:
        if self.state != STATE_RUNNING:
            return
        if (self.clock() - self._last_frame_at) <= self.link_timeout_s:
            return
        self.stats["watchdog_trips"] += 1
        self.state = STATE_STALLED
        self._send_safe_state()
        self._emit({
            "event": "link_stalled",
            "code": ERR_LINK_TIMEOUT,
            "message": "The robot stopped sending. Everything has been switched off "
                       "until it comes back.",
            "timeout_s": self.link_timeout_s,
        })

    # -- helpers -------------------------------------------------------------

    def _send_safe_state(self) -> None:
        """Drive every actuator to its inert value.

        Sent once per stall rather than every poll: if the link really is gone
        the writes go nowhere anyway, and the robot's own watchdog has already
        stopped it. Re-sending would only spin.
        """
        if self._safe_sent:
            return
        # The motors are being stopped from outside the model, so the drive
        # conversion must not resume from the power it last commanded.
        self.plan.reset_state(self.clock())
        safe = self.plan.safe_values()
        try:
            self.transport.write(codec.encode_actuators(codec.seq_next(max(self._last_seq, 0)), safe))
            self._safe_sent = True
            self.last_actuators = safe
        except Exception:
            self._safe_sent = True

    def _reject(self, code: str, message: str) -> None:
        """Tell the robot why we will not talk to it, then stop."""
        try:
            self.transport.write(codec.encode_error(code))
        except Exception:
            pass
        self._fail(RobotError(message, code=code))

    def _fail(self, exc: BaseException) -> None:
        self.state = STATE_ERROR
        if isinstance(exc, RobotError):
            self.error = exc.to_dict()
        else:
            self.error = {"code": "link_failed", "message": str(exc)}
        self._emit({"event": "error", **self.error})
        self._send_safe_state()

    def _emit(self, payload: Dict[str, Any]) -> None:
        if self.on_event is None:
            return
        try:
            self.on_event(payload)
        except Exception:
            # Telemetry must never be able to take down a robot control loop.
            pass

    def status(self) -> Dict[str, Any]:
        return {
            "state": self.state,
            "error": self.error,
            "robot": dict(self.robot_info),
            "stats": dict(self.stats),
            "platform": self.plan.platform.id,
            "transport": self.transport.describe(),
            "last_inputs": list(self.last_inputs),
            "last_outputs": list(self.last_outputs),
            "last_actuators": list(self.last_actuators),
            "drive": [dict(info) for info in self.plan.drive_info],
        }
