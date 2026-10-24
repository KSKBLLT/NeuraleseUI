"""Device script generation.

The generated scripts are pinned as snapshots in ``snapshots/``. They are the
artefact a child actually runs, so any change to device behaviour should show up
as a reviewable diff rather than as a surprise on someone's desk. Regenerate
with ``NEURALESE_UPDATE_SNAPSHOTS=1``.
"""

from __future__ import annotations

import ast
import os
import unittest
from pathlib import Path

from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot import generate
from neuralese_local.robot.codec import MAX_LINE_BYTES
from neuralese_local.robot.config import (
    compile_config,
    config_hash,
    default_config,
    linear_scale,
    validate_config,
)
from neuralese_local.robot.errors import ConfigError, RobotError
from neuralese_local.robot.platforms import get_platform

SNAPSHOT_DIR = Path(__file__).resolve().parent / "snapshots"


CONFIGS = {
    "microbit": {
        "schema_version": 1,
        "platform": "microbit",
        "transport": {"kind": "serial", "port": "", "baud": 115200},
        "rate_hz": 20,
        "watchdog_ms": 300,
        "inputs": [
            {"channel": "accel_x", "scale": linear_scale(-2048, 2048, -1.0, 1.0)},
            {"channel": "light_level", "scale": linear_scale(0, 255, 0.0, 1.0)},
        ],
        "outputs": [
            {"channel": "pin0_analog", "mode": "argmax", "classes": {"0": 1023, "1": 0}},
            {"channel": "display_digit", "mode": "argmax", "classes": {"0": 1, "1": 2}},
        ],
    },
    "ev3": {
        "schema_version": 1,
        "platform": "ev3",
        "transport": {"kind": "tcp", "host": "ev3dev.local", "port": 9999},
        "rate_hz": 20,
        "watchdog_ms": 400,
        "inputs": [
            {"channel": "ultrasonic_4", "scale": linear_scale(0, 2550, 0.0, 1.0)},
            {"channel": "color_reflect_3", "scale": linear_scale(0, 100, 0.0, 1.0)},
            {"channel": "color_ambient_3", "scale": linear_scale(0, 100, 0.0, 1.0)},
        ],
        "outputs": [
            {"channel": "motor_a_speed", "mode": "argmax", "classes": {"0": 75, "1": -75, "2": 0}},
            {"channel": "motor_b_speed", "mode": "argmax", "classes": {"0": -75, "1": 75, "2": 0}},
        ],
    },
    "spike": {
        "schema_version": 1,
        "platform": "spike",
        "transport": {"kind": "serial", "port": "", "baud": 115200},
        "rate_hz": 20,
        "watchdog_ms": 300,
        "inputs": [
            {"channel": "color_a_reflection", "scale": linear_scale(0, 100, 0.0, 1.0)},
            {"channel": "ultrasonic_b", "scale": linear_scale(0, 2000, 0.0, 1.0)},
        ],
        "outputs": [
            {"channel": "motor_e_speed", "mode": "argmax", "classes": {"0": 80, "1": -80}},
            {"channel": "hub_light", "mode": "argmax", "classes": {"0": 2, "1": 1}},
        ],
    },
}


class SnapshotTests(unittest.TestCase):
    def _check(self, platform_id: str) -> str:
        script = generate.generate_script(CONFIGS[platform_id])
        path = SNAPSHOT_DIR / ("%s_script.py" % platform_id)
        if os.environ.get("NEURALESE_UPDATE_SNAPSHOTS"):
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(script, encoding="utf-8")
        self.assertTrue(path.exists(), "Missing snapshot %s (regenerate with NEURALESE_UPDATE_SNAPSHOTS=1)" % path)
        self.assertEqual(
            script, path.read_text(encoding="utf-8"),
            "The generated %s script changed. Review the diff, then regenerate with "
            "NEURALESE_UPDATE_SNAPSHOTS=1 if it is intended." % platform_id,
        )
        return script

    def test_microbit_script_matches_snapshot(self) -> None:
        self._check("microbit")

    def test_ev3_script_matches_snapshot(self) -> None:
        self._check("ev3")

    def test_spike_script_matches_snapshot(self) -> None:
        self._check("spike")


