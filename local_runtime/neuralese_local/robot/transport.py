"""Links between the host and the robot, behind one interface.

Every transport is byte-oriented and non-blocking-ish: :meth:`Transport.read`
returns whatever is available right now and never waits for a whole frame.
Reassembly into lines is :class:`..codec.LineReader`'s job, so no transport has
to know anything about the protocol.

Which transport each robot actually uses, and why
-------------------------------------------------
* **micro:bit -> serial.** It enumerates as a USB CDC port the instant it is
  plugged in. No pairing, no driver, no OS permission dialog.
* **SPIKE Prime -> serial.** Same, via the Pybricks firmware's USB REPL.
* **EV3 -> TCP.** The EV3 has no USB serial port at all; USB presents it as a
  *network* interface, so the brick is reached at ``ev3dev.local``.
* **BLE** is offered as an opt-in alternative on the two hubs that support it,
  never as the default: pairing plus an OS Bluetooth permission prompt is a real
  wall for a child, and the latency is worse and less predictable than a wire.

WiFi is not offered anywhere. The micro:bit and the SPIKE hub have no WiFi
radio, and on the EV3 it needs a specific USB dongle -- so a "WiFi" option would
be a dead end for most users. A browser-side WebSocket link was considered and
rejected for the same class of reason: reaching these devices from a page needs
Web Serial or Web Bluetooth, which would restrict the whole feature to Chrome
and put a browser tab in the middle of a robot's control loop.
"""

from __future__ import annotations

import socket
import time
from typing import Any, Dict, List, Optional

from .errors import ERR_LINK_FAILED, LinkError, MissingDependencyError

# USB identifiers used to pick the right port without asking the child which
# COM port their robot is. (vendor id, product id or None for "any").
KNOWN_USB_IDS: Dict[str, List[Any]] = {
    # micro:bit v1/v2 present the DAPLink CDC interface.
    "microbit": [(0x0D28, 0x0204)],
    # LEGO's vendor id; the SPIKE hub running Pybricks appears under it.
    "spike": [(0x0694, None)],
}


class Transport:
    """Byte pipe to a robot."""

    #: Set by subclasses; surfaces in telemetry and error messages.
    kind = "abstract"

    def open(self) -> None:
        raise NotImplementedError

    def close(self) -> None:
        raise NotImplementedError

    def read(self, max_bytes: int = 4096) -> bytes:
        """Return bytes available now, possibly empty. Must not block long."""
        raise NotImplementedError

    def write(self, data: bytes) -> None:
        raise NotImplementedError

    @property
    def is_open(self) -> bool:
        raise NotImplementedError

    def describe(self) -> Dict[str, Any]:
        return {"kind": self.kind}

    def __enter__(self) -> "Transport":
        self.open()
        return self

    def __exit__(self, *exc: Any) -> None:
        self.close()


class LoopbackTransport(Transport):
    """In-process link used by the tests and by the emulator harness.

    Both ends are plain buffers, so a full bridge run -- handshake, inference,
    watchdog, shutdown -- can be exercised deterministically with no hardware,
    no serial port and no timing luck.
    """

    kind = "loopback"

    def __init__(self) -> None:
        self._open = False
        #: Bytes the host will read (i.e. what the robot "sent").
        self.to_host = bytearray()
        #: Bytes the host has written (i.e. what the robot would receive).
        self.to_robot = bytearray()

    def open(self) -> None:
        self._open = True

    def close(self) -> None:
        self._open = False

    def read(self, max_bytes: int = 4096) -> bytes:
        chunk = bytes(self.to_host[:max_bytes])
        del self.to_host[: len(chunk)]
        return chunk

    def write(self, data: bytes) -> None:
        if not self._open:
            raise LinkError("Loopback transport is closed.", code=ERR_LINK_FAILED)
        self.to_robot.extend(data)

    @property
    def is_open(self) -> bool:
        return self._open

    # -- test-side helpers ---------------------------------------------------

    def robot_send(self, data: bytes) -> None:
        """Queue bytes as if the robot had transmitted them."""
        self.to_host.extend(data)

    def robot_receive(self) -> bytes:
        """Drain everything the host has sent to the robot."""
        chunk = bytes(self.to_robot)
        self.to_robot.clear()
        return chunk


