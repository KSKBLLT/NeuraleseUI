from __future__ import annotations

import json
import secrets
import struct
from typing import Any, Dict, List


DEFAULT_MAX_FRAME_BYTES = 8 * 1024 * 1024
_HEADER_SIZE = 4


class ProtocolError(ValueError):
    """Base class for packets that violate the local worker protocol."""


class FrameSizeError(ProtocolError):
    pass


class FrameDecodeError(ProtocolError):
    pass


class ValidationError(ProtocolError):
    pass


class AuthenticationError(ProtocolError):
    pass


class ReplayError(ProtocolError):
    pass


def _reject_json_constant(value: str) -> None:
    raise ValueError(f"non-finite JSON constant is not allowed: {value}")


def encode_frame(packet: Dict[str, Any], max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES) -> bytes:
    if not isinstance(packet, dict):
        raise ValidationError("protocol packet must be a dictionary")
    try:
        payload = json.dumps(
            packet,
            ensure_ascii=False,
            allow_nan=False,
            separators=(",", ":"),
        ).encode("utf-8")
    except (TypeError, ValueError) as exc:
        raise FrameDecodeError(f"packet is not valid JSON: {exc}") from exc
    if not payload:
        raise FrameSizeError("zero-length frames are not allowed")
    if len(payload) > max_frame_bytes:
        raise FrameSizeError(
            f"frame length {len(payload)} exceeds limit {max_frame_bytes}"
        )
    return struct.pack(">I", len(payload)) + payload


class FrameDecoder:
    def __init__(self, max_frame_bytes: int = DEFAULT_MAX_FRAME_BYTES):
        if max_frame_bytes <= 0:
            raise ValueError("max_frame_bytes must be positive")
        self._max_frame_bytes = int(max_frame_bytes)
        self._buffer = bytearray()
        self._expected_length: int | None = None

    def feed(self, data: bytes) -> List[Dict[str, Any]]:
        if not isinstance(data, (bytes, bytearray, memoryview)):
            raise TypeError("frame data must be bytes-like")
        self._buffer.extend(data)
        packets: List[Dict[str, Any]] = []

        while True:
            if self._expected_length is None:
                if len(self._buffer) < _HEADER_SIZE:
                    break
                self._expected_length = struct.unpack(">I", self._buffer[:_HEADER_SIZE])[0]
                del self._buffer[:_HEADER_SIZE]
                if self._expected_length == 0:
                    raise FrameSizeError("zero-length frames are not allowed")
                if self._expected_length > self._max_frame_bytes:
                    raise FrameSizeError(
                        f"frame length {self._expected_length} exceeds limit "
                        f"{self._max_frame_bytes}"
                    )

            if len(self._buffer) < self._expected_length:
                break

            payload = bytes(self._buffer[: self._expected_length])
            del self._buffer[: self._expected_length]
            self._expected_length = None
            packets.append(self._decode_payload(payload))

        return packets

    @staticmethod
    def _decode_payload(payload: bytes) -> Dict[str, Any]:
        try:
            text = payload.decode("utf-8")
            packet = json.loads(text, parse_constant=_reject_json_constant)
        except (UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
            raise FrameDecodeError(f"invalid frame JSON: {exc}") from exc
        if not isinstance(packet, dict):
            raise ValidationError("protocol packet must decode to a dictionary")
        return packet


def validate_command(packet: Dict[str, Any], token: str, last_request_id: int) -> int:
    if not isinstance(packet, dict):
        raise ValidationError("protocol packet must be a dictionary")

    supplied_token = packet.get("token")
    if not isinstance(supplied_token, str) or not secrets.compare_digest(supplied_token, token):
        raise AuthenticationError("invalid worker session token")

    request_id = packet.get("request_id")
    if isinstance(request_id, bool) or not isinstance(request_id, int):
        raise ValidationError("request_id must be an integer")
    if request_id <= last_request_id:
        raise ReplayError(
            f"request_id {request_id} is not newer than {last_request_id}"
        )

    command = packet.get("command")
    if not isinstance(command, str) or not command.strip():
        raise ValidationError("command must be a non-empty string")

    return request_id
