"""EV3 over Bluetooth with direct commands, against a fake brick.

The driver is a port of the prototype's ``robots/ev3_robot.py``, whose rules
each came from a failure on the real EV3 "KIRISIMA". Each rule has a test here
that reproduces the failure on the fake brick (``fake_ev3.py``), so a later
"simplification" that drops one fails loudly. What this cannot show is how a
real Windows Bluetooth stack and brick time out; that needs the robot.
"""

from __future__ import annotations

import struct
import threading
import unittest

from fake_ev3 import FakeBrick, FakeClock, FakePortFactory
from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot.drivers import ev3_direct
from neuralese_local.robot.drivers.ev3_direct import (
    EMERGENCY_STOP_FRAME,
    Ev3DirectDriver,
    Ev3Error,
    Ev3Link,
    classify_open_error,
    lc,
)
from neuralese_local.robot.ir import validate_ir


def make(com: str = "COM8", **brick_kwargs):
    clock = FakeClock()
    ports = FakePortFactory(clock)
    brick = FakeBrick(**brick_kwargs)
    ports.ports[com] = brick
    link = Ev3Link(com, serial_factory=ports, clock=clock, sleep=clock.sleep)
    return link, brick, ports, clock


class EncodingTests(unittest.TestCase):
    def test_lc_parameters(self) -> None:
        self.assertEqual(lc(5), b"\x05")
        self.assertEqual(lc(-1), b"\x3f")
        self.assertEqual(lc(100), b"\x81\x64")
        self.assertEqual(lc(-100), b"\x81\x9c")
        self.assertEqual(lc(300), b"\x82\x2c\x01")
        self.assertEqual(lc(70000), b"\x83" + struct.pack("<i", 70000))

    def test_motor_commands_are_timed(self) -> None:
        # opOUTPUT_TIME_POWER on B at 50 % for 300 ms with brake; 0 is a braked stop.
        self.assertEqual(Ev3Link.motor_bytecode("B", 50), bytes([0xAD, 0x00, 0x02, 0x81, 50, 0x00, 0x82, 0x2C, 0x01, 0x00, 0x01]))
        self.assertEqual(Ev3Link.motor_bytecode("D", 0), bytes([0xA3, 0x00, 0x08, 0x01]))

    def test_emergency_stop_frame(self) -> None:
        self.assertEqual(EMERGENCY_STOP_FRAME, bytes([9, 0, 0, 0, 0x80, 0, 0, 0xA3, 0x00, 0x0F, 0x01]))


class ConnectTests(unittest.TestCase):
    def test_connects_and_identifies_the_brick(self) -> None:
        link, brick, _, _ = make()
        link.connect()
        self.assertTrue(link.is_open)
        self.assertEqual(link.brick_name, "KIRISIMA")
        self.assertEqual(link.battery_pct, 87)
        self.assertEqual(link.warnings, [])
        self.assertEqual(brick.beeps, [(40, 1200, 150)])   # "I'm connected"

    def test_low_battery_and_missing_motors_are_warned(self) -> None:
        link, brick, _, _ = make(battery=12)
        brick.types.update({17: 126, 19: 126})
        link.connect()
        self.assertEqual(link.warnings, ["low_battery", "no_motors"])
        link2, brick2, _, _ = make()
        brick2.types[19] = 126
        link2.connect()
        self.assertEqual(link2.warnings, ["one_motor"])

    def test_a_silent_brick_is_no_reply_after_two_attempts(self) -> None:
        link, _, ports, _ = make()
        original = ports.__call__

        def silent_port(com):
            ser = original(com)
            ser.silent = True
            return ser

        link.serial_factory = silent_port
        with self.assertRaises(Ev3Error) as caught:
            link.connect()
        self.assertEqual(caught.exception.code, "NO_REPLY")
        self.assertEqual(len(ports.opened), 2)   # NO_REPLY is worth one retry
        self.assertFalse(link.is_open)

    def test_missing_and_busy_ports_are_not_retried(self) -> None:
        for error, code in ((OSError("could not open port 'COM9': FileNotFoundError(2, 'x')"), "PORT_MISSING"),
                            (OSError("could not open port 'COM8': PermissionError(13, 'Access is denied.')"), "PORT_BUSY")):
            with self.subTest(code=code):
                link, _, ports, _ = make()
                ports.errors["COM8"] = error
                with self.assertRaises(Ev3Error) as caught:
                    link.connect()
                self.assertEqual(caught.exception.code, code)
                self.assertEqual(len(ports.open_calls), 1)

    def test_windows_errors_mean_the_robot_is_off_or_far(self) -> None:
        for text in ("could not open port 'COM8': OSError(22, 'The semaphore timeout period has expired.', None, 121)",
                     "could not open port 'COM8': OSError(22, 'Удаленная система недоступна.', None, 1231)",
                     "(1167) The device is not connected."):
            self.assertEqual(classify_open_error("COM8", OSError(text)).code, "OPEN_TIMEOUT", text)
        self.assertEqual(classify_open_error("COM8", OSError("weird")).code, "OPEN_FAILED")

    def test_every_error_has_child_texts_in_all_three_languages(self) -> None:
        for code in ev3_direct.ERROR_TEXTS:
            texts = ev3_direct.ev3_error(code).to_dict()["texts"]
            self.assertEqual(sorted(texts), ["en", "kz", "ru"], code)
            self.assertTrue(all(t["message"] and t["fix"] for t in texts.values()), code)


