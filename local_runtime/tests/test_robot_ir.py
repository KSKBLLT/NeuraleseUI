"""Robot IR: the one description every host-driven robot is reduced to.

The UI draws robot cards, port pickers and the geometry editor from it, and the
mapping config validates channels against it, so these tests pin the shape and
the rules rather than any particular robot.
"""

from __future__ import annotations

import shutil
import tempfile
import unittest
from pathlib import Path

from support import dummy_robot

from neuralese_local.robot import platforms, profiles
from neuralese_local.robot.drivers.dummy import DummyDriver, DummyHardware
from neuralese_local.robot.export_robot import handle_request
from neuralese_local.robot.errors import RobotError
from neuralese_local.robot.ir import (
    DEVICE_TYPES,
    IR_SCHEMA_VERSION,
    RobotIR,
    channel_id,
    channels_for,
    platform_from_ir,
    split_channel_id,
    validate_ir,
)


def _fields(report) -> list:
    return [e["field"] for e in report.errors]


class ShapeTests(unittest.TestCase):
    def test_round_trip_keeps_everything(self) -> None:
        data = dummy_robot()
        again = RobotIR.from_dict(data).to_dict()
        self.assertEqual(again, data)
        self.assertEqual(data["schema_version"], IR_SCHEMA_VERSION)

    def test_the_dummy_describes_itself_validly(self) -> None:
        report = validate_ir(dummy_robot())
        self.assertTrue(report.ok, report.errors)

    def test_channel_ids_name_the_port_and_the_quantity(self) -> None:
        self.assertEqual(channel_id("in2", "distance_mm"), "in2.distance_mm")
        self.assertEqual(split_channel_id("outB.power"), ("outB", "power"))
        self.assertEqual(split_channel_id("outB"), ("outB", ""))

    def test_channels_come_from_the_devices_in_the_ports(self) -> None:
        sensors, actuators = channels_for(RobotIR.from_dict(dummy_robot()))
        by_id = {c.id: c for c in sensors}
        sonar = by_id["in2.distance_mm"]
        self.assertEqual((sonar.native_min, sonar.native_max, sonar.unit), (0, 2550, "mm"))
        # A motor port exposes power to drive and its encoder to read.
        self.assertIn("outB.position_deg", by_id)
        self.assertIn("outB.speed_dps", by_id)
        power = {c.id: c for c in actuators}["outB.power"]
        self.assertEqual((power.native_min, power.native_max, power.safe_value), (-100, 100, 0))
        # Empty ports give nothing.
        self.assertFalse(any(c.id.startswith("in1.") for c in sensors))
        self.assertFalse(any(c.id.startswith("outA.") for c in actuators))

    def test_every_motor_type_can_be_driven_both_ways(self) -> None:
        for device in DEVICE_TYPES.values():
            for spec in device.channels:
                if spec.suffix == "power":
                    self.assertEqual((spec.native_min, spec.native_max), (-100, 100), device.id)

    def test_a_robot_becomes_a_platform_with_nothing_to_deploy(self) -> None:
        platform = platform_from_ir(RobotIR.from_dict(dummy_robot()))
        self.assertEqual(platform.id, "dummy")
        self.assertEqual(platform.transports, ["virtual"])
        self.assertEqual(platform.template, "")
        self.assertEqual(platform.deploy["method"], "none")
        self.assertEqual(platform.sensor("in3.distance_mm").unit, "mm")


class ValidationTests(unittest.TestCase):
    def test_not_a_dictionary(self) -> None:
        self.assertFalse(validate_ir([]).ok)

    def test_newer_schema_is_refused(self) -> None:
        data = dummy_robot()
        data["schema_version"] = IR_SCHEMA_VERSION + 1
        self.assertEqual(_fields(validate_ir(data)), ["robot.schema_version"])

    def test_identity_is_required(self) -> None:
        data = dummy_robot()
        data["robot_id"] = ""
        data["platform"] = " "
        self.assertEqual(sorted(_fields(validate_ir(data))), ["robot.platform", "robot.robot_id"])

    def test_port_problems_are_all_reported(self) -> None:
        data = dummy_robot()
        ports = data["ports"]
        ports.append(dict(ports[0]))                                 # in1 twice
        ports[1]["device"] = "flux_capacitor"                       # unknown device
        ports[2]["device"] = "large_motor"                          # a motor in a sensor port
        report = validate_ir(data)
        self.assertIn("robot.ports[%d]" % (len(ports) - 1), _fields(report))
        self.assertIn("robot.ports[1].device", _fields(report))
        self.assertIn("robot.ports[2].device", _fields(report))

    def test_drive_needs_two_different_motors(self) -> None:
        report = validate_ir(dummy_robot(drive=("outB", "outB")))
        self.assertIn("robot.geometry.drive", _fields(report))
        report = validate_ir(dummy_robot(drive=("outA", "outB")))  # outA is empty
        self.assertEqual(_fields(report), ["robot.geometry.drive.left_port"])
        report = validate_ir(dummy_robot(drive=("", "outB")))
        self.assertEqual(_fields(report), ["robot.geometry.drive.left_port"])

    def test_sensor_positions_belong_to_sensor_ports(self) -> None:
        report = validate_ir(dummy_robot(sonars=[("outB", 0.0)]))
        self.assertEqual(_fields(report), ["robot.geometry.sensors.outB"])


