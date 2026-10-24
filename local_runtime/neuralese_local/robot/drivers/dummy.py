"""Dummy: a simulated robot detailed enough to run the whole pipeline without one.

What it simulates, and where the numbers come from:

* A differential-drive chassis. Default calibration is the robotics prototype's
  fit to the EV3 "KIRISIMA" (``tools/convert_all_datalogs_to_visualizer.py``):
  35 cm/s at 100 % power and an effective track of 31 cm, the width that makes
  spins in place match the recorded runs (it is larger than the real track
  because the tracks slip sideways when turning).
* Motors with the EV3's command semantics: a power command lasts 300 ms
  (``MOTOR_LEASE_MS`` in the prototype's ``robots/ev3_robot.py``) and then the
  motor stops, so a host that goes quiet stops the robot here too. Motor speed
  follows the command with a first-order lag; encoders integrate it.
* Ultrasonic sensors that behave like the EV3's: readings in millimetres up to
  255 cm, 2550 meaning "no echo"; a beam cone (the nearest return inside it
  wins); measurement noise; and lost echoes when the beam hits a wall at a
  glancing angle, the artefact the prototype's datalog filters were written for.
* A gyro (clockwise positive, like the EV3's), a touch sensor that closes while
  the robot pushes against a wall, battery level, and a fixed beep capability.
* A world of wall segments (a room with boxes by default) and collisions with a
  round body.

The physical truth of the robot (which motor is the left wheel, how each sensor
is mounted) is kept here, separate from the geometry the user enters in the IR.
That separation is the point: it lets tests check what happens when the user's
geometry is wrong, exactly the mistake the real robot taught us (left and right
motors swapped).

Everything is deterministic for a given seed and sequence of calls.
"""

from __future__ import annotations

import math
import random
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

from ..ir import (
    DEVICE_TYPES,
    DIRECTION_IN,
    DIRECTION_OUT,
    TRANSPORT_VIRTUAL,
    Geometry,
    PortIR,
    RobotIR,
    SensorPose,
    split_channel_id,
)
from .base import RobotDriver

Point = Tuple[float, float]
Segment = Tuple[float, float, float, float]

INPUT_PORTS = ("in1", "in2", "in3", "in4")
OUTPUT_PORTS = ("outA", "outB", "outC", "outD")

NO_ECHO_MM = 2550


@dataclass
class DummyHardware:
    """The simulated robot as it is physically built."""

    #: port id -> device type id (see ir.DEVICE_TYPES)
    ports: Dict[str, str] = field(default_factory=lambda: {
        "in2": "ultrasonic", "in3": "ultrasonic", "in4": "ultrasonic",
        "outB": "large_motor", "outD": "large_motor",
    })
    #: True mounting of each sensor (angle positive to the left).
    mounts: Dict[str, SensorPose] = field(default_factory=lambda: {
        "in4": SensorPose(45.0, 8.0, 4.0),
        "in3": SensorPose(0.0, 9.0, 0.0),
        "in2": SensorPose(-45.0, 8.0, -4.0),
    })
    #: Which motor turns which wheel, and whether positive power drives that
    #: wheel forward (+1) or backward (-1). KIRISIMA: left D, right B.
    left_motor: str = "outD"
    right_motor: str = "outB"
    left_polarity: int = 1
    right_polarity: int = 1
    #: Effective wheel diameter. With a large motor's 1050 deg/s at full power
    #: this gives the prototype's 35 cm/s.
    wheel_diameter_cm: float = 35.0 * 360.0 / (math.pi * 1050.0)
    effective_track_cm: float = 31.0
    body_radius_cm: float = 12.0
    #: Power below which a motor does not move (static friction).
    deadband_pct: float = 0.0
    #: Time constant of the motor's response to a new command.
    motor_time_constant_s: float = 0.08
    #: How long one power command keeps a motor running.
    motor_lease_s: float = 0.3
    ultrasonic_cone_deg: float = 20.0
    ultrasonic_cone_rays: int = 5
    ultrasonic_min_mm: int = 30
    ultrasonic_noise_mm: float = 5.0
    #: A beam hitting a wall further than this from square-on may lose its echo.
    ricochet_angle_deg: float = 60.0
    ricochet_probability: float = 0.5
    battery_pct: int = 100

    def to_dict(self) -> Dict[str, Any]:
        out = {k: getattr(self, k) for k in self.__dataclass_fields__ if k not in ("mounts",)}
        out["mounts"] = {port: pose.to_dict() for port, pose in self.mounts.items()}
        return out

    @staticmethod
    def from_dict(data: Optional[Dict[str, Any]]) -> "DummyHardware":
        hardware = DummyHardware()
        for key, value in (data or {}).items():
            if key == "mounts":
                hardware.mounts = {str(p): SensorPose.from_dict(v or {}) for p, v in (value or {}).items()}
            elif key == "ports":
                hardware.ports = {str(p): str(d) for p, d in (value or {}).items()}
            elif key in hardware.__dataclass_fields__:
                setattr(hardware, key, type(getattr(hardware, key))(value))
        return hardware


