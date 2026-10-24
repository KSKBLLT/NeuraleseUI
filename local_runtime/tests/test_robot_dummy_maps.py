"""The Dummy driven by what the robot window would start, on maps with obstacles.

Each run builds the configuration the window builds (``robot_maps.window_config``,
the same steps as ``RobotPanel.build_config``) and drives the Dummy with a
stand-in network that heads for the goal and steers away from close rays. The
network is fixed, so what is tested is everything around it: rays between the
placed sonars at the robot's scale, the pose and the goal from the wheels and the
gyro, the order of the inputs, the wheel check's answer, the robot's length.
"""

from __future__ import annotations

import copy
import math
import tempfile
import unittest
from pathlib import Path

from robot_maps import (
    FULL_INPUTS,
    FULL_OUTPUTS,
    MAPS,
    PolicyEngine,
    drive,
    linear_goal_model,
    room,
    window_config,
)

from neuralese_local.robot.config import compile_config, validate_config
from neuralese_local.robot.drivers.dummy import DummyDriver, DummyHardware
from neuralese_local.robot.ir import SensorPose
from neuralese_local.robot.model_meta import OnnxEngine, read_model_meta

#: Maps KIRISIMA (three sonars, echoes lost at glancing angles) gets through.
KIRISIMA_MAPS = ("open_ahead", "goal_to_the_left", "goal_behind", "box_in_the_way", "pillars", "big_room_far_goal")

#: Four sonars over the whole ray fan, for the narrow zigzag.
WIDE_SONARS = [("in1", 60.0), ("in2", 20.0), ("in3", -20.0), ("in4", -60.0)]


def wide_hardware(**overrides) -> DummyHardware:
    ports = {port: "ultrasonic" for port, _ in WIDE_SONARS}
    ports.update({"outB": "large_motor", "outD": "large_motor"})
    return DummyHardware(ports=ports, mounts={port: SensorPose(angle, 8.0, 0.0) for port, angle in WIDE_SONARS}, **overrides)


def gyro_hardware(**overrides) -> DummyHardware:
    ports = dict(DummyHardware().ports, in1="gyro")
    return DummyHardware(ports=ports, **overrides)


def run_map(name: str, *, hardware=None, seconds: float = 90.0, engine=None, **config_args):
    world, goal = MAPS[name]
    world = copy.deepcopy(world)
    hardware = hardware or DummyHardware()
    config = window_config(world=world, goal=goal, hardware=hardware, **config_args)
    report = validate_config(config)
    if not report.ok:
        raise AssertionError(report.errors)
    driver = DummyDriver(world=world, hardware=hardware, seed=1)
    return drive(driver, config, engine or PolicyEngine(config_args.get("inputs", FULL_INPUTS),
                                                        config_args.get("outputs", FULL_OUTPUTS)),
                 goal=goal, seconds=seconds)


class MapTests(unittest.TestCase):
    def test_kirisima_reaches_the_goal_on_every_map_without_touching_a_wall(self) -> None:
        for name in KIRISIMA_MAPS:
            with self.subTest(map=name):
                result = run_map(name)
                self.assertTrue(result["reached"], "%s: ended at %s" % (name, result["pose"]))
                self.assertEqual(result["bumps"], 0, name)

    def test_four_sonars_get_through_the_zigzag(self) -> None:
        result = run_map("zigzag", hardware=wide_hardware(ricochet_probability=0.0), sonars=WIDE_SONARS)
        self.assertTrue(result["reached"], result["pose"])
        self.assertEqual(result["bumps"], 0)

    def test_the_heading_from_the_gyro_gets_there_too(self) -> None:
        for name in ("goal_behind", "box_in_the_way", "pillars"):
            with self.subTest(map=name):
                result = run_map(name, hardware=gyro_hardware(), heading="gyro",
                                 sonars=[("in2", -45.0), ("in3", 0.0), ("in4", 45.0)])
                self.assertTrue(result["reached"], result["pose"])
                self.assertEqual(result["bumps"], 0)


class WheelCheckTests(unittest.TestCase):
    """What the wheel check found decides whether the robot gets anywhere."""

    def test_a_motor_mounted_the_other_way_drives_right_once_the_check_says_so(self) -> None:
        hardware = DummyHardware(left_polarity=-1)
        result = run_map("box_in_the_way", hardware=hardware,
                         sides={"left": [("outD", True)], "right": [("outB", False)]})
        self.assertTrue(result["reached"], result["pose"])
        self.assertEqual(result["bumps"], 0)

    def test_without_that_answer_the_robot_only_spins(self) -> None:
        hardware = DummyHardware(left_polarity=-1)
        result = run_map("open_ahead", hardware=hardware, seconds=20.0)
        self.assertFalse(result["reached"])
        start = MAPS["open_ahead"][0].start
        travelled = math.hypot(result["pose"]["x_cm"] - start[0], result["pose"]["y_cm"] - start[1])
        self.assertLess(travelled, 60.0)

    def test_swapped_wheels_are_found_by_the_check_and_then_drive(self) -> None:
        hardware = DummyHardware(left_motor="outB", right_motor="outD")
        wrong = run_map("goal_to_the_left", hardware=hardware, seconds=25.0)
        right = run_map("goal_to_the_left", hardware=hardware,
                        sides={"left": [("outB", False)], "right": [("outD", False)]})
        self.assertFalse(wrong["reached"])
        self.assertTrue(right["reached"], right["pose"])


