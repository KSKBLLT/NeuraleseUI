"""End-to-end EV3 test against the open-source ev3dev emulator.

This is the strongest coverage in the suite. Nothing is stubbed on the device
side: the *generated* device script runs, importing the *real* ``ev3dev2``
library, driving *real* sysfs attribute files in a fake device tree, over a
*real* TCP socket, answered by the real host bridge. When a test asserts that a
motor was told to run, it is reading the same file the motor driver would.

Skipped, loudly, when the emulator has not been fetched. See
``emulators/ev3_fake_sys.py`` for how to enable it.
"""

from __future__ import annotations

import socket
import threading
import time
import unittest

from support import ScriptedEngine  # noqa: F401  (puts the runtime on sys.path)

from emulators.ev3_fake_sys import Ev3Arena, EmulatorUnavailable
from neuralese_local.robot.bridge import STATE_RUNNING, STATE_STALLED, RobotBridge
from neuralese_local.robot.config import compile_config, linear_scale
from neuralese_local.robot.generate import generate_script_for_plan
from neuralese_local.robot.transport import TcpTransport

#: Emulator tests use real sockets and real threads, so they get real deadlines.
DEADLINE_S = 8.0

MOTOR_A = 0
MOTOR_B = 1
TOUCH_SENSOR = 0
INFRARED_SENSOR = 1


def robot_config(**overrides):
    base = {
        "schema_version": 1,
        "platform": "ev3",
        "transport": {"kind": "tcp", "host": "127.0.0.1", "port": 0},
        "rate_hz": 20,
        "watchdog_ms": 400,
        "inputs": [
            {"channel": "touch_1"},
            {"channel": "infrared_4", "scale": linear_scale(0, 100, 0.0, 1.0)},
        ],
        "outputs": [
            {"channel": "motor_a_speed", "mode": "argmax", "classes": {"0": 75, "1": -75}},
            {"channel": "motor_b_speed", "mode": "argmax", "classes": {"0": -75, "1": 75}},
        ],
    }
    base.update(overrides)
    return base


class EmulatedEv3:
    """Runs a generated device script inside the emulator, on a real socket."""

    def __init__(self, arena: Ev3Arena, script_source: str) -> None:
        self.arena = arena
        self.namespace = {"__name__": "neuralese_generated_ev3"}
        # Executing the script is the point: module-level code constructs the
        # LargeMotor and sensor objects exactly as it would on a brick.
        exec(compile(script_source, "<generated ev3 script>", "exec"), self.namespace)

        self.server = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.server.bind(("127.0.0.1", 0))
        self.server.listen(1)
        self.port = self.server.getsockname()[1]
        self.thread: threading.Thread = None  # type: ignore[assignment]
        self.error: BaseException = None  # type: ignore[assignment]
        self._connection = None

    def start(self) -> None:
        def serve() -> None:
            try:
                self._connection, _ = self.server.accept()
                self.namespace["serve_one_session"](self._connection)
            except BaseException as exc:  # noqa: BLE001 - reported to the test
                self.error = exc

        self.thread = threading.Thread(target=serve, name="emulated-ev3", daemon=True)
        self.thread.start()

    def stop(self) -> None:
        for closeable in (self._connection, self.server):
            try:
                if closeable is not None:
                    closeable.close()
            except Exception:
                pass
        if self.thread is not None:
            self.thread.join(timeout=2.0)

    def safe_stop(self) -> None:
        self.namespace["safe_stop"]()


