"""The drive loop: sensors -> rays -> model -> drive conversion -> motors.

Run against the Dummy and against the fake EV3 brick, on a fake clock. The
order of a tick and its 20 Hz pacing are the prototype's
(``run_real_model_drive.py``); the safety rule is that any failure, Stop or
emergency stop leaves the motors stopped.
"""

from __future__ import annotations

import json
import shutil
import tempfile
import unittest
from pathlib import Path

from fake_ev3 import FakeBrick, FakeClock, FakePortFactory
from support import ScriptedEngine, dummy_drive_config, dummy_robot

from neuralese_local.robot.config import compile_config
from neuralese_local.robot.drivers.dummy import DummyDriver, DummyWorld
from neuralese_local.robot.drivers.ev3_direct import Ev3DirectDriver, Ev3Error, Ev3Link
from neuralese_local.robot.drivers.replay import ReplayDriver
from neuralese_local.robot.runtime import MIN_SLEEP_S, TICK_S, DataLog, DriveLoop, hold_motor, live_robot


def ev3(clock=None):
    clock = clock or FakeClock()
    ports = FakePortFactory(clock)
    brick = FakeBrick()
    ports.ports["COM8"] = brick
    link = Ev3Link("COM8", serial_factory=ports, clock=clock, sleep=clock.sleep)
    driver = Ev3DirectDriver("COM8", mac="00:16:53:4E:DB:AB", link=link)
    driver.open(clock())
    return driver, brick, clock, ports


def ev3_config(driver):
    robot = live_robot(driver.inventory().to_dict(), dummy_robot())
    config = dummy_drive_config(robot=robot)
    config.update(platform="ev3_direct", transport={"kind": "bluetooth"})
    return config


class TickTests(unittest.TestCase):
    def test_one_tick_on_the_ev3_is_one_sonar_round_trip_and_one_motor_command(self) -> None:
        driver, brick, clock, _ = ev3()
        engine = ScriptedEngine([0.0, 1.0])
        loop = DriveLoop(driver, compile_config(ev3_config(driver)), engine, clock=clock)
        loop.start()
        before = len(brick.commands)
        clock.now += 0.05
        record = loop.tick()
        sent = brick.commands[before:]
        self.assertEqual(len(sent), 2)                     # batch read + both motors in one command
        self.assertEqual(record["readings"], {"in4.distance_mm": 600, "in3.distance_mm": 455, "in2.distance_mm": 300})
        self.assertEqual(len(engine.calls[0]), 8)          # eight rays from three sonars
        self.assertAlmostEqual(engine.calls[0][0], 1.0)
        self.assertAlmostEqual(engine.calls[0][7], 0.5)
        self.assertEqual(brick.motor_log[-2:], [("time_power", 0x08, 13, 300), ("time_power", 0x02, 13, 300)])
        self.assertEqual(record["drive"][0]["status"], "forward")

    def test_pacing_is_the_prototypes(self) -> None:
        driver = DummyDriver(world=DummyWorld(start=(0, 0, 0)))
        driver.open(0.0)
        clock = FakeClock(0.0)
        loop = DriveLoop(driver, compile_config(dummy_drive_config()), ScriptedEngine([0.0, 0.5]), clock=clock)
        slept = []
        loop.sleep_after_tick(0.0, slept.append)                 # instant tick: sleep the rest of 50 ms
        clock.now = 0.045
        loop.sleep_after_tick(0.0, slept.append)                 # slow tick: never less than 10 ms
        self.assertEqual(slept, [TICK_S, MIN_SLEEP_S])

    def test_run_drives_until_asked_to_stop_and_stops_the_motors(self) -> None:
        driver = DummyDriver(world=DummyWorld(start=(0, 0, 0)))
        clock = FakeClock(0.0)
        driver.open(clock())
        loop = DriveLoop(driver, compile_config(dummy_drive_config()), ScriptedEngine([0.0, 1.0]), clock=clock)
        loop.run(should_stop=lambda: loop.step >= 40, sleep=clock.sleep)
        self.assertEqual(loop.step, 40)
        self.assertGreater(driver.pose()["x_cm"], 30.0)
        self.assertEqual(driver.read(["outD.power", "outB.power"], clock()), [0, 0])
        self.assertFalse(loop.running)

    def test_time_limit(self) -> None:
        driver = DummyDriver(world=DummyWorld(start=(0, 0, 0)))
        clock = FakeClock(0.0)
        driver.open(clock())
        loop = DriveLoop(driver, compile_config(dummy_drive_config()), ScriptedEngine([0.0, 1.0]), clock=clock)
        loop.run(should_stop=lambda: False, max_seconds=1.0, sleep=clock.sleep)
        self.assertEqual(loop.step, 20)


