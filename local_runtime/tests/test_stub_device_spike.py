"""SPIKE Prime: the generated script run against stubbed Pybricks modules.

NOT an emulator -- no SPIKE Prime simulator exists, open source or otherwise.
See ``emulators/device_stubs.py``. The generated script is genuinely executed and
genuinely talks the protocol to the real host bridge; the hub underneath it is a
stub, so device-specific behaviour still needs hardware to verify.
"""

from __future__ import annotations

import time
import unittest

from support import ScriptedEngine  # noqa: F401  (puts the runtime on sys.path)

from emulators.device_stubs import BytePipe, DeviceWorld, build_pybricks_modules
from emulators.stub_runner import StubDeviceRunner
from neuralese_local.robot.bridge import STATE_RUNNING, RobotBridge
from neuralese_local.robot.config import compile_config, linear_scale
from neuralese_local.robot.generate import generate_script_for_plan

DEADLINE_S = 6.0


def spike_config(**overrides):
    base = {
        "schema_version": 1,
        "platform": "spike",
        "transport": {"kind": "serial", "port": "", "baud": 115200},
        "rate_hz": 20,
        "watchdog_ms": 300,
        "inputs": [
            {"channel": "color_a_reflection", "scale": linear_scale(0, 100, 0.0, 1.0)},
            {"channel": "force_c_pressed"},
        ],
        "outputs": [
            {"channel": "motor_e_speed", "mode": "argmax", "classes": {"0": 80, "1": -80}},
            {"channel": "hub_light", "mode": "argmax", "classes": {"0": 2, "1": 1}},
        ],
    }
    base.update(overrides)
    return base


class SpikeScriptTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.config = spike_config()
        self.plan = compile_config(self.config)
        self.world = DeviceWorld()
        self.pipe = BytePipe()
        self.runner = StubDeviceRunner(
            generate_script_for_plan(self.plan),
            build_pybricks_modules(self.world, self.pipe),
            self.world,
            self.pipe,
        )
        self.addCleanup(self.runner.stop)
        self.bridge = None

    def connect(self, engine=None) -> RobotBridge:
        self.runner.start()
        self.bridge = RobotBridge(self.plan, engine or ScriptedEngine([1.0, 0.0]), self.runner.transport())
        self.bridge.start()
        self.addCleanup(self.bridge.stop)
        self.assertTrue(
            self.pump_until(lambda: self.bridge.state == STATE_RUNNING),
            "The SPIKE script never completed the handshake. Error: %r" % (self.runner.error,),
        )
        return self.bridge

    def pump_until(self, predicate, timeout: float = DEADLINE_S) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            if self.runner.error is not None:
                raise AssertionError("The SPIKE script crashed: %r" % (self.runner.error,))
            self.bridge.poll()
            time.sleep(0.002)
        return bool(predicate())


class HandshakeTests(SpikeScriptTestCase):
    def test_the_script_announces_itself_correctly(self) -> None:
        bridge = self.connect()
        self.assertEqual(bridge.robot_info["platform"], "spike")
        self.assertEqual(bridge.robot_info["n_in"], 2)
        self.assertEqual(bridge.robot_info["n_out"], 2)
        self.assertEqual(bridge.robot_info["cfg_hash"], bridge.expected_config_hash)

    def test_the_hub_light_shows_it_is_waiting_then_connected(self) -> None:
        # The child gets feedback from the hub itself about whether it is
        # waiting or live, without having to look at the computer.
        self.connect()
        self.assertTrue(self.pump_until(lambda: self.world.last("hub_light") == "GREEN"))
        lights = [entry["value"] for entry in self.world.commands if entry["target"] == "hub_light"]
        self.assertEqual(lights[0], "YELLOW")
        self.assertIn("GREEN", lights)
        self.assertLess(lights.index("YELLOW"), lights.index("GREEN"))


class ControlLoopTests(SpikeScriptTestCase):
    def test_sensor_readings_reach_the_model_scaled(self) -> None:
        engine = ScriptedEngine([1.0, 0.0])
        self.world.sensors["color_a_reflection"] = 40
        self.world.sensors["force_c_pressed"] = 1
        self.connect(engine)
        self.assertTrue(self.pump_until(lambda: len(engine.calls) > 1))
        reading = engine.calls[-1]
        self.assertAlmostEqual(reading[0], 0.4, places=3)
        self.assertEqual(reading[1], 1.0)

    def test_a_prediction_drives_the_motor(self) -> None:
        self.connect(ScriptedEngine([0.9, 0.1]))
        self.assertTrue(self.pump_until(lambda: self.world.last("motor_e") == 80))

    def test_changing_the_world_reverses_the_motor(self) -> None:
        engine = ScriptedEngine(lambda values: [1.0, 0.0] if values[1] else [0.0, 1.0])
        self.world.sensors["force_c_pressed"] = 1
        self.connect(engine)
        self.assertTrue(self.pump_until(lambda: self.world.last("motor_e") == 80))

        self.world.sensors["force_c_pressed"] = 0
        self.assertTrue(
            self.pump_until(lambda: self.world.last("motor_e") == -80),
            "The motor never reversed after the force sensor was released.",
        )


class SafetyTests(SpikeScriptTestCase):
    def test_the_script_stops_the_motor_when_the_host_goes_silent(self) -> None:
        self.connect(ScriptedEngine([0.9, 0.1]))
        self.assertTrue(self.pump_until(lambda: self.world.last("motor_e") == 80))

        # Stop answering. Only the script's own watchdog can save it now.
        self.bridge.transport.close()
        deadline = time.monotonic() + DEADLINE_S
        while time.monotonic() < deadline:
            if self.world.last("motor_e") == 0:
                break
            time.sleep(0.01)
        self.assertEqual(
            self.world.last("motor_e"), 0,
            "The SPIKE hub held its last motor command after the computer went quiet.",
        )

    def test_nothing_is_driven_before_the_host_answers(self) -> None:
        self.runner.start()
        time.sleep(0.4)
        self.assertIsNone(self.world.last("motor_e"))
        self.assertEqual(self.world.last("hub_light"), "YELLOW")

    def test_a_damaged_command_is_ignored(self) -> None:
        self.connect(ScriptedEngine([0.9, 0.1]))
        self.assertTrue(self.pump_until(lambda: self.world.last("motor_e") == 80))
        self.pipe.host_write(b"A,50,-80,1,0000\n")
        time.sleep(0.2)
        self.assertEqual(self.world.last("motor_e"), 80)

    def test_a_stop_command_shuts_the_hub_light_off(self) -> None:
        self.connect(ScriptedEngine([0.9, 0.1]))
        self.assertTrue(self.pump_until(lambda: self.world.last("motor_e") == 80))
        self.bridge.stop()
        self.assertTrue(
            self.runner.wait_until(lambda: self.world.last("hub_light") is None),
            "The hub light stayed on after a clean shutdown.",
        )
        self.assertEqual(self.world.last("motor_e"), 0)


if __name__ == "__main__":
    unittest.main()
