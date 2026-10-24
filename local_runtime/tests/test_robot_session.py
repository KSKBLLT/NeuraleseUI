"""The robot session Godot keeps open: commands, events, stopping.

Two levels. :class:`RobotSession` is driven directly with fakes (a scripted
discovery and connection, the fake EV3 brick, the Dummy) to pin every command
and every way a drive ends. Then the real process is started the way Godot
will start it, and driven only through its files (request, response,
progress, status, estop), with the Dummy and the prototype's model.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

from fake_ev3 import FakeBrick, FakeClock, FakePortFactory
from support import RUNTIME_ROOT, ScriptedEngine, dummy_drive_config, dummy_robot

from neuralese_local.robot import bluetooth as bt
from neuralese_local.robot import profiles
from neuralese_local.robot.drivers.ev3_direct import Ev3DirectDriver, Ev3Link
from neuralese_local.robot.robot_session import (
    STATE_CONNECTED,
    STATE_DRIVING,
    STATE_IDLE,
    RobotSession,
)

KIRISIMA = "00:16:53:4E:DB:AB"
CAR_TRACK_META = {"input_size": 8, "output_size": 2}
MODEL = Path(__file__).resolve().parent / "fixtures" / "robot_drive" / "car_brain.onnx"


class Harness:
    """A session with fakes, and helpers that wait for long commands."""

    def __init__(self, tmp: Path, engine=None):
        self.clock = FakeClock()
        self.events = []
        self.ports = FakePortFactory(self.clock)
        self.brick = FakeBrick()
        self.ports.ports["COM8"] = self.brick
        self.engine = engine or ScriptedEngine([0.0, 1.0])
        self.found = [bt.FoundRobot(KIRISIMA, "KIRISIMA", True, com_port="COM8", rssi_dbm=-53, heard=True)]
        self.session = RobotSession(
            emit=self.events.append,
            logs_dir=tmp / "logs",
            profiles_dir=str(tmp / "profiles"),
            clock=self.clock,
            sleep=self.clock.sleep,
            discover=lambda seconds: list(self.found),
            connect_ev3=self.fake_connect,
            model_meta=lambda path: dict(CAR_TRACK_META),
            engine_factory=lambda path, meta: self.engine,
        )
        self.seq = 0

    def fake_connect(self, robot, pin, on_stage=None):
        for stage in ("connecting", "inspecting", "connected"):
            if on_stage:
                on_stage(stage)
        link = Ev3Link(robot.com_port, serial_factory=self.ports, clock=self.clock, sleep=self.clock.sleep)
        link.connect()
        driver = Ev3DirectDriver(robot.com_port, mac=robot.mac, name=robot.name,
                                 proximity={"rssi_dbm": robot.rssi_dbm, "distance_m": robot.distance_m}, link=link)
        driver.refresh_ports()
        return bt.ConnectResult(driver, ["connecting", "inspecting", "connected"])

    def call(self, command, **args):
        self.seq += 1
        packet = self.session.handle({"seq": self.seq, "command": command, "args": args})
        deadline = time.monotonic() + 10.0
        while packet is None:
            packet = self.session.poll_worker()
            if time.monotonic() > deadline:
                raise AssertionError("%s did not finish" % command)
            time.sleep(0.001)
        self.events.append(packet)
        return packet

    def run(self, seconds):
        end = self.clock.now + seconds
        while self.clock.now < end:
            self.session.step()
            self.clock.now += 0.01


class SessionTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)
        self.h = Harness(self.tmp)

    def connect_ev3(self):
        self.h.call("scan")
        packet = self.h.call("connect", robot_id="ev3:" + KIRISIMA, pin="1234")
        self.assertTrue(packet["ok"], packet)
        return packet

    def ev3_config(self):
        return dummy_drive_config(robot=dummy_robot())

    def test_scan_lists_the_dummy_and_robots_with_their_distance(self) -> None:
        packet = self.h.call("scan", seconds=1)
        robots = packet["result"]["robots"]
        self.assertEqual([r["platform"] for r in robots], ["dummy", "ev3_direct"])
        ev3 = robots[1]
        self.assertEqual(ev3["robot_id"], "ev3:" + KIRISIMA)
        self.assertEqual(ev3["name"], "KIRISIMA")
        self.assertEqual(ev3["proximity"]["distance_m"], 0.5)
        self.assertTrue(ev3["paired"])
        self.assertEqual(self.h.session.state, STATE_IDLE)

    def test_connect_reports_stages_and_the_robot(self) -> None:
        packet = self.connect_ev3()
        robot = packet["result"]["robot"]
        self.assertEqual(robot["status"], "connected")
        self.assertEqual(robot["battery_pct"], 87)
        stages = [e["stage"] for e in self.h.events if e.get("event") == "stage"]
        self.assertEqual(stages, ["connecting", "inspecting", "connected"])
        self.assertEqual(self.h.session.state, STATE_CONNECTED)

    def test_the_saved_geometry_comes_back_on_connect(self) -> None:
        saved = dummy_robot()
        saved["robot_id"] = "ev3:" + KIRISIMA
        saved["platform"] = "ev3_direct"
        live = self.h.fake_connect(self.h.found[0], "1234").driver.inventory().to_dict()
        live["geometry"] = saved["geometry"]
        live["name"] = "Kirisima"
        profiles.save_profile(self.tmp / "profiles", live)
        robot = self.connect_ev3()["result"]["robot"]
        self.assertEqual(robot["name"], "Kirisima")
        self.assertEqual(robot["geometry"]["drive"]["left_port"], "outD")

    def test_drive_sends_telemetry_and_logs_every_tick(self) -> None:
        self.connect_ev3()
        packet = self.h.call("start", model_path="car_brain.onnx", config=self.ev3_config())
        self.assertTrue(packet["ok"], packet)
        self.assertEqual(self.h.session.state, STATE_DRIVING)
        self.h.run(2.0)
        telemetry = [e for e in self.h.events if e.get("event") == "telemetry"]
        self.assertAlmostEqual(len(telemetry), 40, delta=2)   # 20 ticks a second
        self.assertEqual(telemetry[-1]["motors"], {"outD.power": 100, "outB.power": 100})
        stopped = self.h.call("stop")["result"]
        self.assertEqual(self.h.brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        self.assertEqual(self.h.session.state, STATE_CONNECTED)
        lines = Path(stopped["datalog"]).read_text(encoding="utf-8").splitlines()
        self.assertEqual(len(lines) - 1, stopped["steps"])
        self.assertAlmostEqual(stopped["steps"], 40, delta=2)   # 20 ticks a second

    def test_start_refuses_a_mapping_the_robot_cannot_do(self) -> None:
        self.connect_ev3()
        config = self.ev3_config()
        config["inputs"][0]["sources"][0]["channel"] = "in1.distance_mm"   # nothing plugged into port 1
        packet = self.h.call("start", model_path="m.onnx", config=config)
        self.assertFalse(packet["ok"])
        self.assertEqual(packet["error"]["field"], "inputs[0].sources[0].channel")
        self.assertEqual(self.h.brick.motor_log, [])

    def test_start_refuses_a_model_of_the_wrong_shape(self) -> None:
        self.connect_ev3()
        self.h.session.model_meta = lambda path: {"input_size": 7, "output_size": 2}
        packet = self.h.call("start", model_path="m.onnx", config=self.ev3_config())
        self.assertFalse(packet["ok"])
        self.assertEqual(packet["error"]["code"], "arity_mismatch")

    def test_estop_stops_the_motors_at_once(self) -> None:
        self.connect_ev3()
        self.h.call("start", model_path="m.onnx", config=self.ev3_config())
        self.h.run(0.5)
        self.h.session.estop()
        self.assertEqual(self.h.brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        reasons = [e["reason"] for e in self.h.events if e.get("event") == "drive_stopped"]
        self.assertEqual(reasons, ["estop"])
        n = len(self.h.brick.motor_log)
        self.h.run(0.5)
        self.assertEqual(len(self.h.brick.motor_log), n)   # nothing moves afterwards

    def test_time_limit(self) -> None:
        self.connect_ev3()
        self.h.call("start", model_path="m.onnx", config=self.ev3_config(), max_seconds=1.0)
        self.h.run(1.5)
        stopped = [e for e in self.h.events if e.get("event") == "drive_stopped"]
        self.assertEqual(stopped[0]["reason"], "time_limit")
        self.assertEqual(self.h.brick.motor_log[-1], ("stop", 0x0F, 0, 0))

    def test_a_crashing_model_ends_the_drive_safely(self) -> None:
        self.connect_ev3()
        self.h.call("start", model_path="m.onnx", config=self.ev3_config())
        self.h.run(0.3)
        self.h.engine.raises = RuntimeError("bad model")
        self.h.run(0.1)
        stopped = [e for e in self.h.events if e.get("event") == "drive_stopped"][0]
        self.assertEqual(stopped["reason"], "error")
        self.assertIn("bad model", stopped["error"]["message"])
        self.assertEqual(self.h.brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        self.assertEqual(self.h.session.state, STATE_CONNECTED)

    def test_losing_the_robot_while_driving(self) -> None:
        self.connect_ev3()
        self.h.call("start", model_path="m.onnx", config=self.ev3_config())
        self.h.run(0.3)
        self.h.ports.opened[-1].silent = True
        self.h.run(5.0)
        kinds = [e.get("event") for e in self.h.events]
        self.assertIn("link_lost", kinds)
        lost = [e for e in self.h.events if e.get("event") == "link_lost"][0]
        self.assertEqual(lost["error"]["code"], "LINK_LOST")
        self.assertIn("ru", lost["error"]["texts"])
        self.assertEqual(self.h.session.state, STATE_IDLE)
        self.assertIsNone(self.h.session.driver)

    def test_losing_the_robot_while_idle_is_noticed_too(self) -> None:
        self.connect_ev3()
        self.h.ports.opened[-1].silent = True
        self.h.run(5.0)
        self.assertIn("link_lost", [e.get("event") for e in self.h.events])

    def test_spin_motor_shows_which_wheel_a_port_drives(self) -> None:
        self.connect_ev3()
        self.h.brick.tacho[1] = 100
        packet = self.h.call("spin_motor", channel="outB.power", power=35, seconds=1.0)
        self.assertTrue(packet["ok"], packet)
        self.assertEqual(packet["result"]["position_before"], 100)
        masks = {mask for _, mask, _, _ in self.h.brick.motor_log}
        self.assertEqual(masks, {0x02})
        self.assertEqual(self.h.brick.motor_log[-1], ("stop", 0x02, 0, 0))

    def test_read_beep_inventory(self) -> None:
        self.connect_ev3()
        values = self.h.call("read", channels=["in3.distance_mm"])["result"]["values"]
        self.assertEqual(values, {"in3.distance_mm": 455})
        self.h.call("beep")
        self.assertEqual(len(self.h.brick.beeps), 2)    # "connected" + this one
        self.h.brick.types[0] = 32                      # a gyro was plugged into port 1
        robot = self.h.call("inventory")["result"]["robot"]
        self.assertEqual({p["id"]: p["device"] for p in robot["ports"]}["in1"], "gyro")

    def test_commands_that_need_a_stopped_robot(self) -> None:
        self.connect_ev3()
        self.h.call("start", model_path="m.onnx", config=self.ev3_config())
        for command, args in (("spin_motor", {"channel": "outB.power"}), ("inventory", {}), ("start", {})):
            packet = self.h.call(command, **args)
            self.assertEqual(packet["error"]["code"], "driving", command)

    def test_the_robot_and_the_mapping_are_remembered(self) -> None:
        self.connect_ev3()
        geometry = dummy_robot()["geometry"]
        packet = self.h.call("save_profile", robot={"name": "Kirisima", "geometry": geometry})
        self.assertTrue(packet["ok"], packet)
        self.assertEqual(packet["result"]["robot"]["name"], "Kirisima")
        self.assertEqual(packet["result"]["robot"]["geometry"]["drive"]["left_port"], "outD")
        self.h.call("save_mapping", key="car_track", mapping={"vision": ["in4", "in3"]})
        self.assertEqual(self.h.call("load_mapping", key="car_track")["result"]["mapping"], {"vision": ["in4", "in3"]})
        self.assertIsNone(self.h.call("load_mapping", key="another_model")["result"]["mapping"])
        # Saving the geometry again keeps what was mapped.
        self.h.call("save_profile", robot={"geometry": geometry})
        self.assertIsNotNone(self.h.call("load_mapping", key="car_track")["result"]["mapping"])

    def test_an_invalid_geometry_is_refused_and_nothing_is_lost(self) -> None:
        self.connect_ev3()
        geometry = dummy_robot()["geometry"]
        self.h.call("save_profile", robot={"geometry": geometry})
        bad = json.loads(json.dumps(geometry))
        bad["drive"]["right_port"] = bad["drive"]["left_port"]
        packet = self.h.call("save_profile", robot={"geometry": bad})
        self.assertFalse(packet["ok"])
        saved = profiles.load_profile(self.tmp / "profiles", "ev3:" + KIRISIMA)
        self.assertEqual(saved["geometry"]["drive"]["right_port"], "outB")

    def test_describe_model_needs_no_robot(self) -> None:
        meta = json.loads((Path(__file__).resolve().parent / "fixtures" / "robot_ui" / "car_track_meta.json")
                          .read_text(encoding="utf-8"))
        packet = self.h.call("describe_model", dataset_meta=meta, input_width=8, output_width=2)
        self.assertTrue(packet["ok"], packet)
        result = packet["result"]
        self.assertEqual([n["name"] for n in result["outputs"]], ["steer", "throttle"])
        self.assertIsNone(result["blocked"])
        blocked = self.h.call("describe_model", dataset_meta=meta, model_ready=False)["result"]["blocked"]
        self.assertEqual(blocked["code"], "not_trained")

    def test_errors_are_answers_not_crashes(self) -> None:
        self.assertEqual(self.h.call("start", model_path="m.onnx")["error"]["code"], "not_connected")
        self.assertEqual(self.h.call("fly")["error"]["code"], "unknown_command")
        self.assertEqual(self.h.call("connect", robot_id="lego:1")["error"]["code"], "unknown_robot")

    def test_busy_while_connecting_but_estop_still_answers(self) -> None:
        import threading

        gate = threading.Event()
        original = self.h.fake_connect

        def slow_connect(robot, pin, on_stage=None):
            gate.wait(5.0)
            return original(robot, pin, on_stage)

        self.h.session.connect_ev3 = slow_connect
        self.h.call("scan")
        self.h.seq += 1
        self.assertIsNone(self.h.session.handle({"seq": self.h.seq, "command": "connect",
                                                 "args": {"robot_id": "ev3:" + KIRISIMA}}))
        busy = self.h.session.handle({"seq": 99, "command": "beep", "args": {}})
        self.assertEqual(busy["error"]["code"], "busy")
        estop = self.h.session.handle({"seq": 100, "command": "estop", "args": {}})
        self.assertTrue(estop["ok"])
        gate.set()
        deadline = time.monotonic() + 5
        packet = None
        while packet is None and time.monotonic() < deadline:
            packet = self.h.session.poll_worker()
        self.assertTrue(packet["ok"])

    def test_dummy_drives_in_the_session(self) -> None:
        packet = self.h.call("connect", robot_id="dummy:kirisima", world={"walls": [], "start": [0, 0, 0]})
        self.assertTrue(packet["ok"], packet)
        self.h.call("start", model_path="m.onnx", config=dummy_drive_config())
        self.h.run(1.0)
        self.h.call("disconnect")
        self.assertEqual(self.h.session.state, STATE_IDLE)

    def test_a_rays_only_network_still_reports_where_the_robot_is(self) -> None:
        # The window always sends the wheels (to draw the room); the network
        # itself takes rays only, and drives as before.
        self.h.call("connect", robot_id="dummy:kirisima", world={"walls": [], "start": [0, 0, 0]})
        wheels = dummy_drive_config(
            world={"cm_per_unit": 0.1875, "start": [0.0, 0.0, 0.0]},
            odometry={"left": [{"channel": "outD.position_deg"}], "right": [{"channel": "outB.position_deg"}],
                      "wheel_diameter_cm": 5.6, "track_cm": 12.0, "heading": {"source": "wheels"}},
        )
        self.assertTrue(self.h.call("start", model_path="m.onnx", config=wheels)["ok"])
        self.h.run(1.0)
        self.h.call("stop")
        poses = [e["pose"] for e in self.h.events if e.get("event") == "telemetry"]
        self.assertEqual(len(poses), len([e for e in self.h.events if e.get("event") == "telemetry"]))
        self.assertGreater(poses[-1]["x_cm"], 5.0)      # straight ahead at full throttle
        self.assertEqual(len(self.h.engine.calls[-1]), 8)
        # Without the wheels there is nothing to report, and nothing is read for it.
        self.h.call("start", model_path="m.onnx", config=dummy_drive_config())
        self.h.run(0.2)
        self.h.call("stop")
        self.assertNotIn("pose", [e for e in self.h.events if e.get("event") == "telemetry"][-1])

    def test_shutdown_stops_everything(self) -> None:
        self.connect_ev3()
        self.h.call("start", model_path="m.onnx", config=self.ev3_config())
        self.h.run(0.3)
        self.h.session.shutdown()
        self.assertEqual(self.h.brick.motor_log[-1], ("stop", 0x0F, 0, 0))
        self.assertTrue(self.h.ports.opened[-1].closed)


@unittest.skipUnless(importlib.util.find_spec("onnxruntime") is not None, "onnxruntime is not installed")
class ProcessTests(unittest.TestCase):
    """The real process, through its files only, as Godot will use it."""

    def setUp(self) -> None:
        self.job = Path(tempfile.mkdtemp())
        self.addCleanup(shutil.rmtree, self.job, ignore_errors=True)
        (self.job / "control.json").write_text(json.dumps({"parent_pid": os.getpid()}), encoding="utf-8")
        script = RUNTIME_ROOT / "neuralese_local" / "robot" / "robot_session.py"
        self.proc = subprocess.Popen([sys.executable, str(script), str(self.job)],
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(self._kill)
        self.seq = 0
        self.wait_for(lambda: any(e.get("event") == "ready" for e in self.events()), "ready")

    def _kill(self) -> None:
        if self.proc.poll() is None:
            self.proc.kill()
        self.proc.communicate(timeout=10)

    def events(self):
        path = self.job / "progress.jsonl"
        if not path.exists():
            return []
        return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip()]

    def wait_for(self, predicate, what, timeout=20.0):
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            if predicate():
                return
            if self.proc.poll() is not None:
                raise AssertionError("session exited while waiting for %s: %s" % (what, self.proc.stderr.read()))
            time.sleep(0.02)
        raise AssertionError("timed out waiting for %s" % what)

    def call(self, command, **args):
        self.seq += 1
        seq = self.seq
        tmp = self.job / "request.json.tmp"
        tmp.write_text(json.dumps({"seq": seq, "command": command, "args": args}), encoding="utf-8")
        tmp.replace(self.job / "request.json")
        found = {}

        def answered():
            for e in self.events():
                if e.get("event") == "response" and e.get("seq") == seq:
                    found["packet"] = e
                    return True
            return False

        self.wait_for(answered, command)
        return found["packet"]

    def test_a_whole_session_with_the_dummy(self) -> None:
        packet = self.call("connect", robot_id="dummy:kirisima", world={"walls": [], "start": [0, 0, 0]})
        self.assertTrue(packet["ok"], packet)
        config = dummy_drive_config()
        packet = self.call("start", model_path=str(MODEL), config=config)
        self.assertTrue(packet["ok"], packet)
        self.wait_for(lambda: sum(1 for e in self.events() if e.get("event") == "telemetry") >= 5, "telemetry")
        telemetry = [e for e in self.events() if e.get("event") == "telemetry"][-1]
        self.assertEqual(len(telemetry["model_input"]), 8)
        self.assertEqual(set(telemetry["motors"]), {"outD.power", "outB.power"})
        status = json.loads((self.job / "status.json").read_text(encoding="utf-8"))
        self.assertEqual(status["state"], "driving")
        # Emergency stop through its file.
        (self.job / "estop").write_text("", encoding="utf-8")
        self.wait_for(lambda: any(e.get("event") == "drive_stopped" and e["reason"] == "estop" for e in self.events()),
                      "estop")
        self.assertFalse((self.job / "estop").exists())
        stopped = [e for e in self.events() if e.get("event") == "drive_stopped"][0]
        self.assertTrue(Path(stopped["datalog"]).exists())
        # End the session through its stop file.
        (self.job / "stop").write_text("", encoding="utf-8")
        self.proc.wait(timeout=10)
        self.assertEqual(self.proc.returncode, 0)
        self.assertEqual(self.events()[-1]["event"], "closed")


if __name__ == "__main__":
    unittest.main()