class RegistryTests(unittest.TestCase):
    def test_the_program_platform_list_is_unchanged(self) -> None:
        # The Godot export screen builds one pill per entry; IR families are
        # listed separately so it does not grow a robot it cannot export to.
        self.assertEqual([p["id"] for p in platforms.list_platforms()], ["microbit", "ev3", "spike"])

    def test_ir_families(self) -> None:
        ids = [p["id"] for p in platforms.list_ir_platforms()]
        self.assertEqual(ids, ["dummy", "ev3_direct"])
        self.assertTrue(platforms.is_ir_platform("dummy"))
        self.assertFalse(platforms.is_ir_platform("ev3"))

    def test_list_robots_always_offers_the_dummy(self) -> None:
        response = handle_request({"action": "list_robots"})
        self.assertEqual(response["status"], "ok")
        dummies = [r for r in response["robots"] if r["platform"] == "dummy"]
        self.assertEqual(len(dummies), 1)
        self.assertTrue(validate_ir(dummies[0]).ok)
        self.assertEqual(dummies[0]["proximity"]["distance_m"], 0.5)

    def test_nothing_is_exported_for_a_host_driven_robot(self) -> None:
        for action in ("preview_script", "export"):
            with self.subTest(action=action):
                with self.assertRaises(RobotError) as caught:
                    handle_request({"action": action, "platform": "dummy", "model_path": "x.onnx", "output_path": "y"})
                self.assertEqual(caught.exception.field, "platform")


class DummyInventoryTests(unittest.TestCase):
    def test_the_user_geometry_is_reported_not_the_true_one(self) -> None:
        # The Dummy knows how it is really built; the IR carries what the user
        # said. Those differ on purpose, so a wrong geometry can be tested.
        robot = DummyDriver().inventory()
        self.assertEqual(robot.geometry.sensors, {})
        self.assertIsNone(robot.geometry.drive)

    def test_status_follows_the_connection(self) -> None:
        driver = DummyDriver()
        self.assertEqual(driver.inventory().status, "available")
        driver.open(0.0)
        self.assertEqual(driver.inventory().status, "connected")
        driver.close()
        self.assertEqual(driver.inventory().status, "available")


class ProfileTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)

    def test_the_geometry_comes_back_on_the_next_listing(self) -> None:
        listed = handle_request({"action": "list_robots", "profiles_dir": str(self.dir)})["robots"][0]
        self.assertFalse(listed["profile_saved"])
        robot = dummy_robot()
        robot["name"] = "Kirisima"
        handle_request({"action": "save_robot_profile", "profiles_dir": str(self.dir), "robot": robot})
        listed = handle_request({"action": "list_robots", "profiles_dir": str(self.dir)})["robots"][0]
        self.assertTrue(listed["profile_saved"])
        self.assertEqual(listed["name"], "Kirisima")
        self.assertEqual(listed["geometry"], robot["geometry"])
        self.assertTrue(validate_ir(listed).ok)

    def test_ids_with_any_characters_get_their_own_file(self) -> None:
        a = profiles.profile_path(self.dir, "ev3:00:16:53:AA:BB:CC")
        b = profiles.profile_path(self.dir, "ev3:00:16:53:AA:BB:CD")
        self.assertNotEqual(a, b)
        self.assertEqual(a.parent, self.dir)
        self.assertNotIn(":", a.name)

    def test_an_invalid_robot_is_not_saved(self) -> None:
        with self.assertRaises(RobotError):
            profiles.save_profile(self.dir, dummy_robot(drive=("outB", "outB")))
        self.assertEqual(list(self.dir.iterdir()), [])

    def test_a_damaged_profile_is_ignored(self) -> None:
        robot = dummy_robot()
        profiles.save_profile(self.dir, robot)
        profiles.profile_path(self.dir, robot["robot_id"]).write_text("{not json", encoding="utf-8")
        self.assertIsNone(profiles.load_profile(self.dir, robot["robot_id"]))

    def test_settings_for_ports_that_changed_are_dropped(self) -> None:
        # The child rebuilt the robot: no sonar on port 2 any more, and the
        # right wheel's motor moved from B to C.
        profile = profiles.save_profile(self.dir, dummy_robot())
        rebuilt = DummyDriver(hardware=DummyHardware.from_dict({"ports": {
            "in3": "ultrasonic", "in4": "ultrasonic", "outC": "large_motor", "outD": "large_motor"}}))
        merged = profiles.apply_profile(rebuilt.inventory().to_dict(), profile)
        self.assertEqual(sorted(merged["geometry"]["sensors"]), ["in3", "in4"])
        self.assertIsNone(merged["geometry"]["drive"])
        self.assertTrue(validate_ir(merged).ok)


class GeometryExtrasTests(unittest.TestCase):
    def test_length_drive_sides_heading_and_spots_round_trip(self) -> None:
        from neuralese_local.robot.ir import Geometry
        data = {
            "sensors": {"in3": {"angle_deg": 0.0, "x_cm": 7.0, "y_cm": 0.0, "spot": "front"}},
            "drive": {"left_port": "outD", "right_port": "outB", "invert_left": False, "invert_right": True},
            "length_cm": 14.0,
            "drive_sides": {"left": [{"port": "outD", "invert": False}, {"port": "outA", "invert": True}],
                            "right": [{"port": "outB", "invert": True}]},
            "heading": "in1",
        }
        back = Geometry.from_dict(data).to_dict()
        self.assertEqual(back["length_cm"], 14.0)
        self.assertEqual(back["drive_sides"], data["drive_sides"])
        self.assertEqual(back["heading"], "in1")
        self.assertEqual(back["sensors"]["in3"]["spot"], "front")


if __name__ == "__main__":
    unittest.main()
