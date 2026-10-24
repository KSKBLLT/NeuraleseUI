"""LEGO MINDSTORMS EV3 on its own firmware, over Bluetooth, with direct commands.

Ported from the robotics prototype (``neuralese-robotics-prototype``,
``robots/ev3_robot.py`` at commit ``be2a4a5``), the driver that drove the EV3
"KIRISIMA". The link layer (:class:`Ev3Link`) keeps every rule the prototype
learned on the real brick; only these changed:

* the serial port and the clock are injected, so a fake brick can test it;
* time is monotonic (the prototype used wall time, which jumps);
* the left and right motor are never guessed from which ports hold motors
  (the prototype took "the first two"); they come from the user's geometry;
* the TCP/ev3dev branch is not here: that is a different robot setup.

Why the link is built the way it is (from the prototype's own notes):

* No operation can hang. Opening a Bluetooth COM port blocks while Windows
  connects over the radio, so it runs in a thread with a deadline. A thread
  abandoned at the deadline keeps the port until Windows gives up (20-40 s);
  opening the port again before that fails with "access denied" -- from
  ourselves -- so a new attempt first waits for the old one.
* Replies are read by the length in their header and matched by message
  number, so a late reply never stands in for the next one.
* Motors run on timed commands (OUTPUT_TIME_POWER): each lasts 300 ms. If the
  link drops, the robot stops by itself.
* A heartbeat asks for the battery once a second; 2.5 s without any reply
  stops the motors and reports the link as lost.
* Every failure becomes an :class:`Ev3Error` with a code, a sentence a child
  can read, what to do about it, and the technical detail for the log.
"""

from __future__ import annotations

import math
import struct
import threading
import time
from typing import Any, Callable, Dict, List, Optional, Sequence

from ..ir import (
    DIRECTION_IN,
    DIRECTION_OUT,
    TRANSPORT_BLUETOOTH,
    Geometry,
    PortIR,
    RobotIR,
    split_channel_id,
)
from .base import RobotDriver

LEGO_OUI = "001653"           # LEGO's MAC prefix: how an EV3 is told apart from other Bluetooth ports
OPEN_DEADLINE_S = 20.0        # how long Windows may take to bring the Bluetooth channel up
READ_TIMEOUT_S = 1.0          # waiting for the robot's reply
WRITE_TIMEOUT_S = 1.0         # a write to the port cannot hang longer
CLOSE_DEADLINE_S = 3.0
MOTOR_LEASE_MS = 300          # a motor stops by itself if no new command arrives in this time
MOTOR_REFRESH_S = 0.10        # how often an unchanged power is re-sent, to extend the lease
HEARTBEAT_S = 1.0             # how often the link is checked
LINK_LOST_S = 2.5             # this long without a reply = the link is lost
PENDING_WAIT_S = 45.0         # how long to wait for Windows to release a port after a hung attempt
LOW_BATTERY_PCT = 20          # below this, warn that the robot may switch off mid-run
NO_ECHO_MM = 2550             # the ultrasonic sensor's "nothing in range" (255 cm)

#: Port -> the open thread we abandoned at its deadline, which still holds the port.
_PENDING_OPENS: Dict[str, threading.Thread] = {}


# ---------------------------------------------------------------------------
# Errors a child can read
# ---------------------------------------------------------------------------

