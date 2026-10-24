"""Replay: a recorded run of a real robot, played back as if it were connected.

Reads either kind of datalog:

* the prototype's (``logs/datalog_*.jsonl`` from ``run_real_model_drive.py``):
  a session header naming the ports and sensor angles, then one record per
  control tick with the raw ultrasonic readings in centimetres;
* Neuralese's own (:class:`..runtime.DataLog`): a header carrying the robot's
  IR, then one record per tick with the reading of every mapped channel.

Both have a ``timestamp_s`` per record. Sensor channels return the reading of the
record whose time has been reached; motor commands are accepted and kept in
:attr:`ReplayDriver.commands` but change nothing, since the recording already
happened.

Useful for building and checking the UI against what a real robot actually
reported, including its noise and lost echoes, without the robot.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from ..ir import (
    DIRECTION_IN,
    DIRECTION_OUT,
    TRANSPORT_REPLAY,
    DriveGeometry,
    Geometry,
    PortIR,
    RobotIR,
    SensorPose,
    split_channel_id,
)
from .base import RobotDriver

NO_ECHO_MM = 2550


class ReplayDriver(RobotDriver):
    def __init__(self, log_path: Any, *, loop: bool = True) -> None:
        self.log_path = Path(log_path)
        self.loop = loop
        self.header: Dict[str, Any] = {}
        self.records: List[Dict[str, Any]] = []
        for line in self.log_path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            record = json.loads(line)
            if record.get("_record_type") == "session_header":
                self.header = record
            else:
                self.records.append(record)
        if not self.records:
            raise ValueError("The recorded run %s has no frames." % self.log_path)
        self.duration_s = float(self.records[-1].get("timestamp_s", 0.0))
        #: Neuralese's own datalog carries the robot and per-channel readings.
        self.recorded_robot: Optional[Dict[str, Any]] = (
            self.header.get("robot") if self.header.get("format") == "neuralese_robot_datalog" else None)
        ports = self.header.get("ports") or {}
        # "sensor_left": 4 -> in4 reads sensors_raw_cm["left_p4"]
        self._sensor_keys: Dict[str, str] = {}
        for role in ("left", "center", "right"):
            port = ports.get("sensor_%s" % role)
            if port is not None:
                self._sensor_keys["in%s" % port] = "%s_p%s" % (role, port)
        self.left_motor = "out%s" % ports.get("motor_left", "D")
        self.right_motor = "out%s" % ports.get("motor_right", "B")
        self.commands: List[Tuple[float, Dict[str, int]]] = []
        self.open_time: Optional[float] = None
        self._index = 0

    def _record_at(self, now: float) -> Dict[str, Any]:
        elapsed = 0.0 if self.open_time is None else max(0.0, now - self.open_time)
        if self.loop and self.duration_s > 0:
            elapsed %= self.duration_s
            if elapsed < float(self.records[self._index].get("timestamp_s", 0.0)):
                self._index = 0
        while (self._index + 1 < len(self.records)
               and float(self.records[self._index + 1].get("timestamp_s", 0.0)) <= elapsed):
            self._index += 1
        return self.records[self._index]

    def inventory(self) -> RobotIR:
        if self.recorded_robot is not None:
            robot = RobotIR.from_dict(self.recorded_robot)
            robot.robot_id = "replay:%s" % self.log_path.name
            robot.platform = "dummy"
            robot.name = "%s (recording)" % (robot.name or "Recorded robot")
            robot.model = "Recorded run"
            robot.transport = TRANSPORT_REPLAY
            robot.status = "connected" if self.open_time is not None else "available"
            robot.proximity = None
            return robot
        angles = self.header.get("sensor_angles_deg") or {}
        sensors: Dict[str, SensorPose] = {}
        ports: List[PortIR] = []
        for port_id in ("in1", "in2", "in3", "in4"):
            device = "ultrasonic" if port_id in self._sensor_keys else ""
            ports.append(PortIR(port_id, port_id[2:], DIRECTION_IN, device, bool(device)))
            if device:
                role = self._sensor_keys[port_id].split("_")[0]
                sensors[port_id] = SensorPose(float(angles.get(role, 0.0)))
        for port_id in ("outA", "outB", "outC", "outD"):
            device = "large_motor" if port_id in (self.left_motor, self.right_motor) else ""
            ports.append(PortIR(port_id, port_id[3:], DIRECTION_OUT, device, bool(device)))
        name = str(self.header.get("robot_name") or "Recorded robot")
        return RobotIR(
            robot_id="replay:%s" % self.log_path.name,
            platform="dummy",
            name="%s (recording)" % name,
            model="Recorded run",
            transport=TRANSPORT_REPLAY,
            status="connected" if self.open_time is not None else "available",
            battery_pct=self.header.get("battery_pct"),
            ports=ports,
            capabilities=[],
            geometry=Geometry(sensors=sensors, drive=DriveGeometry(self.left_motor, self.right_motor)),
        )

    def open(self, now: float) -> None:
        self.open_time = now
        self._index = 0

    def close(self) -> None:
        self.open_time = None

    def read(self, channels: Sequence[str], now: float) -> List[int]:
        record = self._record_at(now)
        if self.recorded_robot is not None:
            readings = record.get("readings") or {}
            missing = [c for c in channels if str(c) not in readings and split_channel_id(str(c))[1] != "power"]
            if missing:
                raise KeyError("The recording has no channel %s." % ", ".join(missing))
            return [int(readings.get(str(c), 0)) for c in channels]
        raw = record.get("sensors_raw_cm") or {}
        values: List[int] = []
        for channel in channels:
            port, suffix = split_channel_id(str(channel))
            key = self._sensor_keys.get(port)
            if key is not None and suffix == "distance_mm":
                cm = raw.get(key)
                values.append(NO_ECHO_MM if cm is None else int(round(float(cm) * 10.0)))
            elif port in (self.left_motor, self.right_motor):
                values.append(0)
            else:
                raise KeyError("The recording has no channel %s." % channel)
        return values

    def write(self, values: Dict[str, int], now: float) -> None:
        self.commands.append((now, dict(values)))

    def stop(self, now: float) -> None:
        self.commands.append((now, {}))
