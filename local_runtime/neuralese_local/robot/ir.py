"""Robot IR: one description of a robot, whatever its platform.

Every driver (the virtual Dummy, a stock-firmware EV3 over Bluetooth, and later
others) turns its hardware into this description, and everything above the
driver -- the mapping config, the bridge, the UI -- reads only this. That is
what lets a new robot family arrive as a new driver rather than as a new
feature.

An IR has four parts:

* identity: id, platform, name, model, how it is connected, battery, proximity;
* ports: each physical socket, its direction, the device found in it (or set by
  hand), and whether that came from the robot or from the user;
* capabilities: things the robot can do besides its ports (beep, screen, ...);
* geometry: what only the person who built the robot knows -- where each sensor
  points, which motor is the left wheel, whether a motor is mounted reversed.
  Ports can be detected; geometry cannot, so it is never guessed.

Channels
--------
A port with a device exposes one channel per thing that device can report or
take, named ``<port id>.<suffix>``: ``in2.distance_mm``, ``outB.power``,
``outB.position_deg``. These are ordinary :class:`.platforms.SensorChannel` /
:class:`.platforms.ActuatorChannel` objects, so the mapping config validates
and scales them exactly like the fixed channels of the device-script robots.
All values are native device units, as integers, like everywhere else on the
wire.
"""

from __future__ import annotations

from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional

from .errors import ERR_BAD_CONFIG, ValidationReport
from .platforms import ActuatorChannel, Platform, SensorChannel

IR_SCHEMA_VERSION = 1

DIRECTION_IN = "in"
DIRECTION_OUT = "out"

TRANSPORT_VIRTUAL = "virtual"
TRANSPORT_REPLAY = "replay"
TRANSPORT_BLUETOOTH = "bluetooth"


@dataclass(frozen=True)
class ChannelSpec:
    suffix: str
    label: str
    native_min: float
    native_max: float
    unit: str = ""
    integer_only: bool = False
    #: Actuators only: the inert value used when the link is not healthy.
    safe_value: int = 0
    #: "in" channels are read from the robot, "out" channels are written to it.
    #: A motor port has both (power out, position and speed in).
    direction: str = DIRECTION_IN


@dataclass(frozen=True)
class DeviceType:
    id: str
    label: str
    port_direction: str
    channels: tuple
    description: str = ""


def _motor(device_id: str, label: str, max_dps: int) -> DeviceType:
    return DeviceType(
        device_id, label, DIRECTION_OUT,
        (
            ChannelSpec("power", "power", -100, 100, unit="%", direction=DIRECTION_OUT, safe_value=0),
            ChannelSpec("position_deg", "position", -999999, 999999, unit="deg"),
            ChannelSpec("speed_dps", "speed", -max_dps, max_dps, unit="deg/s"),
        ),
    )


#: Devices a port can hold. Ranges are the device's native units. Families share
#: this list where the hardware matches (an EV3 and a Dummy both have an
#: ultrasonic sensor reporting millimetres); a family with different hardware
#: adds its own entries.
DEVICE_TYPES: Dict[str, DeviceType] = {
    d.id: d for d in (
        DeviceType("ultrasonic", "Ultrasonic distance sensor", DIRECTION_IN, (
            ChannelSpec("distance_mm", "distance", 0, 2550, unit="mm"),
        ), description="EV3 ultrasonic: 0..255 cm; 255 cm means no echo."),
        DeviceType("infrared", "Infrared sensor", DIRECTION_IN, (
            ChannelSpec("proximity", "proximity", 0, 100),
        )),
        DeviceType("color", "Colour sensor", DIRECTION_IN, (
            ChannelSpec("reflect", "reflected light", 0, 100),
            ChannelSpec("ambient", "ambient light", 0, 100),
            ChannelSpec("color_id", "colour", 0, 7, integer_only=True),
        ), description="color_id: 0 none, 1 black, 2 blue, 3 green, 4 yellow, 5 red, 6 white, 7 brown."),
        DeviceType("gyro", "Gyro sensor", DIRECTION_IN, (
            ChannelSpec("angle_deg", "angle", -32768, 32767, unit="deg"),
            ChannelSpec("rate_dps", "turn rate", -440, 440, unit="deg/s"),
        ), description="Clockwise is positive, as on the EV3."),
        DeviceType("touch", "Touch sensor", DIRECTION_IN, (
            ChannelSpec("pressed", "pressed", 0, 1, integer_only=True),
        )),
        _motor("large_motor", "Large motor", 1050),
        _motor("medium_motor", "Medium motor", 1560),
    )
}


