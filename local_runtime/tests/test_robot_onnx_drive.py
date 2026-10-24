"""The model that drove the real robot, driving the Dummy, end to end.

``car_brain.onnx`` is the prototype's model (trained on the car track: eight
rays in, steer and throttle out) that drove the EV3 "KIRISIMA". Here it runs
through everything a child's run goes through -- ONNX inference, rays from three
sonars, the drive conversion, NLR/1, the bridge's watchdogs -- with the Dummy in
place of the robot and a fake clock, so a minute of driving takes a second.

What is asserted is what the child would see: the robot drives around without
hitting anything, and Stop and a frozen host stop it whatever it is doing.
"""

from __future__ import annotations

import importlib.util
import math
import unittest
from pathlib import Path

from support import FakeClock, dummy_drive_config

from neuralese_local.robot.bridge import STATE_RUNNING, RobotBridge
from neuralese_local.robot.config import compile_config, validate_config
from neuralese_local.robot.drivers.dummy import _distance_to_segment
from neuralese_local.robot.transport import build_transport

MODEL = Path(__file__).resolve().parent / "fixtures" / "robot_drive" / "car_brain.onnx"
STEP_S = 0.005
HAVE_ONNXRUNTIME = importlib.util.find_spec("onnxruntime") is not None


@unittest.skipUnless(HAVE_ONNXRUNTIME, "onnxruntime is not installed")
class CarBrainOnDummyTests(unittest.TestCase):
    def drive(self, seconds: float, world=None, seed: int = 1):
        from neuralese_local.robot.model_meta import OnnxEngine, read_model_meta

        config = dummy_drive_config()
        config["transport"] = {"kind": "virtual", "seed": seed, **({"world": world} if world else {})}
        meta = read_model_meta(MODEL)
        self.assertTrue(validate_config(config, meta).ok)
        clock = FakeClock()
        plan = compile_config(config, meta)
        transport = build_transport(config, clock=clock)
        bridge = RobotBridge(plan, OnnxEngine(MODEL, meta), transport, clock=clock)
        bridge.start()
        dummy = transport.driver
        self.trace = {"bumps": 0, "closest_cm": math.inf, "locked": 0, "frames": 0}
        was_bumped, answered = False, 0
        for k in range(int(round(seconds / STEP_S))):
            clock.advance(STEP_S)
            bridge.poll()
            if dummy.bumped and not was_bumped:
                self.trace["bumps"] += 1
            was_bumped = dummy.bumped
            if k % 20 == 0:
                closest = min(_distance_to_segment(dummy.x, dummy.y, w) for w in dummy.world.walls)
                self.trace["closest_cm"] = min(self.trace["closest_cm"], closest)
            if bridge.stats["frames_answered"] != answered:
                answered = bridge.stats["frames_answered"]
                self.trace["frames"] += 1
                self.trace["locked"] += plan.drive_info[0]["turn_lock_dir"] != 0
                self.trace["status"] = plan.drive_info[0]["status"]
        return bridge, transport, dummy, clock

    def test_drives_around_the_room_without_touching_anything(self) -> None:
        bridge, _, dummy, _ = self.drive(60.0)
        self.assertEqual(bridge.state, STATE_RUNNING)
        stats = bridge.stats
        self.assertEqual(stats["frames_received"], 1200)
        self.assertEqual(stats["frames_answered"], 1200)
        self.assertEqual((stats["frames_corrupt"], stats["inference_errors"], stats["watchdog_trips"]), (0, 0, 0))
        path = sum(math.hypot(b[0] - a[0], b[1] - a[1]) for a, b in zip(dummy.trail, dummy.trail[1:]))
        self.assertGreater(path, 1000.0)
        self.assertEqual(self.trace["bumps"], 0)
        self.assertGreater(self.trace["closest_cm"], dummy.hardware.body_radius_cm + 10.0)
        # Mostly driving, not spinning in place.
        self.assertLess(self.trace["locked"] / self.trace["frames"], 0.25)
        bridge.stop()

    def test_the_noise_seed_does_not_change_the_outcome(self) -> None:
        for seed in (2, 3):
            with self.subTest(seed=seed):
                bridge, _, _, _ = self.drive(30.0, seed=seed)
                self.assertEqual(self.trace["bumps"], 0)
                bridge.stop()

    def test_stop_halts_a_robot_caught_spinning(self) -> None:
        # In a gap about two robot widths wide this model rocks between left
        # and right turns (the real robot did too, for up to ~10 s). Stop must
        # work in the middle of that.
        bridge, _, dummy, clock = self.drive(40.0, world={"preset": "narrow_gap"})
        self.assertIn(self.trace["status"], ("spin_left", "spin_right"))
        bridge.stop()
        heading = dummy.pose()["heading_deg"]
        dummy.tick(clock() + 1.0)
        self.assertAlmostEqual(dummy.pose()["heading_deg"], heading, delta=5.0)
        self.assertEqual(dummy.read(["outD.power", "outB.power"], clock()), [0, 0])

    def test_a_frozen_host_cannot_leave_the_robot_driving(self) -> None:
        bridge, transport, dummy, clock = self.drive(5.0)
        self.assertNotEqual(dummy.read(["outD.power"], clock()), [0])
        # Nobody polls any more. The motor lease alone stops the robot...
        x = dummy.pose()["x_cm"]
        dummy.tick(clock() + 2.0)
        self.assertLess(abs(dummy.pose()["x_cm"] - x), 35.0 * 0.45)
        # ...and the device's own watchdog clears the commands.
        clock.advance(2.0)
        transport.read()
        self.assertEqual(dummy.read(["outD.power", "outB.power"], clock()), [0, 0])


if __name__ == "__main__":
    unittest.main()