#: code -> {lang: (what happened, what to do)}. Russian is the prototype's text.
ERROR_TEXTS: Dict[str, Dict[str, tuple]] = {
    "NO_PYSERIAL": {
        "ru": ("Не установлен модуль связи с роботом (pyserial).",
               "Переустановите Neuralese или обратитесь к учителю."),
        "en": ("The robot connection module (pyserial) is not installed.",
               "Reinstall Neuralese or ask your teacher."),
        "kz": ("Роботпен байланыс модулі (pyserial) орнатылмаған.",
               "Neuralese-ті қайта орнатыңыз немесе мұғалімге хабарласыңыз."),
    },
    "NO_PORT": {
        "ru": ("EV3 ещё не добавлен в Bluetooth этого компьютера.",
               "Включите робота и добавьте его: "
               "Параметры → Bluetooth → Добавить устройство. Код на экране робота обычно 1234."),
        "kz": ("Компьютер бірде-бір EV3 роботын білмейді.",
               "Роботты қосып, оны компьютердің Bluetooth баптауларында қосыңыз "
               "(Параметрлер → Bluetooth → Құрылғы қосу). Робот экранындағы код әдетте 1234."),
        "en": ("This computer does not know any EV3 robot.",
               "Switch the robot on and connect it in the computer's Bluetooth settings "
               "(Settings → Bluetooth → Add device). The code on the robot's screen is usually 1234."),
    },
    "PORT_MISSING": {
        "ru": ("Такого порта на компьютере нет.",
               "Проверьте номер порта или не указывайте его — робот найдётся сам."),
        "kz": ("Компьютерде мұндай порт жоқ.",
               "Порт нөмірін тексеріңіз немесе оны көрсетпеңіз: робот өзі табылады."),
        "en": ("There is no such connection port on this computer.",
               "Check the port number, or leave it out and the robot will be found."),
    },
    "PORT_BUSY": {
        "ru": ("Робот уже подключён к другой программе.",
               "Закройте её (LEGO MINDSTORMS "
               "или второе окно Neuralese) и попробуйте ещё раз."),
        "kz": ("Роботпен байланысты басқа бағдарлама пайдаланып жатыр.",
               "Роботқа қосылған басқа бағдарламаларды (LEGO MINDSTORMS, "
               "Neuralese-тің екінші терезесі) жауып, қайталап көріңіз."),
        "en": ("Another program is using the connection to the robot.",
               "Close other programs that connected to the robot "
               "(LEGO MINDSTORMS, a second Neuralese window) and try again."),
    },
    "OPEN_TIMEOUT": {
        "ru": ("Робот не отвечает.",
               "Проверьте, что робот включён, на нём включён Bluetooth (значок вверху экрана) "
               "и робот стоит рядом с компьютером. Если не поможет, выключите и включите робота."),
        "kz": ("Робот Bluetooth арқылы жауап бермейді.",
               "Робот пен ондағы Bluetooth қосулы екенін (экранның жоғарғы жағындағы белгіше) "
               "және робот компьютерге жақын екенін тексеріңіз. Көмектеспесе, роботты өшіріп, қайта қосыңыз."),
        "en": ("The robot does not answer over Bluetooth.",
               "Check that the robot is on, its Bluetooth is on (the icon at the top of its screen) "
               "and it is near the computer. If that does not help, switch the robot off and on."),
    },
    "OPEN_FAILED": {
        "ru": ("Не удалось подключиться к роботу.",
               "Выключите и включите робота, потом попробуйте ещё раз."),
        "kz": ("Роботқа қосылу мүмкін болмады.",
               "Роботты өшіріп, қайта қосыңыз да, тағы көріңіз."),
        "en": ("Could not open the connection to the robot.",
               "Switch the robot off and on, then try again."),
    },
    "NO_REPLY": {
        "ru": ("Робот подключился, но не отвечает.",
               "Возможно, он завис или это другой робот. Перезапустите его и попробуйте ещё раз."),
        "kz": ("Байланыс орнады, бірақ робот жауап бермейді.",
               "Бұл басқа робот болуы немесе ол қатып қалуы мүмкін. Роботты қайта іске қосып, тағы көріңіз."),
        "en": ("The connection opened, but the robot is silent.",
               "It may be a different robot, or it has frozen. Restart the robot and try again."),
    },
    "LINK_LOST": {
        "ru": ("Связь с роботом пропала. Робот остановлен.",
               "Поставьте робота ближе к компьютеру, проверьте батарею и подключитесь снова."),
        "kz": ("Роботпен байланыс үзілді. Робот тоқтатылды.",
               "Роботты компьютерге жақындатып, батареясын тексеріңіз, содан кейін қайта қосылыңыз."),
        "en": ("The connection to the robot was lost. The robot has been stopped.",
               "Bring the robot closer to the computer and check its battery, then connect again."),
    },
}

_FALLBACK_TEXT = {
    "ru": ("Ошибка связи с роботом.", "Перезапустите робота."),
    "kz": ("Роботпен байланыс қатесі.", "Роботты қайта іске қосыңыз."),
    "en": ("Connection error with the robot.", "Restart the robot."),
}


