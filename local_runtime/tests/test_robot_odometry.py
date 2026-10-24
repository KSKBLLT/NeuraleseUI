"""The robot's movement as a network trained in Simulations sees it.

Golden values come from the simulation itself: ``tests/godot/robot_pose_golden.gd``
runs ``SimulationKernelAgent.encode_*`` on a set of rover states and writes
``fixtures/robot_pose_golden.json``. The robot side must reproduce every value.
The rest checks dead reckoning on wheels and gyro, the scale taken from the
robot's length, and pose inputs end to end on the Dummy.
"""

from __future__ import annotations

import json
import math
import unittest
from pathlib import Path

from fake_ev3 import FakeBrick, FakeClock, FakePortFactory
from support import ScriptedEngine, dummy_drive_config, dummy_robot

from neuralese_local.robot.config import compile_config, validate_config
from neuralese_local.robot.drivers.dummy import DummyDriver, DummyHardware, DummyWorld
from neuralese_local.robot.drivers.ev3_direct import Ev3DirectDriver, Ev3Link
from neuralese_local.robot.odometry import (
    RAY_DISTANCE_UNITS,
    SENSOR_QUANTITIES,
    Odometry,
    OdometrySetup,
    Pose,
    World,
    cm_per_unit_for,
    quantity,
    ray_reach_cm,
)
from neuralese_local.robot.runtime import DriveLoop

GOLDEN = Path(__file__).resolve().parent / "fixtures" / "robot_pose_golden.json"


class GoldenTests(unittest.TestCase):
    """Every encoder, against the simulation's own output."""

    def test_the_robot_computes_what_the_simulation_computed(self) -> None:
        cases = json.loads(GOLDEN.read_text(encoding="utf-8"))["cases"]
        self.assertGreaterEqual(len(cases), 40)
        for number, case in enumerate(cases):
            state = case["state"]
            pose = Pose(state["x"], state["y"], state["heading"], state["vx"], state["vy"])
            world = World(cm_per_unit=1.0, bounds=tuple(state["bounds"]), goal=tuple(state["goal"]))
            for sensor_id, expected in case["values"].items():
                names = SENSOR_QUANTITIES[sensor_id]
                got = [quantity(name, pose, world) for name in names]
                for a, b in zip(got, expected):
                    self.assertAlmostEqual(a, b, places=5, msg="case %d, %s: %s vs %s" % (number, sensor_id, got, expected))


class ScaleTests(unittest.TestCase):
    def test_the_rover_is_as_long_as_the_robot(self) -> None:
        k = cm_per_unit_for(18.0)            # an 18 cm robot, the 72-unit rover
        self.assertAlmostEqual(k, 0.25)
        self.assertAlmostEqual(ray_reach_cm(k), 80.0)
        # The prototype's 60 cm vision is this rule for a 13.5 cm robot.
        self.assertAlmostEqual(ray_reach_cm(cm_per_unit_for(13.5)), 60.0)
        self.assertEqual(RAY_DISTANCE_UNITS, 320.0)


def setup(heading: str = "wheels", gyro: str = "", invert_left: bool = False) -> OdometrySetup:
    return OdometrySetup.from_dict({
        "left": [{"channel": "outD.position_deg", "invert": invert_left}],
        "right": [{"channel": "outB.position_deg"}],
        "wheel_diameter_cm": 360.0 / math.pi,      # one degree of wheel = 1 cm
        "track_cm": 10.0,
        "heading": {"source": heading, "channel": gyro},
    })