class SerialTransport(Transport):
    """USB CDC serial link (micro:bit, SPIKE Prime)."""

    kind = "serial"

    def __init__(self, port: str = "", baud: int = 115200, platform_id: str = "", timeout: float = 0.0) -> None:
        self.port = port
        self.baud = int(baud)
        self.platform_id = platform_id
        self.timeout = timeout
        self._serial = None

    @staticmethod
    def _pyserial():
        try:
            import serial  # type: ignore
            import serial.tools.list_ports  # type: ignore
        except ImportError as exc:
            raise MissingDependencyError(
                "Connecting to a robot over USB needs the 'pyserial' package, which "
                "is not installed in this runtime.",
                details={"package": "pyserial"},
            ) from exc
        return serial

    @classmethod
    def list_ports(cls, platform_id: str = "") -> List[Dict[str, Any]]:
        """Enumerate candidate ports, most likely first.

        Exposed for the UI: it can show a picker, but because known robots are
        flagged it can also just pick one and never ask.
        """
        serial = cls._pyserial()
        wanted = KNOWN_USB_IDS.get(platform_id, [])
        found: List[Dict[str, Any]] = []
        for info in serial.tools.list_ports.comports():
            matches = any(
                info.vid == vid and (pid is None or info.pid == pid)
                for vid, pid in wanted
            )
            found.append({
                "port": info.device,
                "description": info.description or "",
                "vid": info.vid,
                "pid": info.pid,
                "serial_number": info.serial_number or "",
                "likely_robot": matches,
            })
        found.sort(key=lambda item: (not item["likely_robot"], item["port"]))
        return found

    def _autodetect(self) -> str:
        ports = self.list_ports(self.platform_id)
        for entry in ports:
            if entry["likely_robot"]:
                return str(entry["port"])
        if len(ports) == 1:
            return str(ports[0]["port"])
        if not ports:
            raise LinkError(
                "No USB device found. Plug the robot in with a data cable "
                "(some charging cables carry no data) and try again.",
                code=ERR_LINK_FAILED,
            )
        raise LinkError(
            "Several USB devices are connected and none of them is recognisably a "
            "robot. Choose the port to use.",
            code=ERR_LINK_FAILED,
            details={"ports": ports},
        )

    def open(self) -> None:
        serial = self._pyserial()
        port = self.port or self._autodetect()
        try:
            self._serial = serial.Serial(port=port, baudrate=self.baud, timeout=self.timeout, write_timeout=1.0)
        except Exception as exc:
            raise LinkError(
                "Could not open %s: %s" % (port, exc),
                code=ERR_LINK_FAILED,
                details={"port": port},
            ) from exc
        self.port = port
        # Whatever the device emitted before we attached is not ours to parse.
        try:
            self._serial.reset_input_buffer()
            self._serial.reset_output_buffer()
        except Exception:
            pass

    def close(self) -> None:
        if self._serial is not None:
            try:
                self._serial.close()
            finally:
                self._serial = None

    def read(self, max_bytes: int = 4096) -> bytes:
        if self._serial is None:
            return b""
        waiting = self._serial.in_waiting
        if not waiting:
            return b""
        return self._serial.read(min(waiting, max_bytes))

    def write(self, data: bytes) -> None:
        if self._serial is None:
            raise LinkError("Serial link is not open.", code=ERR_LINK_FAILED)
        self._serial.write(data)

    @property
    def is_open(self) -> bool:
        return self._serial is not None and bool(self._serial.is_open)

    def describe(self) -> Dict[str, Any]:
        return {"kind": self.kind, "port": self.port, "baud": self.baud}


class TcpTransport(Transport):
    """TCP link, used for the EV3 over its USB network interface."""

    kind = "tcp"

    def __init__(self, host: str = "ev3dev.local", port: int = 9999, connect_timeout: float = 5.0) -> None:
        self.host = host
        self.port = int(port)
        self.connect_timeout = connect_timeout
        self._socket: Optional[socket.socket] = None

    def open(self) -> None:
        try:
            self._socket = socket.create_connection((self.host, self.port), timeout=self.connect_timeout)
        except OSError as exc:
            raise LinkError(
                "Could not reach the robot at %s:%d (%s). Check it is switched on, "
                "plugged in, and that the program is running on the brick."
                % (self.host, self.port, exc),
                code=ERR_LINK_FAILED,
                details={"host": self.host, "port": self.port},
            ) from exc
        self._socket.setblocking(False)
        # Control frames are tiny and latency-critical; Nagle would sit on them
        # waiting for more data and add tens of milliseconds to every command.
        try:
            self._socket.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        except OSError:
            pass

    def close(self) -> None:
        if self._socket is not None:
            try:
                self._socket.close()
            finally:
                self._socket = None

    def read(self, max_bytes: int = 4096) -> bytes:
        if self._socket is None:
            return b""
        try:
            chunk = self._socket.recv(max_bytes)
        except BlockingIOError:
            return b""
        except OSError as exc:
            raise LinkError("Lost the connection to the robot: %s" % exc, code=ERR_LINK_FAILED) from exc
        if chunk == b"":
            raise LinkError("The robot closed the connection.", code=ERR_LINK_FAILED)
        return chunk

    def write(self, data: bytes) -> None:
        if self._socket is None:
            raise LinkError("TCP link is not open.", code=ERR_LINK_FAILED)
        try:
            self._socket.sendall(data)
        except OSError as exc:
            raise LinkError("Could not send to the robot: %s" % exc, code=ERR_LINK_FAILED) from exc

    @property
    def is_open(self) -> bool:
        return self._socket is not None

    def describe(self) -> Dict[str, Any]:
        return {"kind": self.kind, "host": self.host, "port": self.port}


