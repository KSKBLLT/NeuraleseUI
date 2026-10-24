"""Host control loop: handshake, newest-wins, watchdogs, fail-safe.

These are the tests that stand in for "we drove a real robot off a table once".
The loop is polled by hand against a fake clock, so every safety rule is checked
by arithmetic rather than by sleeping and hoping.
"""

from __future__ import annotations

import unittest

from support import FakeClock, FakeRobot, ScriptedEngine

from neuralese_local.robot import codec
from neuralese_local.robot.bridge import (
    MAX_CONSECUTIVE_INFERENCE_ERRORS,
    STATE_ERROR,
    STATE_RUNNING,
    STATE_STALLED,
    STATE_STOPPED,
    RobotBridge,
)
from neuralese_local.robot.config import compile_config, config_hash, linear_scale


def make_config(**overrides):
    base = {
        "schema_version": 1,
        "platform": "ev3",
        # The config always names the transport the robot really uses; the tests
        # hand the bridge a loopback object directly. "loopback" is deliberately
        # not a valid transport in the registry, so no child can end up with a
        # saved config that connects to nothing.
        "transport": {"kind": "tcp", "host": "ev3dev.local", "port": 9999},
        "rate_hz": 20,
        "watchdog_ms": 400,
        "inputs": [
            {"channel": "ultrasonic_4", "scale": linear_scale(0, 2550, 0.0, 1.0)},
            {"channel": "touch_1"},
        ],
        "outputs": [
            {"channel": "motor_a_speed", "mode": "argmax", "classes": {"0": 60, "1": -60}},
            {"channel": "motor_b_speed", "mode": "argmax", "classes": {"0": -60, "1": 60}},
        ],
    }
    base.update(overrides)
    return base


def build(config=None, engine=None, clock=None, **kwargs):
    config = config or make_config()
    plan = compile_config(config)
    robot = FakeRobot(config, plan.input_count, plan.output_count)
    clock = clock or FakeClock()
    bridge = RobotBridge(
        plan,
        engine or ScriptedEngine([1.0, 0.0]),
        robot.transport,
        clock=clock,
        **kwargs,
    )
    return bridge, robot, clock


def connect(bridge, robot):
    bridge.start()
    robot.send_hello()
    bridge.poll()
    robot.drain()
    return bridge


class HandshakeTests(unittest.TestCase):
    def test_a_matching_robot_is_acknowledged_and_runs(self) -> None:
        bridge, robot, _ = build()
        connect(bridge, robot)
        self.assertTrue(robot.acked)
        self.assertEqual(bridge.state, STATE_RUNNING)

    def test_nothing_is_driven_before_the_handshake(self) -> None:
        # Acting on readings from a robot we have not agreed a mapping with
        # would skip the fingerprint check: an older flashed script with the
        # same channel *count* but different channels would be driven with the
        # wrong mapping and the wrong scaling.
        bridge, robot, _ = build()
        bridge.start()
        robot.send_sensors([1000, 1])
        bridge.poll()
        robot.drain()
        self.assertFalse(robot.acked)
        self.assertIsNone(robot.last_command)
        self.assertEqual(bridge.stats["frames_before_handshake"], 1)
        self.assertNotEqual(bridge.state, STATE_RUNNING)

    def test_a_refused_robot_is_never_driven_even_if_it_keeps_sending(self) -> None:
        bridge, robot, _ = build()
        bridge.start()
        robot.send_hello(cfg_hash="deadbeef")
        bridge.poll()
        for _ in range(5):
            robot.send_sensors([1000, 1])
            bridge.poll()
        robot.drain()
        self.assertEqual(bridge.state, STATE_ERROR)
        # Only the safe state, never a live command.
        self.assertTrue(all(command == [0, 0] for command in robot.applied), robot.applied)

    def test_a_robot_speaking_another_protocol_version_is_refused(self) -> None:
        bridge, robot, _ = build()
        bridge.start()
        robot.send_hello(protocol=codec.PROTOCOL_VERSION + 1)
        bridge.poll()
        robot.drain()
        self.assertEqual(bridge.state, STATE_ERROR)
        self.assertEqual(bridge.error["code"], "protocol_mismatch")
        self.assertTrue(robot.errors)

    def test_a_stale_flashed_script_is_refused(self) -> None:
        # The child changed the mapping but did not copy the new program across.
        bridge, robot, _ = build()
        bridge.start()
        robot.send_hello(cfg_hash="deadbeef")
        bridge.poll()
        self.assertEqual(bridge.state, STATE_ERROR)
        self.assertIn("older export", bridge.error["message"])

    def test_a_robot_sending_the_wrong_number_of_values_is_refused(self) -> None:
        bridge, robot, _ = build()
        bridge.start()
        robot.send_hello(n_in=5)
        bridge.poll()
        self.assertEqual(bridge.error["code"], "arity_mismatch")

    def test_the_wrong_kind_of_robot_is_refused(self) -> None:
        bridge, robot, _ = build()
        bridge.start()
        robot.send_hello(platform="microbit")
        bridge.poll()
        self.assertEqual(bridge.error["code"], "handshake_failed")


