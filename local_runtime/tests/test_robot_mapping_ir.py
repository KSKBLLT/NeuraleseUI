"""Mapping a host-driven robot: rays from a few sonars, two motors from steer/throttle.

The two conversions here sit between the robot and a model trained in the
simulation, so each is pinned against the code that drove the real robot:

* rays: the prototype's ``SensorAdapter3to8`` on every recorded frame of
  KIRISIMA's runs (``fixtures/robot_drive/kirisima_sensors.json.gz``);
* motors: :class:`.drive.DriveController`, itself pinned to the prototype in
  ``test_robot_drive``; here only the wiring around it is checked.
"""

from __future__ import annotations

import copy
import gzip
import json
import unittest
from pathlib import Path

from support import CAR_TRACK_RAY_ANGLES, dummy_drive_config, dummy_robot

from neuralese_local.robot.config import (
    compile_config,
    config_hash,
    validate_config,
    wire_input_channel_ids,
    wire_output_channel_ids,
)
from neuralese_local.robot.drive import DriveController, DriveParams

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "robot_drive"

#: car_track: eight rays in, steer and throttle out.
CAR_TRACK_META = {"input_size": 8, "output_size": 2}


def _fields(report) -> list:
    return [e["field"] for e in report.errors]


class RayValidationTests(unittest.TestCase):
    def test_the_kirisima_mapping_is_valid(self) -> None:
        report = validate_config(dummy_drive_config(), CAR_TRACK_META)
        self.assertTrue(report.ok, report.errors)

    def test_programmed_robots_cannot_use_rays(self) -> None:
        # Their device script would have to compute the ray on the robot.
        config = dummy_drive_config()
        config.update(platform="ev3", transport={"kind": "tcp", "host": "ev3dev.local", "port": 9999})
        config.pop("robot")
        config["outputs"] = [{"channel": "motor_a_speed", "mode": "direct", "index": 0}]
        self.assertIn("inputs[0].derive", _fields(validate_config(config)))

    def test_ray_problems_name_the_field(self) -> None:
        config = dummy_drive_config()
        ray = config["inputs"][0]
        ray["angle_deg"] = "left"
        ray["sources"][1]["channel"] = "in1.distance_mm"      # port 1 is empty
        ray["sources"][2]["angle_deg"] = ray["sources"][0]["angle_deg"]
        config["inputs"][1]["scale"] = {"kind": "identity"}
        config["inputs"][2]["sources"] = []
        config["inputs"][3]["derive"] = "average"
        self.assertEqual(sorted(_fields(validate_config(config))), sorted([
            "inputs[0].angle_deg",
            "inputs[0].sources[1].channel",
            "inputs[0].sources[2].angle_deg",
            "inputs[1].scale",
            "inputs[2].sources",
            "inputs[3].derive",
        ]))

    def test_the_model_must_take_one_value_per_ray(self) -> None:
        report = validate_config(dummy_drive_config(), {"input_size": 7, "output_size": 2})
        self.assertEqual(_fields(report), ["inputs"])


class DriveValidationTests(unittest.TestCase):
    def _drive(self, **changes):
        config = dummy_drive_config()
        config["outputs"][0].update(changes)
        return config

    def test_needs_two_different_motors_that_take_power(self) -> None:
        cases = {
            "outputs[0].channels": self._drive(channels=["outD.power"]),
            "outputs[0].channels.left": self._drive(channels=["outA.power", "outB.power"]),
        }
        for field, config in cases.items():
            with self.subTest(field=field):
                self.assertIn(field, _fields(validate_config(config)))
        same = _fields(validate_config(self._drive(channels=["outB.power", "outB.power"])))
        self.assertIn("outputs[0].channels", same)
        # An encoder is not something to drive.
        self.assertIn("outputs[0].channels.right",
                      _fields(validate_config(self._drive(channels=["outD.power", "outB.position_deg"]))))

    def test_needs_steer_and_throttle(self) -> None:
        config = dummy_drive_config()
        del config["outputs"][0]["steer_index"]
        config["outputs"][0]["throttle_index"] = -1
        self.assertEqual(sorted(_fields(validate_config(config))),
                         ["outputs[0].steer_index", "outputs[0].throttle_index"])

    def test_optional_settings_are_checked(self) -> None:
        config = self._drive(brake_index="2", throttle_scale=0, invert=[True],
                             params={"turn_power": "fast", "warp": 9, "wall_bypass": 1})
        self.assertEqual(sorted(_fields(validate_config(config))), sorted([
            "outputs[0].brake_index",
            "outputs[0].throttle_scale",
            "outputs[0].invert",
            "outputs[0].params.turn_power",
            "outputs[0].params.warp",
            "outputs[0].params.wall_bypass",
            "outputs[0].wall_inputs",  # 1 is not a yes/no, but it does ask for the bypass
        ]))

    def test_the_wall_bypass_needs_its_inputs(self) -> None:
        config = self._drive(params={"wall_bypass": True})
        self.assertEqual(_fields(validate_config(config)), ["outputs[0].wall_inputs"])
        config = self._drive(params={"wall_bypass": True}, wall_inputs={"front": 3, "left": 0, "right": 9})
        self.assertTrue(validate_config(config).ok)
        self.assertEqual(_fields(validate_config(config, CAR_TRACK_META)), ["outputs[0].wall_inputs.right"])

    def test_outputs_must_exist_in_the_model(self) -> None:
        config = self._drive(brake_index=2)
        self.assertEqual(_fields(validate_config(config, CAR_TRACK_META)), ["outputs[0].brake_index"])

    def test_a_replay_needs_its_recording(self) -> None:
        robot = dummy_robot()
        robot["transport"] = "replay"
        config = dummy_drive_config(robot=robot, transport={"kind": "replay"})
        self.assertEqual(_fields(validate_config(config)), ["transport.log"])

    def test_the_transport_is_the_one_the_robot_is_reached_by(self) -> None:
        config = dummy_drive_config(transport={"kind": "replay", "log": "run.jsonl"})
        self.assertEqual(_fields(validate_config(config)), ["transport.kind"])

    def test_the_robot_description_is_validated_first(self) -> None:
        config = dummy_drive_config(robot=dummy_robot(drive=("outB", "outB")))
        self.assertEqual(_fields(validate_config(config)), ["robot.geometry.drive"])


