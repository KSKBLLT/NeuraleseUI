"""Wire protocol for the robot link (NLR/1).

Design constraints, in priority order:

1. It has to be decodable by micro:bit MicroPython, which has a few tens of KB
   of free RAM, no ``json`` worth using in a 20 Hz loop, and slow float parsing.
   So: line-oriented ASCII, comma separated, **integers only**, fixed field
   order, and a checksum cheap enough to compute with a byte sum.
2. Corruption has to be detected, not acted on. A half-received line that parses
   as a plausible motor command is how a robot drives itself off a table.
3. Frames are stateless and carry a sequence number, so both ends can drop stale
   data instead of queueing it.

Every value on the wire is an integer. Scaling to and from model-space floats is
the host's job (see :mod:`.config`) precisely so the device script never has to
know anything about the model.

Frame grammar (``\\n`` terminated, ``<crc>`` is 4 lowercase hex digits)::

    H,<proto>,<platform>,<cfg_hash>,<n_in>,<n_out>,<rate_hz>,<watchdog_ms>,<crc>
    K,<proto>,<crc>
    E,<code>,<crc>
    S,<seq>,<v0>,...,<vn>,<crc>
    A,<seq>,<v0>,...,<vm>,<crc>
    X,<crc>

``H``/``S`` travel robot -> host. ``K``/``E``/``A``/``X`` travel host -> robot.
"""

from __future__ import annotations

from typing import Any, Dict, List, Optional

from .errors import ERR_BAD_FRAME, ProtocolError

PROTOCOL_VERSION = 1

#: Sequence numbers wrap at this value. Kept small so the ASCII field stays
#: short on the wire and the arithmetic stays inside MicroPython's small ints.
SEQ_MOD = 10000

#: Hard cap on a single line. A device that never emits more than this can use a
#: fixed-size receive buffer, which is what keeps micro:bit RX predictable.
MAX_LINE_BYTES = 240

FRAME_HELLO = "H"
FRAME_ACK = "K"
FRAME_ERROR = "E"
FRAME_SENSORS = "S"
FRAME_ACTUATORS = "A"
FRAME_STOP = "X"


def checksum(payload: str) -> int:
    """Additive 16-bit checksum over the payload (everything before the crc).

    A byte sum rather than CRC-16 on purpose: the link is a wired USB CDC pipe
    where whole-byte corruption is rare and truncation is the realistic failure,
    and a sum catches truncation for the price of one add per byte. On a
    micro:bit this is the difference between comfortably hitting 20 Hz and not.
    """
    total = 0
    for byte in payload.encode("ascii"):
        total += byte
    return total & 0xFFFF


def encode_frame(kind: str, fields: Optional[List[Any]] = None) -> bytes:
    """Build one complete line, checksum included."""
    parts = [kind]
    for field in fields or []:
        parts.append(str(field))
    payload = ",".join(parts)
    line = "%s,%04x\n" % (payload, checksum(payload))
    encoded = line.encode("ascii")
    if len(encoded) > MAX_LINE_BYTES:
        raise ProtocolError(
            "Frame exceeds the %d byte link limit (%d bytes). Reduce the number of mapped channels."
            % (MAX_LINE_BYTES, len(encoded)),
            code=ERR_BAD_FRAME,
            details={"kind": kind, "size": len(encoded)},
        )
    return encoded


def decode_frame(line: Any) -> Dict[str, Any]:
    """Parse one line into ``{"kind": ..., "fields": [...]}``.

    Raises :class:`ProtocolError` on anything malformed. Callers on the host side
    are expected to catch and drop, not to abort the link: a single corrupt frame
    is normal on a physical wire, and the next frame arrives in 50 ms.
    """
    if isinstance(line, (bytes, bytearray)):
        try:
            text = bytes(line).decode("ascii")
        except UnicodeDecodeError as exc:
            raise ProtocolError("Frame contained non-ASCII bytes.", code=ERR_BAD_FRAME) from exc
    else:
        text = str(line)

    text = text.strip("\r\n")
    if not text:
        raise ProtocolError("Empty frame.", code=ERR_BAD_FRAME)

    head, sep, crc_text = text.rpartition(",")
    if not sep:
        raise ProtocolError("Frame has no checksum field: %r" % text, code=ERR_BAD_FRAME)

    try:
        received = int(crc_text, 16)
    except ValueError as exc:
        raise ProtocolError("Frame checksum is not hex: %r" % crc_text, code=ERR_BAD_FRAME) from exc

    expected = checksum(head)
    if received != expected:
        raise ProtocolError(
            "Frame checksum mismatch (got %04x, expected %04x)." % (received, expected),
            code=ERR_BAD_FRAME,
        )

    parts = head.split(",")
    return {"kind": parts[0], "fields": parts[1:]}