class Ev3EmulatorTestCase(unittest.TestCase):
    """Shared setup: emulator up, script generated, link established."""

    @classmethod
    def setUpClass(cls) -> None:
        try:
            cls.arena = Ev3Arena()
            cls.arena.start()
        except EmulatorUnavailable as exc:
            raise unittest.SkipTest(str(exc))
        except ImportError as exc:
            raise unittest.SkipTest("EV3 emulator could not be imported: %s" % exc)

    @classmethod
    def tearDownClass(cls) -> None:
        if getattr(cls, "arena", None) is not None:
            cls.arena.stop()

    def setUp(self) -> None:
        self.arena.set_sensor_value(TOUCH_SENSOR, 0)
        self.arena.set_sensor_value(INFRARED_SENSOR, 0)
        self.config = robot_config()
        self.plan = compile_config(self.config)
        self.device = EmulatedEv3(self.arena, generate_script_for_plan(self.plan))
        self.device.start()
        self.addCleanup(self.device.stop)
        self.bridge = None

    def connect(self, engine=None, **kwargs) -> RobotBridge:
        transport = TcpTransport("127.0.0.1", self.device.port)
        self.bridge = RobotBridge(
            self.plan,
            engine or ScriptedEngine([1.0, 0.0]),
            transport,
            **kwargs,
        )
        self.bridge.start()
        self.addCleanup(self.bridge.stop)
        self.assertTrue(
            self.pump_until(lambda: self.bridge.state == STATE_RUNNING),
            "The emulated EV3 never completed the handshake. Device error: %r" % (self.device.error,),
        )
        return self.bridge

    def pump_until(self, predicate, timeout: float = DEADLINE_S) -> bool:
        """Drive the host loop until the condition holds or time runs out."""
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return True
            self.bridge.poll()
            time.sleep(0.002)
        return bool(predicate())


class HandshakeTests(Ev3EmulatorTestCase):
    def test_the_generated_script_connects_and_is_accepted(self) -> None:
        bridge = self.connect()
        self.assertEqual(bridge.robot_info["platform"], "ev3")
        self.assertEqual(bridge.robot_info["n_in"], 2)
        self.assertEqual(bridge.robot_info["n_out"], 2)

    def test_the_script_reports_the_fingerprint_the_host_expects(self) -> None:
        # This is the check that catches "the child changed the mapping but did
        # not copy the new program onto the brick".
        bridge = self.connect()
        self.assertEqual(bridge.robot_info["cfg_hash"], bridge.expected_config_hash)


class ControlLoopTests(Ev3EmulatorTestCase):
    def test_a_prediction_really_drives_the_motors(self) -> None:
        self.connect(ScriptedEngine([1.0, 0.0]))
        self.assertTrue(self.pump_until(lambda: self.bridge.stats["frames_answered"] > 0))

        # Read the sysfs files the motor driver itself would read.
        self.assertTrue(self.pump_until(
            lambda: self.arena.motor_command(MOTOR_A) == "run-forever"))
        self.assertEqual(self.arena.motor_command(MOTOR_B), "run-forever")

        # 75% of the emulated motor's max speed, and B mirrors A.
        max_speed = int(self.arena._read(self.arena.motor_path(MOTOR_A) / "max_speed"))
        self.assertEqual(self.arena.motor_speed_sp(MOTOR_A), int(75 * max_speed / 100))
        self.assertEqual(self.arena.motor_speed_sp(MOTOR_B), int(-75 * max_speed / 100))

    def test_the_model_sees_what_the_emulated_sensors_report(self) -> None:
        engine = ScriptedEngine([1.0, 0.0])
        self.arena.set_sensor_value(TOUCH_SENSOR, 1)
        self.arena.set_sensor_value(INFRARED_SENSOR, 50)
        self.connect(engine)
        self.assertTrue(self.pump_until(lambda: len(engine.calls) > 2))

        # Touch is boolean and passes through; infrared is scaled 0..100 -> 0..1.
        reading = engine.calls[-1]
        self.assertEqual(reading[0], 1.0)
        self.assertAlmostEqual(reading[1], 0.5, places=3)

    def test_changing_the_world_changes_the_motors(self) -> None:
        # The whole loop, end to end: a sensor moves, the model's answer changes,
        # and the motors follow.
        engine = ScriptedEngine(lambda values: [1.0, 0.0] if values[0] else [0.0, 1.0])
        self.arena.set_sensor_value(TOUCH_SENSOR, 1)
        self.connect(engine)
        self.assertTrue(self.pump_until(lambda: self.arena.motor_speed_sp(MOTOR_A) > 0))

        self.arena.set_sensor_value(TOUCH_SENSOR, 0)
        self.assertTrue(
            self.pump_until(lambda: self.arena.motor_speed_sp(MOTOR_A) < 0),
            "The motor never reversed after the touch sensor was released.",
        )

    def test_a_stop_prediction_stops_the_motor_rather_than_reversing_it(self) -> None:
        config = robot_config(outputs=[
            {"channel": "motor_a_speed", "mode": "argmax", "classes": {"0": 0, "1": 60}},
            {"channel": "motor_b_speed", "mode": "argmax", "classes": {"0": 0, "1": 60}},
        ])
        self.plan = compile_config(config)
        self.device.stop()
        self.device = EmulatedEv3(self.arena, generate_script_for_plan(self.plan))
        self.device.start()
        self.addCleanup(self.device.stop)

        self.connect(ScriptedEngine([1.0, 0.0]))
        self.assertTrue(self.pump_until(lambda: self.arena.motor_command(MOTOR_A) == "stop"))


