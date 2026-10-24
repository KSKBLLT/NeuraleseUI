"""Registry of supported robot platforms.

This module is the single source of truth for the whole feature. The UI reads it
to build dropdowns, :mod:`.config` reads it to validate and to derive defaults,
and :mod:`.generate` reads it to emit device code. Adding a robot means adding an
entry here and a template -- nothing else in the package is platform-aware.

Every channel carries both the human-facing label and the device-side code
fragment that reads or drives it, so the two can never drift apart.

Ranges are the *native* device units. Conversion between native integers and
model-space floats lives entirely on the host (:mod:`.config`), which is why the
device scripts stay identical no matter what model the child trained.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from .errors import ERR_UNKNOWN_PLATFORM, RobotError

# Transport identifiers. See `.transport` for the implementations.
TRANSPORT_SERIAL = "serial"
TRANSPORT_TCP = "tcp"
TRANSPORT_BLE = "ble"


class Channel:
    """One sensor input or actuator output the child can pick in the UI."""

    def __init__(
        self,
        channel_id: str,
        label: str,
        native_min: float,
        native_max: float,
        *,
        unit: str = "",
        imports: Optional[List[str]] = None,
        setup: Optional[List[str]] = None,
        expr: str = "",
        integer_only: bool = False,
        group: str = "",
        description: str = "",
    ) -> None:
        self.id = channel_id
        self.label = label
        self.native_min = float(native_min)
        self.native_max = float(native_max)
        self.unit = unit
        self.imports = list(imports or [])
        self.setup = list(setup or [])
        #: For sensors: an expression evaluating to an int.
        #: For actuators: a statement template containing ``{value}``.
        self.expr = expr
        self.integer_only = integer_only
        self.group = group
        self.description = description

    def to_dict(self) -> Dict[str, Any]:
        """The UI-facing view. Device code fragments are deliberately omitted."""
        return {
            "id": self.id,
            "label": self.label,
            "unit": self.unit,
            "native_min": self.native_min,
            "native_max": self.native_max,
            "group": self.group,
            "description": self.description,
        }


class SensorChannel(Channel):
    pass


class ActuatorChannel(Channel):
    def __init__(self, *args: Any, safe_value: int = 0, **kwargs: Any) -> None:
        super().__init__(*args, **kwargs)
        #: What this actuator is driven to when the link drops. Always the
        #: inert value -- a robot that keeps its last motor command after losing
        #: the link is a robot that drives into something.
        self.safe_value = int(safe_value)

    def to_dict(self) -> Dict[str, Any]:
        payload = super().to_dict()
        payload["safe_value"] = self.safe_value
        return payload


class Platform:
    def __init__(
        self,
        platform_id: str,
        label: str,
        *,
        sensors: List[SensorChannel],
        actuators: List[ActuatorChannel],
        transports: List[str],
        default_transport: str,
        template: str,
        default_rate_hz: int = 20,
        max_rate_hz: int = 50,
        default_watchdog_ms: int = 300,
        script_filename: str = "neuralese_robot.py",
        firmware: str = "",
        firmware_url: str = "",
        deploy: Optional[Dict[str, Any]] = None,
        notes: str = "",
        conflicts: Optional[List[Dict[str, Any]]] = None,
    ) -> None:
        self.id = platform_id
        self.label = label
        self.sensors = list(sensors)
        self.actuators = list(actuators)
        self.transports = list(transports)
        self.default_transport = default_transport
        self.template = template
        self.default_rate_hz = default_rate_hz
        self.max_rate_hz = max_rate_hz
        self.default_watchdog_ms = default_watchdog_ms
        self.script_filename = script_filename
        self.firmware = firmware
        self.firmware_url = firmware_url
        self.deploy = deploy or {}
        self.notes = notes
        #: Pairs of channels that share one piece of hardware and interfere when
        #: mapped together. Reported as warnings, not errors: the combination
        #: works, it just works badly, and refusing it outright would be wrong.
        self.conflicts = list(conflicts or [])

        self._sensor_by_id = {c.id: c for c in self.sensors}
        self._actuator_by_id = {c.id: c for c in self.actuators}

    def sensor(self, channel_id: str) -> Optional[SensorChannel]:
        return self._sensor_by_id.get(channel_id)

    def actuator(self, channel_id: str) -> Optional[ActuatorChannel]:
        return self._actuator_by_id.get(channel_id)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "id": self.id,
            "label": self.label,
            "sensors": [c.to_dict() for c in self.sensors],
            "actuators": [c.to_dict() for c in self.actuators],
            "transports": list(self.transports),
            "default_transport": self.default_transport,
            "default_rate_hz": self.default_rate_hz,
            "max_rate_hz": self.max_rate_hz,
            "default_watchdog_ms": self.default_watchdog_ms,
            "script_filename": self.script_filename,
            "firmware": self.firmware,
            "firmware_url": self.firmware_url,
            "deploy": dict(self.deploy),
            "notes": self.notes,
            "conflicts": [dict(entry) for entry in self.conflicts],
        }


# ---------------------------------------------------------------------------
# micro:bit v2
#
# Link: USB CDC serial. The micro:bit enumerates as a serial port the moment it
# is plugged in -- no pairing, no drivers, no permission dialog. BLE exists but
# needs pairing plus an OS Bluetooth permission prompt, so it is opt-in only.
# ---------------------------------------------------------------------------

_MICROBIT_SENSORS = [
    SensorChannel(
        "accel_x", "Tilt left / right", -2048, 2048, unit="mg", group="motion",
        expr="accelerometer.get_x()",
        description="Negative when tilted left, positive when tilted right.",
    ),
    SensorChannel(
        "accel_y", "Tilt forward / back", -2048, 2048, unit="mg", group="motion",
        expr="accelerometer.get_y()",
    ),
    SensorChannel(
        "accel_z", "Tilt up / down", -2048, 2048, unit="mg", group="motion",
        expr="accelerometer.get_z()",
    ),
    SensorChannel(
        "compass_heading", "Compass heading", 0, 359, unit="deg", group="motion",
        expr="compass.heading()",
        description="Needs calibrating on the device the first time it is used.",
    ),
    SensorChannel(
        "light_level", "Light level", 0, 255, group="environment",
        expr="display.read_light_level()",
    ),
    SensorChannel(
        "temperature", "Temperature", -10, 50, unit="C", group="environment",
        expr="temperature()",
    ),
    SensorChannel(
        "sound_level", "Loudness", 0, 255, group="environment",
        expr="microphone.sound_level()",
        description="micro:bit v2 only.",
    ),
    SensorChannel(
        "button_a", "Button A pressed", 0, 1, group="buttons",
        expr="(1 if button_a.is_pressed() else 0)", integer_only=True,
    ),
    SensorChannel(
        "button_b", "Button B pressed", 0, 1, group="buttons",
        expr="(1 if button_b.is_pressed() else 0)", integer_only=True,
    ),
    SensorChannel("pin0_analog", "Pin 0 reading", 0, 1023, group="pins", expr="pin0.read_analog()"),
    SensorChannel("pin1_analog", "Pin 1 reading", 0, 1023, group="pins", expr="pin1.read_analog()"),
    SensorChannel("pin2_analog", "Pin 2 reading", 0, 1023, group="pins", expr="pin2.read_analog()"),
]

_MICROBIT_ACTUATORS = [
    ActuatorChannel(
        "pin0_analog", "Pin 0 power", 0, 1023, group="pins",
        expr="pin0.write_analog({value})", safe_value=0,
    ),
    ActuatorChannel(
        "pin1_analog", "Pin 1 power", 0, 1023, group="pins",
        expr="pin1.write_analog({value})", safe_value=0,
    ),
    ActuatorChannel(
        "pin2_analog", "Pin 2 power", 0, 1023, group="pins",
        expr="pin2.write_analog({value})", safe_value=0,
    ),
    ActuatorChannel(
        "pin8_digital", "Pin 8 on / off", 0, 1, group="pins",
        expr="pin8.write_digital(1 if {value} else 0)", safe_value=0,
    ),
    ActuatorChannel(
        "pin12_digital", "Pin 12 on / off", 0, 1, group="pins",
        expr="pin12.write_digital(1 if {value} else 0)", safe_value=0,
    ),
    ActuatorChannel(
        "display_digit", "Show a number", 0, 9, group="display",
        expr="display.show({value})", safe_value=0,
        description="Shows the predicted class as a digit. Good for classifiers.",
    ),
    ActuatorChannel(
        "display_brightness", "Screen brightness", 0, 9, group="display",
        expr="display.set_pixel(2, 2, {value})", safe_value=0,
    ),
]

MICROBIT = Platform(
    "microbit",
    "BBC micro:bit v2",
    sensors=_MICROBIT_SENSORS,
    actuators=_MICROBIT_ACTUATORS,
    transports=[TRANSPORT_SERIAL, TRANSPORT_BLE],
    default_transport=TRANSPORT_SERIAL,
    template="microbit.py.tmpl",
    default_rate_hz=20,
    max_rate_hz=50,
    default_watchdog_ms=300,
    script_filename="main.py",
    firmware="MicroPython (micro:bit v2)",
    firmware_url="https://python.microbit.org/",
    deploy={
        "method": "flash_hex",
        "automated": False,
        "target_hint": "MICROBIT drive",
        "steps_key": "deploy_microbit",
        "reason": "The micro:bit runs a .hex image, so main.py has to be flashed "
                  "with the online editor or uflash rather than copied.",
    },
    notes="Uses the USB serial port the micro:bit exposes when plugged in. "
          "Nothing needs pairing.",
    conflicts=[
        {
            "sensor": "light_level",
            "actuators": ["display_digit", "display_brightness"],
            "message": "Reading the light level and showing something on the screen both "
                       "use the same grid of LEDs. Used together the screen flickers and "
                       "the light readings get worse. Pick one, or use a pin instead.",
        },
    ],
)


# ---------------------------------------------------------------------------
# LEGO MINDSTORMS EV3 (ev3dev)
#
# Link: TCP over the USB network interface. The EV3 has no USB serial port -- USB
# gives it a CDC/RNDIS *network* device, so the brick is reachable at
# ev3dev.local. WiFi is possible but needs a specific dongle, which is why USB is
# the default and the address is configurable rather than hard-coded.
# ---------------------------------------------------------------------------

def _ev3_motor_setup(port: str) -> List[str]:
    return ["_motor_%s = LargeMotor(OUTPUT_%s)" % (port.lower(), port)]


_EV3_SENSORS = [
    SensorChannel(
        "touch_1", "Touch sensor (port 1) pressed", 0, 1, group="sensors",
        imports=["from ev3dev2.sensor.lego import TouchSensor"],
        setup=["_touch_1 = TouchSensor(INPUT_1)"],
        expr="(1 if _touch_1.is_pressed else 0)", integer_only=True,
    ),
    SensorChannel(
        "touch_2", "Touch sensor (port 2) pressed", 0, 1, group="sensors",
        imports=["from ev3dev2.sensor.lego import TouchSensor"],
        setup=["_touch_2 = TouchSensor(INPUT_2)"],
        expr="(1 if _touch_2.is_pressed else 0)", integer_only=True,
    ),
    SensorChannel(
        "color_reflect_3", "Colour sensor (port 3) reflected light", 0, 100, group="sensors",
        imports=["from ev3dev2.sensor.lego import ColorSensor"],
        setup=["_color_3 = ColorSensor(INPUT_3)"],
        expr="_color_3.reflected_light_intensity",
    ),
    SensorChannel(
        "color_ambient_3", "Colour sensor (port 3) ambient light", 0, 100, group="sensors",
        imports=["from ev3dev2.sensor.lego import ColorSensor"],
        setup=["_color_3 = ColorSensor(INPUT_3)"],
        expr="_color_3.ambient_light_intensity",
    ),
    SensorChannel(
        "color_id_3", "Colour sensor (port 3) colour", 0, 7, group="sensors",
        imports=["from ev3dev2.sensor.lego import ColorSensor"],
        setup=["_color_3 = ColorSensor(INPUT_3)"],
        expr="_color_3.color", integer_only=True,
        description="0 none, 1 black, 2 blue, 3 green, 4 yellow, 5 red, 6 white, 7 brown.",
    ),
    SensorChannel(
        "ultrasonic_4", "Distance sensor (port 4)", 0, 2550, unit="mm", group="sensors",
        imports=["from ev3dev2.sensor.lego import UltrasonicSensor"],
        setup=["_ultrasonic_4 = UltrasonicSensor(INPUT_4)"],
        expr="_ultrasonic_4.distance_centimeters * 10",
    ),
    SensorChannel(
        "gyro_angle_2", "Gyro angle (port 2)", -360, 360, unit="deg", group="sensors",
        imports=["from ev3dev2.sensor.lego import GyroSensor"],
        setup=["_gyro_2 = GyroSensor(INPUT_2)"],
        expr="_gyro_2.angle",
    ),
    SensorChannel(
        "infrared_4", "Infrared proximity (port 4)", 0, 100, group="sensors",
        imports=["from ev3dev2.sensor.lego import InfraredSensor"],
        setup=["_infrared_4 = InfraredSensor(INPUT_4)"],
        expr="_infrared_4.proximity",
    ),
    SensorChannel(
        "motor_a_position", "Motor A position", -3600, 3600, unit="deg", group="motors",
        imports=["from ev3dev2.motor import LargeMotor, OUTPUT_A"],
        setup=_ev3_motor_setup("A"),
        expr="_motor_a.position",
    ),
    SensorChannel(
        "motor_b_position", "Motor B position", -3600, 3600, unit="deg", group="motors",
        imports=["from ev3dev2.motor import LargeMotor, OUTPUT_B"],
        setup=_ev3_motor_setup("B"),
        expr="_motor_b.position",
    ),
]

_EV3_ACTUATORS = [
    ActuatorChannel(
        "motor_a_speed", "Motor A speed", -100, 100, unit="%", group="motors",
        imports=["from ev3dev2.motor import LargeMotor, OUTPUT_A"],
        setup=_ev3_motor_setup("A"),
        expr="_drive_motor(_motor_a, {value})", safe_value=0,
    ),
    ActuatorChannel(
        "motor_b_speed", "Motor B speed", -100, 100, unit="%", group="motors",
        imports=["from ev3dev2.motor import LargeMotor, OUTPUT_B"],
        setup=_ev3_motor_setup("B"),
        expr="_drive_motor(_motor_b, {value})", safe_value=0,
    ),
    ActuatorChannel(
        "motor_c_speed", "Motor C speed", -100, 100, unit="%", group="motors",
        imports=["from ev3dev2.motor import LargeMotor, OUTPUT_C"],
        setup=_ev3_motor_setup("C"),
        expr="_drive_motor(_motor_c, {value})", safe_value=0,
    ),
    ActuatorChannel(
        "motor_d_speed", "Motor D speed", -100, 100, unit="%", group="motors",
        imports=["from ev3dev2.motor import LargeMotor, OUTPUT_D"],
        setup=_ev3_motor_setup("D"),
        expr="_drive_motor(_motor_d, {value})", safe_value=0,
    ),
]

EV3 = Platform(
    "ev3",
    "LEGO MINDSTORMS EV3",
    sensors=_EV3_SENSORS,
    actuators=_EV3_ACTUATORS,
    transports=[TRANSPORT_TCP],
    default_transport=TRANSPORT_TCP,
    template="ev3.py.tmpl",
    default_rate_hz=20,
    max_rate_hz=30,
    default_watchdog_ms=400,
    script_filename="neuralese_robot.py",
    firmware="ev3dev (ev3dev2 Python library)",
    firmware_url="https://www.ev3dev.org/docs/getting-started/",
    deploy={
        "method": "copy_and_run",
        "automated": False,
        "target_hint": "ev3dev.local",
        "steps_key": "deploy_ev3",
        "reason": "The EV3 runs Linux. The script is copied onto the brick and "
                  "started from the brick's file browser.",
    },
    notes="The EV3 has no USB serial port; USB gives it a network interface, so "
          "the link is a TCP socket to the brick (default ev3dev.local:9999).",
)


# ---------------------------------------------------------------------------
# LEGO SPIKE Prime (Pybricks firmware)
#
# Pybricks is chosen over LEGO's own firmware because it is open source, exposes
# a plain USB serial REPL, and has a stable documented API. The child installs it
# once from the Pybricks website.
# ---------------------------------------------------------------------------

_SPIKE_SENSORS = [
    SensorChannel(
        "color_a_reflection", "Colour sensor (port A) reflection", 0, 100, group="sensors",
        imports=["from pybricks.pupdevices import ColorSensor", "from pybricks.parameters import Port"],
        setup=["_color_a = ColorSensor(Port.A)"],
        expr="_color_a.reflection()",
    ),
    SensorChannel(
        "color_a_ambient", "Colour sensor (port A) ambient light", 0, 100, group="sensors",
        imports=["from pybricks.pupdevices import ColorSensor", "from pybricks.parameters import Port"],
        setup=["_color_a = ColorSensor(Port.A)"],
        expr="_color_a.ambient()",
    ),
    SensorChannel(
        "ultrasonic_b", "Distance sensor (port B)", 0, 2000, unit="mm", group="sensors",
        imports=["from pybricks.pupdevices import UltrasonicSensor", "from pybricks.parameters import Port"],
        setup=["_ultrasonic_b = UltrasonicSensor(Port.B)"],
        expr="_ultrasonic_b.distance()",
    ),
    SensorChannel(
        "force_c", "Force sensor (port C)", 0, 100, unit="dN", group="sensors",
        imports=["from pybricks.pupdevices import ForceSensor", "from pybricks.parameters import Port"],
        setup=["_force_c = ForceSensor(Port.C)"],
        expr="int(_force_c.force() * 10)",
    ),
    SensorChannel(
        "force_c_pressed", "Force sensor (port C) pressed", 0, 1, group="sensors",
        imports=["from pybricks.pupdevices import ForceSensor", "from pybricks.parameters import Port"],
        setup=["_force_c = ForceSensor(Port.C)"],
        expr="(1 if _force_c.pressed() else 0)", integer_only=True,
    ),
    SensorChannel(
        "hub_pitch", "Hub tilt forward / back", -180, 180, unit="deg", group="motion",
        setup=[], expr="int(_hub.imu.tilt()[0])",
    ),
    SensorChannel(
        "hub_roll", "Hub tilt left / right", -180, 180, unit="deg", group="motion",
        setup=[], expr="int(_hub.imu.tilt()[1])",
    ),
    SensorChannel(
        "motor_e_angle", "Motor E angle", -3600, 3600, unit="deg", group="motors",
        imports=["from pybricks.pupdevices import Motor", "from pybricks.parameters import Port"],
        setup=["_motor_e = Motor(Port.E)"],
        expr="_motor_e.angle()",
    ),
]

_SPIKE_ACTUATORS = [
    ActuatorChannel(
        "motor_e_speed", "Motor E speed", -100, 100, unit="%", group="motors",
        imports=["from pybricks.pupdevices import Motor", "from pybricks.parameters import Port"],
        setup=["_motor_e = Motor(Port.E)"],
        expr="_drive_motor(_motor_e, {value})", safe_value=0,
    ),
    ActuatorChannel(
        "motor_f_speed", "Motor F speed", -100, 100, unit="%", group="motors",
        imports=["from pybricks.pupdevices import Motor", "from pybricks.parameters import Port"],
        setup=["_motor_f = Motor(Port.F)"],
        expr="_drive_motor(_motor_f, {value})", safe_value=0,
    ),
    ActuatorChannel(
        "motor_a_speed", "Motor A speed", -100, 100, unit="%", group="motors",
        imports=["from pybricks.pupdevices import Motor", "from pybricks.parameters import Port"],
        setup=["_motor_a = Motor(Port.A)"],
        expr="_drive_motor(_motor_a, {value})", safe_value=0,
    ),
    ActuatorChannel(
        "motor_b_speed", "Motor B speed", -100, 100, unit="%", group="motors",
        imports=["from pybricks.pupdevices import Motor", "from pybricks.parameters import Port"],
        setup=["_motor_b = Motor(Port.B)"],
        expr="_drive_motor(_motor_b, {value})", safe_value=0,
    ),
    ActuatorChannel(
        "hub_light", "Hub light colour", 0, 5, group="display",
        expr="_set_hub_light({value})", safe_value=0,
        description="0 off, 1 red, 2 green, 3 blue, 4 yellow, 5 white. "
                    "Good for showing which class a classifier predicted.",
    ),
]

SPIKE = Platform(
    "spike",
    "LEGO SPIKE Prime",
    sensors=_SPIKE_SENSORS,
    actuators=_SPIKE_ACTUATORS,
    transports=[TRANSPORT_SERIAL, TRANSPORT_BLE],
    default_transport=TRANSPORT_SERIAL,
    template="spike.py.tmpl",
    default_rate_hz=20,
    max_rate_hz=40,
    default_watchdog_ms=300,
    script_filename="main.py",
    firmware="Pybricks",
    firmware_url="https://pybricks.com/install/",
    deploy={
        "method": "pybricks_upload",
        "automated": False,
        "target_hint": "SPIKE Prime hub over USB",
        "steps_key": "deploy_spike",
        "reason": "The hub is programmed through the Pybricks editor or "
                  "pybricksdev; there is no drag-and-drop drive.",
    },
    notes="Requires the open-source Pybricks firmware on the hub. LEGO's own "
          "SPIKE firmware is not supported by these scripts.",
)


PLATFORMS: Dict[str, Platform] = {p.id: p for p in (MICROBIT, EV3, SPIKE)}


# ---------------------------------------------------------------------------
# Robots described by an IR (see :mod:`.ir`)
#
# These run no generated device program. A driver on the host talks to the
# hardware (or simulates it) and reports what is plugged in, so their channels
# come from the robot's own IR rather than from a fixed list here. A config for
# one of them carries that IR under ``"robot"``.
# ---------------------------------------------------------------------------

IR_PLATFORMS: Dict[str, Dict[str, Any]] = {
    "dummy": {
        "id": "dummy",
        "label": "Dummy robot",
        "transports": ["virtual", "replay"],
        "notes": "A simulated robot for trying everything without hardware. "
                 "It can also replay a recorded run of a real robot.",
    },
    "ev3_direct": {
        "id": "ev3_direct",
        "label": "LEGO MINDSTORMS EV3 (standard firmware)",
        "transports": ["bluetooth"],
        "notes": "The EV3's own firmware, driven over Bluetooth with LEGO direct "
                 "commands. Nothing is installed on the brick.",
    },
}


def is_ir_platform(platform_id: str) -> bool:
    return str(platform_id) in IR_PLATFORMS


def get_platform(platform_id: str) -> Platform:
    platform = PLATFORMS.get(str(platform_id))
    if platform is None:
        raise RobotError(
            "Unknown robot platform: %s. Supported: %s" % (platform_id, ", ".join(sorted(PLATFORMS))),
            code=ERR_UNKNOWN_PLATFORM,
            details={"supported": sorted(PLATFORMS)},
        )
    return platform


def list_platforms() -> List[Dict[str, Any]]:
    """Full registry as plain data. This is what the UI layer consumes."""
    return [PLATFORMS[key].to_dict() for key in ("microbit", "ev3", "spike")]


def list_ir_platforms() -> List[Dict[str, Any]]:
    """Robot families described by an IR. Their channels come from each robot."""
    return [dict(entry) for entry in IR_PLATFORMS.values()]