class InferenceTests(unittest.TestCase):
    def test_a_reading_becomes_a_motor_command(self) -> None:
        engine = ScriptedEngine([0.9, 0.1])
        bridge, robot, _ = build(engine=engine)
        connect(bridge, robot)
        robot.send_sensors([1275, 1])
        bridge.poll()
        robot.drain()
        # Sensor scaled into model space...
        self.assertAlmostEqual(engine.calls[-1][0], 0.5)
        self.assertEqual(engine.calls[-1][1], 1.0)
        # ...and class 0 wins, so the motors take their class-0 values.
        self.assertEqual(robot.last_command, [60, -60])

    def test_the_answer_echoes_the_reading_it_answers(self) -> None:
        bridge, robot, _ = build()
        connect(bridge, robot)
        seq = robot.send_sensors([0, 0])
        bridge.poll()
        frames = codec.LineReader().feed(robot.transport.robot_receive())
        answer = codec.decode_frame(frames[-1])
        self.assertEqual(codec.parse_values(answer["fields"])["seq"], seq)


class NewestWinsTests(unittest.TestCase):
    def test_only_the_newest_of_a_backlog_is_acted_on(self) -> None:
        # Acting on a stale reading is acting on a world that has moved.
        engine = ScriptedEngine(lambda values: [1.0, 0.0] if values[1] else [0.0, 1.0])
        bridge, robot, _ = build(engine=engine)
        connect(bridge, robot)
        robot.send_sensors([0, 0])
        robot.send_sensors([0, 0])
        robot.send_sensors([0, 1])
        bridge.poll()
        robot.drain()
        self.assertEqual(len(engine.calls), 1)
        self.assertEqual(bridge.stats["frames_received"], 3)
        self.assertEqual(bridge.stats["frames_stale"], 2)
        self.assertEqual(robot.last_command, [60, -60])

    def test_an_out_of_order_reading_is_dropped(self) -> None:
        bridge, robot, _ = build()
        connect(bridge, robot)
        robot.send_sensors([0, 0], seq=50)
        bridge.poll()
        robot.drain()
        robot.send_sensors([0, 0], seq=49)
        bridge.poll()
        self.assertEqual(bridge.stats["frames_stale"], 1)
        self.assertEqual(bridge.stats["frames_answered"], 1)

    def test_sequence_numbers_keep_working_after_they_wrap(self) -> None:
        bridge, robot, _ = build()
        connect(bridge, robot)
        robot.send_sensors([0, 0], seq=codec.SEQ_MOD - 1)
        bridge.poll()
        robot.send_sensors([0, 0], seq=0)
        bridge.poll()
        self.assertEqual(bridge.stats["frames_answered"], 2)
        self.assertEqual(bridge.stats["frames_stale"], 0)