class BleTransport(Transport):
    """Bluetooth Low Energy link over the Nordic UART Service.

    Opt-in alternative to the wire on micro:bit and SPIKE Prime. It runs
    ``bleak``'s asyncio loop on a private thread and exposes the same plain
    byte-pipe interface as the wired transports, so nothing above this class
    changes when a child switches to wireless.

    Two caveats, both deliberate rather than incidental:

    * ``bleak`` is not part of the shipped runtime today, so this raises a clean
      "not installed" error rather than failing obscurely.
    * BLE writes are capped near 20 bytes per packet by the negotiated MTU, so
      frames are split here. That is also why the wire format is compact.
    """

    kind = "ble"

    NUS_SERVICE = "6e400001-b5a3-f393-e0a9-e50e24dcca9e"
    NUS_RX_CHAR = "6e400002-b5a3-f393-e0a9-e50e24dcca9e"  # host writes here
    NUS_TX_CHAR = "6e400003-b5a3-f393-e0a9-e50e24dcca9e"  # robot notifies here

    CHUNK_BYTES = 20

    def __init__(self, address: str = "", name_prefix: str = "", connect_timeout: float = 15.0) -> None:
        self.address = address
        self.name_prefix = name_prefix
        self.connect_timeout = connect_timeout
        self._client = None
        self._loop = None
        self._thread = None
        self._inbox = bytearray()
        self._lock = None

    @staticmethod
    def _bleak():
        try:
            import bleak  # type: ignore
        except ImportError as exc:
            raise MissingDependencyError(
                "Connecting to a robot over Bluetooth needs the 'bleak' package, "
                "which is not installed in this runtime. Use the USB cable, or "
                "install bleak into the local runtime.",
                details={"package": "bleak"},
            ) from exc
        return bleak

    def open(self) -> None:
        import asyncio
        import threading

        bleak = self._bleak()
        self._lock = threading.Lock()
        self._loop = asyncio.new_event_loop()
        ready = threading.Event()

        def run_loop() -> None:
            asyncio.set_event_loop(self._loop)
            ready.set()
            self._loop.run_forever()

        self._thread = threading.Thread(target=run_loop, name="neuralese-ble", daemon=True)
        self._thread.start()
        ready.wait(5.0)

        async def connect() -> Any:
            address = self.address
            if not address:
                devices = await bleak.BleakScanner.discover(timeout=6.0)
                for device in devices:
                    if self.name_prefix and str(device.name or "").startswith(self.name_prefix):
                        address = device.address
                        break
                if not address:
                    raise LinkError(
                        "No Bluetooth robot found. Make sure it is switched on and "
                        "advertising, or connect it with the USB cable instead.",
                        code=ERR_LINK_FAILED,
                    )
            client = bleak.BleakClient(address, timeout=self.connect_timeout)
            await client.connect()
            await client.start_notify(self.NUS_TX_CHAR, self._on_notify)
            return client

        self._client = self._run_sync(connect(), timeout=self.connect_timeout + 10.0)
        self.address = getattr(self._client, "address", self.address)

    def _on_notify(self, _sender: Any, data: bytearray) -> None:
        with self._lock:
            self._inbox.extend(data)

    def _run_sync(self, coro: Any, timeout: float = 10.0) -> Any:
        import asyncio

        if self._loop is None:
            raise LinkError("Bluetooth link is not open.", code=ERR_LINK_FAILED)
        future = asyncio.run_coroutine_threadsafe(coro, self._loop)
        try:
            return future.result(timeout=timeout)
        except LinkError:
            raise
        except Exception as exc:
            raise LinkError("Bluetooth link failed: %s" % exc, code=ERR_LINK_FAILED) from exc

    def close(self) -> None:
        if self._client is not None:
            try:
                self._run_sync(self._client.disconnect(), timeout=5.0)
            except Exception:
                pass
            self._client = None
        if self._loop is not None:
            self._loop.call_soon_threadsafe(self._loop.stop)
            if self._thread is not None:
                self._thread.join(timeout=2.0)
            self._loop = None
            self._thread = None

    def read(self, max_bytes: int = 4096) -> bytes:
        if self._lock is None:
            return b""
        with self._lock:
            chunk = bytes(self._inbox[:max_bytes])
            del self._inbox[: len(chunk)]
        return chunk

    def write(self, data: bytes) -> None:
        if self._client is None:
            raise LinkError("Bluetooth link is not open.", code=ERR_LINK_FAILED)
        for start in range(0, len(data), self.CHUNK_BYTES):
            piece = data[start:start + self.CHUNK_BYTES]
            self._run_sync(self._client.write_gatt_char(self.NUS_RX_CHAR, piece, response=False), timeout=5.0)

    @property
    def is_open(self) -> bool:
        return self._client is not None and bool(getattr(self._client, "is_connected", False))

    def describe(self) -> Dict[str, Any]:
        return {"kind": self.kind, "address": self.address}


