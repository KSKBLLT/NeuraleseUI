"""The in-process robot side of NLR/1, and the whole host loop on a Dummy.

Host-driven robots run no program of their own; ``VirtualDeviceTransport``
plays that program on top of a driver, so the bridge's handshake, watchdog and
safe-state rules apply to them unchanged. These tests run the real bridge
against it on a fake clock and look at what the simulated robot physically did.
"""

from __future__ import annotations

import json
import math
import shutil
import tempfile
import unittest
from pathlib import Path

from support import FakeClock, ScriptedEngine, dummy_drive_config, dummy_robot

from neuralese_local.robot import codec
from neuralese_local.robot.bridge import STATE_RUNNING, STATE_STOPPED, RobotBridge
from neuralese_local.robot.config import compile_config
from neuralese_local.robot.drivers.replay import NO_ECHO_MM, ReplayDriver
from neuralese_local.robot.transport import build_transport
from neuralese_local.robot.virtual_device import HELLO_INTERVAL_S, VirtualDeviceTransport

STEP_S = 0.005


def run(bridge: RobotBridge, clock: FakeClock, seconds: float) -> None:
    for _ in range(int(round(seconds / STEP_S))):
        clock.advance(STEP_S)
        bridge.poll()


def connect(config=None, outputs=(0.0, 0.0), world=None):
    config = config or dummy_drive_config()
    if world is not None:
        config["transport"] = dict(config["transport"], world=world)
    clock = FakeClock()
    transport = build_transport(config, clock=clock)
    engine = ScriptedEngine(list(outputs))
    bridge = RobotBridge(compile_config(config), engine, transport, clock=clock)
    bridge.start()
    return bridge, transport, transport.driver, engine, clock


#: Open floor: nothing within sonar range, so the model sees clear road.
OPEN_FLOOR = {"walls": [], "start": [0, 0, 0]}


class HandshakeTests(unittest.TestCase):
    def test_the_dummy_announces_itself_and_is_accepted(self) -> None:
        bridge, transport, dummy, _, clock = connect()
        self.assertIsInstance(transport, VirtualDeviceTransport)
        run(bridge, clock, 0.1)
        self.assertEqual(bridge.state, STATE_RUNNING)
        self.assertTrue(transport.accepted)
        self.assertEqual(bridge.robot_info["platform"], "dummy")
        self.assertEqual((bridge.robot_info["n_in"], bridge.robot_info["n_out"]), (3, 2))
        self.assertTrue(dummy.is_open)

    def test_frames_flow_at_the_configured_rate(self) -> None:
        bridge, transport, _, engine, clock = connect()
        run(bridge, clock, 0.1)
        sent = transport.frames_sent
        run(bridge, clock, 2.0)
        self.assertAlmostEqual(transport.frames_sent - sent, 40, delta=1)
        self.assertEqual(bridge.stats["frames_answered"], transport.frames_sent)
        self.assertEqual(transport.commands_applied, bridge.stats["frames_answered"])
        self.assertEqual(bridge.stats["frames_corrupt"], 0)
        # The model saw eight rays every time, made from three sonars.
        self.assertTrue(all(len(call) == 8 for call in engine.calls))

    def test_a_mismatched_host_is_refused_and_nothing_moves(self) -> None:
        device_config = dummy_drive_config()
        host_config = dummy_drive_config(rate_hz=10)  # a different fingerprint
        clock = FakeClock()
        transport = build_transport(device_config, clock=clock)
        bridge = RobotBridge(compile_config(host_config), ScriptedEngine([0.0, 1.0]), transport, clock=clock)
        bridge.start()
        run(bridge, clock, 0.5)
        self.assertIsNotNone(transport.refused_code)
        self.assertFalse(transport.accepted)
        self.assertEqual(transport.frames_sent, 0)
        self.assertEqual(transport.commands_applied, 0)
        self.assertEqual(transport.driver.pose()["x_cm"], transport.driver.world.start[0])