class ScaleTests(unittest.TestCase):
    def test_a_bigger_robot_sees_further_and_still_gets_there(self) -> None:
        small = window_config(robot_length_cm=14.0)
        big = window_config(robot_length_cm=28.0)
        self.assertAlmostEqual(big["inputs"][0]["scale"]["in_max"], 2 * small["inputs"][0]["scale"]["in_max"])
        for name in ("open_ahead", "box_in_the_way"):
            with self.subTest(map=name):
                result = run_map(name, robot_length_cm=28.0)
                self.assertTrue(result["reached"], result["pose"])
                self.assertEqual(result["bumps"], 0)

    def test_the_goal_lands_where_it_is_in_the_room_whatever_the_scale(self) -> None:
        world, goal = MAPS["goal_to_the_left"]
        for length in (10.0, 14.0, 30.0):
            config = window_config(world=world, goal=goal, robot_length_cm=length)
            gx, gy = config["world"]["goal"]
            cm = config["world"]["cm_per_unit"]
            self.assertAlmostEqual(gx * cm, goal[0] - world.start[0], places=6)
            self.assertAlmostEqual(-gy * cm, goal[1] - world.start[1], places=6)


class InputLayoutTests(unittest.TestCase):
    """Networks see their inputs in whatever order Brain Mapping gave them."""

    def test_inputs_in_an_unusual_order(self) -> None:
        layout = ["local_goal_y", "ray", "ray", "ray", "speed", "ray", "ray", "ray", "ray", "local_goal_x", "ray"]
        result = run_map("box_in_the_way", inputs=layout)
        self.assertTrue(result["reached"], result["pose"])
        self.assertEqual(result["bumps"], 0)

    def test_every_pose_quantity_at_once(self) -> None:
        layout = ["ray"] * 8 + ["speed", "velocity_x", "velocity_y", "rotation", "heading_sin", "heading_cos",
                                "position_x", "position_y", "goal_x", "goal_y", "local_goal_x", "local_goal_y",
                                "goal_distance"]
        world, goal = MAPS["goal_to_the_left"]
        world = copy.deepcopy(world)
        config = window_config(inputs=layout, world=world, goal=goal)
        engine = PolicyEngine(layout)
        result = drive(DummyDriver(world=world, seed=1), config, engine, goal=goal)
        self.assertTrue(result["reached"], result["pose"])
        first, last = engine.calls[0], engine.calls[-1]
        named = dict(zip(layout[8:], range(8, len(layout))))
        for row in engine.calls:
            # The simulation's ranges: a place is -1..1 across the world, like a direction.
            for name in ("rotation", "velocity_x", "velocity_y", "heading_sin", "heading_cos", "goal_x", "goal_y",
                         "position_x", "position_y"):
                self.assertTrue(-1.0001 <= row[named[name]] <= 1.0001, name)
            for name in ("speed", "goal_distance"):
                self.assertTrue(-0.0001 <= row[named[name]] <= 1.0001, name)
        self.assertLess(last[named["goal_distance"]], first[named["goal_distance"]])
        self.assertAlmostEqual(first[named["rotation"]], 0.0, places=3)
        # The goal is ahead and to the left; the robot turned left (counter-clockwise),
        # which is a negative rotation in the simulation (clockwise positive).
        self.assertLess(min(row[named["rotation"]] for row in engine.calls), -0.05)

    def test_a_network_without_rays_drives_on_its_pose_alone(self) -> None:
        layout = ["speed", "local_goal_x", "local_goal_y", "rotation"]
        result = run_map("goal_behind", inputs=layout)
        self.assertTrue(result["reached"], result["pose"])

    def test_outputs_in_another_order_with_a_brake(self) -> None:
        outputs = ["throttle", "brake", "steering"]
        config = window_config(outputs=outputs)
        self.assertEqual((config["outputs"][0]["steer_index"], config["outputs"][0]["throttle_index"],
                          config["outputs"][0]["brake_index"]), (2, 0, 1))
        result = run_map("pillars", outputs=outputs)
        self.assertTrue(result["reached"], result["pose"])

    def test_two_ray_fans(self) -> None:
        # Two ray sensors in Brain Mapping are two fans of their own, each over 132 degrees.
        layout = ["ray"] * 4 + ["local_goal_x", "local_goal_y"] + ["ray"] * 4
        fan = [66.0, 22.0, -22.0, -66.0]
        config = window_config(inputs=layout, ray_angles=fan + fan, world=room(), goal=(330.0, 150.0))
        angles = [entry["angle_deg"] for entry in config["inputs"] if entry["derive"] == "ray"]
        self.assertEqual(angles, fan + fan)
        plan = compile_config(config)
        self.assertEqual(plan.model_input_count, 10)


class OnnxTests(unittest.TestCase):
    """A real ONNX model through onnxruntime, as a run in the window uses it."""

    def test_an_onnx_network_with_rays_and_the_goal_gets_there(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = linear_goal_model(Path(folder) / "goal.onnx")
            meta = read_model_meta(path)
            self.assertEqual((meta["input_size"], meta["output_size"]), (11, 3))
            engine = OnnxEngine(path, meta)
            for name in ("open_ahead", "goal_to_the_left"):
                with self.subTest(map=name):
                    result = run_map(name, engine=engine)
                    self.assertTrue(result["reached"], result["pose"])
                    self.assertEqual(result["bumps"], 0)
            engine.close()


if __name__ == "__main__":
    unittest.main()