class WireTests(unittest.TestCase):
    def test_rays_share_their_sensors_on_the_wire(self) -> None:
        config = dummy_drive_config()
        self.assertEqual(wire_input_channel_ids(config["inputs"]),
                         ["in4.distance_mm", "in3.distance_mm", "in2.distance_mm"])
        self.assertEqual(wire_output_channel_ids(config["outputs"]), ["outD.power", "outB.power"])
        plan = compile_config(config, CAR_TRACK_META)
        self.assertEqual((plan.input_count, plan.model_input_count, plan.output_count), (3, 8, 2))
        self.assertTrue(plan.has_drive)
        self.assertEqual(plan.safe_values(), [0, 0])

    def test_plain_and_ray_inputs_mix(self) -> None:
        config = dummy_drive_config()
        sonar = {"channel": "in3.distance_mm"}
        speed = {"channel": "outD.speed_dps"}
        config["inputs"] = [config["inputs"][0], sonar, speed]
        wire = wire_input_channel_ids(config["inputs"])
        self.assertEqual(wire, ["in4.distance_mm", "in3.distance_mm", "in2.distance_mm", "in3.distance_mm",
                                "outD.speed_dps"])
        plan = compile_config(config)
        self.assertEqual([c.id for c in plan.input_channels], wire)
        model_input = plan.sensors_to_model([600, 300, 0, 123, 500])
        self.assertEqual(model_input[1:], [123.0, 500.0])

    def test_the_fingerprint_follows_the_wire(self) -> None:
        base = dummy_drive_config()
        swapped = copy.deepcopy(base)
        for ray in swapped["inputs"]:
            ray["sources"].reverse()
        self.assertNotEqual(config_hash(base), config_hash(swapped))
        # What the host alone computes is not part of it, as for scales.
        retuned = copy.deepcopy(base)
        retuned["outputs"][0]["params"] = {"turn_power": 60}
        retuned["inputs"][0]["angle_deg"] = 70.0
        self.assertEqual(config_hash(base), config_hash(retuned))


class RayTests(unittest.TestCase):
    def test_matches_the_prototype_on_every_recorded_frame(self) -> None:
        with gzip.open(FIXTURES / "kirisima_sensors.json.gz", "rb") as fh:
            data = json.loads(fh.read().decode("utf-8"))
        for theirs, mine in zip(data["ray_angles_deg"], CAR_TRACK_RAY_ANGLES):
            self.assertAlmostEqual(theirs, mine, delta=1e-5)  # theirs are float32
        self.assertEqual(data["max_distance_cm"], 60.0)
        plan = compile_config(dummy_drive_config())
        fields = data["frame_fields"]
        frames = 0
        for run in data["runs"]:
            for frame in run["frames"]:
                f = dict(zip(fields, frame))
                cm = {"in4.distance_mm": f["left_p4_cm"], "in3.distance_mm": f["center_p3_cm"],
                      "in2.distance_mm": f["right_p2_cm"]}
                wire = [2550 if cm[c.id] is None else int(round(cm[c.id] * 10)) for c in plan.input_channels]
                rays = plan.sensors_to_model(wire)
                for mine, theirs, logged in zip(rays, f["prototype_rays"], f["logged_rays"]):
                    # The prototype computes in float32; the log keeps 4 decimals.
                    self.assertAlmostEqual(mine, theirs, delta=1e-6)
                    self.assertAlmostEqual(mine, logged, delta=1e-4)
                frames += 1
        self.assertEqual(frames, 5255)

    def test_interpolates_between_neighbouring_sensors(self) -> None:
        plan = compile_config(dummy_drive_config())
        # left 60 cm (1.0), centre 0 cm (0.0), right 30 cm (0.5)
        rays = plan.sensors_to_model([600, 0, 300])
        self.assertEqual(rays[0], 1.0)                 # +66: beyond the left sonar
        self.assertEqual(rays[7], 0.5)                 # -66: beyond the right sonar
        self.assertAlmostEqual(rays[3], 9.428572 / 45.0, places=6)    # +9.4: between centre and left
        self.assertAlmostEqual(rays[4], 0.5 * 9.428572 / 45.0, places=6)

    def test_no_echo_and_far_readings_are_clear_road(self) -> None:
        plan = compile_config(dummy_drive_config())
        self.assertEqual(plan.sensors_to_model([2550, 2550, 2550]), [1.0] * 8)
        self.assertEqual(plan.sensors_to_model([9999, 700, -5])[:3], [1.0, 1.0, 1.0])
        self.assertEqual(plan.sensors_to_model([9999, 700, -5])[7], 0.0)

    def test_a_single_sensor_fills_every_ray(self) -> None:
        config = dummy_drive_config()
        for ray in config["inputs"]:
            ray["sources"] = [{"channel": "in3.distance_mm", "angle_deg": 0.0}]
        self.assertEqual(compile_config(config).sensors_to_model([300]), [0.5] * 8)


