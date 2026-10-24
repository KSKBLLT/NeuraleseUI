"""A fake EV3 brick on stock firmware, at the byte level of LEGO direct commands.

It parses each command the way the brick does (length, message number, reply
or not, reply variable size, then the bytecodes with their LC/GV parameters)
and answers with a real reply frame. Faults that the prototype's driver was
written against can be switched on: an open that hangs, an open that fails
with a given Windows error, silence, a late reply, garbage, a write that fails.
"""

from __future__ import annotations

import struct
import threading
from typing import Any, Callable, Dict, List, Optional, Tuple


class FakeClock:
    def __init__(self, start: float = 100.0) -> None:
        self.now = start

    def __call__(self) -> float:
        return self.now

    def sleep(self, seconds: float) -> None:
        self.now += seconds


def _read_param(code: bytes, i: int) -> Tuple[Any, int]:
    """One parameter: an LC constant (value) or a GV reference (("gv", offset))."""
    b = code[i]
    if b & 0x80 == 0:                       # LC0 (6-bit signed)
        if b & 0x40:                        # GV0 short form 0x60 | index
            if b & 0x20:
                return ("gv", b & 0x1F), i + 1
        value = b & 0x3F
        return (value - 64 if value & 0x20 else value), i + 1
    if b == 0x81:
        return struct.unpack("<b", code[i + 1:i + 2])[0], i + 2
    if b == 0x82:
        return struct.unpack("<h", code[i + 1:i + 3])[0], i + 3
    if b == 0x83:
        return struct.unpack("<i", code[i + 1:i + 5])[0], i + 5
    if b == 0xE1:
        return ("gv", code[i + 1]), i + 2
    raise ValueError("unsupported parameter byte 0x%02X" % b)


class FakeBrick:
    """The brick's state and its answers."""

    def __init__(self, name: str = "KIRISIMA", battery: int = 87) -> None:
        self.name = name
        self.battery = battery
        self.volts = 7.9
        #: layer port (0-3 inputs, 16-19 outputs) -> EV3 type code
        self.types: Dict[int, int] = {0: 126, 1: 30, 2: 30, 3: 30, 16: 126, 17: 7, 18: 126, 19: 7}
        self.distances_cm: Dict[int, float] = {1: 30.0, 2: 45.5, 3: 60.0}  # by port index 0-3
        self.tacho: Dict[int, int] = {0: 0, 1: 120, 2: 0, 3: -35}
        self.gyro_angle = 0.0
        self.gyro_rate = 0.0
        #: what the motors were told: (op, mask, power, ms)
        self.motor_log: List[Tuple[str, int, int, int]] = []
        self.motor_times: List[float] = []   # when each motor_log entry arrived
        self.beeps: List[Tuple[int, int, int]] = []
        self.commands: List[bytes] = []

    def execute(self, code: bytes, globals_buf: bytearray) -> None:
        i = 0
        while i < len(code):
            op = code[i]
            i += 1
            if op == 0x81:                      # opUI_READ
                sub = code[i]
                i += 1
                if sub == 0x12:                 # GET_LBATT (percent)
                    (_, g), i = _read_param(code, i)
                    globals_buf[g] = self.battery
                elif sub == 0x01:               # GET_VBATT
                    (_, g), i = _read_param(code, i)
                    globals_buf[g:g + 4] = struct.pack("<f", self.volts)
                elif sub in (0x0A, 0x09):       # GET_FW_VERS / GET_HW_VERS
                    size, i = _read_param(code, i)
                    (_, g), i = _read_param(code, i)
                    text = b"V1.09H" if sub == 0x0A else b"V0.60"
                    globals_buf[g:g + size] = (text + b"\x00" * size)[:size]
                else:
                    raise ValueError("opUI_READ %02X" % sub)
            elif op == 0xD3:                    # opCOM_GET
                sub = code[i]
                i += 1
                size, i = _read_param(code, i)
                (_, g), i = _read_param(code, i)
                globals_buf[g:g + size] = (self.name.encode("latin1") + b"\x00" * size)[:size]
            elif op == 0xB3:                    # opOUTPUT_GET_COUNT
                _layer, i = _read_param(code, i)
                idx, i = _read_param(code, i)
                (_, g), i = _read_param(code, i)
                globals_buf[g:g + 4] = struct.pack("<i", self.tacho[idx])
            elif op == 0x99:                    # opINPUT_DEVICE
                sub = code[i]
                i += 1
                if sub == 0x05:                 # GET_TYPEMODE
                    _layer, i = _read_param(code, i)
                    port, i = _read_param(code, i)
                    (_, g1), i = _read_param(code, i)
                    (_, g2), i = _read_param(code, i)
                    globals_buf[g1] = self.types.get(port, 126)
                    globals_buf[g2] = 0
                elif sub == 0x1D:               # READY_SI
                    _layer, i = _read_param(code, i)
                    port, i = _read_param(code, i)
                    _type, i = _read_param(code, i)
                    _mode, i = _read_param(code, i)
                    _count, i = _read_param(code, i)
                    (_, g), i = _read_param(code, i)
                    if self.types.get(port) == 32:      # a gyro: mode 0 angle, 1 rate
                        value = self.gyro_angle if _mode == 0 else self.gyro_rate
                    else:
                        value = self.distances_cm.get(port, float("nan"))
                    globals_buf[g:g + 4] = struct.pack("<f", value)
                else:
                    raise ValueError("opINPUT_DEVICE %02X" % sub)
            elif op == 0x94:                    # opSOUND TONE
                i += 1
                volume, i = _read_param(code, i)
                freq, i = _read_param(code, i)
                ms, i = _read_param(code, i)
                self.beeps.append((volume, freq, ms))
            elif op == 0xAD:                    # opOUTPUT_TIME_POWER
                _layer = code[i]
                mask = code[i + 1]
                i += 2
                power, i = _read_param(code, i)
                _up, i = _read_param(code, i)
                ms, i = _read_param(code, i)
                _down, i = _read_param(code, i)
                _brake, i = _read_param(code, i)
                self.motor_log.append(("time_power", mask, power, ms))
            elif op == 0xA3:                    # opOUTPUT_STOP
                _layer = code[i]
                mask = code[i + 1]
                _brake = code[i + 2]
                i += 3
                self.motor_log.append(("stop", mask, 0, 0))
            else:
                raise ValueError("unsupported opcode 0x%02X" % op)


