"""Unusual networks: what the window is told about their inputs and outputs, and
whether the configuration it builds for them is accepted.

Brain Mapping lets a child turn any sensor and actuator on, in any order; datasets
get renamed and changed after a model was trained. Each case here is a binding
(``metadata.binding``) or a name list a real project can produce, run through
``describe_model``; the run configurations come from ``robot_maps.window_config``,
which builds what ``RobotPanel.build_config`` builds.
"""

from __future__ import annotations

import tempfile
import unittest
from pathlib import Path
from typing import Any, Dict, List, Sequence, Tuple

from robot_maps import linear_goal_model, room, window_config
from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot.config import compile_config, validate_config
from neuralese_local.robot.drivers.dummy import DummyHardware
from neuralese_local.robot.model_contract import SENSOR_NEEDS, SENSOR_QUANTITIES, describe_model, ray_layout
from neuralese_local.robot.robot_session import RobotSession


def binding_meta(inputs: Sequence[Tuple[str, int, int]], outputs: Sequence[Tuple[str, int, int]],
                 *, agent: str = "top_down_rover", in_width: int = 0, out_width: int = 0,
                 name: str = "custom") -> Dict[str, Any]:
    """A simulation dataset's meta: (sensor_id, start, length) per binding entry."""
    in_width = in_width or max((s + n for _, s, n in inputs), default=0)
    out_width = out_width or max((s + n for _, s, n in outputs), default=0)
    return {
        "name": name,
        "inputs": {"x": in_width},
        "outputs": [{"x": out_width}],
        "metadata": {"binding": {
            "agent_id": agent,
            "input_width": in_width,
            "output_width": out_width,
            "inputs": [{"sensor_id": s, "start": a, "length": n} for s, a, n in inputs],
            "outputs": [{"actuator_id": s, "start": a, "length": n} for s, a, n in outputs],
        }},
    }


DRIVE = [("steering", 0, 1), ("throttle", 1, 1)]


def groups(model: Dict[str, Any], key: str) -> List[Tuple[str, int, int]]:
    ids = "sensor_id" if key == "input_groups" else "actuator_id"
    return [(g[ids], g["start"], g["length"]) for g in model[key]]


def issue(model: Dict[str, Any], code: str) -> Dict[str, Any]:
    return next((i for i in model["issues"] + model["warnings"] if i["code"] == code), {})


class EverySensorTests(unittest.TestCase):
    def test_every_simulation_sensor_at_once(self) -> None:
        entries, start = [], 0
        for sensor_id in SENSOR_NEEDS:
            length = 8 if sensor_id == "ray_distance" else len(SENSOR_QUANTITIES.get(sensor_id, ("x",)))
            entries.append((sensor_id, start, length))
            start += length
        model = describe_model(binding_meta(entries, DRIVE))
        self.assertIsNone(model["blocked"])
        self.assertEqual(model["issues"], [])
        self.assertEqual(model["input_width"], start)
        self.assertEqual(model["needs"], ["field", "goal", "heading", "sensors", "wheels"])
        for neuron in model["inputs"]:
            self.assertTrue(neuron["supported"], neuron)
            if neuron["sensor_id"] != "ray_distance":
                self.assertIn("quantity", neuron)
        # Each sensor's channels get their own quantities, in order.
        by_index = {n["index"]: n.get("quantity") for n in model["inputs"]}
        for sensor_id, first, length in entries:
            for offset, quantity in enumerate(SENSOR_QUANTITIES.get(sensor_id, ())):
                self.assertEqual(by_index[first + offset], quantity, sensor_id)

    def test_the_window_config_for_every_pose_quantity_is_accepted(self) -> None:
        layout = ["ray"] * 8
        for quantities in SENSOR_QUANTITIES.values():
            layout += list(quantities)
        config = window_config(inputs=layout, world=room(), goal=(300.0, 100.0))
        self.assertTrue(validate_config(config).ok, validate_config(config).errors)
        self.assertEqual(compile_config(config).model_input_count, len(layout))


