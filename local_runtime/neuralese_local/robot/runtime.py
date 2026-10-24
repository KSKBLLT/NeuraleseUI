"""Driving a host-driven robot with a trained model.

The loop is the robotics prototype's ``run_real_model_drive.py`` (the one that
drove the EV3 "KIRISIMA"), made robot-independent: every step goes through a
:class:`.drivers.base.RobotDriver` (an EV3 over Bluetooth, the Dummy) and a
compiled mapping (:class:`.config.MappingPlan`), so nothing here knows ports
or sensors. One tick, in the prototype's order:

1. read the mapped sensor channels (all sonars in one round trip on an EV3);
2. turn them into the model's input (rays interpolated between sonars);
3. run the model;
4. turn steer/throttle into motor power (the prototype's drive conversion);
5. send the power;
6. log the tick.

Ticks run at 20 Hz: after a tick the loop sleeps ``max(0.01, 0.05 - elapsed)``,
as the prototype did. Any failure stops the motors before it is reported, and
so do Stop and the emergency stop. Time is injected, so all of it runs on a
fake clock in the tests.
"""

from __future__ import annotations

import json
import time
from datetime import datetime
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence

from .config import MappingPlan
from .drivers.base import RobotDriver

TICK_S = 0.05            # 20 Hz, as the prototype
MIN_SLEEP_S = 0.01       # the prototype never slept less than this between ticks
DATALOG_FORMAT = "neuralese_robot_datalog"
DATALOG_VERSION = 1


class DataLog:
    """Every tick of a run, one JSON line each, after a header line.

    The prototype's ``RobotDataLogger``: a ``session_header`` record first,
    flushed every 5 records, closed on stop. Records name channels rather than
    sensor roles, so any robot's run can be replayed (``drivers/replay.py``).
    """

    def __init__(self, path: Any, header: Dict[str, Any]) -> None:
        self.path = Path(path)
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.file = self.path.open("w", encoding="utf-8", newline="\n")
        self.record_count = 0
        self.write({
            "_record_type": "session_header",
            "format": DATALOG_FORMAT,
            "version": DATALOG_VERSION,
            "created_at": datetime.now().isoformat(),
            **header,
        })
        self.file.flush()

    def write(self, record: Dict[str, Any]) -> None:
        self.file.write(json.dumps(record, ensure_ascii=False) + "\n")

    def log(self, record: Dict[str, Any]) -> None:
        self.write(record)
        self.record_count += 1
        if self.record_count % 5 == 0:
            self.file.flush()

    def close(self) -> None:
        try:
            self.file.flush()
            self.file.close()
        except Exception:
            pass


class DriveLoop:
    """The model driving one robot."""

    def __init__(
        self,
        driver: RobotDriver,
        plan: MappingPlan,
        engine: Any,
        *,
        clock: Callable[[], float] = time.monotonic,
        datalog: Optional[DataLog] = None,
    ) -> None:
        self.driver = driver
        self.plan = plan
        self.engine = engine
        self.clock = clock
        self.datalog = datalog
        self.input_ids: List[str] = [channel.id for channel in plan.input_channels]
        self.output_ids: List[str] = [channel.id for channel in plan.output_channels]
        self.running = False
        self.started_at: Optional[float] = None
        self.step = 0
        self._last_tick: Optional[float] = None
        self.last: Dict[str, Any] = {}

    def start(self) -> None:
        now = self.clock()
        self.plan.reset_state(now)   # motion ramps up from standstill
        self.started_at = now
        self._last_tick = now
        self.step = 0
        self.running = True

    def tick(self) -> Dict[str, Any]:
        """One read -> model -> motors step. Stops the motors on any failure."""
        if not self.running:
            raise RuntimeError("The drive loop is not running.")
        now = self.clock()
        dt = now - (self._last_tick if self._last_tick is not None else now)
        self._last_tick = now
        try:
            self.driver.tick(now)                                   # link heartbeat / physics
            readings = self.driver.read(self.input_ids, now)        # 1
            model_input = self.plan.sensors_to_model(readings, now=now)   # 2
            model_output = [float(v) for v in self.engine.infer(model_input)]   # 3
            commands = self.plan.model_to_actuators(model_output, now=now, model_input=model_input)  # 4
            self.driver.write(dict(zip(self.output_ids, commands)), now)        # 5
        except BaseException:
            self.halt()
            raise
        record = {
            "step": self.step,
            "timestamp_s": round(now - (now if self.started_at is None else self.started_at), 4),
            "dt_ms": round(dt * 1000.0, 1),
            "readings": dict(zip(self.input_ids, readings)),
            "model_input": [round(float(v), 4) for v in model_input],
            "model_output": [round(v, 4) for v in model_output],
            "motors": dict(zip(self.output_ids, commands)),
            "drive": [dict(info) for info in self.plan.drive_info],
        }
        pose = self.plan.pose_info()
        if pose is not None:
            record["pose"] = pose
        if self.datalog is not None:
            self.datalog.log(record)                                # 6
        self.last = record
        self.step += 1
        return record

    def sleep_after_tick(self, tick_started: float, sleep: Callable[[float], None] = time.sleep) -> None:
        elapsed = self.clock() - tick_started
        sleep(max(MIN_SLEEP_S, TICK_S - elapsed))

    def halt(self) -> None:
        """Stop the motors and the loop. Never raises."""
        self.running = False
        try:
            self.driver.stop(self.clock())
        except Exception:
            pass
        try:
            self.plan.reset_state(self.clock())
        except Exception:
            pass
        if self.datalog is not None:
            self.datalog.close()

    def run(self, *, should_stop: Callable[[], bool], max_seconds: Optional[float] = None,
            sleep: Callable[[float], None] = time.sleep) -> None:
        """Drive until asked to stop (or for ``max_seconds``). Always stops the motors."""
        self.start()
        started = self.clock()
        try:
            while self.running and not should_stop():
                tick_started = self.clock()
                if max_seconds is not None and tick_started - started >= max_seconds:
                    break
                self.tick()
                self.sleep_after_tick(tick_started, sleep)
        finally:
            self.halt()


def hold_motor(driver: RobotDriver, channel: str, power: int, seconds: float, *,
               clock: Callable[[], float] = time.monotonic, sleep: Callable[[float], None] = time.sleep,
               refresh_s: float = 0.05) -> None:
    """Run one motor for a while, then stop it (the prototype's ``_hold_motor``).

    A command lasts 300 ms on an EV3, so it is re-sent every ``refresh_s``.
    Used to spin one wheel so the child can see which wheel a port drives.
    """
    end = clock() + seconds
    try:
        while clock() < end:
            now = clock()
            driver.tick(now)
            driver.write({channel: int(power)}, now)
            sleep(refresh_s)
    finally:
        try:
            driver.write({channel: 0}, clock())
        except Exception:
            driver.stop(clock())


def live_robot(inventory: Dict[str, Any], geometry_from: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """The connected robot's IR with the geometry the mapping was made for.

    Ports and devices always come from the robot as it is now, so a mapping
    that names a sensor that is not plugged in fails validation before any
    motor moves.
    """
    robot = dict(inventory)
    if geometry_from and geometry_from.get("geometry"):
        robot["geometry"] = geometry_from["geometry"]
    return robot
