"""Where the robot is, in the units of the world its network was trained in.

A network trained on the top-down rover in Simulations may see more than rays:
its speed, its rotation, where it is in the world, where the goal is. On a real
robot those come from the wheels (every EV3 and SPIKE motor counts its own
turns) and, when there is one, from a gyro. This module turns those counts into
the rover's pose -- position, heading, velocity -- and the pose into exactly the
numbers the simulation feeds the network (``simulation_kernel_agent.gd``,
``encode_*``).

The room is the training world shrunk to the robot's size: one simulation unit
is ``cm_per_unit`` centimetres, where ``cm_per_unit`` is the robot's length over
the rover's length in that world. Rays, speeds, positions and the goal all use
that one number.

Conventions are the simulation's (Godot 2D, y down): heading 0 faces +x and
grows clockwise, so a turn to the right is a positive change. The EV3 gyro and
the Dummy's gyro count clockwise as positive too.

Like :mod:`.config`, this module needs nothing beyond the standard library.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Sequence, Tuple

#: ``SimulationKernelAgent.MAX_OBSERVED_SPEED``: speeds are divided by this.
MAX_OBSERVED_SPEED = 600.0
#: ``SimulationKernelAgent.DEFAULT_RAY_DISTANCE``: a ray's reach, in units.
RAY_DISTANCE_UNITS = 320.0
#: The rover's length in the object catalog (``default_size`` 72 x 48).
ROVER_LENGTH_UNITS = 72.0
#: ``SimulationKernel.context_for_agent`` falls back to this world.
DEFAULT_BOUNDS = (-480.0, -260.0, 960.0, 520.0)
#: Velocity is smoothed over about this long, so one encoder step does not jump it.
VELOCITY_SMOOTHING_S = 0.2

HEADING_GYRO = "gyro"
HEADING_WHEELS = "wheels"

#: Pose quantities a model input can be: one per channel of each simulation
#: sensor (``encode_*``), named after what they are.
QUANTITIES = (
    "speed", "velocity_x", "velocity_y", "rotation", "heading_sin", "heading_cos",
    "position_x", "position_y", "goal_x", "goal_y", "local_goal_x", "local_goal_y", "goal_distance",
)
#: Quantities that need a goal in the world.
GOAL_QUANTITIES = ("goal_x", "goal_y", "local_goal_x", "local_goal_y", "goal_distance")
#: Quantities that need the robot's place in the world (a start position).
PLACE_QUANTITIES = ("position_x", "position_y") + GOAL_QUANTITIES

#: Simulation sensors (registry ids) and the pose quantities of their channels.
SENSOR_QUANTITIES: Dict[str, Tuple[str, ...]] = {
    "speed": ("speed",),
    "velocity_x": ("velocity_x",),
    "velocity_y": ("velocity_y",),
    "rotation": ("rotation",),
    "heading_sincos": ("heading_sin", "heading_cos"),
    "normalized_position": ("position_x", "position_y"),
    "gps": ("position_x", "position_y"),
    "goal_vector": ("goal_x", "goal_y"),
    "goal_direction": ("goal_x", "goal_y"),
    "local_goal_direction": ("local_goal_x", "local_goal_y"),
    "goal_distance": ("goal_distance",),
}


def clamp(value: float, low: float, high: float) -> float:
    return low if value < low else high if value > high else value


def wrap_angle(angle: float) -> float:
    """``wrapf(angle, -PI, PI)``."""
    return (angle + math.pi) % (2.0 * math.pi) - math.pi


def normalized(x: float, y: float) -> Tuple[float, float]:
    """``Vector2.normalized()``: a zero vector stays zero."""
    length = math.hypot(x, y)
    return (0.0, 0.0) if length == 0.0 else (x / length, y / length)


def rotated(x: float, y: float, angle: float) -> Tuple[float, float]:
    """``Vector2.rotated(angle)``."""
    c, s = math.cos(angle), math.sin(angle)
    return (x * c - y * s, x * s + y * c)


def normalize_axis(value: float, minimum: float, maximum: float) -> float:
    """``SimulationKernelAgent._normalize_axis``: a world axis to -1..1."""
    if math.isclose(minimum, maximum):
        return 0.0
    return clamp((value - minimum) / (maximum - minimum) * 2.0 - 1.0, -1.0, 1.0)


@dataclass
class World:
    """The training world, and how big it is in the room."""

    cm_per_unit: float
    bounds: Tuple[float, float, float, float] = DEFAULT_BOUNDS   # x, y, width, height (units)
    start: Tuple[float, float, float] = (0.0, 0.0, 0.0)          # x, y (units), heading (radians)
    goal: Optional[Tuple[float, float]] = None                   # units
    max_goal_distance: Optional[float] = None                    # units; default: the bounds' diagonal

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "World":
        bounds = data.get("bounds") or DEFAULT_BOUNDS
        start = data.get("start") or (0.0, 0.0, 0.0)
        goal = data.get("goal")
        max_goal = data.get("max_goal_distance")
        return World(
            cm_per_unit=float(data["cm_per_unit"]),
            bounds=tuple(float(v) for v in bounds),
            start=tuple(float(v) for v in start),
            goal=tuple(float(v) for v in goal) if goal is not None else None,
            max_goal_distance=float(max_goal) if max_goal is not None else None,
        )

    def to_dict(self) -> Dict[str, Any]:
        return {
            "cm_per_unit": self.cm_per_unit,
            "bounds": list(self.bounds),
            "start": list(self.start),
            "goal": list(self.goal) if self.goal is not None else None,
            "max_goal_distance": self.max_goal_distance,
        }

    def goal_reach(self) -> float:
        """``max_goal_distance`` of ``context_for_agent``: the bounds' diagonal, at least 1."""
        if self.max_goal_distance is not None:
            return max(self.max_goal_distance, 0.001)
        return max(math.hypot(self.bounds[2], self.bounds[3]), 1.0)


