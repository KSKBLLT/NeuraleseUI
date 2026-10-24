"""Mapping config: validation, defaults, and the scaling arithmetic."""

from __future__ import annotations

import unittest

from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot import config as cfg
from neuralese_local.robot.errors import ERR_ARITY_MISMATCH, ERR_UNKNOWN_CHANNEL, ConfigError
from neuralese_local.robot.platforms import get_platform


def ev3_config(**overrides):
    base = {
        "schema_version": 1,
        "platform": "ev3",
        "transport": {"kind": "tcp", "host": "ev3dev.local", "port": 9999},
        "rate_hz": 20,
        "watchdog_ms": 400,
        "inputs": [
            {"channel": "ultrasonic_4", "scale": cfg.linear_scale(0, 2550, 0.0, 1.0)},
        ],
        "outputs": [
            {"channel": "motor_a_speed", "mode": "argmax", "classes": {"0": 50, "1": -50}},
        ],
    }
    base.update(overrides)
    return base


class ScaleTests(unittest.TestCase):
    def test_linear_maps_endpoints_and_midpoint(self) -> None:
        scale = cfg.linear_scale(0, 100, -1.0, 1.0)
        self.assertAlmostEqual(cfg.apply_scale(scale, 0), -1.0)
        self.assertAlmostEqual(cfg.apply_scale(scale, 50), 0.0)
        self.assertAlmostEqual(cfg.apply_scale(scale, 100), 1.0)

    def test_identity_passes_values_through(self) -> None:
        self.assertEqual(cfg.apply_scale(cfg.identity_scale(), 17.5), 17.5)

    def test_degenerate_range_collapses_to_the_inert_end(self) -> None:
        # Rather than dividing by zero. The low end of an actuator range is
        # "stopped", which is the right thing to do with a broken config.
        scale = cfg.linear_scale(5, 5, 10.0, 20.0)
        self.assertEqual(cfg.apply_scale(scale, 5), 10.0)

    def test_inverting_a_scale_round_trips(self) -> None:
        scale = cfg.linear_scale(0, 255, 0.0, 1.0)
        back = cfg.invert_scale(scale)
        self.assertAlmostEqual(cfg.apply_scale(back, cfg.apply_scale(scale, 200)), 200.0)


class DefaultScaleTests(unittest.TestCase):
    """The highest-risk behaviour in the feature: if a sensor's range is not
    mapped onto the range the model was trained on, the robot behaves randomly
    and nothing reports an error."""

    def test_training_range_becomes_the_output_range(self) -> None:
        channel = get_platform("ev3").sensor("ultrasonic_4")
        scale = cfg.default_input_scale(channel, {"name": "distance", "min": 0, "max": 100})
        # Sensor reads millimetres; the model was trained on 0..100.
        self.assertAlmostEqual(cfg.apply_scale(scale, 2550), 100.0)
        self.assertAlmostEqual(cfg.apply_scale(scale, 1275), 50.0)

    def test_unknown_training_range_falls_back_to_identity(self) -> None:
        channel = get_platform("ev3").sensor("ultrasonic_4")
        self.assertEqual(cfg.default_input_scale(channel, None)["kind"], cfg.SCALE_IDENTITY)
        self.assertEqual(cfg.default_input_scale(channel, {"min": 5, "max": 5})["kind"], cfg.SCALE_IDENTITY)

    def test_falling_back_to_identity_is_warned_about(self) -> None:
        from neuralese_local.robot.errors import ValidationReport

        report = ValidationReport()
        cfg.default_config("ev3", {"input_size": 1, "output_size": 2}, {}, report=report)
        self.assertTrue(any(w["code"] == "unscaled_input" for w in report.warnings))