class OddBindingTests(unittest.TestCase):
    def test_entries_out_of_order_are_put_in_model_order(self) -> None:
        model = describe_model(binding_meta(
            [("speed", 8, 1), ("ray_distance", 0, 8), ("local_goal_direction", 9, 2)],
            [("throttle", 1, 1), ("steering", 0, 1)]))
        self.assertEqual(groups(model, "input_groups"), [("ray_distance", 0, 8), ("speed", 8, 1), ("local_goal_direction", 9, 2)])
        self.assertEqual(groups(model, "output_groups"), [("steering", 0, 1), ("throttle", 1, 1)])
        self.assertEqual([n["actuator_id"] for n in model["outputs"]], ["steering", "throttle"])

    def test_a_gap_between_entries_is_an_input_no_robot_can_feed(self) -> None:
        model = describe_model(binding_meta([("ray_distance", 0, 4), ("speed", 6, 1)], DRIVE, in_width=7))
        unsupported = issue(model, "unsupported_inputs")
        self.assertEqual(unsupported.get("neurons"), [4, 5])
        self.assertTrue(all(model["inputs"][i]["supported"] for i in (0, 1, 2, 3, 6)))

    def test_an_unknown_sensor_is_named_as_unsupported(self) -> None:
        model = describe_model(binding_meta([("ray_distance", 0, 8), ("height", 8, 1), ("grounded", 9, 1)], DRIVE))
        self.assertEqual(issue(model, "unsupported_inputs").get("neurons"), [8, 9])
        height = model["input_groups"][1]
        self.assertFalse(height["supported"])
        self.assertEqual(height["needs"], [])

    def test_a_binding_longer_than_the_model_is_cut_to_the_model(self) -> None:
        # The dataset says 8 rays; the project's network (and its file) has 6 inputs.
        model = describe_model(binding_meta([("ray_distance", 0, 8)], DRIVE), input_width=6)
        self.assertEqual(model["input_width"], 6)
        self.assertEqual(model["input_groups"][0]["indices"], list(range(6)))

    def test_two_ray_sensors_are_two_fans(self) -> None:
        model = describe_model(binding_meta([("ray_distance", 0, 5), ("speed", 5, 1), ("ray_distance", 6, 3)], DRIVE))
        self.assertEqual(model["ray_angles_deg"], ray_layout(5) + ray_layout(3))
        self.assertEqual(model["ray_angles_deg"][0], 66.0)
        self.assertEqual(model["ray_angles_deg"][5], 66.0)

    def test_a_single_ray_looks_straight_ahead(self) -> None:
        model = describe_model(binding_meta([("ray_distance", 0, 1)], DRIVE))
        self.assertEqual(model["ray_angles_deg"], [0.0])

    def test_a_network_without_rays_needs_no_sensors(self) -> None:
        model = describe_model(binding_meta([("speed", 0, 1), ("rotation", 1, 1), ("local_goal_direction", 2, 2)], DRIVE))
        self.assertNotIn("sensors", model["needs"])
        self.assertEqual(model["needs"], ["field", "goal", "heading", "wheels"])
        self.assertEqual(model["ray_angles_deg"], [])