class Ev3Error(Exception):
    """A failure that can be shown to a child as it is.

    code    -- machine code (for the UI and logs)
    message -- what happened, in plain words (English; see :meth:`text`)
    fix     -- what to do
    detail  -- the technical cause (for the log / developer)
    """

    def __init__(self, code: str, message: str, fix: str = "", detail: str = "") -> None:
        super().__init__(message)
        self.code = code
        self.message = message
        self.fix = fix
        self.detail = detail

    def text(self, lang: str = "en") -> tuple:
        """(message, fix) in a language the UI shows."""
        return ERROR_TEXTS.get(self.code, _FALLBACK_TEXT).get(lang) or _FALLBACK_TEXT["en"]

    def to_dict(self) -> Dict[str, Any]:
        return {
            "code": self.code,
            "message": self.message,
            "fix": self.fix,
            "detail": self.detail,
            "texts": {lang: {"message": m, "fix": f}
                      for lang, (m, f) in ERROR_TEXTS.get(self.code, _FALLBACK_TEXT).items()},
        }

    def __str__(self) -> str:
        s = self.message
        if self.fix:
            s += "\n  What to do: %s" % self.fix
        if self.detail:
            s += "\n  (technical cause: %s)" % self.detail
        return s


def ev3_error(code: str, detail: str = "") -> Ev3Error:
    message, fix = ERROR_TEXTS.get(code, _FALLBACK_TEXT)["en"]
    return Ev3Error(code, message, fix, detail)


# ---------------------------------------------------------------------------
# Direct-command encoding
# ---------------------------------------------------------------------------

def lc(value: int) -> bytes:
    """An integer as an EV3 LC parameter (LC0 / LC1 / LC2 / LC4)."""
    if -32 < value < 32:
        return bytes([value & 0x3F])
    if -128 <= value <= 127:
        return bytes([0x81, value & 0xFF])
    if -32768 <= value <= 32767:
        return bytes([0x82]) + struct.pack("<h", value)
    return bytes([0x83]) + struct.pack("<i", value)


def gv(index: int) -> bytes:
    """A reference to a reply global variable (GV0 + offset)."""
    if index < 32:
        return bytes([0x60 | index])
    return bytes([0xE1, index & 0xFF])


def port_mask(port_letter: str) -> int:
    return {"A": 0x01, "B": 0x02, "C": 0x04, "D": 0x08}.get(port_letter.upper(), 0x01)


#: Every motor, stop with brake, no reply -- written raw, outside the command lock.
EMERGENCY_STOP_FRAME = struct.pack("<HHBBB", 9, 0, 0x80, 0, 0) + bytes([0xA3, 0x00, 0x0F, 0x01])

#: EV3 device type codes (opINPUT_DEVICE GET_TYPEMODE) -> the IR's device ids.
DEVICE_TYPE_CODES: Dict[int, str] = {
    1: "touch",          # NXT touch
    4: "color",          # NXT colour
    5: "ultrasonic",     # NXT ultrasonic
    7: "large_motor",
    8: "medium_motor",
    16: "touch",
    29: "color",
    30: "ultrasonic",
    32: "gyro",
    33: "infrared",
}
#: Gyro channels and the EV3 gyro mode that reads them.
GYRO_MODES: Dict[str, int] = {"angle_deg": 0, "rate_dps": 1}
#: Port empty / wrong kind of port / unknown device.
TYPE_EMPTY = 126
TYPE_WRONG = 125
TYPE_UNKNOWN_SET = {0, 125, 126, 127, 255}


def _default_serial_factory(com: str):
    try:
        import serial  # pyserial, bundled with the runtime
    except ImportError as exc:
        raise ev3_error("NO_PYSERIAL", str(exc))
    return serial.Serial(com, 115200, timeout=READ_TIMEOUT_S, write_timeout=WRITE_TIMEOUT_S)


# ---------------------------------------------------------------------------
# The link
# ---------------------------------------------------------------------------