class DrivingTests(unittest.TestCase):
    def test_full_throttle_drives_forward(self) -> None:
        bridge, _, dummy, _, clock = connect(outputs=(0.0, 1.0), world=OPEN_FLOOR)
        run(bridge, clock, 2.0)
        pose = dummy.pose()
        self.assertGreater(pose["x_cm"], 40.0)
        self.assertAlmostEqual(pose["heading_deg"], 0.0, delta=0.5)
        self.assertEqual(bridge.status()["drive"][0]["status"], "forward")

    def test_motion_ramps_up_from_the_moment_of_connection(self) -> None:
        # The drive's clock starts at the handshake, so the first command is a
        # gentle step even though the plan was compiled long before.
        bridge, _, dummy, _, clock = connect(outputs=(0.0, 1.0), world=OPEN_FLOOR)
        while bridge.stats["frames_answered"] == 0:
            clock.advance(STEP_S)
            bridge.poll()
        first = bridge.status()["drive"][0]
        self.assertLessEqual(max(first["left"], first["right"]), 260 * 0.01 + 0.5)  # one minimum step
        self.assertGreater(first["left"], 0)

    def test_steering_right_turns_the_robot_right(self) -> None:
        bridge, _, dummy, _, clock = connect(outputs=(1.0, 0.5), world=OPEN_FLOOR)
        run(bridge, clock, 1.0)
        self.assertLess(dummy.pose()["heading_deg"], -45.0)    # clockwise
        self.assertEqual(bridge.status()["drive"][0]["status"], "spin_right")

    def test_wrong_motor_ports_turn_the_wrong_way(self) -> None:
        # The mistake the real robot made: left and right motors swapped in the
        # mapping. The Dummy is built the true way round, so the mapping's
        # error shows up as a turn in the wrong direction, as it did on KIRISIMA.
        config = dummy_drive_config(robot=dummy_robot(drive=("outB", "outD")))
        config["outputs"][0]["channels"] = ["outB.power", "outD.power"]
        bridge, _, dummy, _, clock = connect(config=config, outputs=(1.0, 0.5), world=OPEN_FLOOR)
        run(bridge, clock, 1.0)
        self.assertGreater(dummy.pose()["heading_deg"], 45.0)  # counter-clockwise

    def test_stop_stops_the_motors_and_releases_the_robot(self) -> None:
        bridge, transport, dummy, _, clock = connect(outputs=(0.0, 1.0), world=OPEN_FLOOR)
        run(bridge, clock, 1.0)
        bridge.stop()
        self.assertEqual(bridge.state, STATE_STOPPED)
        self.assertFalse(transport.is_open)
        self.assertFalse(dummy.is_open)
        self.assertEqual(dummy.read(["outD.power", "outB.power"], clock()), [0, 0])
        x = dummy.pose()["x_cm"]
        dummy.tick(clock() + 1.0)
        # Only the motors' spin-down, no more driving.
        self.assertLess(dummy.pose()["x_cm"] - x, 3.5)


class DeviceWatchdogTests(unittest.TestCase):
    def test_a_silent_host_stops_the_robot_and_it_announces_again(self) -> None:
        bridge, transport, dummy, _, clock = connect(outputs=(0.0, 1.0), world=OPEN_FLOOR)
        run(bridge, clock, 1.0)
        self.assertGreater(dummy.read(["outD.power"], clock())[0], 0)
        # The host freezes: the link is still read, but nothing is answered.
        clock.advance(transport.watchdog_s + 0.01)
        hello = transport.read()
        self.assertEqual(transport.watchdog_trips, 1)
        self.assertFalse(transport.accepted)
        self.assertEqual(dummy.read(["outD.power", "outB.power"], clock()), [0, 0])
        self.assertEqual(codec.decode_frame(hello.strip())["kind"], codec.FRAME_HELLO)  # at once
        # It keeps announcing until a host answers.
        clock.advance(HELLO_INTERVAL_S)
        self.assertEqual(codec.decode_frame(transport.read().strip())["kind"], codec.FRAME_HELLO)

    def test_commands_after_a_trip_are_ignored_until_accepted_again(self) -> None:
        bridge, transport, dummy, _, clock = connect(outputs=(0.0, 1.0), world=OPEN_FLOOR)
        run(bridge, clock, 0.5)
        clock.advance(transport.watchdog_s + 0.01)
        transport.read()
        applied = transport.commands_applied
        transport.write(codec.encode_actuators(1, [100, 100]))
        self.assertEqual(transport.commands_applied, applied)
        self.assertEqual(dummy.read(["outD.power"], clock()), [0])


class ReplayTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        header = {
            "_record_type": "session_header",
            "robot_name": "KIRISIMA",
            "ports": {"sensor_left": 4, "sensor_center": 3, "sensor_right": 2, "motor_left": "D", "motor_right": "B"},
            "sensor_angles_deg": {"left": 45.0, "center": 0.0, "right": -45.0},
        }
        records = [
            {"step": 0, "timestamp_s": 0.0, "sensors_raw_cm": {"left_p4": 50.0, "center_p3": 40.0, "right_p2": 30.0}},
            {"step": 1, "timestamp_s": 0.5, "sensors_raw_cm": {"left_p4": 20.0, "center_p3": None, "right_p2": 10.5}},
            {"step": 2, "timestamp_s": 1.0, "sensors_raw_cm": {"left_p4": 60.0, "center_p3": 60.0, "right_p2": 60.0}},
        ]
        self.log = self.tmp / "datalog_test.jsonl"
        self.log.write_text("\n".join(json.dumps(r) for r in [header] + records) + "\n", encoding="utf-8")

    def test_plays_the_recorded_readings_in_time(self) -> None:
        replay = ReplayDriver(self.log, loop=False)
        replay.open(10.0)
        channels = ["in4.distance_mm", "in3.distance_mm", "in2.distance_mm"]
        self.assertEqual(replay.read(channels, 10.2), [500, 400, 300])
        self.assertEqual(replay.read(channels, 10.6), [200, NO_ECHO_MM, 105])
        self.assertEqual(replay.read(channels, 15.0), [600, 600, 600])

    def test_loops(self) -> None:
        replay = ReplayDriver(self.log, loop=True)
        replay.open(0.0)
        self.assertEqual(replay.read(["in4.distance_mm"], 2.2), [500])

    def test_describes_the_recorded_robot(self) -> None:
        robot = ReplayDriver(self.log).inventory()
        self.assertEqual(robot.transport, "replay")
        self.assertEqual(robot.geometry.sensors["in4"].angle_deg, 45.0)
        self.assertEqual(robot.geometry.drive.left_port, "outD")
        self.assertEqual(robot.port("in2").device, "ultrasonic")
        self.assertEqual(robot.port("in1").device, "")

    def test_runs_through_the_bridge(self) -> None:
        robot = ReplayDriver(self.log).inventory().to_dict()
        config = dummy_drive_config(robot=robot, transport={"kind": "replay", "log": str(self.log)})
        bridge, transport, replay, engine, clock = connect(config=config, outputs=(0.0, 1.0))
        run(bridge, clock, 0.4)
        self.assertEqual(bridge.state, STATE_RUNNING)
        # Rays from the first record: left 50 cm, centre 40 cm, right 30 cm.
        first = engine.calls[0]
        self.assertAlmostEqual(first[0], 50.0 / 60.0, places=6)
        self.assertAlmostEqual(first[7], 30.0 / 60.0, places=6)
        # Commands are recorded, not acted on.
        self.assertTrue(any(values for _, values in replay.commands))

    def test_an_empty_recording_is_refused(self) -> None:
        empty = self.tmp / "empty.jsonl"
        empty.write_text(json.dumps({"_record_type": "session_header"}) + "\n", encoding="utf-8")
        with self.assertRaises(ValueError):
            ReplayDriver(empty)


if __name__ == "__main__":
    unittest.main()