@dataclass
class DummyWorld:
    """Walls as line segments, in centimetres; x to the right, y up."""

    walls: List[Segment] = field(default_factory=list)
    start: Tuple[float, float, float] = (60.0, 150.0, 0.0)  # x, y, heading in degrees (0 = +x, CCW)

    @staticmethod
    def default_room() -> "DummyWorld":
        """A 4 x 3 m room with one box in the middle, every gap at least 1.1 m.

        Wide gaps on purpose: with three sonars and the prototype's turn lock, a
        gap of about two robot widths traps the robot spinning in place (see
        :meth:`narrow_gap_room`), which is not what a first run should show.
        """
        world = DummyWorld()
        world.add_box(0.0, 0.0, 400.0, 300.0)
        world.add_box(160.0, 110.0, 80.0, 80.0)
        world.start = (60.0, 150.0, 0.0)
        return world

    @staticmethod
    def narrow_gap_room() -> "DummyWorld":
        """The trap: a 60 cm gap between a box and the wall.

        ``car_brain.onnx`` ends up rocking between left and right turn lock in the
        gap, as the right sonar sweeps on and off the box corner. The real robot
        showed the same kind of episode (spinning up to ~10 s), so this world is
        kept to test that runs, telemetry and Stop behave while it happens.
        """
        world = DummyWorld()
        world.add_box(0.0, 0.0, 400.0, 300.0)
        world.add_box(170.0, 40.0, 60.0, 90.0)
        world.add_box(250.0, 190.0, 90.0, 50.0)
        world.start = (60.0, 150.0, 0.0)
        return world

    def add_box(self, x: float, y: float, w: float, h: float) -> None:
        corners = [(x, y), (x + w, y), (x + w, y + h), (x, y + h)]
        for a, b in zip(corners, corners[1:] + corners[:1]):
            self.walls.append((a[0], a[1], b[0], b[1]))

    def to_dict(self) -> Dict[str, Any]:
        return {"walls": [list(w) for w in self.walls], "start": list(self.start)}

    @staticmethod
    def from_dict(data: Optional[Dict[str, Any]]) -> "DummyWorld":
        if not data:
            return DummyWorld.default_room()
        preset = data.get("preset")
        if preset is not None:
            presets = {"default": DummyWorld.default_room, "narrow_gap": DummyWorld.narrow_gap_room}
            if preset not in presets:
                raise ValueError("Unknown Dummy world '%s'. Known: %s" % (preset, ", ".join(sorted(presets))))
            return presets[preset]()
        world = DummyWorld()
        for wall in data.get("walls") or []:
            world.walls.append(tuple(float(v) for v in wall))  # type: ignore[arg-type]
        for box in data.get("boxes") or []:
            world.add_box(*[float(v) for v in box])
        if data.get("start") is not None:
            sx, sy, sh = (float(v) for v in data["start"])
            world.start = (sx, sy, sh)
        return world


def _ray_hit(ox: float, oy: float, dx: float, dy: float, wall: Segment) -> Optional[Tuple[float, float, float]]:
    """Distance along the ray to the wall, and the wall's direction (ex, ey)."""
    x1, y1, x2, y2 = wall
    ex, ey = x2 - x1, y2 - y1
    denom = dx * ey - dy * ex
    if abs(denom) < 1e-12:
        return None
    t = ((x1 - ox) * ey - (y1 - oy) * ex) / denom
    u = ((x1 - ox) * dy - (y1 - oy) * dx) / denom
    if t >= 0.0 and 0.0 <= u <= 1.0:
        return t, ex, ey
    return None


def _distance_to_segment(px: float, py: float, wall: Segment) -> float:
    x1, y1, x2, y2 = wall
    ex, ey = x2 - x1, y2 - y1
    length2 = ex * ex + ey * ey
    t = 0.0 if length2 == 0.0 else max(0.0, min(1.0, ((px - x1) * ex + (py - y1) * ey) / length2))
    return math.hypot(px - (x1 + t * ex), py - (y1 + t * ey))


class _Motor:
    def __init__(self, max_dps: float) -> None:
        self.max_dps = float(max_dps)
        self.command = 0
        self.expires_at = -math.inf
        self.dps = 0.0
        self.position_deg = 0.0


