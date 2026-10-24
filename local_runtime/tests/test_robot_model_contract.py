"""What a model's neurons mean, and whether it may run on a robot.

The fixtures are dataset dictionaries as the project's training node holds them:
``car_track`` is the built-in dataset (read from the running app: its inputs are
``ray_0`` ... ``ray_7``, its outputs ``steer`` and ``throttle``); the ``sim_*``
ones have the shape the simulation's dataset generator produces (column names
from the sensor and actuator definitions, the agent in ``metadata.binding``).
"""

from __future__ import annotations

import json
import unittest
from pathlib import Path

from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot.model_contract import (
    KIND_BRAKE,
    KIND_GOAL,
    KIND_OTHER,
    KIND_RAY,
    KIND_SPEED,
    KIND_STEER,
    KIND_THROTTLE,
    classify,
    describe_model,
    ray_layout,
)

FIXTURES = Path(__file__).resolve().parent / "fixtures" / "robot_ui"


def meta(name: str) -> dict:
    return json.loads((FIXTURES / ("%s_meta.json" % name)).read_text(encoding="utf-8"))


def kinds(neurons) -> list:
    return [n["kind"] for n in neurons]


class ClassifyTests(unittest.TestCase):
    def test_inputs(self) -> None:
        for name in ("ray_0", "ray_7", "Ray 1", "Ray 8:float", "ray3"):
            self.assertEqual(classify(name, is_output=False), KIND_RAY, name)
        self.assertEqual(classify("Speed:float", is_output=False), KIND_SPEED)
        for name in ("Local goal X", "Goal distance", "Goal direction Y:float", "GPS X"):
            self.assertEqual(classify(name, is_output=False), KIND_GOAL, name)
        for name in ("Height", "Grounded", "Rotation", "passenger_features"):
            self.assertEqual(classify(name, is_output=False), KIND_OTHER, name)

    def test_outputs(self) -> None:
        self.assertEqual(classify("steer", is_output=True), KIND_STEER)
        self.assertEqual(classify("Steering:float", is_output=True), KIND_STEER)
        self.assertEqual(classify("throttle", is_output=True), KIND_THROTTLE)
        self.assertEqual(classify("Brake", is_output=True), KIND_BRAKE)
        self.assertEqual(classify("Jump", is_output=True), KIND_OTHER)
        self.assertEqual(classify("Horizontal thrust", is_output=True), KIND_OTHER)

    def test_a_ray_is_only_a_ray_as_an_input(self) -> None:
        self.assertEqual(classify("ray_0", is_output=True), KIND_OTHER)


class RayLayoutTests(unittest.TestCase):
    def test_matches_the_simulation_and_the_prototype(self) -> None:
        angles = ray_layout(8)
        self.assertEqual(len(angles), 8)
        self.assertAlmostEqual(angles[0], 66.0)
        self.assertAlmostEqual(angles[7], -66.0)
        self.assertAlmostEqual(angles[3], 9.428571, places=5)

    def test_edges(self) -> None:
        self.assertEqual(ray_layout(0), [])
        self.assertEqual(ray_layout(1), [0.0])
        self.assertEqual(ray_layout(2), [66.0, -66.0])


class CarTrackTests(unittest.TestCase):
    def setUp(self) -> None:
        self.model = describe_model(meta("car_track"), input_width=8, output_width=2)

    def test_names_come_from_the_dataset(self) -> None:
        self.assertEqual(self.model["source"], "input_hints")
        self.assertEqual([n["name"] for n in self.model["inputs"]], ["ray_%d" % i for i in range(8)])
        self.assertEqual([n["name"] for n in self.model["outputs"]], ["steer", "throttle"])
        self.assertEqual(self.model["dataset_name"], "car_track")

    def test_meaning(self) -> None:
        self.assertEqual(kinds(self.model["inputs"]), [KIND_RAY] * 8)
        self.assertEqual(kinds(self.model["outputs"]), [KIND_STEER, KIND_THROTTLE])
        self.assertTrue(all(n["supported"] for n in self.model["inputs"] + self.model["outputs"]))

    def test_the_rays_are_one_group_with_their_angles(self) -> None:
        group = self.model["input_groups"][0]
        self.assertEqual((group["kind"], group["indices"]), (KIND_RAY, list(range(8))))
        self.assertEqual(group["title"]["ru"], "Зрение")
        self.assertEqual(len(self.model["ray_angles_deg"]), 8)

    def test_allowed_with_a_note_that_it_was_not_trained_in_the_simulation(self) -> None:
        self.assertIsNone(self.model["blocked"])
        self.assertEqual([w["code"] for w in self.model["warnings"]], ["no_binding"])
        self.assertEqual(self.model["issues"], [])
        self.assertEqual(self.model["perspective"], "unknown")