class MotorCommandCacheTests(Ev3EmulatorTestCase):
    """The generated script skips repeating an unchanged motor command, because
    each one is a real sysfs write on a 300 MHz brick. The cache must not be
    able to swallow a stop."""

    class FlakyMotor:
        max_speed = 1000

        def __init__(self, fail_stops: int = 0) -> None:
            self.commands = []
            self._fail_stops = fail_stops

        def stop(self):
            if self._fail_stops > 0:
                self._fail_stops -= 1
                raise OSError("sysfs write failed")
            self.commands.append("stop")

        def run_forever(self, speed_sp=0):
            self.commands.append(speed_sp)

    def test_an_unchanged_command_is_not_rewritten(self) -> None:
        drive = self.device.namespace["_drive_motor"]
        motor = self.FlakyMotor()
        drive(motor, 50)
        drive(motor, 50)
        self.assertEqual(motor.commands, [500])

    def test_a_stop_that_failed_is_retried_rather_than_remembered(self) -> None:
        # If the command were cached before the write, a raising stop() would
        # leave the script believing the motor had stopped. The next safe_stop()
        # would return early and the motor would keep running -- the exact
        # opposite of what safe_stop exists to guarantee.
        drive = self.device.namespace["_drive_motor"]
        motor = self.FlakyMotor(fail_stops=1)
        drive(motor, 50)
        with self.assertRaises(OSError):
            drive(motor, 0)
        drive(motor, 0)
        self.assertEqual(motor.commands, [500, "stop"])


class SafetyTests(Ev3EmulatorTestCase):
    def test_the_robot_stops_itself_when_the_host_goes_away(self) -> None:
        # The rule that matters most: the child unplugs the laptop, or Neuralese
        # is closed, and the robot must not keep driving.
        self.connect(ScriptedEngine([1.0, 0.0]))
        self.assertTrue(self.pump_until(lambda: self.arena.motor_speed_sp(MOTOR_A) != 0))

        # Stop answering, but leave the socket open, so only the device-side
        # watchdog can save it.
        self.bridge.transport.close()

        deadline = time.monotonic() + DEADLINE_S
        while time.monotonic() < deadline:
            if self.arena.motor_command(MOTOR_A) == "stop":
                break
            time.sleep(0.02)
        self.assertEqual(
            self.arena.motor_command(MOTOR_A), "stop",
            "The EV3 kept its last motor command after the host went silent.",
        )

    def test_the_host_reports_the_link_as_stalled_when_the_robot_goes_quiet(self) -> None:
        self.connect(ScriptedEngine([1.0, 0.0]))
        self.assertTrue(self.pump_until(lambda: self.bridge.stats["frames_answered"] > 0))
        self.device.stop()
        self.assertTrue(
            self.pump_until(lambda: self.bridge.state in (STATE_STALLED, "error")),
            "The host never noticed the robot had gone.",
        )

    def test_a_clean_shutdown_stops_the_motors(self) -> None:
        self.connect(ScriptedEngine([1.0, 0.0]))
        self.assertTrue(self.pump_until(lambda: self.arena.motor_speed_sp(MOTOR_A) != 0))
        self.bridge.stop()
        deadline = time.monotonic() + DEADLINE_S
        while time.monotonic() < deadline:
            if self.arena.motor_command(MOTOR_A) == "stop":
                break
            time.sleep(0.02)
        self.assertEqual(self.arena.motor_command(MOTOR_A), "stop")


if __name__ == "__main__":
    unittest.main()