class HungOpenTests(unittest.TestCase):
    def setUp(self) -> None:
        self.saved = (ev3_direct.OPEN_DEADLINE_S, ev3_direct.PENDING_WAIT_S)
        ev3_direct.OPEN_DEADLINE_S = 0.2
        ev3_direct.PENDING_WAIT_S = 0.3
        self.addCleanup(self._restore)

    def _restore(self) -> None:
        ev3_direct.OPEN_DEADLINE_S, ev3_direct.PENDING_WAIT_S = self.saved
        ev3_direct._PENDING_OPENS.clear()

    def test_a_hanging_open_times_out_without_a_retry(self) -> None:
        # A retry would only wait for the hung open to let go; the child is
        # told at once that the robot does not answer.
        link, _, ports, _ = make()
        sleeps = []
        link.sleep = sleeps.append
        gate = threading.Event()
        ports.hang["COM8"] = gate
        with self.assertRaises(Ev3Error) as caught:
            link.connect()
        self.assertEqual(caught.exception.code, "OPEN_TIMEOUT")
        self.assertEqual(len(ports.open_calls), 1)
        self.assertEqual(sleeps, [])
        gate.set()

    def test_the_next_attempt_waits_for_the_abandoned_one(self) -> None:
        # The abandoned open still holds the port; opening again at once would
        # be refused by Windows -- because of ourselves.
        link, _, ports, _ = make()
        gate = threading.Event()
        ports.hang["COM8"] = gate
        with self.assertRaises(Ev3Error):
            link.connect()
        # Still hanging: the next attempt waits, then gives up without opening again.
        with self.assertRaises(Ev3Error) as caught:
            link.connect()
        self.assertEqual(caught.exception.code, "OPEN_TIMEOUT")
        self.assertEqual(len(ports.open_calls), 1)
        # Windows finally lets go: the abandoned port is closed, not leaked, and
        # the next attempt connects.
        gate.set()
        ev3_direct._PENDING_OPENS["COM8"].join(1.0)
        self.assertTrue(all(s.closed for s in ports.opened))
        del ports.hang["COM8"]
        link.connect()
        self.assertTrue(link.is_open)