def seq_next(seq: int) -> int:
    return (seq + 1) % SEQ_MOD


def seq_is_newer(candidate: int, reference: int) -> bool:
    """Modular "is this frame newer than the last one I handled?".

    Straight ``>`` breaks the moment the counter wraps, and the robot would then
    ignore every command for the next 10000 frames. Treating the forward half of
    the ring as "newer" keeps newest-wins correct across the wrap.
    """
    delta = (candidate - reference) % SEQ_MOD
    return 0 < delta < (SEQ_MOD // 2)


def encode_hello(platform: str, cfg_hash: str, n_in: int, n_out: int, rate_hz: int, watchdog_ms: int) -> bytes:
    return encode_frame(FRAME_HELLO, [PROTOCOL_VERSION, platform, cfg_hash, n_in, n_out, rate_hz, watchdog_ms])


def encode_ack() -> bytes:
    return encode_frame(FRAME_ACK, [PROTOCOL_VERSION])


def encode_error(code: str) -> bytes:
    return encode_frame(FRAME_ERROR, [code])


def encode_sensors(seq: int, values: List[int]) -> bytes:
    return encode_frame(FRAME_SENSORS, [seq % SEQ_MOD] + [int(v) for v in values])


def encode_actuators(seq: int, values: List[int]) -> bytes:
    return encode_frame(FRAME_ACTUATORS, [seq % SEQ_MOD] + [int(v) for v in values])


def encode_stop() -> bytes:
    return encode_frame(FRAME_STOP)


def parse_hello(fields: List[str]) -> Dict[str, Any]:
    if len(fields) < 7:
        raise ProtocolError("Hello frame is truncated.", code=ERR_BAD_FRAME)
    try:
        return {
            "protocol": int(fields[0]),
            "platform": fields[1],
            "cfg_hash": fields[2],
            "n_in": int(fields[3]),
            "n_out": int(fields[4]),
            "rate_hz": int(fields[5]),
            "watchdog_ms": int(fields[6]),
        }
    except ValueError as exc:
        raise ProtocolError("Hello frame has non-integer fields.", code=ERR_BAD_FRAME) from exc


def parse_values(fields: List[str]) -> Dict[str, Any]:
    """Parse the ``seq`` + integer payload shared by ``S`` and ``A`` frames."""
    if not fields:
        raise ProtocolError("Value frame is missing its sequence number.", code=ERR_BAD_FRAME)
    try:
        seq = int(fields[0])
        values = [int(f) for f in fields[1:]]
    except ValueError as exc:
        raise ProtocolError("Value frame carried a non-integer.", code=ERR_BAD_FRAME) from exc
    if not 0 <= seq < SEQ_MOD:
        raise ProtocolError("Sequence number %d out of range." % seq, code=ERR_BAD_FRAME)
    return {"seq": seq, "values": values}


class LineReader:
    """Accumulates arbitrary chunks from a transport into complete lines.

    A serial ``read()`` returns whatever bytes happen to be buffered, which
    splits frames at arbitrary points. Everything that reads from a transport
    goes through here so no other code has to think about partial lines.

    Over-long garbage (a device stuck emitting noise with no newline) is dropped
    rather than buffered, so a misbehaving robot cannot exhaust host memory.
    """

    def __init__(self, max_line: int = MAX_LINE_BYTES) -> None:
        self._buffer = bytearray()
        self._max_line = max_line
        self.dropped_overlong = 0

    def feed(self, chunk: bytes) -> List[bytes]:
        if not chunk:
            return []
        self._buffer.extend(chunk)
        lines: List[bytes] = []
        while True:
            index = self._buffer.find(b"\n")
            if index < 0:
                break
            line = bytes(self._buffer[:index])
            del self._buffer[: index + 1]
            if line:
                lines.append(line)
        if len(self._buffer) > self._max_line:
            # No newline in more than a full frame's worth of bytes: this is
            # noise, not a slow frame. Drop it and resynchronise.
            self._buffer.clear()
            self.dropped_overlong += 1
        return lines

    def reset(self) -> None:
        self._buffer.clear()