class DriveTests(unittest.TestCase):
    def test_equals_the_drive_controller(self) -> None:
        plan = compile_config(dummy_drive_config(), CAR_TRACK_META)
        plan.reset_state(10.0)
        reference = DriveController(DriveParams(), now=10.0)
        t = 10.0
        for k in range(200):
            t += 0.05
            steer = ((k * 37) % 200 - 100) / 100.0
            throttle = (k * 13 % 100) / 100.0
            wire = plan.model_to_actuators([steer, throttle], now=t)
            command = reference.compute(steer, throttle * 100.0, now=t)
            self.assertEqual(wire, [int(round(command.left)), int(round(command.right))])
            self.assertEqual(plan.drive_info[0]["status"], command.info["status"])

    def test_driving_needs_the_time(self) -> None:
        plan = compile_config(dummy_drive_config())
        with self.assertRaises(ValueError):
            plan.model_to_actuators([0.0, 1.0])

    def test_reversed_motors_are_negated(self) -> None:
        config = dummy_drive_config()
        config["outputs"][0]["invert"] = [True, False]
        plan = compile_config(config)
        plan.reset_state(0.0)
        left, right = plan.model_to_actuators([0.0, 1.0], now=1.0)
        self.assertLess(left, 0)
        self.assertGreater(right, 0)
        self.assertEqual(left, -right)

    def test_brake_scales_the_throttle_down(self) -> None:
        def settle(config, outputs):
            plan = compile_config(config)
            plan.reset_state(0.0)
            t, wire = 0.0, None
            for _ in range(40):
                t += 0.05
                wire = plan.model_to_actuators(outputs, now=t)
            return wire

        config = dummy_drive_config()
        config["outputs"][0]["brake_index"] = 2
        self.assertEqual(settle(config, [0.0, 0.8, 0.0]), [80, 80])
        self.assertEqual(settle(config, [0.0, 0.8, 0.5]), [40, 40])
        self.assertEqual(settle(config, [0.0, 0.8, 7.0]), [0, 0])   # brake is clamped to 0..1
        config["outputs"][0]["throttle_scale"] = 50
        self.assertEqual(settle(config, [0.0, 0.8, 0.0]), [40, 40])

    def test_reset_ramps_up_from_standstill_again(self) -> None:
        plan = compile_config(dummy_drive_config())
        plan.reset_state(0.0)
        t = 0.0
        for _ in range(40):
            t += 0.05
            plan.model_to_actuators([0.0, 1.0], now=t)
        self.assertEqual(plan.model_to_actuators([0.0, 1.0], now=t + 0.05), [100, 100])
        plan.reset_state(t + 0.05)
        self.assertEqual(plan.drive_info, [])
        # 260 %/s for one 50 ms frame.
        self.assertEqual(plan.model_to_actuators([0.0, 1.0], now=t + 0.1), [13, 13])

    def test_wall_bypass_reads_the_mapped_inputs(self) -> None:
        config = dummy_drive_config()
        config["outputs"][0].update(params={"wall_bypass": True}, wall_inputs={"front": 3, "left": 0, "right": 7})
        plan = compile_config(config)
        plan.reset_state(0.0)
        rays = [1.0, 1.0, 1.0, 0.2, 0.2, 0.3, 0.3, 0.3]   # wall ahead, more room on the left
        plan.model_to_actuators([0.0, 0.5], now=0.05, model_input=rays)
        self.assertEqual(plan.drive_info[0]["status"], "spin_left")
        default = compile_config(dummy_drive_config())
        default.reset_state(0.0)
        default.model_to_actuators([0.0, 0.5], now=0.05, model_input=rays)
        self.assertEqual(default.drive_info[0]["status"], "forward")


if __name__ == "__main__":
    unittest.main()