class SimulationDatasetTests(unittest.TestCase):
    def test_a_side_view_model_is_refused(self) -> None:
        model = describe_model(meta("sim_side_view"), input_width=8, output_width=2)
        self.assertEqual(model["perspective"], "side_view")
        self.assertEqual(model["blocked"]["code"], "side_view")
        for lang in ("ru", "en", "kz"):
            self.assertTrue(model["blocked"]["texts"][lang])
        # Its names are still reported, so the window can show what it was.
        self.assertEqual(model["inputs"][7]["name"], "Speed")
        self.assertEqual(kinds(model["inputs"]), [KIND_RAY] * 7 + [KIND_SPEED])

    def test_top_down_rays_only_is_fully_supported(self) -> None:
        model = describe_model(meta("sim_top_down_rays_only"))
        self.assertIsNone(model["blocked"])
        self.assertEqual(model["warnings"], [])
        self.assertEqual(model["issues"], [])
        self.assertEqual(model["source"], "col_names")
        self.assertEqual([n["name"] for n in model["inputs"]], ["Ray %d" % i for i in range(1, 9)])
        self.assertEqual(kinds(model["outputs"]), [KIND_STEER, KIND_THROTTLE])
        self.assertEqual(model["perspective"], "top_down")

    def test_speed_and_goal_come_from_the_binding_with_what_they_need(self) -> None:
        model = describe_model(meta("sim_top_down_full"))
        self.assertIsNone(model["blocked"])
        self.assertEqual(model["issues"], [])
        self.assertEqual(kinds(model["inputs"]), [KIND_RAY] * 8 + [KIND_SPEED, KIND_GOAL, KIND_GOAL])
        groups = model["input_groups"]
        self.assertEqual([g["sensor_id"] for g in groups], ["ray_distance", "speed", "local_goal_direction"])
        self.assertEqual([(g["start"], g["length"]) for g in groups], [(0, 8), (8, 1), (9, 2)])
        self.assertEqual(groups[0]["needs"], ["sensors"])
        self.assertEqual(groups[1]["quantities"], ["speed"])
        self.assertEqual(groups[2]["quantities"], ["local_goal_x", "local_goal_y"])
        self.assertEqual(model["inputs"][10]["quantity"], "local_goal_y")
        self.assertEqual(model["needs"], ["field", "goal", "heading", "sensors", "wheels"])
        self.assertEqual([g["actuator_id"] for g in model["output_groups"]], ["steering", "throttle", "brake"])
        self.assertEqual(kinds(model["outputs"]), [KIND_STEER, KIND_THROTTLE, KIND_BRAKE])

    def test_side_view_inputs_and_thrust_outputs(self) -> None:
        data = meta("sim_top_down_full")
        data["metadata"]["binding"]["inputs"].append({"sensor_id": "height", "start": 11, "length": 1})
        data["metadata"]["binding"]["outputs"].append({"actuator_id": "horizontal_thrust", "start": 3, "length": 1})
        data["col_names"] = data["col_names"][:11] + ["Height:float"] + data["col_names"][11:] + ["Horizontal thrust:float"]
        data["outputs_from"] = 12
        data["inputs"]["x"] = 12
        data["outputs"][0]["x"] = 4
        model = describe_model(data)
        issue = next(i for i in model["issues"] if i["code"] == "unsupported_inputs")
        self.assertEqual(issue["neurons"], [11])
        self.assertIn("Brain Mapping", issue["texts"]["en"])
        ignored = next(w for w in model["warnings"] if w["code"] == "ignored_outputs")
        self.assertEqual(ignored["neurons"], [3])
        self.assertTrue(model["output_groups"][3]["ignored"])

    def test_a_named_speed_without_a_binding_is_the_wheels(self) -> None:
        data = meta("car_track")
        model = describe_model(data)
        self.assertEqual(model["input_groups"][0]["sensor_id"], "ray_distance")
        self.assertEqual(model["needs"], ["sensors"])


class EdgeCaseTests(unittest.TestCase):
    def test_an_untrained_model_is_refused_first(self) -> None:
        model = describe_model(meta("car_track"), input_width=8, output_width=2, model_ready=False)
        self.assertEqual(model["blocked"]["code"], "not_trained")

    def test_untrained_wins_over_side_view(self) -> None:
        model = describe_model(meta("sim_side_view"), model_ready=False)
        self.assertEqual(model["blocked"]["code"], "not_trained")

    def test_names_that_do_not_fit_the_model_are_dropped_with_a_warning(self) -> None:
        model = describe_model(meta("car_track"), input_width=6, output_width=2)
        # The inputs no longer fit and show numbers; the two outputs still do.
        self.assertEqual([n["label"] for n in model["inputs"]], ["#%d" % i for i in range(1, 7)])
        self.assertEqual([n["name"] for n in model["outputs"]], ["steer", "throttle"])
        self.assertIn("labels_mismatch", [w["code"] for w in model["warnings"]])
        self.assertEqual(kinds(model["inputs"]), [KIND_OTHER] * 6)

    def test_no_dataset_at_all(self) -> None:
        model = describe_model(None, input_width=3, output_width=1)
        self.assertEqual(model["input_width"], 3)
        self.assertEqual([n["label"] for n in model["outputs"]], ["#1"])
        self.assertIn("no_names", [w["code"] for w in model["warnings"]])
        self.assertTrue(all(not n["supported"] for n in model["inputs"]))

    def test_widths_come_from_the_dataset_when_not_given(self) -> None:
        model = describe_model(meta("sim_top_down_rays_only"))
        self.assertEqual((model["input_width"], model["output_width"]), (8, 2))

    def test_every_text_has_three_languages(self) -> None:
        from neuralese_local.robot.model_contract import GROUP_TITLES, TEXTS

        for table in list(TEXTS.values()) + list(GROUP_TITLES.values()):
            self.assertEqual(sorted(table), ["en", "kz", "ru"])
            self.assertTrue(all(table.values()))


if __name__ == "__main__":
    unittest.main()