class FailureTests(unittest.TestCase):
    def test_a_failing_model_stops_the_motors(self) -> None:
        driver, brick, clock, _ = ev3()
        engine = ScriptedEngine([0.0, 1.0])
        loop = DriveLoop(driver, compile_config(ev3_config(driver)), engine, clock=clock)
        loop.start()
        for _ in range(10):
            clock.now += 0.05
            loop.tick()
        engine.raises = RuntimeError("model crashed")
        clock.now += 0.05
        with self.assertRaises(RuntimeError):
            loop.tick()
        self.assertEqual(brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        self.assertFalse(loop.running)

    def test_a_lost_link_stops_the_motors_and_says_so(self) -> None:
        driver, brick, clock, ports = ev3()
        loop = DriveLoop(driver, compile_config(ev3_config(driver)), ScriptedEngine([0.0, 1.0]), clock=clock)
        loop.start()
        clock.now += 0.05
        loop.tick()
        ports.opened[-1].silent = True
        with self.assertRaises(Ev3Error) as caught:
            for _ in range(200):
                clock.now += 0.05
                loop.tick()
        self.assertEqual(caught.exception.code, "LINK_LOST")
        self.assertEqual(brick.motor_log[-1], ("stop", 0x0F, 0, 0))

    def test_halt_never_raises(self) -> None:
        driver, _, clock, ports = ev3()
        loop = DriveLoop(driver, compile_config(ev3_config(driver)), ScriptedEngine([0.0, 1.0]), clock=clock)
        loop.start()
        ports.opened[-1].fail_writes = True
        loop.halt()


class DataLogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.dir = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.dir, ignore_errors=True)

    def test_every_tick_is_logged_and_the_run_replays(self) -> None:
        driver, _, clock, _ = ev3()
        config = ev3_config(driver)
        log = DataLog(self.dir / "run.jsonl", {"robot": config["robot"], "config": config})
        loop = DriveLoop(driver, compile_config(config), ScriptedEngine([0.2, 0.8]), clock=clock, datalog=log)
        loop.start()
        for _ in range(30):
            clock.now += 0.05
            loop.tick()
        loop.halt()
        lines = [json.loads(line) for line in (self.dir / "run.jsonl").read_text(encoding="utf-8").splitlines()]
        self.assertEqual(lines[0]["_record_type"], "session_header")
        self.assertEqual(lines[0]["format"], "neuralese_robot_datalog")
        self.assertEqual(len(lines), 31)
        self.assertEqual(lines[5]["step"], 4)
        self.assertEqual(sorted(lines[5]), ["drive", "dt_ms", "model_input", "model_output", "motors", "readings",
                                            "step", "timestamp_s"])
        # The recording plays back as a robot.
        replay = ReplayDriver(self.dir / "run.jsonl", loop=False)
        robot = replay.inventory()
        self.assertEqual(robot.transport, "replay")
        self.assertEqual(robot.port("in2").device, "ultrasonic")
        replay.open(0.0)
        self.assertEqual(replay.read(["in4.distance_mm", "in3.distance_mm", "in2.distance_mm"], 0.5), [600, 455, 300])


class HoldMotorTests(unittest.TestCase):
    def test_one_wheel_turns_then_stops(self) -> None:
        driver, brick, clock, _ = ev3()
        start = clock()
        hold_motor(driver, "outB.power", 35, 1.0, clock=clock, sleep=clock.sleep)
        sent = [(t, entry) for t, entry in zip(brick.motor_times, brick.motor_log) if entry[1] == 0x02]
        self.assertEqual(sent[0][1][:3], ("time_power", 0x02, 35))
        self.assertEqual(sent[-1][1][:3], ("stop", 0x02, 0))
        # Each command lasts 300 ms; they come often enough that the wheel
        # never stops during the second, and it stops right after.
        times = [start] + [t for t, entry in sent]
        self.assertLess(max(b - a for a, b in zip(times, times[1:])), 0.3)
        self.assertAlmostEqual(sent[-1][0] - start, 1.0, delta=0.06)
        self.assertFalse(any(mask & 0x08 for _, mask, _, _ in brick.motor_log))   # D never moved


if __name__ == "__main__":
    unittest.main()
