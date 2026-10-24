"""Stub device modules for running micro:bit and SPIKE scripts on a desktop.

Honest labelling, because it matters for reading the test results: **this is not
an emulator.** The EV3 tier runs the real ``ev3dev2`` library against a real
fake-sysfs device tree (see ``ev3_fake_sys.py``); there is no equivalent for
these two.

* micro:bit: the Foundation's simulator is a WebAssembly build with no published
  binary artifact, so using it would mean an Emscripten toolchain and a Node
  runtime in the test path.
* SPIKE Prime: no simulator exists at all, open source or otherwise.

So these modules reimplement just enough of the ``microbit`` and ``pybricks``
APIs for the generated scripts to run under CPython. What that *does* buy is
real: the actual generated script is executed line by line, its protocol
handling, watchdog and framing are exercised against the real host bridge over a
real byte pipe, and every sensor read and motor write is recorded and asserted.
What it cannot catch is anything device-specific -- MicroPython dialect gaps,
RAM limits, real timing. Those need hardware.
"""

from __future__ import annotations

import threading
import time
from typing import Any, Dict, List, Optional

from neuralese_local.robot.transport import Transport


class Halt(Exception):
    """Raised inside a device script's sleep to unwind its infinite loop."""


class BytePipe:
    """A two-way byte pipe between a device script and the host bridge."""

    def __init__(self) -> None:
        self.lock = threading.Lock()
        self.to_host = bytearray()
        self.to_device = bytearray()

    def device_write(self, data: bytes) -> None:
        with self.lock:
            self.to_host.extend(data)

    def device_read(self, count: int) -> bytes:
        with self.lock:
            chunk = bytes(self.to_device[:count])
            del self.to_device[: len(chunk)]
        return chunk

    def device_available(self) -> int:
        with self.lock:
            return len(self.to_device)

    def host_write(self, data: bytes) -> None:
        with self.lock:
            self.to_device.extend(data)

    def host_read(self, count: int) -> bytes:
        with self.lock:
            chunk = bytes(self.to_host[:count])
            del self.to_host[: len(chunk)]
        return chunk


class PipeTransport(Transport):
    """The host's end of a :class:`BytePipe`."""

    kind = "stub_device"

    def __init__(self, pipe: BytePipe) -> None:
        self.pipe = pipe
        self._open = False

    def open(self) -> None:
        self._open = True

    def close(self) -> None:
        self._open = False

    def read(self, max_bytes: int = 4096) -> bytes:
        return self.pipe.host_read(max_bytes)

    def write(self, data: bytes) -> None:
        self.pipe.host_write(data)

    @property
    def is_open(self) -> bool:
        return self._open


class DeviceWorld:
    """The values the stubbed sensors report and the commands they receive.

    A test moves the world by writing to :attr:`sensors`, and asserts on what
    landed in :attr:`commands`.
    """

    def __init__(self) -> None:
        self.sensors: Dict[str, Any] = {}
        self.commands: List[Dict[str, Any]] = []
        self.clock_start = time.monotonic()
        self.halted = False

    def get(self, name: str, default: Any = 0) -> Any:
        return self.sensors.get(name, default)

    def record(self, target: str, value: Any) -> None:
        self.commands.append({"target": target, "value": value})

    def last(self, target: str) -> Optional[Any]:
        for entry in reversed(self.commands):
            if entry["target"] == target:
                return entry["value"]
        return None

    def ticks_ms(self) -> int:
        return int((time.monotonic() - self.clock_start) * 1000)


# ---------------------------------------------------------------------------
# micro:bit
# ---------------------------------------------------------------------------

def build_microbit_module(world: DeviceWorld, pipe: BytePipe):
    import types

    module = types.ModuleType("microbit")

    class _Uart:
        def init(self, baudrate: int = 115200, **kwargs: Any) -> None:
            world.record("uart_init", baudrate)

        def any(self) -> bool:
            return pipe.device_available() > 0

        def read(self, count: int = 4096) -> Optional[bytes]:
            data = pipe.device_read(count)
            return data or None

        def write(self, payload: Any) -> None:
            if isinstance(payload, str):
                payload = payload.encode("ascii")
            pipe.device_write(payload)

    class _Accelerometer:
        def get_x(self) -> int:
            return int(world.get("accel_x"))

        def get_y(self) -> int:
            return int(world.get("accel_y"))

        def get_z(self) -> int:
            return int(world.get("accel_z"))

    class _Compass:
        def heading(self) -> int:
            return int(world.get("compass_heading"))

    class _Microphone:
        def sound_level(self) -> int:
            return int(world.get("sound_level"))

    class _Button:
        def __init__(self, name: str) -> None:
            self._name = name

        def is_pressed(self) -> bool:
            return bool(world.get(self._name, 0))

    class _Display:
        def show(self, value: Any) -> None:
            world.record("display", value)

        def clear(self) -> None:
            world.record("display", None)

        def set_pixel(self, x: int, y: int, brightness: int) -> None:
            world.record("display_pixel", (x, y, brightness))

        def read_light_level(self) -> int:
            return int(world.get("light_level"))

    class _Pin:
        def __init__(self, index: int) -> None:
            self._index = index

        def read_analog(self) -> int:
            return int(world.get("pin%d_analog" % self._index))

        def write_analog(self, value: int) -> None:
            world.record("pin%d_analog" % self._index, int(value))

        def write_digital(self, value: int) -> None:
            world.record("pin%d_digital" % self._index, int(value))

    class _Image:
        # The scripts only use these as opaque display markers.
        NO = "NO"
        YES = "YES"
        ARROW_E = "ARROW_E"
        CONFUSED = "CONFUSED"
        SQUARE_SMALL = "SQUARE_SMALL"

    def sleep(milliseconds: int) -> None:
        if world.halted:
            raise Halt()
        time.sleep(min(float(milliseconds), 20.0) / 1000.0)
        if world.halted:
            raise Halt()

    module.uart = _Uart()
    module.accelerometer = _Accelerometer()
    module.compass = _Compass()
    module.microphone = _Microphone()
    module.button_a = _Button("button_a")
    module.button_b = _Button("button_b")
    module.display = _Display()
    module.Image = _Image
    module.sleep = sleep
    module.running_time = world.ticks_ms
    module.temperature = lambda: int(world.get("temperature"))
    for index in (0, 1, 2, 8, 12):
        setattr(module, "pin%d" % index, _Pin(index))
    return module