class DeadReckoningTests(unittest.TestCase):
    def world(self, **kwargs) -> World:
        return World(cm_per_unit=kwargs.pop("cm_per_unit", 1.0), start=kwargs.pop("start", (0.0, 0.0, 0.0)), **kwargs)

    def test_straight_ahead_moves_along_the_heading(self) -> None:
        odo = Odometry(setup(), self.world(start=(5.0, 5.0, math.pi / 2)))
        odo.update([0, 0], 0.0)
        odo.update([100, 100], 1.0)
        self.assertAlmostEqual(odo.pose.x, 5.0, places=6)
        self.assertAlmostEqual(odo.pose.y, 105.0, places=6)     # heading pi/2 is +y (down on screen)
        self.assertAlmostEqual(odo.pose.heading, math.pi / 2)

    def test_the_scale_turns_centimetres_into_units(self) -> None:
        odo = Odometry(setup(), self.world(cm_per_unit=0.25))
        odo.update([0, 0], 0.0)
        odo.update([50, 50], 0.5)                                # 50 cm
        self.assertAlmostEqual(odo.pose.x, 200.0)                # 200 units
        self.assertGreater(odo.quantity("speed"), 0.0)

    def test_left_wheel_further_turns_right_which_is_clockwise(self) -> None:
        odo = Odometry(setup(), self.world())
        odo.update([0, 0], 0.0)
        odo.update([math.pi * 5, -math.pi * 5], 1.0)              # spin on the spot, half a turn of a 10 cm track
        self.assertAlmostEqual(odo.pose.heading, math.pi, places=6)
        self.assertAlmostEqual(odo.pose.x, 0.0, places=6)
        self.assertAlmostEqual(odo.pose.y, 0.0, places=6)

    def test_a_reversed_motor_counts_backwards(self) -> None:
        odo = Odometry(setup(invert_left=True), self.world())
        odo.update([0, 0], 0.0)
        odo.update([-30, 30], 1.0)
        self.assertAlmostEqual(odo.pose.x, 30.0)
        self.assertAlmostEqual(odo.pose.heading, 0.0)

    def test_the_gyro_wins_over_the_wheels_for_the_heading(self) -> None:
        odo = Odometry(setup("gyro", "in1.angle_deg"), self.world(start=(0.0, 0.0, 0.5)))
        odo.update([0, 0, 1000], 0.0)                            # the gyro's own zero is wherever it was
        odo.update([0, 0, 1090], 1.0)                            # 90 degrees clockwise
        self.assertAlmostEqual(odo.pose.heading, 0.5 + math.pi / 2)

    def test_velocity_is_smoothed_and_reset_puts_the_robot_back_at_the_start(self) -> None:
        odo = Odometry(setup(), self.world(start=(1.0, 2.0, 0.0)))
        odo.update([0, 0], 0.0)
        for step in range(1, 21):
            odo.update([10 * step, 10 * step], 0.05 * step)       # 200 units/s
        self.assertAlmostEqual(odo.pose.vx, 200.0, delta=1.0)
        odo.reset()
        self.assertEqual((odo.pose.x, odo.pose.y, odo.pose.speed), (1.0, 2.0, 0.0))


def pose_config(**odometry_overrides):
    """KIRISIMA's rays plus speed and the way to a goal, on the Dummy."""
    hardware = DummyHardware()
    config = dummy_drive_config(robot=dummy_robot())
    rays = config["inputs"]
    config["inputs"] = rays + [
        {"derive": "pose", "quantity": "speed"},
        {"derive": "pose", "quantity": "local_goal_x"},
        {"derive": "pose", "quantity": "local_goal_y"},
        {"derive": "pose", "quantity": "rotation"},
    ]
    config["world"] = {"cm_per_unit": cm_per_unit_for(13.5), "bounds": [-480, -260, 960, 520],
                       "start": [0.0, 0.0, 0.0], "goal": [400.0, 0.0]}
    odometry = {
        "left": [{"channel": "outD.position_deg"}],
        "right": [{"channel": "outB.position_deg"}],
        "wheel_diameter_cm": hardware.wheel_diameter_cm,
        "track_cm": hardware.effective_track_cm,
        "heading": {"source": "wheels"},
    }
    odometry.update(odometry_overrides)
    config["odometry"] = odometry
    return config