@dataclass
class PortIR:
    id: str
    label: str
    direction: str
    device: str = ""
    #: True when the robot reported the device; False when the user set it.
    detected: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return {"id": self.id, "label": self.label, "direction": self.direction,
                "device": self.device, "detected": self.detected}

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "PortIR":
        return PortIR(str(data.get("id", "")), str(data.get("label", "")), str(data.get("direction", "")),
                      str(data.get("device", "") or ""), bool(data.get("detected", False)))


@dataclass
class SensorPose:
    """Where a sensor sits on the robot and where it points.

    ``angle_deg`` is measured from straight ahead, positive to the LEFT
    (counter-clockwise seen from above), which is the convention the model's
    rays use (ray 0 is the leftmost). ``x_cm`` is forward of the robot's
    turning centre, ``y_cm`` to the left.
    """

    angle_deg: float = 0.0
    x_cm: float = 0.0
    y_cm: float = 0.0
    #: The spot on the window's drawing the sensor was put on ("front", "left", ...).
    spot: str = ""

    def to_dict(self) -> Dict[str, Any]:
        out: Dict[str, Any] = {"angle_deg": self.angle_deg, "x_cm": self.x_cm, "y_cm": self.y_cm}
        if self.spot:
            out["spot"] = self.spot
        return out

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "SensorPose":
        return SensorPose(float(data.get("angle_deg", 0.0)), float(data.get("x_cm", 0.0)), float(data.get("y_cm", 0.0)),
                          str(data.get("spot", "") or ""))


@dataclass
class DriveGeometry:
    left_port: str = ""
    right_port: str = ""
    invert_left: bool = False
    invert_right: bool = False

    def to_dict(self) -> Dict[str, Any]:
        return {"left_port": self.left_port, "right_port": self.right_port,
                "invert_left": self.invert_left, "invert_right": self.invert_right}

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "DriveGeometry":
        return DriveGeometry(str(data.get("left_port", "")), str(data.get("right_port", "")),
                             bool(data.get("invert_left", False)), bool(data.get("invert_right", False)))


@dataclass
class Geometry:
    sensors: Dict[str, SensorPose] = field(default_factory=dict)
    drive: Optional[DriveGeometry] = None
    wheel_diameter_cm: Optional[float] = None
    track_cm: Optional[float] = None
    chassis_preset: str = ""
    #: The robot's length: every conversion between the training world and the
    #: room is taken from it (see odometry.cm_per_unit_for).
    length_cm: Optional[float] = None
    #: Every drive motor of each side, found by the wheel check:
    #: {"left": [{"port", "invert"}], "right": [...]}. ``drive`` names the first of each.
    drive_sides: Optional[Dict[str, List[Dict[str, Any]]]] = None
    #: Where the robot's heading comes from: "wheels" or a gyro port ("in1").
    heading: str = ""

    def to_dict(self) -> Dict[str, Any]:
        return {
            "sensors": {port: pose.to_dict() for port, pose in self.sensors.items()},
            "drive": self.drive.to_dict() if self.drive else None,
            "wheel_diameter_cm": self.wheel_diameter_cm,
            "track_cm": self.track_cm,
            "chassis_preset": self.chassis_preset,
            "length_cm": self.length_cm,
            "drive_sides": self.drive_sides,
            "heading": self.heading,
        }

    @staticmethod
    def from_dict(data: Optional[Dict[str, Any]]) -> "Geometry":
        data = data or {}
        drive = data.get("drive")
        return Geometry(
            sensors={str(k): SensorPose.from_dict(v or {}) for k, v in (data.get("sensors") or {}).items()},
            drive=DriveGeometry.from_dict(drive) if isinstance(drive, dict) else None,
            wheel_diameter_cm=_optional_float(data.get("wheel_diameter_cm")),
            track_cm=_optional_float(data.get("track_cm")),
            chassis_preset=str(data.get("chassis_preset", "") or ""),
            length_cm=_optional_float(data.get("length_cm")),
            drive_sides=_drive_sides(data.get("drive_sides")),
            heading=str(data.get("heading", "") or ""),
        )