class DummyDriver(RobotDriver):
    """The simulated robot, behind the same interface as a real one."""

    PHYSICS_STEP_S = 0.005

    def __init__(
        self,
        *,
        name: str = "Dummy",
        robot_id: str = "dummy:kirisima",
        hardware: Optional[DummyHardware] = None,
        world: Optional[DummyWorld] = None,
        seed: int = 0,
        geometry: Optional[Geometry] = None,
    ) -> None:
        self.name = name
        self.robot_id = robot_id
        self.hardware = hardware or DummyHardware()
        self.world = world or DummyWorld.default_room()
        self.seed = int(seed)
        self.geometry = geometry or Geometry()
        self._rng = random.Random(self.seed)
        self._motors: Dict[str, _Motor] = {}
        for port, device in self.hardware.ports.items():
            if device in ("large_motor", "medium_motor"):
                speed = next(c for c in DEVICE_TYPES[device].channels if c.suffix == "speed_dps")
                self._motors[port] = _Motor(speed.native_max)
        self.reset_pose()
        self.sim_time: Optional[float] = None
        self.is_open = False
        self.beeps: List[Tuple[float, int, int]] = []

    # -- construction from a config ---------------------------------------------

    @staticmethod
    def from_spec(spec: Dict[str, Any], robot: Optional[Dict[str, Any]] = None) -> "DummyDriver":
        """Build from a transport spec: ``{"kind": "virtual", "hardware": ..., "world": ..., "seed": ...}``."""
        ir_geometry = Geometry.from_dict((robot or {}).get("geometry")) if robot else None
        return DummyDriver(
            name=str((robot or {}).get("name") or spec.get("name") or "Dummy"),
            robot_id=str((robot or {}).get("robot_id") or spec.get("robot_id") or "dummy:kirisima"),
            hardware=DummyHardware.from_dict(spec.get("hardware")),
            world=DummyWorld.from_dict(spec.get("world")),
            seed=int(spec.get("seed", 0)),
            geometry=ir_geometry,
        )

    # -- pose and physics -------------------------------------------------------

    def reset_pose(self) -> None:
        sx, sy, sh = self.world.start
        self.x, self.y = float(sx), float(sy)
        self.heading = math.radians(float(sh))
        self.start_heading = self.heading
        self.omega = 0.0
        self.bumped = False
        self.trail: List[Point] = [(self.x, self.y)]

    def pose(self) -> Dict[str, float]:
        return {"x_cm": self.x, "y_cm": self.y, "heading_deg": math.degrees(self.heading)}

    def _wheel_speed_cm_s(self, motor_port: str, polarity: int) -> float:
        motor = self._motors.get(motor_port)
        if motor is None:
            return 0.0
        return polarity * motor.dps / 360.0 * math.pi * self.hardware.wheel_diameter_cm

    def _step(self, dt: float, t: float) -> None:
        hw = self.hardware
        alpha = 1.0 - math.exp(-dt / hw.motor_time_constant_s) if hw.motor_time_constant_s > 0 else 1.0
        for motor in self._motors.values():
            command = motor.command if t <= motor.expires_at else 0
            if abs(command) < hw.deadband_pct:
                command = 0
            target = command / 100.0 * motor.max_dps
            motor.dps += (target - motor.dps) * alpha
            motor.position_deg += motor.dps * dt

        v_left = self._wheel_speed_cm_s(hw.left_motor, hw.left_polarity)
        v_right = self._wheel_speed_cm_s(hw.right_motor, hw.right_polarity)
        v = (v_left + v_right) / 2.0
        self.omega = (v_right - v_left) / hw.effective_track_cm
        self.heading += self.omega * dt
        nx = self.x + v * math.cos(self.heading) * dt
        ny = self.y + v * math.sin(self.heading) * dt
        blocked = any(_distance_to_segment(nx, ny, wall) < hw.body_radius_cm for wall in self.world.walls)
        self.bumped = blocked and abs(v) > 1e-6
        if not blocked:
            self.x, self.y = nx, ny
            self.trail.append((self.x, self.y))

    def tick(self, now: float) -> None:
        if self.sim_time is None:
            self.sim_time = now
            return
        while self.sim_time + self.PHYSICS_STEP_S <= now + 1e-12:
            self.sim_time += self.PHYSICS_STEP_S
            self._step(self.PHYSICS_STEP_S, self.sim_time)

    # -- sensors ----------------------------------------------------------------

    def _ultrasonic_mm(self, port: str) -> int:
        hw = self.hardware
        mount = hw.mounts.get(port, SensorPose())
        fx, fy = math.cos(self.heading), math.sin(self.heading)
        lx, ly = -fy, fx
        ox = self.x + fx * mount.x_cm + lx * mount.y_cm
        oy = self.y + fy * mount.x_cm + ly * mount.y_cm
        centre = self.heading + math.radians(mount.angle_deg)
        rays = max(1, int(hw.ultrasonic_cone_rays))
        best: Optional[Tuple[float, float, float, float, float]] = None
        for k in range(rays):
            offset = 0.0 if rays == 1 else (k / (rays - 1) - 0.5) * math.radians(hw.ultrasonic_cone_deg)
            dx, dy = math.cos(centre + offset), math.sin(centre + offset)
            for wall in self.world.walls:
                hit = _ray_hit(ox, oy, dx, dy, wall)
                if hit is not None and (best is None or hit[0] < best[0]):
                    best = (hit[0], hit[1], hit[2], dx, dy)
        if best is None or best[0] * 10.0 >= NO_ECHO_MM:
            return NO_ECHO_MM
        distance_cm, ex, ey, dx, dy = best
        # Angle between the beam and the wall's normal: 0 is square-on.
        wall_length = math.hypot(ex, ey) or 1.0
        along = abs(dx * ex + dy * ey) / wall_length
        incidence = math.degrees(math.asin(min(1.0, along)))
        if incidence > hw.ricochet_angle_deg and self._rng.random() < hw.ricochet_probability:
            return NO_ECHO_MM
        reading = distance_cm * 10.0 + self._rng.gauss(0.0, hw.ultrasonic_noise_mm)
        return int(round(min(NO_ECHO_MM, max(hw.ultrasonic_min_mm, reading))))

    def _read_channel(self, channel: str) -> int:
        port, suffix = split_channel_id(channel)
        device = self.hardware.ports.get(port, "")
        if device == "ultrasonic" and suffix == "distance_mm":
            return self._ultrasonic_mm(port)
        if device == "gyro" and suffix == "angle_deg":
            return int(round(-math.degrees(self.heading - self.start_heading)))
        if device == "gyro" and suffix == "rate_dps":
            return int(round(-math.degrees(self.omega)))
        if device == "touch" and suffix == "pressed":
            return 1 if self.bumped else 0
        if device == "infrared" and suffix == "proximity":
            mm = self._ultrasonic_mm(port)
            return int(round(min(100.0, mm / 7.0)))
        if device == "color":
            return {"reflect": 40, "ambient": 15, "color_id": 6}.get(suffix, 0)
        if device in ("large_motor", "medium_motor"):
            motor = self._motors[port]
            if suffix == "position_deg":
                return int(round(motor.position_deg))
            if suffix == "speed_dps":
                return int(round(motor.dps))
            if suffix == "power":
                return motor.command
        raise KeyError("The Dummy has no channel %s." % channel)

    # -- RobotDriver --------------------------------------------------------------

    def inventory(self) -> RobotIR:
        ports = []
        for port_id in INPUT_PORTS:
            ports.append(PortIR(port_id, port_id[2:], DIRECTION_IN, self.hardware.ports.get(port_id, ""), True))
        for port_id in OUTPUT_PORTS:
            ports.append(PortIR(port_id, port_id[3:], DIRECTION_OUT, self.hardware.ports.get(port_id, ""), True))
        return RobotIR(
            robot_id=self.robot_id,
            platform="dummy",
            name=self.name,
            model="Dummy (simulated EV3)",
            transport=TRANSPORT_VIRTUAL,
            status="connected" if self.is_open else "available",
            battery_pct=self.hardware.battery_pct,
            # A simulated robot has no radio; report it as next to the computer.
            proximity={"rssi_dbm": None, "distance_m": 0.5, "simulated": True},
            ports=ports,
            capabilities=["beep"],
            geometry=self.geometry,
        )

    def open(self, now: float) -> None:
        self.is_open = True
        self.sim_time = now

    def close(self) -> None:
        self.stop(self.sim_time or 0.0)
        self.is_open = False

    def read(self, channels: Sequence[str], now: float) -> List[int]:
        self.tick(now)
        return [self._read_channel(str(c)) for c in channels]

    def write(self, values: Dict[str, int], now: float) -> None:
        self.tick(now)
        for channel, value in values.items():
            port, suffix = split_channel_id(channel)
            motor = self._motors.get(port)
            if motor is None or suffix != "power":
                raise KeyError("The Dummy cannot drive %s." % channel)
            motor.command = int(max(-100, min(100, int(value))))
            motor.expires_at = now + self.hardware.motor_lease_s

    def stop(self, now: float) -> None:
        for motor in self._motors.values():
            motor.command = 0
            motor.expires_at = -math.inf

    def beep(self, now: float, frequency_hz: int = 1000, duration_ms: int = 200) -> None:
        self.beeps.append((now, int(frequency_hz), int(duration_ms)))
