"""The input/output mapping config: schema, defaults, validation, and the math.

This module is deliberately free of numpy, onnx and every other heavy import, so
the UI can validate a config and preview the mapping without the runtime being
installed, and so the fast test tier needs no dependencies at all.

The config is a plain dict, JSON round-trippable, versioned::

    {
      "schema_version": 1,
      "platform": "ev3",
      "transport": {"kind": "tcp", "host": "ev3dev.local", "port": 9999},
      "rate_hz": 20,
      "watchdog_ms": 400,
      "inputs": [
        {"channel": "ultrasonic_4",
         "scale": {"kind": "linear", "in_min": 0, "in_max": 2550,
                   "out_min": 0.0, "out_max": 1.0}}
      ],
      "outputs": [
        {"channel": "motor_a_speed", "mode": "argmax",
         "classes": {"0": 60, "1": -60, "2": 0}}
      ]
    }

``inputs`` is ordered: entry *i* becomes element *i* of the model input vector,
and element *i* of the sensor frame on the wire. ``outputs`` is ordered the same
way against the actuator frame.

Why scaling lives here and not on the robot
-------------------------------------------
The device sends raw native integers and receives final native integers. All
float work happens on the host. That means the device script is identical for
every model, a micro:bit never parses a float, and -- most importantly -- the
scaling that has to match how the model was *trained* is derived once, here,
from the dataset's own column ranges, instead of being retyped by a child.
"""

from __future__ import annotations

import hashlib
import json
from typing import Any, Dict, List, Optional, Sequence, Tuple

import dataclasses

from .codec import MAX_LINE_BYTES, SEQ_MOD
from .drive import DriveController, DriveParams
from .errors import (
    ERR_ARITY_MISMATCH,
    ERR_BAD_CONFIG,
    ERR_UNKNOWN_CHANNEL,
    ERR_UNSUPPORTED_TRANSPORT,
    ConfigError,
    ValidationReport,
)
from .ir import TRANSPORT_REPLAY, TRANSPORT_VIRTUAL, RobotIR, platform_from_ir, validate_ir
from .odometry import (
    GOAL_QUANTITIES,
    HEADING_GYRO,
    HEADING_WHEELS,
    QUANTITIES,
    Odometry,
    OdometrySetup,
    World,
)
from .platforms import TRANSPORT_BLE, TRANSPORT_SERIAL, TRANSPORT_TCP, Platform, get_platform, is_ir_platform

SCHEMA_VERSION = 1

MODE_DIRECT = "direct"
MODE_ARGMAX = "argmax"
MODE_THRESHOLD = "threshold"
#: Two model outputs (steer, throttle, optionally brake) -> two motors, through
#: :class:`.drive.DriveController`. Occupies two actuator slots on the wire.
MODE_DRIVE = "drive"
OUTPUT_MODES = (MODE_DIRECT, MODE_ARGMAX, MODE_THRESHOLD, MODE_DRIVE)

#: An input entry with ``"derive": "ray"`` is one model input computed from
#: several distance sensors: each reading is scaled and clamped, then the values
#: are interpolated at the ray's angle. This is the prototype's
#: ``SensorAdapter3to8``, which fed the model on the real robot.
DERIVE_RAY = "ray"
#: An input entry with ``"derive": "pose", "quantity": ...`` is one channel of a
#: simulation sensor that the robot cannot measure directly -- its speed,
#: rotation, place in the world, the way to the goal -- computed from the wheel
#: encoders (and a gyro) by :mod:`.odometry`, with the simulation's own formulas.
#: Needs the config's ``"world"`` and ``"odometry"`` sections.
DERIVE_POSE = "pose"
DERIVE_KINDS = (DERIVE_RAY, DERIVE_POSE)

_DRIVE_PARAM_NAMES = frozenset(f.name for f in dataclasses.fields(DriveParams))


def resolve_platform(config: Dict[str, Any]) -> Platform:
    """The platform a config targets.

    Fixed robots come from the registry. IR robots (Dummy, stock-firmware EV3)
    are described by the config's own ``"robot"`` IR, because their channels are
    whatever is plugged into that particular robot.
    """
    platform_id = str(config.get("platform", ""))
    if not is_ir_platform(platform_id):
        return get_platform(platform_id)
    robot = config.get("robot")
    if not isinstance(robot, dict):
        raise ConfigError("This robot needs its description (the 'robot' section).", field="robot")
    ir = RobotIR.from_dict(robot)
    if ir.platform != platform_id:
        raise ConfigError(
            "The robot description is for '%s', but the config targets '%s'." % (ir.platform, platform_id),
            field="robot.platform",
        )
    return platform_from_ir(ir)

SCALE_LINEAR = "linear"
SCALE_IDENTITY = "identity"
SCALE_KINDS = (SCALE_LINEAR, SCALE_IDENTITY)

MIN_RATE_HZ = 1
MIN_WATCHDOG_MS = 50
MAX_WATCHDOG_MS = 5000


def clamp(value: float, low: float, high: float) -> float:
    if low > high:
        low, high = high, low
    if value < low:
        return low
    if value > high:
        return high
    return value


# ---------------------------------------------------------------------------
# Scaling
# ---------------------------------------------------------------------------

def linear_scale(in_min: float, in_max: float, out_min: float, out_max: float) -> Dict[str, Any]:
    return {
        "kind": SCALE_LINEAR,
        "in_min": float(in_min),
        "in_max": float(in_max),
        "out_min": float(out_min),
        "out_max": float(out_max),
    }


def identity_scale() -> Dict[str, Any]:
    return {"kind": SCALE_IDENTITY}


def apply_scale(scale: Dict[str, Any], value: float) -> float:
    kind = str(scale.get("kind", SCALE_IDENTITY))
    if kind == SCALE_IDENTITY:
        return float(value)
    in_min = float(scale.get("in_min", 0.0))
    in_max = float(scale.get("in_max", 1.0))
    out_min = float(scale.get("out_min", 0.0))
    out_max = float(scale.get("out_max", 1.0))
    span = in_max - in_min
    if span == 0.0:
        # A degenerate range would divide by zero. Collapsing to the low end of
        # the output range is the inert choice: for a motor that is "stopped".
        return out_min
    ratio = (float(value) - in_min) / span
    return out_min + ratio * (out_max - out_min)


def invert_scale(scale: Dict[str, Any]) -> Dict[str, Any]:
    """The same linear map read backwards, for the model -> actuator direction."""
    if str(scale.get("kind", SCALE_IDENTITY)) == SCALE_IDENTITY:
        return identity_scale()
    return linear_scale(
        float(scale.get("out_min", 0.0)),
        float(scale.get("out_max", 1.0)),
        float(scale.get("in_min", 0.0)),
        float(scale.get("in_max", 1.0)),
    )


# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------

def _column_range(column: Dict[str, Any]) -> Optional[Tuple[float, float]]:
    """The value range a training column actually occupied, if it is known."""
    if not isinstance(column, dict):
        return None
    low = column.get("min")
    high = column.get("max")
    if low is None or high is None:
        return None
    try:
        low_f, high_f = float(low), float(high)
    except (TypeError, ValueError):
        return None
    if low_f == high_f:
        return None
    return (low_f, high_f)


def default_input_scale(channel, train_column: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    """Map a sensor's native range onto the range the model was trained on.

    This is the single most important function in the feature. The Neuralese
    trainer feeds dataset cells through essentially unchanged (numbers as-is,
    image bytes divided by 255), so "model space" *is* "dataset column space".
    If a sensor reports 0..2550 mm but the model only ever saw 0..100, the robot
    behaves randomly and nothing anywhere reports an error -- so when the column
    range is known we build the map from it, and when it is not we fall back to
    identity and make the caller warn about it.
    """
    column_range = _column_range(train_column or {})
    if column_range is None:
        return identity_scale()
    out_min, out_max = column_range
    return linear_scale(channel.native_min, channel.native_max, out_min, out_max)


def default_transport(platform_id: str) -> Dict[str, Any]:
    platform = get_platform(platform_id)
    kind = platform.default_transport
    if kind == TRANSPORT_SERIAL:
        # `port` empty means "autodetect": the UI can offer a picker, and the
        # bridge falls back to scanning for a plausible device.
        return {"kind": TRANSPORT_SERIAL, "port": "", "baud": 115200}
    if kind == TRANSPORT_TCP:
        return {"kind": TRANSPORT_TCP, "host": "ev3dev.local", "port": 9999}
    return {"kind": TRANSPORT_BLE, "address": ""}


def default_config(
    platform_id: str,
    model_meta: Optional[Dict[str, Any]] = None,
    train_signature: Optional[Dict[str, Any]] = None,
    report: Optional[ValidationReport] = None,
) -> Dict[str, Any]:
    """Build a ready-to-run config, guessing sensibly so the child sees a
    working default rather than an empty form.

    ``model_meta`` comes from :mod:`.model_meta` (``input_size``/``output_size``).
    ``train_signature`` is optional dataset metadata::

        {"input_columns":  [{"name": "distance", "min": 0, "max": 100}, ...],
         "output_columns": [{"name": "action", "classes": ["go", "left"]}]}

    Everything it produces is overridable; nothing here is load-bearing for
    correctness beyond giving good starting ranges.
    """
    platform = get_platform(platform_id)
    meta = model_meta or {}
    signature = train_signature or {}

    input_size = int(meta.get("input_size", 0) or 0)
    output_size = int(meta.get("output_size", 0) or 0)
    train_columns: List[Dict[str, Any]] = list(signature.get("input_columns", []) or [])

    inputs: List[Dict[str, Any]] = []
    for index in range(input_size):
        if index >= len(platform.sensors):
            # More model inputs than the robot has sensors. Validation reports
            # this properly; here we just stop rather than invent channels.
            break
        channel = platform.sensors[index]
        column = train_columns[index] if index < len(train_columns) else None
        scale = default_input_scale(channel, column)
        if report is not None and scale["kind"] == SCALE_IDENTITY:
            report.warn(
                "unscaled_input",
                "No training range is known for '%s', so its readings are sent to the "
                "model unchanged. Check that the sensor's range matches the data the "
                "model was trained on." % channel.label,
                field="inputs[%d]" % index,
                channel=channel.id,
            )
        inputs.append({"channel": channel.id, "scale": scale})

    outputs: List[Dict[str, Any]] = []
    if platform.actuators and output_size > 0:
        if output_size > 1:
            # More than one model output is overwhelmingly a classifier in this
            # product, and "pick the winning class, then do the thing" is the
            # mental model a child already has.
            channel = platform.actuators[0]
            outputs.append({
                "channel": channel.id,
                "mode": MODE_ARGMAX,
                "classes": {str(i): _default_class_value(channel, i, output_size) for i in range(output_size)},
            })
        else:
            channel = platform.actuators[0]
            outputs.append({
                "channel": channel.id,
                "mode": MODE_DIRECT,
                "index": 0,
                "scale": linear_scale(0.0, 1.0, channel.native_min, channel.native_max),
            })

    return {
        "schema_version": SCHEMA_VERSION,
        "platform": platform.id,
        "transport": default_transport(platform.id),
        "rate_hz": platform.default_rate_hz,
        "watchdog_ms": platform.default_watchdog_ms,
        "inputs": inputs,
        "outputs": outputs,
    }


def _default_class_value(channel, class_index: int, class_count: int) -> int:
    """Spread class indices across the actuator's range.

    For a 3-class model on a motor this gives full reverse / stop / full
    forward, which is a demonstrably sensible first behaviour to watch.
    """
    if class_count <= 1:
        return int(channel.safe_value)
    ratio = class_index / float(class_count - 1)
    return int(round(channel.native_min + ratio * (channel.native_max - channel.native_min)))


# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate_config(config: Dict[str, Any], model_meta: Optional[Dict[str, Any]] = None) -> ValidationReport:
    """Check a config top to bottom, collecting every problem.

    Passing ``model_meta`` additionally checks the config against the real
    model's input/output arity, which is the check that catches "the child
    retrained with an extra column and the old mapping is now wrong".
    """
    report = ValidationReport()

    if not isinstance(config, dict):
        report.error(ERR_BAD_CONFIG, "The robot config must be a dictionary.")
        return report

    version = config.get("schema_version", SCHEMA_VERSION)
    if int(version or 0) > SCHEMA_VERSION:
        report.error(
            ERR_BAD_CONFIG,
            "This robot config was written by a newer version of Neuralese "
            "(schema %s, this build understands %s)." % (version, SCHEMA_VERSION),
            field="schema_version",
        )
        return report

    is_ir = is_ir_platform(config.get("platform", ""))
    if is_ir:
        robot_report = validate_ir(config.get("robot"))
        report.errors.extend(robot_report.errors)
        report.warnings.extend(robot_report.warnings)
        if not robot_report.ok:
            return report

    try:
        platform = resolve_platform(config)
    except Exception as exc:  # RobotError, but keep validation total
        report.error(getattr(exc, "code", ERR_BAD_CONFIG), str(exc), field=getattr(exc, "field", "") or "platform")
        return report

    _validate_transport(config.get("transport"), platform, report)
    _validate_timing(config, platform, report)
    _validate_inputs(config.get("inputs"), platform, report, allow_derived=is_ir, config=config)
    _validate_outputs(config.get("outputs"), platform, report)
    if not is_ir:
        # Host-driven robots are read and driven directly (runtime.py): there
        # is no NLR/1 line whose length could overflow.
        _validate_frame_size(config, platform, report)
    _validate_hardware_conflicts(config, platform, report)

    if model_meta:
        _validate_against_model(config, model_meta, report)

    return report


def _validate_transport(transport: Any, platform, report: ValidationReport) -> None:
    if not isinstance(transport, dict):
        report.error(ERR_BAD_CONFIG, "The transport section is missing.", field="transport")
        return
    kind = str(transport.get("kind", ""))
    if kind not in platform.transports:
        report.error(
            ERR_UNSUPPORTED_TRANSPORT,
            "%s cannot connect over '%s'. Supported: %s."
            % (platform.label, kind or "(none)", ", ".join(platform.transports)),
            field="transport.kind",
            supported=list(platform.transports),
        )
        return
    if kind == TRANSPORT_TCP and not str(transport.get("host", "")).strip():
        report.error(ERR_BAD_CONFIG, "A TCP link needs the robot's address.", field="transport.host")
    if kind == TRANSPORT_SERIAL:
        baud = transport.get("baud", 115200)
        if not isinstance(baud, int) or baud <= 0:
            report.error(ERR_BAD_CONFIG, "Serial baud rate must be a positive whole number.", field="transport.baud")
    if kind == TRANSPORT_REPLAY and not str(transport.get("log", "")).strip():
        report.error(ERR_BAD_CONFIG, "A replay needs the recorded run to play.", field="transport.log")


def _validate_timing(config: Dict[str, Any], platform, report: ValidationReport) -> None:
    rate = config.get("rate_hz", platform.default_rate_hz)
    if not isinstance(rate, int) or rate < MIN_RATE_HZ:
        report.error(ERR_BAD_CONFIG, "Update rate must be a whole number of hertz, at least %d." % MIN_RATE_HZ, field="rate_hz")
    elif rate > platform.max_rate_hz:
        report.error(
            ERR_BAD_CONFIG,
            "%s cannot keep up with %d Hz; the maximum is %d Hz." % (platform.label, rate, platform.max_rate_hz),
            field="rate_hz",
            max_rate_hz=platform.max_rate_hz,
        )

    watchdog = config.get("watchdog_ms", platform.default_watchdog_ms)
    if not isinstance(watchdog, int) or not MIN_WATCHDOG_MS <= watchdog <= MAX_WATCHDOG_MS:
        report.error(
            ERR_BAD_CONFIG,
            "The safety timeout must be between %d and %d milliseconds." % (MIN_WATCHDOG_MS, MAX_WATCHDOG_MS),
            field="watchdog_ms",
        )
    elif isinstance(rate, int) and rate >= MIN_RATE_HZ and watchdog < (2000 // rate):
        # Shorter than two update periods and ordinary jitter trips the
        # watchdog, so the robot stutters to a halt on a perfectly healthy link.
        report.warn(
            "watchdog_too_tight",
            "A %d ms safety timeout at %d Hz will trip on normal delays. "
            "At least %d ms is recommended." % (watchdog, rate, 2000 // rate),
            field="watchdog_ms",
            recommended_ms=2000 // rate,
        )


def _validate_scale(scale: Any, field: str, report: ValidationReport) -> None:
    if scale is None:
        return
    if not isinstance(scale, dict):
        report.error(ERR_BAD_CONFIG, "Scaling must be a dictionary.", field=field)
        return
    kind = str(scale.get("kind", SCALE_IDENTITY))
    if kind not in SCALE_KINDS:
        report.error(ERR_BAD_CONFIG, "Unknown scaling type '%s'." % kind, field=field + ".kind")
        return
    if kind == SCALE_LINEAR:
        for key in ("in_min", "in_max", "out_min", "out_max"):
            value = scale.get(key)
            if not isinstance(value, (int, float)) or isinstance(value, bool):
                report.error(ERR_BAD_CONFIG, "Scaling value '%s' must be a number." % key, field="%s.%s" % (field, key))
                return
        if float(scale["in_min"]) == float(scale["in_max"]):
            report.error(
                ERR_BAD_CONFIG,
                "Scaling input range is empty (min and max are both %s)." % scale["in_min"],
                field=field,
            )


def _validate_ray_input(entry: Dict[str, Any], field: str, platform, report: ValidationReport) -> None:
    angle = entry.get("angle_deg")
    if not isinstance(angle, (int, float)) or isinstance(angle, bool):
        report.error(ERR_BAD_CONFIG, "A ray needs its angle.", field=field + ".angle_deg")
    sources = entry.get("sources")
    if not isinstance(sources, list) or not sources:
        report.error(ERR_BAD_CONFIG, "A ray needs at least one distance sensor.", field=field + ".sources")
        return
    seen = set()
    for source_index, source in enumerate(sources):
        where = "%s.sources[%d]" % (field, source_index)
        if not isinstance(source, dict):
            report.error(ERR_BAD_CONFIG, "Each ray source must be a dictionary.", field=where)
            continue
        channel_id = str(source.get("channel", ""))
        if platform.sensor(channel_id) is None:
            report.error(ERR_UNKNOWN_CHANNEL, "%s has no sensor called '%s'." % (platform.label, channel_id),
                         field=where + ".channel", channel=channel_id, available=[c.id for c in platform.sensors])
        source_angle = source.get("angle_deg")
        if not isinstance(source_angle, (int, float)) or isinstance(source_angle, bool):
            report.error(ERR_BAD_CONFIG, "Each ray source needs the angle its sensor points at.", field=where + ".angle_deg")
        elif float(source_angle) in seen:
            report.error(ERR_BAD_CONFIG, "Two sensors of one ray point at the same angle.", field=where + ".angle_deg")
        else:
            seen.add(float(source_angle))
    scale = entry.get("scale")
    if not isinstance(scale, dict) or str(scale.get("kind", "")) != SCALE_LINEAR:
        report.error(ERR_BAD_CONFIG, "A ray needs a linear scale from the sensor's units to the model's.", field=field + ".scale")
    else:
        _validate_scale(scale, field + ".scale", report)


def _validate_inputs(inputs: Any, platform, report: ValidationReport, allow_derived: bool = False,
                     config: Optional[Dict[str, Any]] = None) -> None:
    if not isinstance(inputs, list):
        report.error(ERR_BAD_CONFIG, "The inputs section must be a list.", field="inputs")
        return
    if not inputs:
        report.error(ERR_BAD_CONFIG, "At least one sensor has to be connected to the model.", field="inputs")
        return
    pose_quantities: List[str] = []
    for index, entry in enumerate(inputs):
        field = "inputs[%d]" % index
        if not isinstance(entry, dict):
            report.error(ERR_BAD_CONFIG, "Each input must be a dictionary.", field=field)
            continue
        derive = entry.get("derive")
        if derive is not None:
            if str(derive) not in DERIVE_KINDS:
                report.error(ERR_BAD_CONFIG, "Unknown derived input '%s'." % derive, field=field + ".derive")
            elif not allow_derived:
                # A device script would have to compute this on the robot.
                report.error(ERR_BAD_CONFIG, "%s cannot compute this input on the robot." % platform.label, field=field + ".derive")
            elif str(derive) == DERIVE_RAY:
                _validate_ray_input(entry, field, platform, report)
            else:
                quantity = str(entry.get("quantity", ""))
                if quantity not in QUANTITIES:
                    report.error(ERR_BAD_CONFIG, "Unknown robot movement input '%s'." % quantity, field=field + ".quantity")
                else:
                    pose_quantities.append(quantity)
            continue
        channel_id = str(entry.get("channel", ""))
        if platform.sensor(channel_id) is None:
            report.error(
                ERR_UNKNOWN_CHANNEL,
                "%s has no sensor called '%s'." % (platform.label, channel_id),
                field=field + ".channel",
                channel=channel_id,
                available=[c.id for c in platform.sensors],
            )
            continue
        _validate_scale(entry.get("scale"), field + ".scale", report)
    if pose_quantities:
        _validate_pose_setup(config or {}, platform, report, pose_quantities)


def _is_number(value: Any) -> bool:
    return isinstance(value, (int, float)) and not isinstance(value, bool)


def _validate_pose_setup(config: Dict[str, Any], platform, report: ValidationReport, quantities: List[str]) -> None:
    """The world and the wheels that inputs computed from the robot's movement need."""
    world = config.get("world")
    if not isinstance(world, dict):
        report.error(ERR_BAD_CONFIG, "Inputs computed from the robot's movement need the world it was trained in.", field="world")
    else:
        if not _is_number(world.get("cm_per_unit")) or float(world["cm_per_unit"]) <= 0:
            report.error(ERR_BAD_CONFIG, "The world needs its scale: centimetres per simulation unit.", field="world.cm_per_unit")
        bounds = world.get("bounds")
        if bounds is not None and (not isinstance(bounds, list) or len(bounds) != 4 or not all(_is_number(v) for v in bounds)
                                   or float(bounds[2]) <= 0 or float(bounds[3]) <= 0):
            report.error(ERR_BAD_CONFIG, "The world's bounds must be x, y, width, height.", field="world.bounds")
        start = world.get("start")
        if start is not None and (not isinstance(start, list) or len(start) != 3 or not all(_is_number(v) for v in start)):
            report.error(ERR_BAD_CONFIG, "The start must be x, y and a heading.", field="world.start")
        goal = world.get("goal")
        if any(q in GOAL_QUANTITIES for q in quantities):
            if not isinstance(goal, list) or len(goal) != 2 or not all(_is_number(v) for v in goal):
                report.error(ERR_BAD_CONFIG, "This network looks for a goal: set where the goal is.", field="world.goal")
    odometry = config.get("odometry")
    if not isinstance(odometry, dict):
        report.error(ERR_BAD_CONFIG, "Inputs computed from the robot's movement need its wheels (check the wheels).", field="odometry")
        return
    for side in ("left", "right"):
        entries = odometry.get(side)
        if not isinstance(entries, list) or not entries:
            report.error(ERR_BAD_CONFIG, "The %s wheel's motor is not known (check the wheels)." % side, field="odometry." + side)
            continue
        for index, item in enumerate(entries):
            channel_id = str(item.get("channel", "")) if isinstance(item, dict) else str(item)
            if platform.sensor(channel_id) is None or not channel_id.endswith(".position_deg"):
                report.error(ERR_UNKNOWN_CHANNEL, "%s cannot count the turns of '%s'." % (platform.label, channel_id),
                             field="odometry.%s[%d]" % (side, index), channel=channel_id)
    for key, what in (("wheel_diameter_cm", "wheel size"), ("track_cm", "distance between the wheels")):
        if not _is_number(odometry.get(key)) or float(odometry[key]) <= 0:
            report.error(ERR_BAD_CONFIG, "The %s is not set." % what, field="odometry." + key)
    heading = odometry.get("heading") or {}
    source = str(heading.get("source", HEADING_WHEELS)) if isinstance(heading, dict) else ""
    if source not in (HEADING_GYRO, HEADING_WHEELS):
        report.error(ERR_BAD_CONFIG, "The heading comes from a gyro or from the wheels.", field="odometry.heading.source")
    elif source == HEADING_GYRO:
        channel_id = str(heading.get("channel", ""))
        if platform.sensor(channel_id) is None or not channel_id.endswith(".angle_deg"):
            report.error(ERR_UNKNOWN_CHANNEL, "%s has no gyro called '%s'." % (platform.label, channel_id),
                         field="odometry.heading.channel", channel=channel_id)


def _is_index(value: Any) -> bool:
    return isinstance(value, int) and not isinstance(value, bool) and value >= 0


def drive_sides(entry: Dict[str, Any]) -> Tuple[List[str], List[str], List[bool], List[bool]]:
    """The motors of a drive output, per side, and which of them turn the other way.

    ``channels`` is ``[left, right]``; each side is one channel or a list of
    channels (several motors on one side get the same power). ``invert`` has
    the same shape, or one flag per side for all its motors.
    """
    channels = entry.get("channels") or [[], []]
    invert = entry.get("invert", [False, False])

    def as_list(value: Any) -> List[str]:
        return [str(v) for v in value] if isinstance(value, list) else [str(value)]

    left = as_list(channels[0]) if len(channels) > 0 else []
    right = as_list(channels[1]) if len(channels) > 1 else []
    flags = []
    for side, motors in ((0, left), (1, right)):
        value = invert[side] if isinstance(invert, list) and len(invert) > side else False
        flags.append([bool(v) for v in value] if isinstance(value, list) else [bool(value)] * len(motors))
    return left, right, flags[0], flags[1]


def _validate_drive_output(entry: Dict[str, Any], field: str, platform, report: ValidationReport) -> None:
    channels = entry.get("channels")
    if not isinstance(channels, list) or len(channels) != 2 or any(isinstance(c, list) and not c for c in channels):
        report.error(ERR_BAD_CONFIG, "Driving needs motors on both sides: left and right.", field=field + ".channels")
    else:
        left, right, _, _ = drive_sides(entry)
        for side, motors in (("left", left), ("right", right)):
            for channel_id in motors:
                channel = platform.actuator(channel_id)
                if channel is None:
                    report.error(ERR_UNKNOWN_CHANNEL, "%s has no motor called '%s'." % (platform.label, channel_id),
                                 field="%s.channels.%s" % (field, side), channel=channel_id,
                                 available=[c.id for c in platform.actuators])
                elif channel.native_min > -100 or channel.native_max < 100:
                    report.error(ERR_BAD_CONFIG, "'%s' cannot take motor power from -100 to 100." % channel.label,
                                 field="%s.channels.%s" % (field, side))
        if len(set(left + right)) != len(left + right):
            report.error(ERR_BAD_CONFIG, "The left and right wheel cannot be the same motor.", field=field + ".channels")
    for key in ("steer_index", "throttle_index"):
        if not _is_index(entry.get(key)):
            report.error(ERR_BAD_CONFIG, "Choose which model output is the %s." % key.split("_")[0],
                         field="%s.%s" % (field, key))
    brake = entry.get("brake_index")
    if brake is not None and not _is_index(brake):
        report.error(ERR_BAD_CONFIG, "The brake output must be a model output number.", field=field + ".brake_index")
    scale = entry.get("throttle_scale", 100.0)
    if not isinstance(scale, (int, float)) or isinstance(scale, bool) or scale <= 0:
        report.error(ERR_BAD_CONFIG, "Throttle scale must be a positive number.", field=field + ".throttle_scale")
    invert = entry.get("invert", [False, False])
    if not isinstance(invert, list) or len(invert) != 2 or not all(
            isinstance(v, bool) or (isinstance(v, list) and all(isinstance(f, bool) for f in v)) for v in invert):
        report.error(ERR_BAD_CONFIG, "Motor reversal must be two yes/no values.", field=field + ".invert")
    params = entry.get("params", {})
    if not isinstance(params, dict):
        report.error(ERR_BAD_CONFIG, "Driving parameters must be a dictionary.", field=field + ".params")
    else:
        for key, value in params.items():
            if key not in _DRIVE_PARAM_NAMES:
                report.error(ERR_BAD_CONFIG, "Unknown driving parameter '%s'." % key, field="%s.params.%s" % (field, key))
            elif key == "wall_bypass":
                if not isinstance(value, bool):
                    report.error(ERR_BAD_CONFIG, "wall_bypass must be true or false.", field="%s.params.%s" % (field, key))
            elif not isinstance(value, (int, float)) or isinstance(value, bool):
                report.error(ERR_BAD_CONFIG, "Driving parameter '%s' must be a number." % key, field="%s.params.%s" % (field, key))
        if params.get("wall_bypass"):
            wall = entry.get("wall_inputs")
            if not isinstance(wall, dict) or not all(_is_index(wall.get(k)) for k in ("front", "left", "right")):
                report.error(ERR_BAD_CONFIG, "The wall bypass needs the front, left and right distance inputs.",
                             field=field + ".wall_inputs")


def _validate_outputs(outputs: Any, platform, report: ValidationReport) -> None:
    if not isinstance(outputs, list):
        report.error(ERR_BAD_CONFIG, "The outputs section must be a list.", field="outputs")
        return
    if not outputs:
        report.error(ERR_BAD_CONFIG, "The model has to drive at least one motor or light.", field="outputs")
        return
    for index, entry in enumerate(outputs):
        field = "outputs[%d]" % index
        if not isinstance(entry, dict):
            report.error(ERR_BAD_CONFIG, "Each output must be a dictionary.", field=field)
            continue
        if str(entry.get("mode", MODE_DIRECT)) == MODE_DRIVE:
            _validate_drive_output(entry, field, platform, report)
            continue
        channel_id = str(entry.get("channel", ""))
        channel = platform.actuator(channel_id)
        if channel is None:
            report.error(
                ERR_UNKNOWN_CHANNEL,
                "%s has no motor or light called '%s'." % (platform.label, channel_id),
                field=field + ".channel",
                channel=channel_id,
                available=[c.id for c in platform.actuators],
            )
            continue

        mode = str(entry.get("mode", MODE_DIRECT))
        if mode not in OUTPUT_MODES:
            report.error(
                ERR_BAD_CONFIG,
                "Unknown output mode '%s'. Use one of: %s." % (mode, ", ".join(OUTPUT_MODES)),
                field=field + ".mode",
            )
            continue

        if mode == MODE_DIRECT:
            model_index = entry.get("index", 0)
            if not isinstance(model_index, int) or isinstance(model_index, bool) or model_index < 0:
                report.error(ERR_BAD_CONFIG, "Output index must be a whole number of 0 or more.", field=field + ".index")
            _validate_scale(entry.get("scale"), field + ".scale", report)
        elif mode == MODE_ARGMAX:
            classes = entry.get("classes", {})
            if not isinstance(classes, dict) or not classes:
                report.error(
                    ERR_BAD_CONFIG,
                    "An 'argmax' output needs a value for each class the model can predict.",
                    field=field + ".classes",
                )
                continue
            for key, value in classes.items():
                if not str(key).lstrip("-").isdigit():
                    report.error(ERR_BAD_CONFIG, "Class key '%s' is not a class number." % key, field=field + ".classes")
                elif not isinstance(value, (int, float)) or isinstance(value, bool):
                    report.error(ERR_BAD_CONFIG, "Class '%s' must map to a number." % key, field=field + ".classes")
                elif not (channel.native_min <= float(value) <= channel.native_max):
                    report.error(
                        ERR_BAD_CONFIG,
                        "Class '%s' is set to %s, outside what %s accepts (%g to %g)."
                        % (key, value, channel.label, channel.native_min, channel.native_max),
                        field=field + ".classes",
                    )
        elif mode == MODE_THRESHOLD:
            if not isinstance(entry.get("threshold", 0.5), (int, float)) or isinstance(entry.get("threshold"), bool):
                report.error(ERR_BAD_CONFIG, "Threshold must be a number.", field=field + ".threshold")
            model_index = entry.get("index", 0)
            if not isinstance(model_index, int) or isinstance(model_index, bool) or model_index < 0:
                report.error(ERR_BAD_CONFIG, "Output index must be a whole number of 0 or more.", field=field + ".index")


def _channel_ids(entries: Any) -> List[str]:
    if not isinstance(entries, list):
        return []
    ids: List[str] = []
    for entry in entries:
        if not isinstance(entry, dict):
            continue
        if entry.get("derive") is not None:
            ids.extend(str(s.get("channel", "")) for s in entry.get("sources") or [] if isinstance(s, dict))
        elif str(entry.get("mode", "")) == MODE_DRIVE:
            left, right, _, _ = drive_sides(entry)
            ids.extend(left + right)
        else:
            ids.append(str(entry.get("channel", "")))
    return ids


def wire_input_channel_ids(inputs: Any) -> List[str]:
    """Sensor channels in the order they travel in an ``S`` frame.

    A plain input sends its own channel, in config order, as it always has. A
    ray adds the sensors it reads, each only once across the whole frame, since
    several rays share the same few sensors.
    """
    ids: List[str] = []
    for entry in inputs or []:
        if not isinstance(entry, dict):
            continue
        if entry.get("derive") is not None:
            for source in entry.get("sources") or []:
                channel_id = str(source.get("channel", "")) if isinstance(source, dict) else ""
                if channel_id not in ids:
                    ids.append(channel_id)
        else:
            ids.append(str(entry.get("channel", "")))
    return ids


def wire_output_channel_ids(outputs: Any) -> List[str]:
    """Actuator channels in the order they travel in an ``A`` frame."""
    ids: List[str] = []
    for entry in outputs or []:
        if not isinstance(entry, dict):
            continue
        if str(entry.get("mode", "")) == MODE_DRIVE:
            left, right, _, _ = drive_sides(entry)
            ids.extend(left + right)
        else:
            ids.append(str(entry.get("channel", "")))
    return ids


def _validate_hardware_conflicts(config: Dict[str, Any], platform, report: ValidationReport) -> None:
    """Warn when two mapped channels share one piece of hardware.

    A warning rather than an error: the combination works, it just works badly,
    and a child who genuinely wants it should not be blocked. But nobody should
    have to discover it by watching a screen flicker and wondering why the robot
    got worse.
    """
    inputs = set(_channel_ids(config.get("inputs")))
    outputs = set(_channel_ids(config.get("outputs")))
    for conflict in platform.conflicts:
        sensor = str(conflict.get("sensor", ""))
        if sensor not in inputs:
            continue
        clashing = [name for name in conflict.get("actuators", []) if name in outputs]
        if clashing:
            report.warn(
                "hardware_conflict",
                str(conflict.get("message", "")),
                field="outputs",
                sensor=sensor,
                actuators=clashing,
            )


def _worst_case_frame_bytes(channels: List[Any]) -> int:
    """Longest line these channels could ever produce.

    ``"S"`` + seq + one field per channel + checksum + newline, with each field
    sized by the widest number the channel's native range can print.
    """
    total = 1 + 1 + len(str(SEQ_MOD - 1)) + 1 + 4 + 1
    for channel in channels:
        widest = max(len(str(int(channel.native_min))), len(str(int(channel.native_max))))
        total += 1 + widest
    return total


def _validate_frame_size(config: Dict[str, Any], platform, report: ValidationReport) -> None:
    """Refuse a mapping whose frames would not fit on the wire.

    Caught here, at export, rather than by the codec at encode time -- which
    would mean the failure surfaces on the robot, mid-run, once a sensor happens
    to report a wide enough value.
    """
    for section, lookup, wire_ids in (
        ("inputs", platform.sensor, wire_input_channel_ids),
        ("outputs", platform.actuator, wire_output_channel_ids),
    ):
        entries = config.get(section)
        if not isinstance(entries, list):
            continue
        channels = []
        for channel_id in wire_ids(entries):
            channel = lookup(channel_id)
            if channel is not None:
                channels.append(channel)
        if not channels:
            continue
        size = _worst_case_frame_bytes(channels)
        if size > MAX_LINE_BYTES:
            report.error(
                ERR_BAD_CONFIG,
                "Too many things are connected at once: they would need %d bytes per "
                "message and the robot link allows %d. Connect fewer than %d."
                % (size, MAX_LINE_BYTES, len(channels)),
                field=section,
                bytes_needed=size,
                bytes_available=MAX_LINE_BYTES,
            )


def _validate_against_model(config: Dict[str, Any], model_meta: Dict[str, Any], report: ValidationReport) -> None:
    inputs = config.get("inputs") or []
    outputs = config.get("outputs") or []

    input_size = int(model_meta.get("input_size", 0) or 0)
    if input_size and isinstance(inputs, list) and len(inputs) != input_size:
        report.error(
            ERR_ARITY_MISMATCH,
            "The model expects %d input value(s) but %d sensor(s) are connected."
            % (input_size, len(inputs)),
            field="inputs",
            expected=input_size,
            actual=len(inputs),
        )

    output_size = int(model_meta.get("output_size", 0) or 0)
    if not output_size or not isinstance(outputs, list):
        return
    for index, entry in enumerate(outputs):
        if not isinstance(entry, dict):
            continue
        mode = str(entry.get("mode", MODE_DIRECT))
        field = "outputs[%d]" % index
        if mode == MODE_DRIVE:
            for key in ("steer_index", "throttle_index", "brake_index"):
                model_index = entry.get(key)
                if _is_index(model_index) and model_index >= output_size:
                    report.error(
                        ERR_ARITY_MISMATCH,
                        "Driving reads model value %d as the %s, but the model only produces %d."
                        % (model_index, key.split("_")[0], output_size),
                        field="%s.%s" % (field, key),
                        expected_below=output_size,
                    )
            wall = entry.get("wall_inputs")
            if input_size and isinstance(wall, dict):
                for key in ("front", "left", "right"):
                    model_index = wall.get(key)
                    if _is_index(model_index) and model_index >= input_size:
                        report.error(
                            ERR_ARITY_MISMATCH,
                            "The wall bypass reads model input %d as %s, but the model only has %d."
                            % (model_index, key, input_size),
                            field="%s.wall_inputs.%s" % (field, key),
                            expected_below=input_size,
                        )
            continue
        if mode in (MODE_DIRECT, MODE_THRESHOLD):
            model_index = entry.get("index", 0)
            if isinstance(model_index, int) and not isinstance(model_index, bool) and model_index >= output_size:
                report.error(
                    ERR_ARITY_MISMATCH,
                    "This output reads model value %d, but the model only produces %d."
                    % (model_index, output_size),
                    field=field + ".index",
                    expected_below=output_size,
                )
        elif mode == MODE_ARGMAX:
            classes = entry.get("classes", {})
            if isinstance(classes, dict):
                missing = [str(i) for i in range(output_size) if str(i) not in classes]
                if missing:
                    report.error(
                        ERR_ARITY_MISMATCH,
                        "The model can predict %d classes, but classes %s have no value set."
                        % (output_size, ", ".join(missing)),
                        field=field + ".classes",
                        missing=missing,
                    )


# ---------------------------------------------------------------------------
# Compiled plan
# ---------------------------------------------------------------------------

class MappingPlan:
    """A validated config turned into the two functions the bridge needs.

    Compiling up front keeps per-frame work to arithmetic on a short list, which
    matters when this runs 20-50 times a second.
    """

    def __init__(self, config: Dict[str, Any]) -> None:
        self.config = config
        self.platform = resolve_platform(config)
        self.rate_hz = int(config.get("rate_hz", self.platform.default_rate_hz))
        self.watchdog_ms = int(config.get("watchdog_ms", self.platform.default_watchdog_ms))

        # Wire order of sensor channels (see wire_input_channel_ids), and one
        # spec per model input saying how it is computed from them.
        self.input_channels = []
        self._input_specs: List[Tuple[Any, ...]] = []
        wire_index: Dict[str, int] = {}
        for entry in config.get("inputs", []):
            if entry.get("derive") == DERIVE_RAY:
                sources = []
                for source in entry["sources"]:
                    channel_id = str(source["channel"])
                    if channel_id not in wire_index:
                        wire_index[channel_id] = len(self.input_channels)
                        self.input_channels.append(self.platform.sensor(channel_id))
                    sources.append((float(source["angle_deg"]), wire_index[channel_id]))
                sources.sort()
                self._input_specs.append(("ray", float(entry["angle_deg"]), sources, entry["scale"]))
            elif entry.get("derive") == DERIVE_POSE:
                self._input_specs.append(("pose", str(entry["quantity"])))
            else:
                channel = self.platform.sensor(str(entry["channel"]))
                wire_index.setdefault(channel.id, len(self.input_channels))
                self._input_specs.append(("direct", len(self.input_channels), entry.get("scale") or identity_scale()))
                self.input_channels.append(channel)

        # The robot's movement: its encoders (and gyro) are read with the
        # sensors, every tick. An input may need it; otherwise a robot driven
        # from here still reports where it is (the window draws the room from
        # it) whenever its wheels are known and it can count their turns.
        self.odometry: Optional[Odometry] = None
        self._odometry_wire: List[int] = []
        if any(spec[0] == "pose" for spec in self._input_specs) or self._can_track(config):
            world = config.get("world") or {"cm_per_unit": 1.0}
            self.odometry = Odometry(OdometrySetup.from_dict(config["odometry"]), World.from_dict(world))
            for channel_id in self.odometry.setup.channels():
                if channel_id not in wire_index:
                    wire_index[channel_id] = len(self.input_channels)
                    self.input_channels.append(self.platform.sensor(channel_id))
                self._odometry_wire.append(wire_index[channel_id])

        # Wire order of actuator channels, and one spec per config output with
        # the slot it fills. A drive output fills one slot per motor.
        self.output_channels = []
        self._output_specs: List[Tuple[int, Dict[str, Any]]] = []
        self._drives: Dict[int, DriveController] = {}
        self.drive_info: List[Dict[str, Any]] = []
        for entry in config.get("outputs", []):
            slot = len(self.output_channels)
            if str(entry.get("mode", MODE_DIRECT)) == MODE_DRIVE:
                left, right, _, _ = drive_sides(entry)
                for channel_id in left + right:
                    self.output_channels.append(self.platform.actuator(channel_id))
                params = DriveParams(**dict(entry.get("params") or {}))
                # The real start time is unknown here; the bridge resets every
                # drive with the link's clock when the robot is accepted.
                self._drives[slot] = DriveController(params, now=0.0)
            else:
                self.output_channels.append(self.platform.actuator(str(entry["channel"])))
            self._output_specs.append((slot, entry))
    def _can_track(self, config: Dict[str, Any]) -> bool:
        """A robot driven from here whose config names its wheels' encoders,
        all of which it has (a robot that cannot count turns just drives)."""
        if not is_ir_platform(str(config.get("platform", ""))) or not isinstance(config.get("odometry"), dict):
            return False
        try:
            setup = OdometrySetup.from_dict(config["odometry"])
        except (KeyError, TypeError, ValueError):
            return False
        return (bool(setup.left.channels) and bool(setup.right.channels)
                and setup.wheel_diameter_cm > 0 and setup.track_cm > 0
                and all(self.platform.sensor(channel_id) is not None for channel_id in setup.channels()))


    @property
    def input_count(self) -> int:
        """Values per sensor frame on the wire."""
        return len(self.input_channels)

    @property
    def model_input_count(self) -> int:
        """Values in the model's input vector."""
        return len(self._input_specs)

    @property
    def output_count(self) -> int:
        """Values per actuator frame on the wire."""
        return len(self.output_channels)

    @property
    def has_drive(self) -> bool:
        return bool(self._drives)

    def safe_values(self) -> List[int]:
        """What every actuator is driven to when the link is not healthy."""
        return [int(channel.safe_value) for channel in self.output_channels]

    def reset_state(self, now: float) -> None:
        """Forget motion history, so the next command ramps up from standstill.

        Called when the robot is accepted and whenever the motors were stopped
        by something other than the model (a stalled link, a stop).
        """
        for drive in self._drives.values():
            drive.reset(now)
        self.drive_info = []
        if self.odometry is not None:
            self.odometry.reset()

    def pose_info(self) -> Optional[Dict[str, Any]]:
        """Where the robot thinks it is, for telemetry and the datalog."""
        return self.odometry.to_dict() if self.odometry is not None else None

    def sensors_to_model(self, native_values: Sequence[int], now: Optional[float] = None) -> List[float]:
        """Native sensor integers from the wire -> the model's input vector.

        ``now`` times the robot's movement for inputs computed from it.
        """
        if len(native_values) != self.input_count:
            raise ValueError(
                "Robot sent %d sensor value(s), the mapping expects %d."
                % (len(native_values), self.input_count)
            )
        # Clamp before scaling: a sensor briefly reporting outside its
        # documented range must not push the model far outside the space it
        # was trained on, where its output is meaningless.
        bounded = [
            clamp(float(raw), channel.native_min, channel.native_max)
            for raw, channel in zip(native_values, self.input_channels)
        ]
        if self.odometry is not None:
            self.odometry.update([bounded[i] for i in self._odometry_wire], now if now is not None else 0.0)
        out: List[float] = []
        for spec in self._input_specs:
            if spec[0] == "direct":
                out.append(apply_scale(spec[2], bounded[spec[1]]))
            elif spec[0] == "pose":
                out.append(self.odometry.quantity(spec[1]))
            else:
                out.append(self._ray_value(spec, bounded))
        return out

    @staticmethod
    def _ray_value(spec: Tuple[Any, ...], bounded: List[float]) -> float:
        """One model ray from the distance sensors around it.

        As on the robot: each reading is scaled and clamped to the model's
        range first, then the values are linearly interpolated at the ray's
        angle. Outside the sensors' span the nearest sensor's value is used.
        """
        _, angle, sources, scale = spec
        low = min(float(scale["out_min"]), float(scale["out_max"]))
        high = max(float(scale["out_min"]), float(scale["out_max"]))
        points = [(source_angle, clamp(apply_scale(scale, bounded[wire]), low, high)) for source_angle, wire in sources]
        if angle <= points[0][0]:
            return points[0][1]
        if angle >= points[-1][0]:
            return points[-1][1]
        for (a0, v0), (a1, v1) in zip(points, points[1:]):
            if a0 <= angle <= a1:
                return v0 + (v1 - v0) * (angle - a0) / (a1 - a0)
        return points[-1][1]

    def model_to_actuators(
        self,
        model_output: Sequence[float],
        now: Optional[float] = None,
        model_input: Optional[Sequence[float]] = None,
    ) -> List[int]:
        """The model's output vector -> native actuator integers for the wire.

        ``now`` is required when the config drives two motors: the drive
        conversion ramps power over time. ``model_input`` feeds the optional
        wall bypass.
        """
        values = [float(v) for v in model_output]
        results: List[int] = [0] * len(self.output_channels)
        drive_info: List[Dict[str, Any]] = []
        for slot, spec in self._output_specs:
            mode = str(spec.get("mode", MODE_DIRECT))
            if mode == MODE_DRIVE:
                if now is None:
                    raise ValueError("Driving two motors needs the current time.")
                left, right, info = self._drive_values(slot, spec, values, now, model_input)
                left_motors, right_motors, left_flip, right_flip = drive_sides(spec)
                powers = [-left if flip else left for flip in left_flip] + [-right if flip else right for flip in right_flip]
                for offset, power in enumerate(powers):
                    channel = self.output_channels[slot + offset]
                    results[slot + offset] = int(round(clamp(power, channel.native_min, channel.native_max)))
                info = dict(info, left=powers[0], right=powers[len(left_motors)])
                drive_info.append(info)
                continue
            channel = self.output_channels[slot]
            if mode == MODE_ARGMAX:
                native = self._argmax_value(spec, channel, values)
            elif mode == MODE_THRESHOLD:
                native = self._threshold_value(spec, channel, values)
            else:
                native = self._direct_value(spec, channel, values)
            results[slot] = int(round(clamp(native, channel.native_min, channel.native_max)))
        if drive_info:
            self.drive_info = drive_info
        return results

    def _drive_values(self, slot: int, spec: Dict[str, Any], values: List[float], now: float,
                      model_input: Optional[Sequence[float]]) -> Tuple[int, int, Dict[str, Any]]:
        def output(key: str, default: float = 0.0) -> float:
            index = spec.get(key)
            return values[index] if isinstance(index, int) and 0 <= index < len(values) else default

        steer = output("steer_index")
        throttle = output("throttle_index")
        if spec.get("brake_index") is not None:
            # As in the simulation, braking scales the pushing force down.
            throttle *= 1.0 - clamp(output("brake_index"), 0.0, 1.0)
        throttle_pct = throttle * float(spec.get("throttle_scale", 100.0))

        wall = spec.get("wall_inputs") or {}
        inputs = list(model_input or [])

        def distance(key: str) -> float:
            index = wall.get(key)
            return float(inputs[index]) if isinstance(index, int) and 0 <= index < len(inputs) else 1.0

        command = self._drives[slot].compute(
            steer, throttle_pct, now=now, front=distance("front"), left=distance("left"), right=distance("right"),
        )
        # Reversed motors are applied per motor by the caller (see ``drive_sides``).
        return command.left, command.right, dict(command.info)

    def _direct_value(self, spec: Dict[str, Any], channel, values: List[float]) -> float:
        model_index = int(spec.get("index", 0))
        raw = values[model_index] if 0 <= model_index < len(values) else 0.0
        scale = spec.get("scale")
        if scale:
            return apply_scale(scale, raw)
        return raw

    def _argmax_value(self, spec: Dict[str, Any], channel, values: List[float]) -> float:
        if not values:
            return float(channel.safe_value)
        best_index = 0
        best_value = values[0]
        for index in range(1, len(values)):
            if values[index] > best_value:
                best_value = values[index]
                best_index = index
        classes = spec.get("classes", {}) or {}
        if str(best_index) in classes:
            return float(classes[str(best_index)])
        # An unmapped class is not an error worth stopping the robot for, but
        # guessing a motor speed for it would be. Do the inert thing.
        return float(channel.safe_value)

    def _threshold_value(self, spec: Dict[str, Any], channel, values: List[float]) -> float:
        model_index = int(spec.get("index", 0))
        raw = values[model_index] if 0 <= model_index < len(values) else 0.0
        threshold = float(spec.get("threshold", 0.5))
        if raw >= threshold:
            return float(spec.get("on_value", channel.native_max))
        return float(spec.get("off_value", channel.safe_value))


def compile_config(config: Dict[str, Any], model_meta: Optional[Dict[str, Any]] = None) -> MappingPlan:
    """Validate then compile. Raises :class:`.errors.ConfigError` on failure."""
    validate_config(config, model_meta).raise_if_failed()
    return MappingPlan(config)


def config_hash(config: Dict[str, Any]) -> str:
    """Short stable fingerprint of the parts the device script depends on.

    The device reports this in its hello frame, so a host running a config the
    child has since changed is caught at connect time rather than showing up as
    a robot that drives the wrong motor. Only fields the *script* embeds are
    hashed: retuning a scale on the host must not invalidate a flashed script.
    """
    material = {
        "schema_version": config.get("schema_version", SCHEMA_VERSION),
        "platform": config.get("platform", ""),
        "rate_hz": config.get("rate_hz", 0),
        "watchdog_ms": config.get("watchdog_ms", 0),
        # What travels on the wire, in order. For configs without rays or
        # drives this is exactly the per-entry channel list it always was.
        "inputs": wire_input_channel_ids(config.get("inputs")),
        "outputs": wire_output_channel_ids(config.get("outputs")),
    }
    blob = json.dumps(material, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(blob).hexdigest()[:8]