class OutputTests(unittest.TestCase):
    def test_thrust_is_ignored_like_the_rover_ignores_it(self) -> None:
        model = describe_model(binding_meta([("ray_distance", 0, 8)],
                                            DRIVE + [("horizontal_thrust", 2, 1), ("vertical_thrust", 3, 1)]))
        self.assertEqual(issue(model, "ignored_outputs").get("neurons"), [2, 3])
        self.assertEqual(issue(model, "unsupported_outputs"), {})
        self.assertTrue(model["output_groups"][2]["ignored"])

    def test_jump_is_an_output_the_robot_cannot_drive(self) -> None:
        model = describe_model(binding_meta([("ray_distance", 0, 8)], DRIVE + [("jump", 2, 1)]))
        self.assertEqual(issue(model, "unsupported_outputs").get("neurons"), [2])

    def test_brake_alone_says_nothing_about_steering(self) -> None:
        model = describe_model(binding_meta([("ray_distance", 0, 8)], [("brake", 0, 1)]))
        self.assertEqual([n.get("actuator_id") for n in model["outputs"]], ["brake"])
        self.assertFalse(any(n.get("actuator_id") == "steering" for n in model["outputs"]))

    def test_an_output_without_a_name_keeps_a_number(self) -> None:
        meta = {"name": "unnamed", "inputs": {"x": 2}, "outputs": [{"x": 2}]}
        model = describe_model(meta)
        self.assertEqual([n["label"] for n in model["outputs"]], ["#1", "#2"])
        self.assertEqual(issue(model, "unsupported_outputs").get("neurons"), [0, 1])


class NameOnlyTests(unittest.TestCase):
    """Datasets made outside the simulation: only names say what a column is."""

    def test_rays_and_speed_by_name_in_any_order(self) -> None:
        names = ["speed", "ray_0", "ray_1", "ray_2", "steer", "throttle"]
        meta = {"name": "csv", "col_names": names, "outputs_from": 4, "inputs": {"x": 4}, "outputs": [{"x": 2}]}
        model = describe_model(meta)
        self.assertEqual([n["sensor_id"] for n in model["inputs"]], ["speed", "ray_distance", "ray_distance", "ray_distance"])
        self.assertEqual(model["ray_angles_deg"], ray_layout(3))
        self.assertEqual(model["needs"], ["sensors", "wheels"])

    def test_a_goal_by_name_is_not_guessed(self) -> None:
        names = ["ray_0", "ray_1", "goal_x", "goal_y", "steer", "throttle"]
        meta = {"name": "csv", "col_names": names, "outputs_from": 4}
        model = describe_model(meta, input_width=4, output_width=2)
        self.assertEqual(issue(model, "unsupported_inputs").get("neurons"), [2, 3])

    def test_russian_column_names(self) -> None:
        names = ["луч 1", "луч 2", "скорость", "руль", "газ", "тормоз"]
        meta = {"name": "ru", "col_names": names, "outputs_from": 3}
        model = describe_model(meta, input_width=3, output_width=3)
        self.assertEqual([n["kind"] for n in model["inputs"]], ["ray", "ray", "speed"])
        self.assertEqual([n["actuator_id"] for n in model["outputs"]], ["steering", "throttle", "brake"])