def _drive_sides(value: Any) -> Optional[Dict[str, List[Dict[str, Any]]]]:
    if not isinstance(value, dict):
        return None
    sides: Dict[str, List[Dict[str, Any]]] = {}
    for side in ("left", "right"):
        motors = value.get(side)
        sides[side] = [{"port": str(m.get("port", "")), "invert": bool(m.get("invert", False))}
                       for m in motors if isinstance(m, dict) and m.get("port")] if isinstance(motors, list) else []
    return sides


def _optional_float(value: Any) -> Optional[float]:
    return None if value is None else float(value)


@dataclass
class RobotIR:
    robot_id: str
    platform: str
    name: str
    model: str = ""
    transport: str = ""
    status: str = "unknown"
    battery_pct: Optional[int] = None
    #: {"rssi_dbm": int, "distance_m": float} when the link can measure it.
    proximity: Optional[Dict[str, Any]] = None
    ports: List[PortIR] = field(default_factory=list)
    capabilities: List[str] = field(default_factory=list)
    geometry: Geometry = field(default_factory=Geometry)

    def port(self, port_id: str) -> Optional[PortIR]:
        for port in self.ports:
            if port.id == port_id:
                return port
        return None

    def to_dict(self) -> Dict[str, Any]:
        return {
            "schema_version": IR_SCHEMA_VERSION,
            "robot_id": self.robot_id,
            "platform": self.platform,
            "name": self.name,
            "model": self.model,
            "transport": self.transport,
            "status": self.status,
            "battery_pct": self.battery_pct,
            "proximity": dict(self.proximity) if self.proximity else None,
            "ports": [port.to_dict() for port in self.ports],
            "capabilities": list(self.capabilities),
            "geometry": self.geometry.to_dict(),
        }

    @staticmethod
    def from_dict(data: Dict[str, Any]) -> "RobotIR":
        battery = data.get("battery_pct")
        return RobotIR(
            robot_id=str(data.get("robot_id", "")),
            platform=str(data.get("platform", "")),
            name=str(data.get("name", "")),
            model=str(data.get("model", "") or ""),
            transport=str(data.get("transport", "") or ""),
            status=str(data.get("status", "unknown") or "unknown"),
            battery_pct=None if battery is None else int(battery),
            proximity=dict(data["proximity"]) if isinstance(data.get("proximity"), dict) else None,
            ports=[PortIR.from_dict(p) for p in data.get("ports") or [] if isinstance(p, dict)],
            capabilities=[str(c) for c in data.get("capabilities") or []],
            geometry=Geometry.from_dict(data.get("geometry")),
        )


# ---------------------------------------------------------------------------
# Channels
# ---------------------------------------------------------------------------

def channel_id(port_id: str, suffix: str) -> str:
    return "%s.%s" % (port_id, suffix)


def split_channel_id(channel: str) -> tuple:
    port_id, _, suffix = str(channel).partition(".")
    return port_id, suffix


def channels_for(ir: RobotIR) -> tuple:
    """(sensor channels, actuator channels) the robot's devices expose."""
    sensors: List[SensorChannel] = []
    actuators: List[ActuatorChannel] = []
    for port in ir.ports:
        device = DEVICE_TYPES.get(port.device)
        if device is None:
            continue
        for spec in device.channels:
            label = "%s %s (%s)" % (device.label, spec.label, port.label)
            if spec.direction == DIRECTION_OUT:
                actuators.append(ActuatorChannel(
                    channel_id(port.id, spec.suffix), label, spec.native_min, spec.native_max,
                    unit=spec.unit, integer_only=spec.integer_only, group=port.id, safe_value=spec.safe_value,
                ))
            else:
                sensors.append(SensorChannel(
                    channel_id(port.id, spec.suffix), label, spec.native_min, spec.native_max,
                    unit=spec.unit, integer_only=spec.integer_only, group=port.id,
                ))
    return sensors, actuators