class CorruptFrameTests(unittest.TestCase):
    def test_a_damaged_frame_is_counted_and_ignored(self) -> None:
        bridge, robot, _ = build()
        connect(bridge, robot)
        robot.send_raw(b"S,4,999,1,0000\n")
        bridge.poll()
        robot.drain()
        self.assertEqual(bridge.stats["frames_corrupt"], 1)
        self.assertIsNone(robot.last_command)

    def test_one_damaged_frame_does_not_break_the_link(self) -> None:
        # Corruption is normal on a physical wire; the next frame is 50 ms away.
        bridge, robot, _ = build()
        connect(bridge, robot)
        robot.send_raw(b"S,4,999,1,0000\n")
        bridge.poll()
        robot.send_sensors([0, 0])
        bridge.poll()
        robot.drain()
        self.assertEqual(bridge.state, STATE_RUNNING)
        self.assertIsNotNone(robot.last_command)

    def test_a_reading_with_the_wrong_number_of_values_is_not_acted_on(self) -> None:
        bridge, robot, _ = build()
        connect(bridge, robot)
        robot.send_raw(codec.encode_sensors(80, [1, 2, 3, 4]))
        bridge.poll()
        robot.drain()
        self.assertIsNone(robot.last_command)
        self.assertEqual(bridge.stats["frames_corrupt"], 1)

    def test_unknown_frame_kinds_are_ignored_rather_than_fatal(self) -> None:
        # So a newer device script can add frames without breaking an old host.
        bridge, robot, _ = build()
        connect(bridge, robot)
        robot.send_raw(codec.encode_frame("Q", [1, 2]))
        bridge.poll()
        self.assertEqual(bridge.state, STATE_RUNNING)


class WatchdogTests(unittest.TestCase):
    def test_silence_stops_the_robot(self) -> None:
        bridge, robot, clock = build()
        connect(bridge, robot)
        robot.send_sensors([2550, 1])
        bridge.poll()
        robot.drain()
        self.assertEqual(robot.last_command, [60, -60])

        clock.advance(bridge.link_timeout_s + 0.01)
        bridge.poll()
        robot.drain()
        self.assertEqual(bridge.state, STATE_STALLED)
        self.assertEqual(robot.last_command, [0, 0])
        self.assertEqual(bridge.stats["watchdog_trips"], 1)

    def test_a_healthy_link_never_trips_the_watchdog(self) -> None:
        bridge, robot, clock = build()
        connect(bridge, robot)
        for _ in range(20):
            clock.advance(1.0 / 20)
            robot.send_sensors([0, 0])
            bridge.poll()
        self.assertEqual(bridge.stats["watchdog_trips"], 0)
        self.assertEqual(bridge.state, STATE_RUNNING)

    def test_the_stop_command_is_sent_once_not_every_poll(self) -> None:
        bridge, robot, clock = build()
        connect(bridge, robot)
        robot.send_sensors([0, 0])
        bridge.poll()
        robot.drain()
        clock.advance(bridge.link_timeout_s + 0.01)
        for _ in range(5):
            bridge.poll()
            clock.advance(0.1)
        robot.drain()
        self.assertEqual(robot.applied.count([0, 0]), 1)

    def test_the_link_recovers_by_itself_when_the_robot_comes_back(self) -> None:
        bridge, robot, clock = build()
        connect(bridge, robot)
        clock.advance(bridge.link_timeout_s + 0.01)
        bridge.poll()
        self.assertEqual(bridge.state, STATE_STALLED)

        robot.send_sensors([0, 0])
        bridge.poll()
        robot.drain()
        self.assertEqual(bridge.state, STATE_RUNNING)
        self.assertEqual(robot.last_command, [60, -60])

    def test_the_host_waits_at_least_as_long_as_the_robot_does(self) -> None:
        # Tripping earlier than the robot's own watchdog would be pure stutter.
        config = make_config(rate_hz=20, watchdog_ms=1000)
        bridge, _, _ = build(config=config)
        self.assertGreaterEqual(bridge.link_timeout_s, 1.0)