def cm_per_unit_for(robot_length_cm: float, agent_length_units: float = ROVER_LENGTH_UNITS) -> float:
    """The scale between the world and the room: the rover is as long as the robot."""
    return float(robot_length_cm) / max(float(agent_length_units), 0.001)


def ray_reach_cm(cm_per_unit: float) -> float:
    """How far a ray reaches in the room."""
    return RAY_DISTANCE_UNITS * cm_per_unit


@dataclass
class WheelSide:
    """The encoder channels of one side's drive motors."""

    channels: List[str]
    invert: List[bool]


@dataclass
class OdometrySetup:
    left: WheelSide
    right: WheelSide
    wheel_diameter_cm: float
    track_cm: float
    heading: str = HEADING_WHEELS
    gyro_channel: str = ""

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "OdometrySetup":
        def side(entries: Any) -> WheelSide:
            channels, invert = [], []
            for entry in entries or []:
                if isinstance(entry, dict):
                    channels.append(str(entry.get("channel", "")))
                    invert.append(bool(entry.get("invert", False)))
                else:
                    channels.append(str(entry))
                    invert.append(False)
            return WheelSide(channels, invert)

        heading = data.get("heading") or {}
        return OdometrySetup(
            left=side(data.get("left")),
            right=side(data.get("right")),
            wheel_diameter_cm=float(data["wheel_diameter_cm"]),
            track_cm=float(data["track_cm"]),
            heading=str(heading.get("source", HEADING_WHEELS)),
            gyro_channel=str(heading.get("channel", "")),
        )

    def channels(self) -> List[str]:
        """Every channel the odometry reads, in a fixed order."""
        result = list(self.left.channels) + list(self.right.channels)
        if self.heading == HEADING_GYRO and self.gyro_channel:
            result.append(self.gyro_channel)
        return result


@dataclass
class Pose:
    x: float
    y: float
    heading: float
    vx: float = 0.0
    vy: float = 0.0

    @property
    def speed(self) -> float:
        return math.hypot(self.vx, self.vy)