class ModelFileTests(unittest.TestCase):
    """The trained file is the truth: a dataset changed after training is caught here."""

    def test_a_model_trained_on_another_dataset_is_refused_up_front(self) -> None:
        meta = binding_meta([("ray_distance", 0, 8), ("speed", 8, 1), ("local_goal_direction", 9, 2)], DRIVE + [("brake", 2, 1)])
        model = describe_model(meta, model_widths=(8, 2))
        self.assertEqual(model["blocked"]["code"], "dataset_changed")
        self.assertEqual((model["input_width"], model["output_width"]), (8, 2))
        self.assertEqual(set(model["blocked"]["texts"]), {"ru", "en", "kz"})

    def test_a_matching_model_is_described_normally(self) -> None:
        meta = binding_meta([("ray_distance", 0, 8)], DRIVE)
        model = describe_model(meta, model_widths=(8, 2))
        self.assertIsNone(model["blocked"])

    def test_the_file_wins_over_the_projects_network(self) -> None:
        # The child changed the network after training: the file still has 8 inputs.
        meta = binding_meta([("ray_distance", 0, 8)], DRIVE)
        model = describe_model(meta, input_width=11, output_width=3, model_widths=(8, 2))
        self.assertIsNone(model["blocked"])
        self.assertEqual((model["input_width"], model["output_width"]), (8, 2))

    def test_untrained_comes_before_a_changed_dataset(self) -> None:
        meta = binding_meta([("ray_distance", 0, 8)], DRIVE)
        model = describe_model(meta, model_ready=False, model_widths=(5, 2))
        self.assertEqual(model["blocked"]["code"], "not_trained")

    def test_the_session_reads_the_model_file(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            path = linear_goal_model(Path(folder) / "m.onnx")          # 11 inputs, 3 outputs
            session = RobotSession.__new__(RobotSession)
            fits = binding_meta([("ray_distance", 0, 8), ("speed", 8, 1), ("local_goal_direction", 9, 2)],
                                DRIVE + [("brake", 2, 1)])
            other = binding_meta([("ray_distance", 0, 8)], DRIVE)
            self.assertIsNone(session.cmd_describe_model({"dataset_meta": fits, "model_path": str(path)})["blocked"])
            refused = session.cmd_describe_model({"dataset_meta": other, "model_path": str(path)})
            self.assertEqual(refused["blocked"]["code"], "dataset_changed")
            missing = session.cmd_describe_model({"dataset_meta": other, "model_path": str(Path(folder) / "none.onnx")})
            self.assertIsNone(missing["blocked"])


class ConfigVariantTests(unittest.TestCase):
    """What the window builds for each kind of network is accepted and compiled."""

    def assert_accepted(self, config: Dict[str, Any], inputs: int, outputs: List[str]) -> None:
        report = validate_config(config)
        self.assertTrue(report.ok, report.errors)
        plan = compile_config(config)
        self.assertEqual(plan.model_input_count, inputs)
        self.assertEqual([c.id for c in plan.output_channels], outputs)

    def test_rays_only(self) -> None:
        self.assert_accepted(window_config(inputs=["ray"] * 8, outputs=["steering", "throttle"]), 8, ["outD.power", "outB.power"])

    def test_pose_only_with_a_gyro(self) -> None:
        hardware = DummyHardware(ports=dict(DummyHardware().ports, in1="gyro"))
        config = window_config(inputs=["speed", "rotation", "local_goal_x", "local_goal_y"], heading="gyro",
                               hardware=hardware, world=room(), goal=(300.0, 200.0))
        self.assertEqual(config["odometry"]["heading"], {"source": "gyro", "channel": "in1.angle_deg"})
        self.assert_accepted(config, 4, ["outD.power", "outB.power"])

    def test_two_motors_on_each_side_one_reversed(self) -> None:
        hardware = DummyHardware(ports=dict(DummyHardware().ports, outA="large_motor", outC="large_motor"))
        sides = {"left": [("outD", False), ("outA", True)], "right": [("outB", False), ("outC", True)]}
        config = window_config(hardware=hardware, sides=sides, world=room(), goal=(300.0, 150.0))
        self.assertEqual(config["outputs"][0]["invert"], [[False, True], [False, True]])
        self.assertEqual([m["invert"] for m in config["odometry"]["left"]], [False, True])
        self.assert_accepted(config, 11, ["outD.power", "outA.power", "outB.power", "outC.power"])
        plan = compile_config(config)
        powers = plan.model_to_actuators([0.0, 1.0, 0.0], now=1.0)
        self.assertEqual(powers[0], -powers[1])
        self.assertEqual(powers[2], -powers[3])

    def test_a_goal_network_without_a_goal_in_the_world_is_refused(self) -> None:
        config = window_config(world=room(), goal=None)
        fields = {e["field"] for e in validate_config(config).to_dict()["errors"]}
        self.assertIn("world.goal", fields)

    def test_one_sonar_feeds_every_ray(self) -> None:
        config = window_config(inputs=["ray"] * 8, outputs=["steering", "throttle"], sonars=[("in3", 0.0)])
        self.assert_accepted(config, 8, ["outD.power", "outB.power"])
        self.assertTrue(all(len(entry["sources"]) == 1 for entry in config["inputs"]))


if __name__ == "__main__":
    unittest.main()