class ExchangeTests(unittest.TestCase):
    def test_a_late_reply_is_not_taken_for_the_current_one(self) -> None:
        link, brick, ports, _ = make()
        link.connect()
        ser = ports.opened[-1]
        # A reply to an old command (number 1) arrives just before the real one.
        ser.late_replies.append(struct.pack("<H", 4) + struct.pack("<HB", 1, 0x02) + bytes([5]))
        brick.battery = 64
        self.assertEqual(link.query_battery_percent(), 64)

    def test_garbage_is_flushed_and_the_reply_counts_as_missing(self) -> None:
        link, _, ports, clock = make()
        link.connect()
        ports.opened[-1].garbage_next = True
        t0 = clock()
        self.assertIsNone(link.query_battery_percent())
        # Recognised as garbage at once, not waited on for a 2000-byte reply.
        self.assertLess(clock() - t0, 0.5)
        self.assertEqual(ports.opened[-1].rx, bytearray())
        self.assertEqual(link.query_battery_percent(), 87)   # the stream recovered

    def test_an_error_reply_is_none(self) -> None:
        link, _, ports, _ = make()
        link.connect()
        ser = ports.opened[-1]
        original = ser.write

        def error_reply(data):
            n = original(data)
            raw = bytes(ser.rx)
            ser.rx.clear()
            ser.rx += raw[:4] + bytes([0x04]) + raw[5:]      # DIRECT_REPLY_ERROR
            return n

        ser.write = error_reply
        self.assertIsNone(link.query_battery_percent())

    def test_queries(self) -> None:
        link, brick, _, _ = make()
        link.connect()
        self.assertAlmostEqual(link.query_battery_volts(), 7.9, places=5)
        self.assertEqual(link.query_firmware(), "V1.09H")
        self.assertEqual(link.query_hardware(), "V0.60")
        self.assertEqual(link.query_tacho("D"), -35)
        self.assertEqual(link.query_device_type(1), 30)
        self.assertAlmostEqual(link.query_ultrasonic_cm(3), 45.5, places=4)

    def test_three_sonars_in_one_round_trip(self) -> None:
        link, brick, _, _ = make()
        link.connect()
        before = len(brick.commands)
        self.assertEqual(link.query_ultrasonic_batch_cm([4, 3, 2]), {4: 60.0, 3: 45.5, 2: 30.0})
        self.assertEqual(len(brick.commands) - before, 1)

    def test_sonar_values_as_the_prototype_reads_them(self) -> None:
        link, brick, _, _ = make()
        link.connect()
        brick.distances_cm = {1: 300.0, 2: float("nan"), 3: -4.0}
        # Batch: over-range is 255, anything else invalid is 0 (prototype behaviour).
        self.assertEqual(link.query_ultrasonic_batch_cm([2, 3, 4]), {2: 255.0, 3: 0.0, 4: 0.0})
        # Single: over-range is 255, invalid is None.
        self.assertEqual(link.query_ultrasonic_cm(2), 255.0)
        self.assertIsNone(link.query_ultrasonic_cm(3))