class Odometry:
    """Dead reckoning from wheel encoders (and a gyro), in world units.

    ``update`` takes the raw counts of every channel in :meth:`OdometrySetup.channels`
    order. The first update after :meth:`reset` only remembers them: the robot is
    where the world says it starts.
    """

    def __init__(self, setup: OdometrySetup, world: World) -> None:
        self.setup = setup
        self.world = world
        self._degrees_to_units = math.pi * setup.wheel_diameter_cm / 360.0 / world.cm_per_unit
        self.reset()

    def reset(self) -> None:
        x, y, heading = self.world.start
        self.pose = Pose(float(x), float(y), float(heading))
        self._last: Optional[List[float]] = None
        self._last_time: Optional[float] = None
        self._gyro_zero: Optional[float] = None

    def _side_degrees(self, side: WheelSide, values: Sequence[float]) -> float:
        if not side.channels:
            return 0.0
        total = 0.0
        for value, invert in zip(values, side.invert):
            total += -float(value) if invert else float(value)
        return total / len(side.channels)

    def update(self, values: Sequence[float], now: float) -> Pose:
        setup = self.setup
        n_left, n_right = len(setup.left.channels), len(setup.right.channels)
        left = self._side_degrees(setup.left, values[:n_left])
        right = self._side_degrees(setup.right, values[n_left:n_left + n_right])
        gyro = float(values[n_left + n_right]) if setup.heading == HEADING_GYRO and len(values) > n_left + n_right else None
        if self._last is None:
            self._last = [left, right]
            self._last_time = now
            if gyro is not None:
                self._gyro_zero = gyro
            return self.pose
        d_left = (left - self._last[0]) * self._degrees_to_units
        d_right = (right - self._last[1]) * self._degrees_to_units
        self._last = [left, right]
        dt = max(now - (self._last_time if self._last_time is not None else now), 0.0)
        self._last_time = now
        pose = self.pose
        start_heading = self.world.start[2]
        if gyro is not None and self._gyro_zero is not None:
            heading = start_heading + math.radians(gyro - self._gyro_zero)
        else:
            track_units = setup.track_cm / self.world.cm_per_unit
            # The left wheel going further turns the robot right: clockwise, positive.
            heading = pose.heading + (d_left - d_right) / max(track_units, 1e-6)
        distance = (d_left + d_right) / 2.0
        middle = (pose.heading + heading) / 2.0
        dx = distance * math.cos(middle)
        dy = distance * math.sin(middle)
        pose.x += dx
        pose.y += dy
        pose.heading = heading
        if dt > 0.0:
            weight = clamp(dt / VELOCITY_SMOOTHING_S, 0.0, 1.0)
            pose.vx += (dx / dt - pose.vx) * weight
            pose.vy += (dy / dt - pose.vy) * weight
        return pose

    def quantity(self, name: str) -> float:
        """One model input from the pose, as the simulation encodes it."""
        return quantity(name, self.pose, self.world)

    def to_dict(self) -> Dict[str, Any]:
        pose = self.pose
        k = self.world.cm_per_unit
        return {
            "x": round(pose.x, 3), "y": round(pose.y, 3), "heading": round(pose.heading, 4),
            "speed": round(pose.speed, 3),
            "x_cm": round((pose.x - self.world.start[0]) * k, 1),
            "y_cm": round((pose.y - self.world.start[1]) * k, 1),
        }


def quantity(name: str, pose: Pose, world: World) -> float:
    """``SimulationKernelAgent.encode_*`` for one channel."""
    if name == "speed":
        return clamp(pose.speed / MAX_OBSERVED_SPEED, 0.0, 1.0)
    if name == "velocity_x":
        return clamp(pose.vx / MAX_OBSERVED_SPEED, -1.0, 1.0)
    if name == "velocity_y":
        return clamp(pose.vy / MAX_OBSERVED_SPEED, -1.0, 1.0)
    if name == "rotation":
        return wrap_angle(pose.heading) / math.pi
    if name == "heading_sin":
        return math.sin(pose.heading)
    if name == "heading_cos":
        return math.cos(pose.heading)
    bx, by, bw, bh = world.bounds
    if name == "position_x":
        return normalize_axis(pose.x, bx, bx + bw)
    if name == "position_y":
        return normalize_axis(pose.y, by, by + bh)
    goal = world.goal if world.goal is not None else (bx + bw, by + bh)   # ``goal_position()`` without a goal
    gx, gy = goal[0] - pose.x, goal[1] - pose.y
    if name in ("goal_x", "goal_y"):
        nx, ny = normalized(gx, gy)
        return nx if name == "goal_x" else ny
    if name in ("local_goal_x", "local_goal_y"):
        lx, ly = rotated(gx, gy, -pose.heading)
        nx, ny = normalized(lx, ly)
        return nx if name == "local_goal_x" else ny
    if name == "goal_distance":
        return clamp(math.hypot(gx, gy) / world.goal_reach(), 0.0, 1.0)
    raise KeyError("Unknown pose quantity '%s'." % name)