class ConfigTests(unittest.TestCase):
    def test_a_pose_config_is_valid_and_reads_the_encoders(self) -> None:
        config = pose_config()
        report = validate_config(config)
        self.assertTrue(report.ok, report.errors)
        plan = compile_config(config)
        self.assertEqual(plan.model_input_count, 12)
        ids = [c.id for c in plan.input_channels]
        self.assertIn("outD.position_deg", ids)
        self.assertIn("outB.position_deg", ids)

    def test_missing_pieces_are_named(self) -> None:
        config = pose_config()
        del config["world"]["goal"]
        config["odometry"]["left"] = []
        fields = {e["field"] for e in validate_config(config).to_dict()["errors"]}
        self.assertIn("world.goal", fields)
        self.assertIn("odometry.left", fields)

    def test_a_gyro_channel_must_be_a_gyro(self) -> None:
        config = pose_config(heading={"source": "gyro", "channel": "in3.distance_mm"})
        fields = {e["field"] for e in validate_config(config).to_dict()["errors"]}
        self.assertIn("odometry.heading.channel", fields)

    def test_several_motors_on_one_side_get_the_same_power(self) -> None:
        config = dummy_drive_config()
        hardware_ports = dict(DummyHardware().ports, outA="large_motor", outC="large_motor")
        robot = DummyDriver(hardware=DummyHardware(ports=hardware_ports)).inventory().to_dict()
        config["robot"] = robot
        config["outputs"][0]["channels"] = [["outD.power", "outA.power"], ["outB.power", "outC.power"]]
        config["outputs"][0]["invert"] = [[False, True], False]
        self.assertTrue(validate_config(config).ok, validate_config(config).errors)
        plan = compile_config(config)
        self.assertEqual([c.id for c in plan.output_channels], ["outD.power", "outA.power", "outB.power", "outC.power"])
        powers = plan.model_to_actuators([0.0, 1.0], now=1.0)
        self.assertEqual(powers[0], -powers[1])
        self.assertEqual(powers[2], powers[3])


class EndToEndTests(unittest.TestCase):
    def test_the_dummy_drives_and_the_pose_follows_it(self) -> None:
        driver = DummyDriver(world=DummyWorld(start=(60.0, 150.0, 0.0)))
        clock = FakeClock(0.0)
        driver.open(clock())
        plan = compile_config(pose_config())
        engine = ScriptedEngine([0.0, 1.0])           # straight ahead, full throttle
        loop = DriveLoop(driver, plan, engine, clock=clock)
        loop.start()
        for _ in range(40):
            clock.now += 0.05
            record = loop.tick()
        travelled_cm = driver.pose()["x_cm"] - 60.0
        self.assertGreater(travelled_cm, 10.0)
        self.assertAlmostEqual(record["pose"]["x_cm"], travelled_cm, delta=1.5)
        model_input = engine.calls[-1]
        self.assertGreater(model_input[8], 0.0)        # speed
        self.assertAlmostEqual(model_input[9], 1.0, places=3)   # the goal is straight ahead
        self.assertAlmostEqual(model_input[10], 0.0, places=3)
        self.assertAlmostEqual(model_input[11], 0.0, places=3)  # still facing +x


class Ev3BatchTests(unittest.TestCase):
    def test_sonars_gyro_and_encoders_come_in_one_round_trip(self) -> None:
        clock = FakeClock()
        ports = FakePortFactory(clock)
        brick = FakeBrick()
        brick.types[0] = 32                     # a gyro in port 1
        brick.gyro_angle = 37.0
        brick.tacho = {0: 0, 1: 720, 2: 0, 3: -360}
        ports.ports["COM8"] = brick
        link = Ev3Link("COM8", serial_factory=ports, clock=clock, sleep=clock.sleep)
        driver = Ev3DirectDriver("COM8", mac="00:16:53:4E:DB:AB", link=link)
        driver.open(clock())
        before = len(brick.commands)
        values = driver.read(["in3.distance_mm", "in1.angle_deg", "outB.position_deg", "outD.position_deg", "in4.distance_mm"], clock())
        self.assertEqual(len(brick.commands) - before, 1)
        self.assertEqual(values, [455, 37, 720, -360, 600])


if __name__ == "__main__":
    unittest.main()