class GeneratedCodeTests(unittest.TestCase):
    def test_every_script_is_valid_python(self) -> None:
        # MicroPython is a subset, so parsing is necessary but not sufficient.
        # It does catch the whole class of template-substitution mistakes.
        for platform_id, config in CONFIGS.items():
            with self.subTest(platform=platform_id):
                ast.parse(generate.generate_script(config))

    def test_generation_is_deterministic(self) -> None:
        # No timestamps or paths baked in, so snapshots and the config
        # fingerprint stay meaningful.
        for config in CONFIGS.values():
            self.assertEqual(generate.generate_script(config), generate.generate_script(config))

    def test_the_script_embeds_the_fingerprint_the_host_will_check(self) -> None:
        for platform_id, config in CONFIGS.items():
            with self.subTest(platform=platform_id):
                self.assertIn(
                    'CFG_HASH = "%s"' % config_hash(config),
                    generate.generate_script(config),
                )

    def test_the_script_reads_exactly_the_configured_sensors_in_order(self) -> None:
        config = CONFIGS["ev3"]
        script = generate.generate_script(config)
        plan = compile_config(config)
        positions = [script.index(channel.expr) for channel in plan.input_channels]
        self.assertEqual(positions, sorted(positions))

    def test_shared_hardware_is_only_set_up_once(self) -> None:
        # Reflected and ambient light are two channels on one ColorSensor;
        # constructing it twice would claim the port twice.
        script = generate.generate_script(CONFIGS["ev3"])
        self.assertEqual(script.count("_color_3 = ColorSensor(INPUT_3)"), 1)

    def test_safe_values_are_the_inert_ones(self) -> None:
        for platform_id, config in CONFIGS.items():
            with self.subTest(platform=platform_id):
                plan = compile_config(config)
                self.assertIn("SAFE = %r" % plan.safe_values(), generate.generate_script(config))
                self.assertTrue(all(value == 0 for value in plan.safe_values()))

    def test_timing_constants_follow_the_config(self) -> None:
        config = dict(CONFIGS["microbit"], rate_hz=25, watchdog_ms=500)
        script = generate.generate_script(config)
        self.assertIn("PERIOD_MS = 40", script)
        self.assertIn("WATCHDOG_MS = 500", script)

    def test_every_script_has_a_watchdog_and_a_safe_stop(self) -> None:
        for platform_id, config in CONFIGS.items():
            with self.subTest(platform=platform_id):
                script = generate.generate_script(config)
                self.assertIn("def safe_stop():", script)
                self.assertIn("WATCHDOG", script)

    def test_the_default_config_generates_for_every_platform(self) -> None:
        for platform_id in ("microbit", "ev3", "spike"):
            with self.subTest(platform=platform_id):
                meta = {"input_size": 2, "output_size": 3}
                ast.parse(generate.generate_script(default_config(platform_id, meta), meta))

    def test_a_mapping_too_wide_for_the_link_is_refused_at_export(self) -> None:
        # Caught at export, not by the codec at encode time -- which would mean
        # the failure surfaces on the robot, mid-run, the first time a sensor
        # happens to report a wide enough value. Five copies of the micro:bit's
        # sensor list needs ~330 bytes against a 240 byte limit.
        platform = get_platform("microbit")
        wide = dict(CONFIGS["microbit"], inputs=[
            {"channel": channel.id} for channel in platform.sensors
        ] * 5)
        with self.assertRaises(ConfigError) as caught:
            generate.generate_script(wide)
        self.assertEqual(caught.exception.field, "inputs")

    def test_a_mapping_that_fits_is_allowed(self) -> None:
        platform = get_platform("microbit")
        snug = dict(CONFIGS["microbit"], inputs=[
            {"channel": channel.id} for channel in platform.sensors
        ] * 3)
        self.assertTrue(validate_config(snug).ok)


class FrameSizeTests(unittest.TestCase):
    def test_snapshot_configs_fit_comfortably_inside_a_frame(self) -> None:
        from neuralese_local.robot import codec

        for platform_id, config in CONFIGS.items():
            with self.subTest(platform=platform_id):
                plan = compile_config(config)
                # Widest plausible values for the configured channels.
                sensors = [int(channel.native_min) for channel in plan.input_channels]
                frame = codec.encode_sensors(codec.SEQ_MOD - 1, sensors)
                self.assertLess(len(frame), MAX_LINE_BYTES)


class TemplateErrorTests(unittest.TestCase):
    def test_an_unfilled_placeholder_is_caught(self) -> None:
        with self.assertRaises(RobotError):
            generate.render_template("microbit.py.tmpl", {"BANNER": "x"})


if __name__ == "__main__":
    unittest.main()