BLE_NAME_PREFIX = {"microbit": "BBC micro:bit", "spike": "Pybricks"}


def build_transport(config: Dict[str, Any], clock: Any = None) -> Transport:
    """Construct the transport a validated config asks for.

    ``clock`` only matters for in-process robots (Dummy, replay), which advance
    on it; pass the bridge's clock so both sides agree on time.
    """
    platform_id = str(config.get("platform", ""))
    spec = config.get("transport") or {}
    kind = str(spec.get("kind", ""))

    if kind in ("virtual", "replay"):
        # Imported here: these modules build on .config, which must stay
        # importable without the transport layer.
        from .virtual_device import VirtualDeviceTransport

        if kind == "virtual":
            from .drivers.dummy import DummyDriver

            driver = DummyDriver.from_spec(spec, config.get("robot"))
        else:
            from .drivers.replay import ReplayDriver

            driver = ReplayDriver(str(spec.get("log", "")), loop=bool(spec.get("loop", True)))
        if clock is None:
            return VirtualDeviceTransport(driver, config)
        return VirtualDeviceTransport(driver, config, clock=clock)

    if kind == "serial":
        return SerialTransport(
            port=str(spec.get("port", "") or ""),
            baud=int(spec.get("baud", 115200)),
            platform_id=platform_id,
        )
    if kind == "tcp":
        return TcpTransport(
            host=str(spec.get("host", "ev3dev.local")),
            port=int(spec.get("port", 9999)),
            connect_timeout=float(spec.get("connect_timeout", 5.0)),
        )
    if kind == "ble":
        return BleTransport(
            address=str(spec.get("address", "") or ""),
            name_prefix=str(spec.get("name_prefix", "") or BLE_NAME_PREFIX.get(platform_id, "")),
        )
    if kind == "loopback":
        return LoopbackTransport()
    raise LinkError("Unknown transport '%s'." % kind, code=ERR_LINK_FAILED)


def list_available_devices(platform_id: str) -> Dict[str, Any]:
    """What the UI shows on a "connect your robot" screen.

    Never raises: a missing optional dependency is reported as an unavailable
    transport with a readable reason, not as a crash on the connect screen.
    """
    from .platforms import get_platform, is_ir_platform

    if is_ir_platform(platform_id):
        return list_ir_robots(platform_id)

    platform = get_platform(platform_id)
    result: Dict[str, Any] = {"platform": platform.id, "transports": {}}
    for kind in platform.transports:
        entry: Dict[str, Any] = {"available": True, "devices": []}
        if kind == "serial":
            try:
                entry["devices"] = SerialTransport.list_ports(platform.id)
            except MissingDependencyError as exc:
                entry["available"] = False
                entry["error"] = exc.to_dict()
        elif kind == "ble":
            try:
                BleTransport._bleak()
            except MissingDependencyError as exc:
                entry["available"] = False
                entry["error"] = exc.to_dict()
        elif kind == "tcp":
            entry["devices"] = [{"host": "ev3dev.local", "port": 9999, "likely_robot": True}]
        result["transports"][kind] = entry
    return result


def list_ir_robots(platform_id: str) -> Dict[str, Any]:
    """Robots of an IR family that can be connected now, as IR dicts.

    The Dummy is always available. For the EV3, this is the fast answer: robots
    already paired with this computer (a COM port each), without listening to
    the radio. Finding new robots and their distance takes a scan of several
    seconds, which the robot session runs (``robot_session.py``).
    """
    robots: List[Dict[str, Any]] = []
    if platform_id == "dummy":
        from .drivers.dummy import DummyDriver

        robots.append(DummyDriver().inventory().to_dict())
    elif platform_id == "ev3_direct":
        from .bluetooth import lego_com_ports, registry_name
        from .drivers.ev3_direct import Ev3DirectDriver

        for mac, com in sorted(lego_com_ports().items()):
            robot = Ev3DirectDriver(com, mac=mac, name=registry_name(mac) or "EV3").inventory().to_dict()
            robot["paired"] = True
            robots.append(robot)
    return {"platform": platform_id, "robots": robots, "transports": {}}


def wait_until(predicate, timeout_s: float, poll_s: float = 0.005) -> bool:
    """Poll ``predicate`` until it is true or the deadline passes."""
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if predicate():
            return True
        time.sleep(poll_s)
    return bool(predicate())