class Ev3Link:
    """One Bluetooth SPP link to an EV3 brick, speaking LEGO direct commands."""

    def __init__(
        self,
        com_port: str,
        *,
        serial_factory: Callable[[str], Any] = _default_serial_factory,
        clock: Callable[[], float] = time.monotonic,
        sleep: Callable[[float], None] = time.sleep,
        on_stage: Optional[Callable[[str], None]] = None,
    ) -> None:
        self.com_port = com_port
        self.serial_factory = serial_factory
        self.clock = clock
        self.sleep = sleep
        self._on_stage = on_stage
        self.ser: Any = None
        self.brick_name: Optional[str] = None
        self.battery_pct: Optional[int] = None
        self.warnings: List[str] = []
        self._counter = 0
        self._lock = threading.Lock()
        self._last_sent: Dict[str, tuple] = {}   # port -> (power, time sent)
        self._last_heartbeat = 0.0
        self._last_reply = 0.0

    @property
    def is_open(self) -> bool:
        return self.ser is not None

    def _stage(self, text: str) -> None:
        if self._on_stage:
            try:
                self._on_stage(text)
            except Exception:
                pass

    # -- low-level exchange ---------------------------------------------------

    def _open_serial_with_deadline(self, com: str):
        """Open the port in a thread, waiting no longer than the deadline.

        An abandoned thread keeps the port until Windows gives up (~20-40 s).
        Opening it again at once gives "access denied" -- from ourselves -- so
        first wait for the previous attempt to finish.
        """
        prev = _PENDING_OPENS.get(com)
        if prev is not None and prev.is_alive():
            self._stage("Waiting for Windows to finish the previous connection attempt...")
            prev.join(PENDING_WAIT_S)
            if prev.is_alive():
                raise ev3_error("OPEN_TIMEOUT", "%s: the previous open attempt is still hanging" % com)

        box: Dict[str, Any] = {}
        abandoned = threading.Event()

        def worker() -> None:
            try:
                s = self.serial_factory(com)
                if abandoned.is_set():
                    try:
                        s.close()
                    except Exception:
                        pass
                    return
                box["ser"] = s
            except Ev3Error as e:
                box["ev3"] = e
            except Exception as e:  # noqa: BLE001 -- classified below
                box["exc"] = e

        t = threading.Thread(target=worker, name="ev3-open-%s" % com, daemon=True)
        _PENDING_OPENS[com] = t
        t.start()
        t.join(OPEN_DEADLINE_S)
        if t.is_alive():
            abandoned.set()
            raise ev3_error("OPEN_TIMEOUT", "%s: opening the port took longer than %.0f s" % (com, OPEN_DEADLINE_S))
        _PENDING_OPENS.pop(com, None)
        if "ev3" in box:
            raise box["ev3"]
        if "exc" in box:
            raise classify_open_error(com, box["exc"])
        return box["ser"]

    def _write(self, data: bytes) -> None:
        try:
            self.ser.write(data)
        except Exception as e:  # SerialTimeoutException, SerialException, OSError
            self._drop_link()
            raise ev3_error("LINK_LOST", "writing to the port: %s: %s" % (type(e).__name__, e))

    def _read_exact(self, n: int, deadline: float) -> bytes:
        buf = b""
        while len(buf) < n:
            if self.clock() > deadline:
                break
            try:
                chunk = self.ser.read(n - len(buf))
            except Exception as e:
                self._drop_link()
                raise ev3_error("LINK_LOST", "reading from the port: %s: %s" % (type(e).__name__, e))
            if chunk:
                buf += chunk
        return buf

    def direct(self, bytecodes: bytes, n_globals: int = 0, reply: bool = False,
               timeout: float = READ_TIMEOUT_S) -> Optional[bytes]:
        """Send a direct command. With ``reply``, return the reply's global
        variables (without the header), or None if the robot did not answer in time."""
        if self.ser is None:
            return None
        with self._lock:
            self._counter = (self._counter + 1) & 0xFFFF
            cnt = self._counter
            cmd_type = 0x00 if reply else 0x80
            body = struct.pack("<HB", cnt, cmd_type) + bytes([n_globals & 0xFF, (n_globals >> 8) & 0x03]) + bytecodes
            self._write(struct.pack("<H", len(body)) + body)
            if not reply:
                return None
            deadline = self.clock() + timeout
            while self.clock() < deadline:
                hdr = self._read_exact(2, deadline)
                if len(hdr) < 2:
                    return None
                (length,) = struct.unpack("<H", hdr)
                if length < 3 or length > 1024:
                    # garbage in the stream: flush the buffer and give up on this reply
                    try:
                        self.ser.reset_input_buffer()
                    except Exception:
                        pass
                    return None
                payload = self._read_exact(length, deadline)
                if len(payload) < length:
                    return None
                r_cnt, r_type = struct.unpack("<HB", payload[:3])
                if r_cnt != cnt:
                    continue  # a late reply to an older command: skip it
                self._last_reply = self.clock()
                if r_type != 0x02:
                    return None  # DIRECT_REPLY_ERROR
                return payload[3:]
            return None

    def _drop_link(self) -> None:
        """The port is broken: close it without waiting, so nothing hangs."""
        s, self.ser = self.ser, None
        if s is not None:
            threading.Thread(target=_safe_close, args=(s,), daemon=True).start()

    # -- queries -----------------------------------------------------------------

    def query_battery_percent(self) -> Optional[int]:
        r = self.direct(bytes([0x81, 0x12]) + gv(0), n_globals=1, reply=True)
        return r[0] if r else None

    def query_battery_volts(self) -> Optional[float]:
        r = self.direct(bytes([0x81, 0x01]) + gv(0), n_globals=4, reply=True)
        return struct.unpack("<f", r[:4])[0] if r and len(r) >= 4 else None

    def _query_string(self, bytecodes_prefix: bytes, size: int) -> Optional[str]:
        r = self.direct(bytecodes_prefix + lc(size) + gv(0), n_globals=size, reply=True)
        if not r:
            return None
        return r.split(b"\x00")[0].decode("latin1", "ignore").strip() or None

    def query_firmware(self) -> Optional[str]:
        return self._query_string(bytes([0x81, 0x0A]), 16)   # opUI_READ GET_FW_VERS

    def query_hardware(self) -> Optional[str]:
        return self._query_string(bytes([0x81, 0x09]), 8)    # opUI_READ GET_HW_VERS

    def query_brick_name(self) -> Optional[str]:
        return self._query_string(bytes([0xD3, 0x0D]), 32)   # opCOM_GET GET_BRICKNAME

    def query_tacho(self, port_letter: str) -> Optional[int]:
        """A motor's encoder count (degrees)."""
        idx = ord(port_letter.upper()) - ord("A")
        if not (0 <= idx <= 3):
            return None
        r = self.direct(bytes([0xB3, 0x00, idx]) + gv(0), n_globals=4, reply=True)
        return struct.unpack("<i", r[:4])[0] if r and len(r) >= 4 else None

    def query_device_type(self, layer_port: int) -> Optional[int]:
        """Device type on a port. Inputs 1-4 are 0..3, outputs A-D are 16..19."""
        r = self.direct(bytes([0x99, 0x05, 0x00]) + lc(layer_port) + gv(0) + gv(1), n_globals=2, reply=True)
        return r[0] if r else None

    def query_ultrasonic_cm(self, port_num: int) -> Optional[float]:
        """Distance in cm from an ultrasonic sensor (ports 1-4)."""
        if not (1 <= port_num <= 4):
            return None
        port_idx = port_num - 1
        # opINPUT_DEVICE READY_SI (0x99, 0x1D), layer 0, port, type 0 (auto), mode 0 (cm), 1 value
        code = bytes([0x99, 0x1D, 0x00]) + lc(port_idx) + bytes([0x00, 0x00, 0x01]) + gv(0)
        r = self.direct(code, n_globals=4, reply=True)
        if r and len(r) >= 4:
            val = struct.unpack("<f", r[:4])[0]
            if not math.isnan(val) and 0.0 <= val <= 255.0:
                return float(val)
            elif val > 255.0:
                return 255.0
        return None

    def query_ultrasonic_batch_cm(self, ports: Sequence[int] = (4, 3, 2)) -> Dict[int, Optional[float]]:
        """Several ultrasonic sensors in one Bluetooth round trip."""
        code = b""
        n_globals = len(ports) * 4
        for i, p in enumerate(ports):
            code += bytes([0x99, 0x1D, 0x00]) + lc(p - 1) + bytes([0x00, 0x00, 0x01]) + gv(i * 4)
        r = self.direct(code, n_globals=n_globals, reply=True)
        results: Dict[int, Optional[float]] = {}
        if r and len(r) >= n_globals:
            for i, p in enumerate(ports):
                val = struct.unpack("<f", r[i * 4:(i + 1) * 4])[0]
                if not math.isnan(val) and 0.0 <= val <= 255.0:
                    results[p] = float(val)
                elif val > 255.0:
                    results[p] = 255.0
                else:
                    results[p] = 0.0
            return results
        # Fall back to one sensor at a time.
        for p in ports:
            results[p] = self.query_ultrasonic_cm(p)
        return results

    def query_batch(self, sonar_ports: Sequence[int] = (), gyro_reads: Sequence[tuple] = (),
                    tacho_letters: Sequence[str] = ()) -> Dict[str, Any]:
        """Everything a drive tick reads, in one Bluetooth round trip.

        The prototype read its three sonars in one command because every round
        trip costs 10-30 ms at 20 Hz; encoders and a gyro go into the same
        command for the same reason. ``gyro_reads`` are ``(port_num, mode)``
        pairs: mode 0 is the angle in degrees, 1 the turn rate in deg/s.
        Values that did not come back are None.
        """
        code = b""
        offset = 0
        layout = []
        for p in sonar_ports:
            code += bytes([0x99, 0x1D, 0x00]) + lc(p - 1) + bytes([0x00, 0x00, 0x01]) + gv(offset)
            layout.append(("sonar", p, offset)); offset += 4
        for p, mode in gyro_reads:
            code += bytes([0x99, 0x1D, 0x00]) + lc(p - 1) + bytes([0x00]) + lc(mode) + bytes([0x01]) + gv(offset)
            layout.append(("gyro", (p, mode), offset)); offset += 4
        for letter in tacho_letters:
            idx = ord(letter.upper()) - ord("A")
            code += bytes([0xB3, 0x00, idx]) + gv(offset)
            layout.append(("tacho", letter.upper(), offset)); offset += 4
        result: Dict[str, Any] = {"sonar": {}, "gyro": {}, "tacho": {}}
        if not code:
            return result
        r = self.direct(code, n_globals=offset, reply=True)
        for kind, key, at in layout:
            raw = r[at:at + 4] if r and len(r) >= at + 4 else None
            if raw is None:
                result[kind][key] = None
            elif kind == "tacho":
                result[kind][key] = struct.unpack("<i", raw)[0]
            else:
                val = struct.unpack("<f", raw)[0]
                if kind == "sonar":
                    result[kind][key] = 255.0 if val > 255.0 else (float(val) if not math.isnan(val) and val >= 0.0 else 0.0)
                else:
                    result[kind][key] = None if math.isnan(val) else float(val)
        return result

    def check_link(self, force: bool = False) -> None:
        """Heartbeat: ask for the battery every HEARTBEAT_S. No reply for LINK_LOST_S is an error."""
        if self.ser is None:
            return
        now = self.clock()
        if not force and now - self._last_heartbeat < HEARTBEAT_S:
            return
        self._last_heartbeat = now
        ok = self.query_battery_percent() is not None
        if not ok and self.clock() - self._last_reply > LINK_LOST_S:
            self.emergency_stop()
            self._drop_link()
            raise ev3_error("LINK_LOST", "the robot has not answered for %.1f s" % LINK_LOST_S)

    def beep(self, freq_hz: int = 1000, duration_ms: int = 300, volume: int = 50) -> None:
        self.direct(bytes([0x94, 0x01]) + lc(volume) + lc(freq_hz) + lc(duration_ms))

    # -- connection ----------------------------------------------------------------

    def connect(self, attempts: int = 2) -> None:
        """Open the link and check the brick answers. Raises Ev3Error with the reason."""
        last: Optional[Ev3Error] = None
        for attempt in range(1, attempts + 1):
            try:
                self._connect_once()
                return
            except Ev3Error as e:
                last = e
                # PORT_*: retrying will not help. OPEN_TIMEOUT: the hung open still
                # holds the port, a retry only adds waiting -- say at once that the
                # robot does not answer.
                if e.code in ("PORT_MISSING", "PORT_BUSY", "NO_PYSERIAL", "OPEN_TIMEOUT"):
                    raise
                if attempt < attempts:
                    self._stage("Attempt %d failed (%s), trying again..." % (attempt, e.code))
                    self.sleep(1.5)
        assert last is not None
        raise last

    def _connect_once(self) -> None:
        com = self.com_port
        self._stage("Connecting to the robot over Bluetooth (%s)..." % com)
        t0 = self.clock()
        self.ser = self._open_serial_with_deadline(com)
        self._stage("Channel open in %.1f s, waiting for the robot to answer..." % (self.clock() - t0))
        try:
            self.ser.reset_input_buffer()
        except Exception:
            pass
        batt = None
        for _ in range(3):
            batt = self.query_battery_percent()
            if batt is not None:
                break
        if batt is None:
            self._drop_link()
            raise ev3_error("NO_REPLY", "%s: no reply to the battery request" % com)
        self.brick_name = self.query_brick_name() or "EV3"
        self.battery_pct = batt
        self.warnings = []
        self._stage("Robot \"%s\" is connected (battery %d%%)." % (self.brick_name, batt))
        if batt < LOW_BATTERY_PCT:
            self.warnings.append("low_battery")

        types = {p: self.query_device_type(16 + i) for i, p in enumerate("ABCD")}
        found = [p for p, t in types.items() if t in (7, 8)]
        if all(t is not None for t in types.values()) and not found:
            self.warnings.append("no_motors")
        elif len(found) == 1:
            self.warnings.append("one_motor")
        self._last_sent.clear()
        self._last_heartbeat = self.clock()
        self._last_reply = self.clock()
        self.beep(1200, 150, 40)

    def emergency_stop(self) -> None:
        """Stop every motor, never raising."""
        if self.ser is not None:
            try:
                self.ser.write(EMERGENCY_STOP_FRAME)
            except Exception:
                pass
        self._last_sent.clear()

    def disconnect(self) -> None:
        if self.ser is None:
            return
        self.emergency_stop()
        s, self.ser = self.ser, None
        t = threading.Thread(target=_safe_close, args=(s,), daemon=True)
        t.start()
        t.join(CLOSE_DEADLINE_S)
        self._stage("Disconnected.")

    # -- motors ----------------------------------------------------------------------

    @staticmethod
    def motor_bytecode(port_letter: str, power: int) -> bytes:
        mask = port_mask(port_letter)
        if power == 0:
            return bytes([0xA3, 0x00, mask, 0x01])  # opOUTPUT_STOP, brake
        # opOUTPUT_TIME_POWER: layer, nos, power, ramp_up, run_ms, ramp_down, brake
        return bytes([0xAD, 0x00, mask]) + lc(power) + lc(0) + lc(MOTOR_LEASE_MS) + lc(0) + lc(1)

    def set_motors(self, powers: Dict[str, float]) -> None:
        """Set several motors (by port letter) in one command. An unchanged
        power is re-sent no more often than MOTOR_REFRESH_S, only to extend the lease."""
        now = self.clock()
        code = b""
        for port_letter, value in powers.items():
            power = int(round(max(-100.0, min(100.0, float(value)))))
            prev = self._last_sent.get(port_letter)
            if prev and prev[0] == power and (power == 0 or now - prev[1] < MOTOR_REFRESH_S):
                continue
            code += self.motor_bytecode(port_letter, power)
            self._last_sent[port_letter] = (power, now)
        if code:
            self.direct(code)


