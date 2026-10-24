from __future__ import annotations

import json
import struct

import pytest

from neuralese_local.train_protocol import (
    AuthenticationError,
    FrameDecodeError,
    FrameDecoder,
    FrameSizeError,
    ReplayError,
    ValidationError,
    encode_frame,
    validate_command,
)


def test_decoder_handles_fragmented_and_coalesced_frames():
    raw = encode_frame({"a": 1}) + encode_frame({"b": 2})
    decoder = FrameDecoder(max_frame_bytes=1024)

    assert decoder.feed(raw[:3]) == []
    assert decoder.feed(raw[3:]) == [{"a": 1}, {"b": 2}]


def test_decoder_rejects_zero_and_oversized_frames():
    decoder = FrameDecoder(max_frame_bytes=8)

    with pytest.raises(FrameSizeError, match="zero-length"):
        decoder.feed(struct.pack(">I", 0))

    decoder = FrameDecoder(max_frame_bytes=8)
    with pytest.raises(FrameSizeError, match="exceeds"):
        decoder.feed(struct.pack(">I", 9))


@pytest.mark.parametrize(
    "payload, error_type",
    [
        (b"\xff", FrameDecodeError),
        (json.dumps([1, 2]).encode("utf-8"), ValidationError),
        (b"{not json}", FrameDecodeError),
    ],
)
def test_decoder_rejects_invalid_payloads(payload, error_type):
    decoder = FrameDecoder(max_frame_bytes=1024)

    with pytest.raises(error_type):
        decoder.feed(struct.pack(">I", len(payload)) + payload)


def test_encoder_rejects_non_dictionary_packets():
    with pytest.raises(ValidationError, match="dictionary"):
        encode_frame(["not", "a", "packet"])


def test_validate_command_accepts_next_request_id():
    packet = {"token": "secret", "request_id": 12, "command": "PING"}

    assert validate_command(packet, token="secret", last_request_id=11) == 12


def test_validate_command_rejects_wrong_token():
    packet = {"token": "wrong", "request_id": 1, "command": "PING"}

    with pytest.raises(AuthenticationError):
        validate_command(packet, token="secret", last_request_id=0)


@pytest.mark.parametrize("request_id", [0, 4])
def test_validate_command_rejects_replayed_request_ids(request_id):
    packet = {"token": "secret", "request_id": request_id, "command": "PING"}

    with pytest.raises(ReplayError):
        validate_command(packet, token="secret", last_request_id=4)


@pytest.mark.parametrize(
    "packet",
    [
        {"token": "secret", "request_id": True, "command": "PING"},
        {"token": "secret", "request_id": "5", "command": "PING"},
        {"token": "secret", "request_id": 5},
        {"token": "secret", "request_id": 5, "command": ""},
    ],
)
def test_validate_command_rejects_malformed_packets(packet):
    with pytest.raises(ValidationError):
        validate_command(packet, token="secret", last_request_id=4)
