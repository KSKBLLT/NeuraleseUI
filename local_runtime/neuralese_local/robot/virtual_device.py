"""Put any driver on the NLR/1 link, inside the host process.

The bridge (:mod:`.bridge`) was built to talk to a small program running on the
robot. IR robots run no such program: the host drives them directly (the Dummy
is simulated, a stock-firmware EV3 takes LEGO direct commands). This transport
plays the robot-side program in-process, on top of a driver, so the bridge --
its handshake, its watchdog, newest-wins frames and the single safe-state path
-- is used unchanged for every robot.

It behaves like the generated device scripts in ``templates/``:

* announces itself with ``H`` until the host accepts it with ``K``, and again
  whenever the host goes quiet (so Disconnect, then Connect always completes);
* once accepted, reads the mapped sensor channels from the driver and sends an
  ``S`` frame every 1/rate_hz seconds;
* applies each ``A`` frame to the mapped actuator channels;
* stops every actuator on ``X``, on ``E`` (refused), on close, and when no
  ``A`` has arrived for ``watchdog_ms`` -- its own watchdog, independent of the
  host's.

Nothing here sleeps. Every step happens inside :meth:`read`, driven by the
injected clock, so tests run it on a fake clock frame by frame.
"""

from __future__ import annotations

import time
from typing import Any, Callable, Dict, List, Optional

from . import codec
from .codec import LineReader
from .config import config_hash, wire_input_channel_ids, wire_output_channel_ids
from .drivers.base import RobotDriver
from .errors import ERR_LINK_FAILED, LinkError
from .transport import Transport

#: How often an unaccepted device repeats its hello.
HELLO_INTERVAL_S = 0.5


class VirtualDeviceTransport(Transport):
    kind = "virtual"

    def __init__(self, driver: RobotDriver, config: Dict[str, Any], *, clock: Callable[[], float] = time.monotonic) -> None:
        self.driver = driver
        self.config = config
        self.clock = clock
        self.platform_id = str(config.get("platform", ""))
        self.rate_hz = max(1, int(config.get("rate_hz", 20)))
        self.watchdog_s = int(config.get("watchdog_ms", 400)) / 1000.0
        self.input_channels: List[str] = wire_input_channel_ids(config.get("inputs"))
        self.output_channels: List[str] = wire_output_channel_ids(config.get("outputs"))
        self.cfg_hash = config_hash(config)

        self._open = False
        self._outbox = bytearray()
        self._reader = LineReader()
        self.accepted = False
        self.refused_code: Optional[str] = None
        self._seq = 0
        self._last_hello = -1e9
        self._next_frame = 0.0
        self._last_command: Optional[float] = None
        self.watchdog_trips = 0
        self.frames_sent = 0
        self.commands_applied = 0

    # -- Transport ----------------------------------------------------------------

    def open(self) -> None:
        now = self.clock()
        self.driver.open(now)
        self._open = True
        self.accepted = False
        self._last_hello = -1e9

    def close(self) -> None:
        if not self._open:
            return
        try:
            self.driver.stop(self.clock())
        finally:
            try:
                self.driver.close()
            finally:
                self._open = False

    @property
    def is_open(self) -> bool:
        return self._open

    def read(self, max_bytes: int = 4096) -> bytes:
        if not self._open:
            return b""
        self._advance(self.clock())
        chunk = bytes(self._outbox[:max_bytes])
        del self._outbox[: len(chunk)]
        return chunk

    def write(self, data: bytes) -> None:
        if not self._open:
            raise LinkError("The robot link is closed.", code=ERR_LINK_FAILED)
        now = self.clock()
        for line in self._reader.feed(data):
            try:
                frame = codec.decode_frame(line)
            except Exception:
                continue  # a device drops corrupt frames, it never acts on them
            self._handle(frame, now)

    def describe(self) -> Dict[str, Any]:
        robot = self.driver.inventory()
        return {"kind": self.kind, "robot_id": robot.robot_id, "platform": robot.platform, "transport": robot.transport}

    # -- the device side ------------------------------------------------------------

    def _handle(self, frame: Dict[str, Any], now: float) -> None:
        kind = frame["kind"]
        if kind == codec.FRAME_ACK:
            self.accepted = True
            self.refused_code = None
            self._last_command = now
            self._next_frame = now
        elif kind == codec.FRAME_ERROR:
            self.refused_code = frame["fields"][0] if frame["fields"] else "refused"
            self.accepted = False
            self.driver.stop(now)
        elif kind == codec.FRAME_STOP:
            self.driver.stop(now)
        elif kind == codec.FRAME_ACTUATORS and self.accepted:
            try:
                values = codec.parse_values(frame["fields"])["values"]
            except Exception:
                return
            if len(values) != len(self.output_channels):
                return
            self.driver.write(dict(zip(self.output_channels, values)), now)
            self._last_command = now
            self.commands_applied += 1

    def _advance(self, now: float) -> None:
        self.driver.tick(now)
        if self.accepted and self._last_command is not None and now - self._last_command > self.watchdog_s:
            # The host went quiet: stop, and start announcing again so a new
            # host (or the same one, reconnecting) gets a fresh handshake.
            self.driver.stop(now)
            self.watchdog_trips += 1
            self.accepted = False
            self._last_hello = -1e9

        if not self.accepted:
            if now - self._last_hello >= HELLO_INTERVAL_S:
                self._outbox.extend(codec.encode_hello(
                    self.platform_id, self.cfg_hash, len(self.input_channels), len(self.output_channels),
                    self.rate_hz, int(round(self.watchdog_s * 1000)),
                ))
                self._last_hello = now
            return

        period = 1.0 / self.rate_hz
        if now + 1e-9 >= self._next_frame:
            self._seq = codec.seq_next(self._seq)
            values = self.driver.read(self.input_channels, now)
            self._outbox.extend(codec.encode_sensors(self._seq, values))
            self.frames_sent += 1
            self._next_frame = max(self._next_frame + period, now)