def _safe_close(s: Any) -> None:
    try:
        s.close()
    except Exception:
        pass


def classify_open_error(com: str, exc: BaseException) -> Ev3Error:
    """What a failed open of a Bluetooth COM port means for the child."""
    text = str(exc)
    low = ("%s %s" % (type(exc).__name__, text)).lower()
    if "filenotfound" in low:
        return ev3_error("PORT_MISSING", "%s: %s" % (com, text))
    if "permissionerror" in low or "access is denied" in low or "отказано" in low:
        return ev3_error("PORT_BUSY", "%s: %s" % (com, text))
    # 121 semaphore timeout, 1231 "remote system not reachable", 1167 device not
    # connected: all mean the robot is off or too far away.
    unreachable = ("semaphore", "timeout", "121", "1231", "1167",
                   "удаленная система", "удалённая система", "remote system",
                   "not connected", "не подключено", "превышен таймаут")
    if any(k in low for k in unreachable):
        return ev3_error("OPEN_TIMEOUT", "%s: %s" % (com, text))
    return ev3_error("OPEN_FAILED", "%s: %s" % (com, text))


# ---------------------------------------------------------------------------
# The driver
# ---------------------------------------------------------------------------

INPUT_PORTS = ("in1", "in2", "in3", "in4")
OUTPUT_PORTS = ("outA", "outB", "outC", "outD")