class MotorTests(unittest.TestCase):
    def test_unchanged_power_is_only_resent_to_extend_the_lease(self) -> None:
        link, brick, _, clock = make()
        link.connect()
        link.set_motors({"D": 40, "B": 40})
        link.set_motors({"D": 40, "B": 40})           # same, too soon: nothing sent
        self.assertEqual(len(brick.motor_log), 2)
        clock.now += 0.11
        link.set_motors({"D": 40, "B": 40})           # lease refresh
        self.assertEqual(len(brick.motor_log), 4)
        link.set_motors({"D": 41, "B": 40})           # only the changed motor
        self.assertEqual(brick.motor_log[-1], ("time_power", 0x08, 41, 300))
        self.assertEqual(len(brick.motor_log), 5)

    def test_zero_is_a_braked_stop_sent_once(self) -> None:
        link, brick, _, clock = make()
        link.connect()
        link.set_motors({"B": 0})
        clock.now += 1.0
        link.set_motors({"B": 0})
        self.assertEqual(brick.motor_log, [("stop", 0x02, 0, 0)])

    def test_power_is_clamped(self) -> None:
        link, brick, _, _ = make()
        link.connect()
        link.set_motors({"B": 250, "D": -250})
        self.assertEqual([(p, ms) for _, _, p, ms in brick.motor_log], [(100, 300), (-100, 300)])

    def test_emergency_stop_reaches_every_motor_even_without_the_lock(self) -> None:
        link, brick, _, _ = make()
        link.connect()
        link.set_motors({"B": 60, "D": 60})
        link.emergency_stop()
        self.assertEqual(brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        # After a stop the same power is sent again at once, not after a lease refresh.
        link.set_motors({"B": 60, "D": 60})
        self.assertEqual(brick.motor_log[-1][0], "time_power")

    def test_emergency_stop_never_raises(self) -> None:
        link, _, ports, _ = make()
        link.connect()
        ports.opened[-1].fail_writes = True
        link.emergency_stop()


class LinkLossTests(unittest.TestCase):
    def test_heartbeat_once_a_second(self) -> None:
        link, brick, _, clock = make()
        link.connect()
        n = len(brick.commands)
        link.check_link()
        self.assertEqual(len(brick.commands), n)
        clock.now += 1.0
        link.check_link()
        self.assertEqual(len(brick.commands), n + 1)

    def test_silence_stops_the_motors_and_reports_link_lost(self) -> None:
        link, brick, ports, clock = make()
        link.connect()
        link.set_motors({"B": 50, "D": 50})
        ser = ports.opened[-1]
        ser.silent = True
        clock.now += 1.0
        link.check_link()                 # one missed beat is not yet a loss
        self.assertTrue(link.is_open)
        clock.now += 2.0
        with self.assertRaises(Ev3Error) as caught:
            link.check_link()
        self.assertEqual(caught.exception.code, "LINK_LOST")
        self.assertEqual(brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        self.assertFalse(link.is_open)

    def test_a_broken_port_is_link_lost(self) -> None:
        link, _, ports, _ = make()
        link.connect()
        ports.opened[-1].fail_writes = True
        with self.assertRaises(Ev3Error) as caught:
            link.set_motors({"B": 30})
        self.assertEqual(caught.exception.code, "LINK_LOST")
        self.assertFalse(link.is_open)

    def test_disconnect_stops_and_closes(self) -> None:
        link, brick, ports, _ = make()
        link.connect()
        link.disconnect()
        self.assertEqual(brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        self.assertTrue(ports.opened[-1].closed)
        link.disconnect()                 # twice is fine


class DriverTests(unittest.TestCase):
    def driver(self, **kwargs):
        link, brick, ports, clock = make()
        driver = Ev3DirectDriver("COM8", mac="00:16:53:4E:DB:AB", link=link, **kwargs)
        driver.open(clock())
        return driver, brick, clock

    def test_inventory_comes_from_the_brick(self) -> None:
        driver, _, _ = self.driver(proximity={"rssi_dbm": -62, "distance_m": 1.4})
        robot = driver.inventory().to_dict()
        self.assertTrue(validate_ir(robot).ok, validate_ir(robot).errors)
        self.assertEqual(robot["robot_id"], "ev3:00:16:53:4E:DB:AB")
        self.assertEqual(robot["platform"], "ev3_direct")
        self.assertEqual(robot["name"], "KIRISIMA")
        self.assertEqual(robot["status"], "connected")
        self.assertEqual(robot["battery_pct"], 87)
        self.assertEqual(robot["proximity"]["distance_m"], 1.4)
        devices = {p["id"]: p["device"] for p in robot["ports"]}
        self.assertEqual(devices, {"in1": "", "in2": "ultrasonic", "in3": "ultrasonic", "in4": "ultrasonic",
                                   "outA": "", "outB": "large_motor", "outC": "", "outD": "large_motor"})
        # Left and right are the user's to say; the driver never guesses them.
        self.assertIsNone(robot["geometry"]["drive"])

    def test_reads_sonars_and_encoders_in_one_round_trip(self) -> None:
        driver, brick, clock = self.driver()
        before = len(brick.commands)
        values = driver.read(["in4.distance_mm", "in3.distance_mm", "in2.distance_mm", "outD.position_deg"], clock())
        self.assertEqual(values, [600, 455, 300, -35])
        self.assertEqual(len(brick.commands) - before, 1)    # sonars and the encoder in one batch

    def test_writes_power_by_port(self) -> None:
        driver, brick, clock = self.driver()
        driver.write({"outD.power": 35, "outB.power": -20}, clock())
        self.assertEqual(brick.motor_log[-2:], [("time_power", 0x08, 35, 300), ("time_power", 0x02, -20, 300)])
        self.assertEqual(driver.read(["outD.power"], clock()), [35])
        with self.assertRaises(KeyError):
            driver.write({"in2.distance_mm": 1}, clock())

    def test_stop_and_close(self) -> None:
        driver, brick, clock = self.driver()
        driver.write({"outD.power": 35, "outB.power": 35}, clock())
        driver.stop(clock())
        self.assertEqual(brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        driver.close()
        self.assertEqual(driver.inventory().status, "available")

    def test_tick_is_the_heartbeat(self) -> None:
        driver, brick, clock = self.driver()
        driver.link.ser.silent = True
        clock.now += 3.0
        with self.assertRaises(Ev3Error) as caught:
            driver.tick(clock())   # the last reply is more than 2.5 s old
        self.assertEqual(caught.exception.code, "LINK_LOST")
        self.assertEqual(brick.motor_log[-1], ("stop", 0x0F, 0, 0))


if __name__ == "__main__":
    unittest.main()