class FakeSerial:
    """The COM port of a paired EV3, wired to a :class:`FakeBrick`."""

    def __init__(self, brick: FakeBrick, clock: FakeClock, *, read_step_s: float = 0.05) -> None:
        self.brick = brick
        self.clock = clock
        self.read_step_s = read_step_s
        self.rx = bytearray()
        self.closed = False
        self.silent = False            # the brick stops answering
        self.fail_writes = False       # the port breaks
        self.late_replies: List[bytes] = []   # sent before the next real reply
        self.garbage_next = False

    def write(self, data: bytes) -> int:
        if self.fail_writes:
            raise OSError("The semaphore timeout period has expired (121)")
        i = 0
        while i < len(data):
            (length,) = struct.unpack("<H", data[i:i + 2])
            body = data[i + 2:i + 2 + length]
            i += 2 + length
            cnt, cmd_type = struct.unpack("<HB", body[:3])
            n_globals = body[3] | ((body[4] & 0x03) << 8)
            code = body[5:]
            self.brick.commands.append(code)
            globals_buf = bytearray(n_globals)
            before = len(self.brick.motor_log)
            self.brick.execute(code, globals_buf)
            self.brick.motor_times.extend([self.clock.now] * (len(self.brick.motor_log) - before))
            if cmd_type & 0x80 or self.silent:
                continue
            for late in self.late_replies:
                self.rx += late
            self.late_replies = []
            if self.garbage_next:
                # A header claiming 2000 bytes, then a few stray ones.
                self.rx += b"\xd0\x07\x00\x01\x02"
                self.garbage_next = False
                continue
            payload = struct.pack("<HB", cnt, 0x02) + bytes(globals_buf)
            self.rx += struct.pack("<H", len(payload)) + payload
        return len(data)

    def read(self, n: int) -> bytes:
        if not self.rx:
            self.clock.now += self.read_step_s   # a read with nothing to read waits its timeout
            return b""
        chunk = bytes(self.rx[:n])
        del self.rx[:n]
        return chunk

    def reset_input_buffer(self) -> None:
        self.rx.clear()

    def close(self) -> None:
        self.closed = True


class FakePortFactory:
    """What ``serial.Serial(com, ...)`` does for each COM port on the fake PC."""

    def __init__(self, clock: FakeClock) -> None:
        self.clock = clock
        self.ports: Dict[str, FakeBrick] = {}
        self.errors: Dict[str, BaseException] = {}
        self.hang: Dict[str, threading.Event] = {}
        self.opened: List[FakeSerial] = []
        self.open_calls: List[str] = []

    def __call__(self, com: str) -> FakeSerial:
        self.open_calls.append(com)
        gate = self.hang.get(com)
        if gate is not None:
            gate.wait(10.0)            # Windows still connecting over the radio
        if com in self.errors:
            raise self.errors[com]
        if com not in self.ports:
            raise OSError("could not open port '%s': FileNotFoundError(2, 'The system cannot find the file specified.')" % com)
        ser = FakeSerial(self.ports[com], self.clock)
        self.opened.append(ser)
        return ser