class ValidationTests(unittest.TestCase):
    def test_a_good_config_passes(self) -> None:
        self.assertTrue(cfg.validate_config(ev3_config()).ok)

    def test_unknown_platform_is_reported(self) -> None:
        report = cfg.validate_config(ev3_config(platform="turtlebot"))
        self.assertFalse(report.ok)
        self.assertEqual(report.errors[0]["field"], "platform")

    def test_unknown_sensor_names_the_field_and_the_alternatives(self) -> None:
        report = cfg.validate_config(ev3_config(inputs=[{"channel": "laser_9"}]))
        self.assertFalse(report.ok)
        error = report.errors[0]
        self.assertEqual(error["code"], ERR_UNKNOWN_CHANNEL)
        self.assertEqual(error["field"], "inputs[0].channel")
        self.assertIn("ultrasonic_4", error["details"]["available"])

    def test_transport_the_platform_cannot_use_is_rejected(self) -> None:
        # The EV3 has no USB serial port at all.
        report = cfg.validate_config(ev3_config(transport={"kind": "serial", "port": "COM3", "baud": 115200}))
        self.assertFalse(report.ok)
        self.assertEqual(report.errors[0]["field"], "transport.kind")

    def test_every_problem_is_reported_at_once(self) -> None:
        # A child fixing one dropdown per round trip through the UI is exactly
        # the cognitive load this feature exists to remove.
        report = cfg.validate_config(ev3_config(
            inputs=[{"channel": "nope"}, {"channel": "also_nope"}],
            outputs=[{"channel": "not_a_motor"}],
        ))
        self.assertEqual(len(report.errors), 3)

    def test_rate_above_what_the_platform_can_sustain_is_rejected(self) -> None:
        report = cfg.validate_config(ev3_config(rate_hz=200))
        self.assertFalse(report.ok)
        self.assertEqual(report.errors[0]["field"], "rate_hz")

    def test_watchdog_shorter_than_two_frames_warns(self) -> None:
        report = cfg.validate_config(ev3_config(rate_hz=20, watchdog_ms=60))
        self.assertTrue(report.ok)
        self.assertEqual(report.warnings[0]["code"], "watchdog_too_tight")

    def test_class_value_outside_the_motor_range_is_rejected(self) -> None:
        report = cfg.validate_config(ev3_config(
            outputs=[{"channel": "motor_a_speed", "mode": "argmax", "classes": {"0": 5000}}]))
        self.assertFalse(report.ok)

    def test_newer_schema_is_refused_rather_than_guessed_at(self) -> None:
        report = cfg.validate_config(ev3_config(schema_version=99))
        self.assertFalse(report.ok)
        self.assertEqual(report.errors[0]["field"], "schema_version")


class HardwareConflictTests(unittest.TestCase):
    """Two channels sharing one piece of hardware. Warned about, not blocked --
    handled under the hood so nobody discovers it by watching a screen flicker."""

    def _microbit(self, inputs, outputs):
        return {
            "schema_version": 1,
            "platform": "microbit",
            "transport": {"kind": "serial", "port": "", "baud": 115200},
            "rate_hz": 20,
            "watchdog_ms": 300,
            "inputs": inputs,
            "outputs": outputs,
        }

    def test_reading_light_while_using_the_screen_is_warned_about(self) -> None:
        # read_light_level() repurposes the same LED grid the display writes to.
        config = self._microbit(
            [{"channel": "light_level"}],
            [{"channel": "display_digit", "mode": "argmax", "classes": {"0": 1}}],
        )
        report = cfg.validate_config(config)
        self.assertTrue(report.ok)
        self.assertEqual(report.warnings[0]["code"], "hardware_conflict")
        self.assertEqual(report.warnings[0]["details"]["actuators"], ["display_digit"])

    def test_either_one_alone_is_fine(self) -> None:
        for inputs, outputs in (
            ([{"channel": "light_level"}], [{"channel": "pin0_analog", "mode": "argmax", "classes": {"0": 500}}]),
            ([{"channel": "accel_x"}], [{"channel": "display_digit", "mode": "argmax", "classes": {"0": 1}}]),
        ):
            with self.subTest(inputs=inputs):
                report = cfg.validate_config(self._microbit(inputs, outputs))
                self.assertFalse([w for w in report.warnings if w["code"] == "hardware_conflict"])


class ModelArityTests(unittest.TestCase):
    def test_sensor_count_must_match_the_model_input(self) -> None:
        report = cfg.validate_config(ev3_config(), {"input_size": 3, "output_size": 2})
        self.assertFalse(report.ok)
        self.assertEqual(report.errors[0]["code"], ERR_ARITY_MISMATCH)

    def test_argmax_must_cover_every_class_the_model_can_predict(self) -> None:
        # Otherwise a class the model does predict silently does nothing.
        report = cfg.validate_config(ev3_config(), {"input_size": 1, "output_size": 4})
        self.assertFalse(report.ok)
        self.assertEqual(report.errors[0]["details"]["missing"], ["2", "3"])

    def test_direct_output_cannot_read_past_the_model(self) -> None:
        config = ev3_config(outputs=[{
            "channel": "motor_a_speed", "mode": "direct", "index": 5,
            "scale": cfg.linear_scale(0, 1, -100, 100)}])
        report = cfg.validate_config(config, {"input_size": 1, "output_size": 2})
        self.assertFalse(report.ok)
        self.assertEqual(report.errors[0]["code"], ERR_ARITY_MISMATCH)


