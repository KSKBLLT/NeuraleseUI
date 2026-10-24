"""Wire protocol tests.

The codec is the one component both the host and every device script implement
independently, so its exact byte-level behaviour is pinned here.
"""

from __future__ import annotations

import unittest

from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot import codec
from neuralese_local.robot.errors import ProtocolError


class ChecksumTests(unittest.TestCase):
    def test_checksum_is_a_plain_byte_sum(self) -> None:
        # Pinned rather than computed: every device script reimplements this in
        # MicroPython, and a "harmless" change here silently breaks all of them.
        self.assertEqual(codec.checksum("S,1,0"), sum(b"S,1,0"))
        self.assertEqual(codec.checksum(""), 0)

    def test_checksum_wraps_at_16_bits(self) -> None:
        self.assertEqual(codec.checksum("z" * 1000), (ord("z") * 1000) & 0xFFFF)


class FrameTests(unittest.TestCase):
    def test_sensor_frame_round_trip(self) -> None:
        line = codec.encode_sensors(7, [1, -2, 300])
        # 0x25d == sum(b"S,7,1,-2,300"). Pinned so a device script can be
        # checked against this by hand.
        self.assertEqual(line, b"S,7,1,-2,300,025d\n")
        frame = codec.decode_frame(line)
        self.assertEqual(frame["kind"], codec.FRAME_SENSORS)
        self.assertEqual(codec.parse_values(frame["fields"]), {"seq": 7, "values": [1, -2, 300]})

    def test_actuator_frame_round_trip(self) -> None:
        frame = codec.decode_frame(codec.encode_actuators(9999, [-100, 0]))
        self.assertEqual(codec.parse_values(frame["fields"]), {"seq": 9999, "values": [-100, 0]})

    def test_hello_round_trip(self) -> None:
        frame = codec.decode_frame(codec.encode_hello("ev3", "abc12345", 3, 2, 20, 400))
        self.assertEqual(codec.parse_hello(frame["fields"]), {
            "protocol": codec.PROTOCOL_VERSION,
            "platform": "ev3",
            "cfg_hash": "abc12345",
            "n_in": 3,
            "n_out": 2,
            "rate_hz": 20,
            "watchdog_ms": 400,
        })

    def test_sequence_wraps_into_range(self) -> None:
        frame = codec.decode_frame(codec.encode_sensors(codec.SEQ_MOD + 5, [0]))
        self.assertEqual(codec.parse_values(frame["fields"])["seq"], 5)

    def test_frames_that_would_overflow_the_link_are_refused(self) -> None:
        # Better to fail at export time with a readable message than to have a
        # device silently truncate a motor command.
        with self.assertRaises(ProtocolError):
            codec.encode_sensors(1, list(range(100)))


class CorruptionTests(unittest.TestCase):
    def test_bad_checksum_is_rejected(self) -> None:
        with self.assertRaises(ProtocolError):
            codec.decode_frame(b"S,1,42,0000\n")

    def test_truncated_frame_is_rejected(self) -> None:
        # The realistic serial failure: the tail of a line is lost. Without the
        # checksum this parses as a valid, entirely wrong, command.
        full = codec.encode_actuators(1, [100, -100])
        with self.assertRaises(ProtocolError):
            codec.decode_frame(full[: len(full) // 2])

    def test_single_flipped_digit_is_rejected(self) -> None:
        line = codec.encode_actuators(1, [100]).decode().strip()
        corrupt = line.replace("100", "900", 1)
        with self.assertRaises(ProtocolError):
            codec.decode_frame(corrupt)

    def test_non_integer_payload_is_rejected(self) -> None:
        payload = "S,1,3.5"
        line = "%s,%04x" % (payload, codec.checksum(payload))
        frame = codec.decode_frame(line)
        with self.assertRaises(ProtocolError):
            codec.parse_values(frame["fields"])

    def test_empty_and_checksumless_frames_are_rejected(self) -> None:
        for bad in (b"\n", b"S1234\n"):
            with self.assertRaises(ProtocolError):
                codec.decode_frame(bad)


class SequenceTests(unittest.TestCase):
    def test_newer_is_forward_within_the_ring(self) -> None:
        self.assertTrue(codec.seq_is_newer(5, 4))
        self.assertFalse(codec.seq_is_newer(4, 5))
        self.assertFalse(codec.seq_is_newer(5, 5))

    def test_newer_survives_the_wrap(self) -> None:
        # Straight `>` fails here, and the robot would then ignore every command
        # for the next 10000 frames.
        self.assertTrue(codec.seq_is_newer(1, codec.SEQ_MOD - 1))
        self.assertFalse(codec.seq_is_newer(codec.SEQ_MOD - 1, 1))

    def test_next_wraps(self) -> None:
        self.assertEqual(codec.seq_next(codec.SEQ_MOD - 1), 0)


class LineReaderTests(unittest.TestCase):
    def test_reassembles_frames_split_across_reads(self) -> None:
        reader = codec.LineReader()
        payload = codec.encode_sensors(1, [42])
        self.assertEqual(reader.feed(payload[:4]), [])
        self.assertEqual(reader.feed(payload[4:]), [payload.strip(b"\n")])

    def test_returns_several_frames_from_one_read(self) -> None:
        reader = codec.LineReader()
        blob = codec.encode_sensors(1, [1]) + codec.encode_sensors(2, [2])
        self.assertEqual(len(reader.feed(blob)), 2)

    def test_drops_endless_noise_instead_of_buffering_it(self) -> None:
        # A device stuck emitting garbage must not be able to exhaust host memory.
        reader = codec.LineReader()
        reader.feed(b"x" * (codec.MAX_LINE_BYTES * 3))
        self.assertEqual(reader.dropped_overlong, 1)
        self.assertEqual(reader.feed(codec.encode_sensors(1, [7])), [b"S,1,7,0113"])


if __name__ == "__main__":
    unittest.main()
