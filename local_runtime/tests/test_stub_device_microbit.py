"""micro:bit: the generated script run against stubbed device modules.

NOT an emulator -- see ``emulators/device_stubs.py`` for why one is not used and
what this does and does not prove. The generated script itself is genuinely
executed and genuinely talks the protocol to the real host bridge; the hardware
underneath it is a stub.
"""

from __future__ import annotations

import time
import unittest

from support import ScriptedEngine  # noqa: F401  (puts the runtime on sys.path)

from emulators.device_stubs import BytePipe, DeviceWorld, build_microbit_module
from emulators.stub_runner import StubDeviceRunner
from neuralese_local.robot.bridge import STATE_RUNNING, RobotBridge
from neuralese_local.robot.config import compile_config, linear_scale
from neuralese_local.robot.generate import generate_script_for_plan

DEADLINE_S = 6.0


def microbit_config(**overrides):
    base = {
        "schema_version": 1,
        "platform": "microbit",
        "transport": {"kind": "serial", "port": "", "baud": 115200},
        "rate_hz": 20,
        "watchdog_ms": 300,
        "inputs": [
            {"channel": "accel_x", "scale": linear_scale(-2048, 2048, -1.0, 1.0)},
            {"channel": "button_a"},
        ],
        "outputs": [
            {"channel": "pin0_analog", "mode": "argmax", "classes": {"0": 1023, "1": 0}},
            {"channel": "display_digit", "mode": "argmax", "classes": {"0": 1, "1": 2}},
        ],
    }
    base.update(overrides)
    return base


class MicrobitScriptTestCase(unittest.TestCase):
    def setUp(self) -> None:
        self.config = microbit_config()
        self.plan = compile_config(self.config)
        self.world = DeviceWorld()
        self.pipe = BytePipe()
        self.runner = StubDeviceRunner(
            generate_script_for_plan(self.plan),
            {"microbit": build_microbit_module(self.world, self.pipe)},
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
            "The micro:bit script never completed the handshake. Error: %r" % (self.runner.error,),
        )
        return self.bridge

    def pump_until(self, predicate, timeout: float = DEADLINE_S) -> bool:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            if self.runner.error is not None:
                raise AssertionError("The micro:bit script crashed: %r" % (self.runner.error,))
            self.bridge.poll()
            time.sleep(0.002)
        return bool(predicate())


class HandshakeTests(MicrobitScriptTestCase):
    def test_the_script_announces_itself_correctly(self) -> None:
        bridge = self.connect()
        self.assertEqual(bridge.robot_info["platform"], "microbit")
        self.assertEqual(bridge.robot_info["n_in"], 2)
        self.assertEqual(bridge.robot_info["n_out"], 2)
        self.assertEqual(bridge.robot_info["cfg_hash"], bridge.expected_config_hash)

    def test_the_serial_port_is_opened_at_the_configured_speed(self) -> None:
        self.connect()
        self.assertEqual(self.world.last("uart_init"), 115200)


class ControlLoopTests(MicrobitScriptTestCase):
    def test_sensor_readings_reach_the_model_scaled(self) -> None:
        engine = ScriptedEngine([1.0, 0.0])
        self.world.sensors["accel_x"] = 1024
        self.world.sensors["button_a"] = 1
        self.connect(engine)
        self.assertTrue(self.pump_until(lambda: len(engine.calls) > 1))
        reading = engine.calls[-1]
        self.assertAlmostEqual(reading[0], 0.5, places=3)
        self.assertEqual(reading[1], 1.0)

    def test_a_prediction_drives_the_pin_and_the_display(self) -> None:
        self.connect(ScriptedEngine([0.9, 0.1]))
        self.assertTrue(self.pump_until(lambda: self.world.last("pin0_analog") == 1023))
        self.assertEqual(self.world.last("display"), 1)

    def test_changing_the_world_changes_the_output(self) -> None:
        engine = ScriptedEngine(lambda values: [1.0, 0.0] if values[1] else [0.0, 1.0])
        self.world.sensors["button_a"] = 1
        self.connect(engine)
        self.assertTrue(self.pump_until(lambda: self.world.last("pin0_analog") == 1023))

        self.world.sensors["button_a"] = 0
        self.assertTrue(
            self.pump_until(lambda: self.world.last("pin0_analog") == 0),
            "The pin never followed the button being released.",
        )


class SafetyTests(MicrobitScriptTestCase):
    def test_the_script_stops_the_pin_when_the_host_goes_silent(self) -> None:
        self.connect(ScriptedEngine([0.9, 0.1]))
        self.assertTrue(self.pump_until(lambda: self.world.last("pin0_analog") == 1023))

        # Stop answering. Only the script's own watchdog can save it now.
        self.bridge.transport.close()
        deadline = time.monotonic() + DEADLINE_S
        while time.monotonic() < deadline:
            if self.world.last("pin0_analog") == 0:
                break
            time.sleep(0.01)
        self.assertEqual(
            self.world.last("pin0_analog"), 0,
            "The micro:bit held its last output after the computer went quiet.",
        )

    def test_nothing_is_driven_before_the_host_answers(self) -> None:
        # The script must sit still saying hello, not act on an unconfirmed link.
        self.runner.start()
        time.sleep(0.4)
        self.assertIsNone(self.world.last("pin0_analog"))
        # The display is showing the "waiting to connect" arrow rather than one
        # of the digits a prediction would put there, so the child can see the
        # micro:bit is alive and waiting rather than broken.
        self.assertEqual(self.world.last("display"), "ARROW_E")

    def test_the_script_re_announces_itself_so_a_new_host_can_reconnect(self) -> None:
        # The host refuses to act on readings from a robot it has not agreed a
        # mapping with. That is only safe because a robot whose host went away
        # starts saying hello again -- otherwise "Disconnect, then Connect"
        # would hang forever on a device that had already been accepted once.
        self.connect(ScriptedEngine([0.9, 0.1]))
        self.assertTrue(self.pump_until(lambda: self.world.last("pin0_analog") == 1023))

        first = self.bridge
        first.transport.close()
        # Let the device's watchdog trip and start re-announcing.
        time.sleep(0.6)

        self.bridge = RobotBridge(self.plan, ScriptedEngine([0.1, 0.9]), self.runner.transport())
        self.bridge.start()
        self.addCleanup(self.bridge.stop)
        self.assertTrue(
            self.pump_until(lambda: self.bridge.state == STATE_RUNNING),
            "A reconnecting host never saw a fresh hello from the micro:bit.",
        )
        self.assertTrue(self.pump_until(lambda: self.world.last("pin0_analog") == 0))

    def test_a_damaged_command_is_ignored(self) -> None:
        self.connect(ScriptedEngine([0.9, 0.1]))
        self.assertTrue(self.pump_until(lambda: self.world.last("pin0_analog") == 1023))
        commands_before = len(self.world.commands)

        # A frame whose checksum does not match must never reach a pin.
        self.pipe.host_write(b"A,50,0,2,0000\n")
        time.sleep(0.2)
        self.assertEqual(self.world.last("pin0_analog"), 1023)
        self.assertEqual(len(self.world.commands), commands_before)


if __name__ == "__main__":
    unittest.main()