class Ev3DirectDriver(RobotDriver):
    """An EV3 on stock firmware, behind the same interface as the Dummy."""

    def __init__(
        self,
        com_port: str,
        *,
        mac: str = "",
        name: str = "",
        proximity: Optional[Dict[str, Any]] = None,
        geometry: Optional[Geometry] = None,
        link: Optional[Ev3Link] = None,
    ) -> None:
        self.com_port = com_port
        self.mac = mac
        self.name = name
        self.proximity = proximity
        self.geometry = geometry or Geometry()
        self.link = link or Ev3Link(com_port)
        self.device_types: Dict[str, Optional[int]] = {}

    @property
    def robot_id(self) -> str:
        return "ev3:%s" % (self.mac or self.com_port)

    def open(self, now: float) -> None:
        if not self.link.is_open:   # connect_ev3 hands over a link that is already up
            self.link.connect()
        self.refresh_ports()

    def refresh_ports(self) -> None:
        """Ask the brick what is plugged into each of its eight ports."""
        for i, port_id in enumerate(INPUT_PORTS):
            self.device_types[port_id] = self.link.query_device_type(i)
        for i, port_id in enumerate(OUTPUT_PORTS):
            self.device_types[port_id] = self.link.query_device_type(16 + i)

    def close(self) -> None:
        self.link.disconnect()

    def inventory(self) -> RobotIR:
        ports = []
        for port_id in INPUT_PORTS + OUTPUT_PORTS:
            direction = DIRECTION_IN if port_id.startswith("in") else DIRECTION_OUT
            code = self.device_types.get(port_id)
            device = DEVICE_TYPE_CODES.get(code, "") if code is not None else ""
            # A sensor code on a motor port (or the reverse) is not a device we can use.
            if device and (device.endswith("motor")) != (direction == DIRECTION_OUT):
                device = ""
            ports.append(PortIR(port_id, port_id[2:] if direction == DIRECTION_IN else port_id[3:],
                                direction, device, code is not None))
        return RobotIR(
            robot_id=self.robot_id,
            platform="ev3_direct",
            name=self.name or self.link.brick_name or "EV3",
            model="LEGO MINDSTORMS EV3",
            transport=TRANSPORT_BLUETOOTH,
            status="connected" if self.link.is_open else "available",
            battery_pct=self.link.battery_pct,
            proximity=dict(self.proximity) if self.proximity else None,
            ports=ports,
            capabilities=["beep"],
            geometry=self.geometry,
        )

    def tick(self, now: float) -> None:
        self.link.check_link()

    def read(self, channels: Sequence[str], now: float) -> List[int]:
        # Every sensor, gyro and encoder in one round trip, as the prototype's
        # drive loop read its sonars.
        sonar_ports: List[int] = []
        gyro_reads: List[tuple] = []
        tacho_letters: List[str] = []
        for channel in channels:
            port, suffix = split_channel_id(str(channel))
            if suffix == "distance_mm" and port in INPUT_PORTS and int(port[2:]) not in sonar_ports:
                sonar_ports.append(int(port[2:]))
            elif suffix in GYRO_MODES and port in INPUT_PORTS and (int(port[2:]), GYRO_MODES[suffix]) not in gyro_reads:
                gyro_reads.append((int(port[2:]), GYRO_MODES[suffix]))
            elif suffix in ("position_deg", "speed_dps") and port in OUTPUT_PORTS and port[3:] not in tacho_letters:
                tacho_letters.append(port[3:])
        batch = self.link.query_batch(sonar_ports, gyro_reads, tacho_letters)
        values: List[int] = []
        for channel in channels:
            port, suffix = split_channel_id(str(channel))
            if suffix == "distance_mm" and port in INPUT_PORTS:
                cm = batch["sonar"].get(int(port[2:]))
                values.append(NO_ECHO_MM if cm is None else int(round(cm * 10.0)))
            elif suffix in GYRO_MODES and port in INPUT_PORTS:
                value = batch["gyro"].get((int(port[2:]), GYRO_MODES[suffix]))
                values.append(0 if value is None else int(round(value)))
            elif suffix == "position_deg" and port in OUTPUT_PORTS:
                tacho = batch["tacho"].get(port[3:].upper())
                values.append(0 if tacho is None else int(tacho))
            elif suffix == "power" and port in OUTPUT_PORTS:
                sent = self.link._last_sent.get(port[3:])
                values.append(int(sent[0]) if sent else 0)
            else:
                raise KeyError("The EV3 driver cannot read %s yet." % channel)
        return values

    def write(self, values: Dict[str, int], now: float) -> None:
        powers: Dict[str, float] = {}
        for channel, value in values.items():
            port, suffix = split_channel_id(str(channel))
            if suffix != "power" or port not in OUTPUT_PORTS:
                raise KeyError("The EV3 driver cannot drive %s." % channel)
            powers[port[3:]] = float(value)
        self.link.set_motors(powers)

    def stop(self, now: float) -> None:
        self.link.emergency_stop()

    def beep(self, now: float, frequency_hz: int = 1000, duration_ms: int = 200) -> None:
        self.link.beep(frequency_hz, duration_ms, 60)