class MappingPlanTests(unittest.TestCase):
    def test_sensor_readings_are_scaled_into_model_space(self) -> None:
        plan = cfg.compile_config(ev3_config())
        self.assertAlmostEqual(plan.sensors_to_model([1275])[0], 0.5)

    def test_readings_outside_the_documented_range_are_clamped(self) -> None:
        # A sensor glitching outside its range must not push the model into a
        # region it never saw during training, where its output means nothing.
        plan = cfg.compile_config(ev3_config())
        self.assertAlmostEqual(plan.sensors_to_model([99999])[0], 1.0)
        self.assertAlmostEqual(plan.sensors_to_model([-5])[0], 0.0)

    def test_wrong_number_of_readings_is_an_error_not_a_guess(self) -> None:
        plan = cfg.compile_config(ev3_config())
        with self.assertRaises(ValueError):
            plan.sensors_to_model([1, 2])

    def test_argmax_picks_the_winning_class(self) -> None:
        plan = cfg.compile_config(ev3_config())
        self.assertEqual(plan.model_to_actuators([0.9, 0.1]), [50])
        self.assertEqual(plan.model_to_actuators([0.1, 0.9]), [-50])

    def test_argmax_ties_take_the_first_class(self) -> None:
        plan = cfg.compile_config(ev3_config())
        self.assertEqual(plan.model_to_actuators([0.5, 0.5]), [50])

    def test_unmapped_class_does_the_inert_thing(self) -> None:
        plan = cfg.compile_config(ev3_config())
        # Class 2 has no value configured; stopping beats guessing a speed.
        self.assertEqual(plan.model_to_actuators([0.1, 0.2, 0.9]), [0])

    def test_direct_output_is_scaled_and_clamped_to_the_motor(self) -> None:
        plan = cfg.compile_config(ev3_config(outputs=[{
            "channel": "motor_a_speed", "mode": "direct", "index": 0,
            "scale": cfg.linear_scale(0.0, 1.0, -100.0, 100.0)}]))
        self.assertEqual(plan.model_to_actuators([0.5]), [0])
        self.assertEqual(plan.model_to_actuators([1.0]), [100])
        self.assertEqual(plan.model_to_actuators([9.0]), [100])

    def test_threshold_output_switches_between_two_values(self) -> None:
        plan = cfg.compile_config(ev3_config(outputs=[{
            "channel": "motor_a_speed", "mode": "threshold", "index": 0,
            "threshold": 0.6, "on_value": 75, "off_value": 0}]))
        self.assertEqual(plan.model_to_actuators([0.7]), [75])
        self.assertEqual(plan.model_to_actuators([0.5]), [0])

    def test_safe_values_are_the_inert_ones(self) -> None:
        self.assertEqual(cfg.compile_config(ev3_config()).safe_values(), [0])

    def test_compiling_an_invalid_config_raises(self) -> None:
        with self.assertRaises(ConfigError):
            cfg.compile_config(ev3_config(inputs=[{"channel": "nope"}]))


class ConfigHashTests(unittest.TestCase):
    def test_hash_is_stable_across_equal_configs(self) -> None:
        self.assertEqual(cfg.config_hash(ev3_config()), cfg.config_hash(ev3_config()))

    def test_changing_a_channel_changes_the_hash(self) -> None:
        other = ev3_config(inputs=[{"channel": "touch_1"}])
        self.assertNotEqual(cfg.config_hash(ev3_config()), cfg.config_hash(other))

    def test_retuning_a_scale_does_not_invalidate_a_flashed_script(self) -> None:
        # The device script embeds only the channel list and timing, so tuning a
        # scale on the host must not force the child to reflash the robot.
        retuned = ev3_config(inputs=[
            {"channel": "ultrasonic_4", "scale": cfg.linear_scale(0, 2550, 0.0, 5.0)},
        ])
        self.assertEqual(cfg.config_hash(ev3_config()), cfg.config_hash(retuned))


class DefaultConfigTests(unittest.TestCase):
    def test_defaults_are_valid_for_every_platform(self) -> None:
        for platform_id in ("microbit", "ev3", "spike"):
            meta = {"input_size": 2, "output_size": 3}
            config = cfg.default_config(platform_id, meta)
            report = cfg.validate_config(config, meta)
            self.assertTrue(report.ok, "%s: %s" % (platform_id, report.errors))

    def test_multi_output_models_default_to_classifier_behaviour(self) -> None:
        config = cfg.default_config("ev3", {"input_size": 1, "output_size": 3})
        self.assertEqual(config["outputs"][0]["mode"], cfg.MODE_ARGMAX)
        # Three classes spread across the motor range: reverse, stop, forward.
        self.assertEqual(config["outputs"][0]["classes"], {"0": -100, "1": 0, "2": 100})

    def test_single_output_models_default_to_direct_control(self) -> None:
        config = cfg.default_config("ev3", {"input_size": 1, "output_size": 1})
        self.assertEqual(config["outputs"][0]["mode"], cfg.MODE_DIRECT)


if __name__ == "__main__":
    unittest.main()