# ---------------------------------------------------------------------------
# SPIKE Prime / Pybricks
# ---------------------------------------------------------------------------

def build_pybricks_modules(world: DeviceWorld, pipe: BytePipe) -> Dict[str, Any]:
    import types

    class Port:
        A, B, C, D, E, F = "A", "B", "C", "D", "E", "F"

    class Color:
        RED, GREEN, BLUE, YELLOW, WHITE, ORANGE, NONE = (
            "RED", "GREEN", "BLUE", "YELLOW", "WHITE", "ORANGE", "NONE")

    class _Light:
        def on(self, color: Any) -> None:
            world.record("hub_light", color)

        def off(self) -> None:
            world.record("hub_light", None)

    class _Imu:
        def tilt(self):
            return (world.get("hub_pitch"), world.get("hub_roll"))

    class PrimeHub:
        def __init__(self) -> None:
            self.light = _Light()
            self.imu = _Imu()

    class Motor:
        def __init__(self, port: str, *args: Any, **kwargs: Any) -> None:
            self.port = port

        def dc(self, percent: int) -> None:
            world.record("motor_%s" % self.port.lower(), int(percent))

        def stop(self) -> None:
            world.record("motor_%s" % self.port.lower(), 0)

        def angle(self) -> int:
            return int(world.get("motor_%s_angle" % self.port.lower()))

    class ColorSensor:
        def __init__(self, port: str) -> None:
            self.port = port

        def reflection(self) -> int:
            return int(world.get("color_%s_reflection" % self.port.lower()))

        def ambient(self) -> int:
            return int(world.get("color_%s_ambient" % self.port.lower()))

    class UltrasonicSensor:
        def __init__(self, port: str) -> None:
            self.port = port

        def distance(self) -> int:
            return int(world.get("ultrasonic_%s" % self.port.lower()))

    class ForceSensor:
        def __init__(self, port: str) -> None:
            self.port = port

        def force(self) -> float:
            return float(world.get("force_%s" % self.port.lower()))

        def pressed(self) -> bool:
            return bool(world.get("force_%s_pressed" % self.port.lower(), 0))

    class StopWatch:
        def time(self) -> int:
            return world.ticks_ms()

    def wait(milliseconds: int) -> None:
        if world.halted:
            raise Halt()
        time.sleep(min(float(milliseconds), 20.0) / 1000.0)
        if world.halted:
            raise Halt()

    class _DeviceIn:
        class _Buffer:
            def read(self, count: int = 1) -> bytes:
                return pipe.device_read(count)

        buffer = _Buffer()

    class _DeviceOut:
        class _Buffer:
            def write(self, data: bytes) -> None:
                pipe.device_write(data)

        buffer = _Buffer()

    class _Poll:
        def __init__(self) -> None:
            self._registered: List[Any] = []

        def register(self, stream: Any) -> None:
            self._registered.append(stream)

        def poll(self, timeout: int = 0):
            if pipe.device_available():
                return [(stream, 1) for stream in self._registered]
            return []

    modules: Dict[str, Any] = {}

    hubs = types.ModuleType("pybricks.hubs")
    hubs.PrimeHub = PrimeHub
    parameters = types.ModuleType("pybricks.parameters")
    parameters.Port = Port
    parameters.Color = Color
    tools = types.ModuleType("pybricks.tools")
    tools.StopWatch = StopWatch
    tools.wait = wait
    pupdevices = types.ModuleType("pybricks.pupdevices")
    pupdevices.Motor = Motor
    pupdevices.ColorSensor = ColorSensor
    pupdevices.UltrasonicSensor = UltrasonicSensor
    pupdevices.ForceSensor = ForceSensor

    pybricks = types.ModuleType("pybricks")
    pybricks.hubs = hubs
    pybricks.parameters = parameters
    pybricks.tools = tools
    pybricks.pupdevices = pupdevices

    usys = types.ModuleType("usys")
    usys.stdin = _DeviceIn()
    usys.stdout = _DeviceOut()
    uselect = types.ModuleType("uselect")
    uselect.poll = _Poll

    modules.update({
        "pybricks": pybricks,
        "pybricks.hubs": hubs,
        "pybricks.parameters": parameters,
        "pybricks.tools": tools,
        "pybricks.pupdevices": pupdevices,
        "usys": usys,
        "uselect": uselect,
    })
    return modules