class FailureTests(unittest.TestCase):
    def test_an_inference_failure_stops_the_motors(self) -> None:
        engine = ScriptedEngine(raises=RuntimeError("bad tensor"))
        bridge, robot, _ = build(engine=engine)
        connect(bridge, robot)
        robot.send_sensors([0, 0])
        bridge.poll()
        robot.drain()
        self.assertEqual(robot.last_command, [0, 0])
        self.assertEqual(bridge.stats["inference_errors"], 1)

    def test_one_bad_frame_is_a_glitch_not_a_shutdown(self) -> None:
        engine = ScriptedEngine(raises=RuntimeError("bad tensor"))
        bridge, robot, _ = build(engine=engine)
        connect(bridge, robot)
        robot.send_sensors([0, 0])
        bridge.poll()
        self.assertEqual(bridge.state, STATE_RUNNING)

    def test_a_model_that_always_fails_gives_up_and_says_so(self) -> None:
        # Silently retrying forever leaves a child watching a robot that never
        # moves, with nothing anywhere saying why.
        engine = ScriptedEngine(raises=RuntimeError("bad tensor"))
        bridge, robot, _ = build(engine=engine)
        connect(bridge, robot)
        for _ in range(MAX_CONSECUTIVE_INFERENCE_ERRORS):
            robot.send_sensors([0, 0])
            bridge.poll()
        self.assertEqual(bridge.state, STATE_ERROR)
        self.assertIn("failed", bridge.error["message"])

    def test_a_recovered_model_resets_the_failure_count(self) -> None:
        engine = ScriptedEngine([1.0, 0.0])
        bridge, robot, _ = build(engine=engine)
        connect(bridge, robot)
        for _ in range(MAX_CONSECUTIVE_INFERENCE_ERRORS - 1):
            engine.raises = RuntimeError("transient")
            robot.send_sensors([0, 0])
            bridge.poll()
        engine.raises = None
        robot.send_sensors([0, 0])
        bridge.poll()
        for _ in range(MAX_CONSECUTIVE_INFERENCE_ERRORS - 1):
            engine.raises = RuntimeError("transient")
            robot.send_sensors([0, 0])
            bridge.poll()
        self.assertEqual(bridge.state, STATE_RUNNING)


class ShutdownTests(unittest.TestCase):
    def test_stopping_stops_the_motors_then_closes(self) -> None:
        bridge, robot, _ = build()
        connect(bridge, robot)
        robot.send_sensors([0, 0])
        bridge.poll()
        robot.drain()

        bridge.stop()
        robot.drain()
        self.assertEqual(robot.last_command, [0, 0])
        self.assertTrue(robot.stopped)
        self.assertEqual(bridge.state, STATE_STOPPED)

    def test_leaving_the_context_manager_stops_the_robot(self) -> None:
        config = make_config()
        plan = compile_config(config)
        robot = FakeRobot(config, plan.input_count, plan.output_count)
        with RobotBridge(plan, ScriptedEngine([1.0, 0.0]), robot.transport, clock=FakeClock()) as bridge:
            robot.send_hello()
            bridge.poll()
        robot.drain()
        self.assertTrue(robot.stopped)

    def test_the_expected_fingerprint_matches_what_the_script_embeds(self) -> None:
        config = make_config()
        bridge, _, _ = build(config=config)
        self.assertEqual(bridge.expected_config_hash, config_hash(config))


class TelemetryTests(unittest.TestCase):
    def test_events_are_published_for_the_ui(self) -> None:
        events = []
        bridge, robot, clock = build(on_event=events.append)
        connect(bridge, robot)
        clock.advance(bridge.link_timeout_s + 0.01)
        bridge.poll()
        bridge.stop()
        kinds = [event["event"] for event in events]
        self.assertEqual(kinds[:2], ["link_open", "handshake"])
        self.assertIn("link_stalled", kinds)
        self.assertIn("link_closed", kinds)

    def test_a_broken_telemetry_callback_cannot_stop_the_robot_loop(self) -> None:
        def explode(_payload):
            raise RuntimeError("logging is down")

        bridge, robot, _ = build(on_event=explode)
        connect(bridge, robot)
        robot.send_sensors([0, 0])
        bridge.poll()
        robot.drain()
        self.assertEqual(bridge.state, STATE_RUNNING)
        self.assertIsNotNone(robot.last_command)

    def test_status_describes_the_link_for_the_ui(self) -> None:
        bridge, robot, _ = build()
        connect(bridge, robot)
        robot.send_sensors([2550, 1])
        bridge.poll()
        status = bridge.status()
        self.assertEqual(status["state"], STATE_RUNNING)
        self.assertEqual(status["platform"], "ev3")
        self.assertEqual(status["last_actuators"], [60, -60])
        self.assertEqual(status["stats"]["frames_answered"], 1)


if __name__ == "__main__":
    unittest.main()