def platform_from_ir(ir: RobotIR, *, max_rate_hz: int = 30, default_watchdog_ms: int = 400) -> Platform:
    """A :class:`Platform` view of one robot, for the mapping config.

    IR robots run no generated device program (the driver talks to the hardware
    directly from the host), so the platform has no template and nothing to
    deploy.
    """
    sensors, actuators = channels_for(ir)
    transport = ir.transport or TRANSPORT_VIRTUAL
    return Platform(
        ir.platform,
        ir.name or ir.platform,
        sensors=sensors,
        actuators=actuators,
        transports=[transport],
        default_transport=transport,
        template="",
        default_rate_hz=20,
        max_rate_hz=max_rate_hz,
        default_watchdog_ms=default_watchdog_ms,
        script_filename="",
        deploy={"method": "none", "automated": True,
                "reason": "The host drives this robot directly; nothing is copied onto it."},
    )


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_ir(data: Any) -> ValidationReport:
    """Check an IR dict, collecting every problem."""
    report = ValidationReport()
    if not isinstance(data, dict):
        report.error(ERR_BAD_CONFIG, "The robot description must be a dictionary.", field="robot")
        return report
    if int(data.get("schema_version", IR_SCHEMA_VERSION) or 0) > IR_SCHEMA_VERSION:
        report.error(ERR_BAD_CONFIG, "This robot description was written by a newer version of Neuralese.",
                     field="robot.schema_version")
        return report
    for key in ("robot_id", "platform"):
        if not str(data.get(key, "")).strip():
            report.error(ERR_BAD_CONFIG, "The robot description has no %s." % key, field="robot.%s" % key)

    ir = RobotIR.from_dict(data)
    seen: Dict[str, int] = {}
    for index, port in enumerate(ir.ports):
        where = "robot.ports[%d]" % index
        if not port.id:
            report.error(ERR_BAD_CONFIG, "A port has no id.", field=where)
            continue
        if port.id in seen:
            report.error(ERR_BAD_CONFIG, "Port %s is listed twice." % port.label, field=where)
        seen[port.id] = index
        if port.direction not in (DIRECTION_IN, DIRECTION_OUT):
            report.error(ERR_BAD_CONFIG, "Port %s has no direction." % port.label, field=where + ".direction")
        if not port.device:
            continue
        device = DEVICE_TYPES.get(port.device)
        if device is None:
            report.error(ERR_BAD_CONFIG, "Unknown device '%s' on port %s." % (port.device, port.label),
                         field=where + ".device")
        elif device.port_direction != port.direction:
            report.error(ERR_BAD_CONFIG, "A %s cannot sit in port %s." % (device.label.lower(), port.label),
                         field=where + ".device")

    drive = ir.geometry.drive
    if drive is not None:
        for side in ("left", "right"):
            port_id = getattr(drive, side + "_port")
            port = ir.port(port_id)
            if not port_id:
                report.error(ERR_BAD_CONFIG, "Choose the %s motor." % side, field="robot.geometry.drive.%s_port" % side)
            elif port is None or port.device not in ("large_motor", "medium_motor"):
                report.error(ERR_BAD_CONFIG, "Port %s has no motor for the %s wheel." % (port_id, side),
                             field="robot.geometry.drive.%s_port" % side)
        if drive.left_port and drive.left_port == drive.right_port:
            report.error(ERR_BAD_CONFIG, "The left and right wheel cannot be the same motor.",
                         field="robot.geometry.drive")
    for port_id in ir.geometry.sensors:
        port = ir.port(port_id)
        if port is None or port.direction != DIRECTION_IN:
            report.error(ERR_BAD_CONFIG, "A sensor position is set for %s, which is not a sensor port." % port_id,
                         field="robot.geometry.sensors.%s" % port_id)
    return report
