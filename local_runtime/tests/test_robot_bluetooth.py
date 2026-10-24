"""Finding, pairing and connecting an EV3, with a fake helper and a fake brick.

The decision that matters most here is when to forget a robot's pairing. Doing
it too eagerly un-pairs a robot that is simply switched off; never doing it
leaves a child stuck with a stale pairing they would have to remove in Windows
settings. Each branch is pinned below. The HWIDs are copied from a real PC
with two paired EV3s (KIRISIMA on COM8, Jason on COM7).
"""

from __future__ import annotations

import unittest
from types import SimpleNamespace

from fake_ev3 import FakeBrick, FakeClock, FakePortFactory
from support import RUNTIME_ROOT  # noqa: F401  (puts the runtime on sys.path)

from neuralese_local.robot import bluetooth as bt
from neuralese_local.robot.drivers.ev3_direct import Ev3Error, Ev3Link

KIRISIMA = "00:16:53:4E:DB:AB"
JASON = "00:16:53:5F:B4:33"

HWIDS = {
    "COM8": "BTHENUM\\{00001101-0000-1000-8000-00805F9B34FB}_LOCALMFG&0002\\7&BCA2F7B&0&0016534EDBAB_C00000000",
    "COM7": "BTHENUM\\{00001101-0000-1000-8000-00805F9B34FB}_LOCALMFG&0002\\7&BCA2F7B&0&0016535FB433_C00000000",
    "COM4": "BTHENUM\\{00001101-0000-1000-8000-00805F9B34FB}_LOCALMFG&0000\\7&BCA2F7B&0&000000000000_00000000",
    "COM3": "BTHENUM\\{00001101-0000-1000-8000-00805F9B34FB}_VID&000105D6_PID&000A\\7&BCA2F7B&0&B372CED4BFD8_C00000000",
}


def ports(*coms):
    return lambda: [SimpleNamespace(device=c, hwid=HWIDS[c]) for c in coms]


class FakeHelper:
    """neuralese_bt.exe: records calls, answers from a script."""

    def __init__(self, scan=None, pair=None, repair=None, on_pair=None):
        self.calls = []
        self.answers = {"scan": scan or {"ok": True, "devices": []},
                        "pair": pair or {"ok": True, "status": "Paired"},
                        "repair": repair or {"ok": True, "status": "Paired"}}
        self.on_pair = on_pair

    def __call__(self, args, timeout):
        self.calls.append(args[0])
        if args[0] in ("pair", "repair") and self.on_pair and self.answers[args[0]].get("ok"):
            self.on_pair()
        return self.answers[args[0]]


class Pc:
    """The fake PC: COM ports that appear after pairing, bricks behind them."""

    def __init__(self, *coms):
        self.clock = FakeClock()
        self.coms = list(coms)
        self.factory = FakePortFactory(self.clock)
        self.bricks = {}

    def comports(self):
        return [SimpleNamespace(device=c, hwid=HWIDS[c]) for c in self.coms]

    def add_brick(self, com, **kwargs):
        brick = FakeBrick(**kwargs)
        self.factory.ports[com] = brick
        return brick

    def link(self, com):
        return Ev3Link(com, serial_factory=self.factory, clock=self.clock, sleep=self.clock.sleep)


def found(mac=KIRISIMA, paired=True, com="", heard=False):
    return bt.FoundRobot(mac, "KIRISIMA", paired, com_port=com, rssi_dbm=-60 if heard else None, heard=heard)


class AddressTests(unittest.TestCase):
    def test_mac_from_a_real_hwid(self) -> None:
        self.assertEqual(bt.extract_mac_from_hwid(HWIDS["COM8"]), KIRISIMA)
        self.assertIsNone(bt.extract_mac_from_hwid(HWIDS["COM4"]))   # incoming port

    def test_only_outgoing_lego_ports(self) -> None:
        self.assertEqual(bt.lego_com_ports(ports("COM8", "COM7", "COM4", "COM3")), {KIRISIMA: "COM8", JASON: "COM7"})

    def test_mac_spellings(self) -> None:
        self.assertEqual(bt.normalize_mac("00-16-53-4e-db-ab"), KIRISIMA)
        self.assertTrue(bt.is_lego("0016534edbab"))
        self.assertFalse(bt.is_lego("b3:72:ce:d4:bf:d8"))


class SignalTests(unittest.TestCase):
    def test_only_a_strength_heard_now_counts(self) -> None:
        # Measured: a switched-off paired EV3 is reported with its last strength.
        self.assertIsNone(bt.fresh_rssi({"paired": True, "rssi_cached_dbm": -37, "rssi_dbm": None}))
        self.assertEqual(bt.fresh_rssi({"paired": True, "rssi_cached_dbm": -37, "rssi_dbm": -52}), -52)
        # An unpaired device is only listed because the radio just heard it.
        self.assertEqual(bt.fresh_rssi({"paired": False, "rssi_cached_dbm": -93, "rssi_dbm": None}), -93)

    def test_distance(self) -> None:
        self.assertEqual(bt.distance_from_rssi(-59), 1.0)
        self.assertEqual(bt.distance_from_rssi(-79), 10.0)
        self.assertEqual(bt.distance_from_rssi(-53), 0.5)
        self.assertIsNone(bt.distance_from_rssi(None))


class DiscoveryTests(unittest.TestCase):
    def test_merges_the_radio_and_the_com_ports(self) -> None:
        scan = {"ok": True, "devices": [
            {"address": "00:16:53:4e:db:ab", "name": "KIRISIMA", "paired": True, "rssi_cached_dbm": -57, "rssi_dbm": None},
            {"address": "00:16:53:aa:bb:cc", "name": "NEW", "paired": False, "rssi_cached_dbm": -70, "rssi_dbm": None},
            {"address": "00:16:53:11:22:33", "name": "NEAR", "paired": False, "rssi_cached_dbm": -55, "rssi_dbm": None},
            {"address": "b3:72:ce:d4:bf:d8", "name": "Headphones", "paired": True, "rssi_dbm": -40},
        ]}
        robots = bt.discover_ev3(runner=FakeHelper(scan=scan), comports=ports("COM8", "COM7"),
                                 names={JASON: "Jason"}.get, last_used=[JASON])
        self.assertEqual([r.name for r in robots], ["Jason", "NEAR", "NEW", "KIRISIMA"])
        by_name = {r.name: r for r in robots}
        self.assertEqual(by_name["KIRISIMA"].com_port, "COM8")
        self.assertIsNone(by_name["KIRISIMA"].distance_m)          # switched off: no made-up distance
        self.assertFalse(by_name["KIRISIMA"].heard)
        self.assertEqual(by_name["NEAR"].distance_m, 0.6)
        self.assertFalse(by_name["NEW"].paired)
        self.assertTrue(by_name["Jason"].last_used)
        self.assertNotIn("Headphones", by_name)

    def test_without_the_helper_paired_robots_are_still_listed(self) -> None:
        def no_helper(args, timeout):
            raise bt.ev3_error("NO_HELPER")

        robots = bt.discover_ev3(runner=no_helper, comports=ports("COM8"), names=lambda mac: "KIRISIMA")
        self.assertEqual([(r.name, r.com_port) for r in robots], [("KIRISIMA", "COM8")])
        with self.assertRaises(Ev3Error) as caught:
            bt.discover_ev3(runner=no_helper, comports=ports())
        self.assertEqual(caught.exception.code, "NO_HELPER")


class ListRobotsTests(unittest.TestCase):
    def test_paired_ev3s_are_listed_at_once_without_a_scan(self) -> None:
        from neuralese_local.robot.export_robot import handle_request

        saved = (bt.lego_com_ports, bt.registry_name)
        bt.lego_com_ports = lambda comports=None: {KIRISIMA: "COM8", JASON: "COM7"}
        bt.registry_name = {KIRISIMA: "KIRISIMA", JASON: "Jason"}.get
        try:
            robots = handle_request({"action": "list_robots"})["robots"]
        finally:
            bt.lego_com_ports, bt.registry_name = saved
        ev3s = [r for r in robots if r["platform"] == "ev3_direct"]
        self.assertEqual([(r["robot_id"], r["name"]) for r in ev3s],
                         [("ev3:" + KIRISIMA, "KIRISIMA"), ("ev3:" + JASON, "Jason")])
        self.assertTrue(all(r["paired"] and r["status"] == "available" and r["proximity"] is None for r in ev3s))


class ConnectTests(unittest.TestCase):
    def connect(self, pc, robot, helper, **kwargs):
        return bt.connect_ev3(robot, "1234", runner=helper, comports=pc.comports, link_factory=pc.link,
                              sleep=pc.clock.sleep, **kwargs)

    def test_a_paired_robot_just_connects(self) -> None:
        pc = Pc("COM8")
        pc.add_brick("COM8")
        helper = FakeHelper()
        result = self.connect(pc, found(com="COM8"), helper)
        self.assertEqual(helper.calls, [])
        self.assertEqual(result.steps, ["connecting", "inspecting", "connected"])
        robot = result.driver.inventory()
        self.assertEqual((robot.robot_id, robot.name, robot.status), ("ev3:" + KIRISIMA, "KIRISIMA", "connected"))

    def test_a_new_robot_is_paired_with_the_pin_and_its_port_awaited(self) -> None:
        pc = Pc()
        pc.add_brick("COM8")
        helper = FakeHelper(on_pair=lambda: pc.coms.append("COM8"))
        result = self.connect(pc, found(paired=False, heard=True), helper)
        self.assertEqual(helper.calls, ["pair"])
        self.assertEqual(result.steps, ["pairing", "waiting_for_port", "connecting", "inspecting", "connected"])
        self.assertEqual(result.driver.com_port, "COM8")

    def test_the_port_may_take_a_few_seconds_to_appear(self) -> None:
        pc = Pc()
        pc.add_brick("COM8")
        polls = []

        def slow_ports():
            polls.append(1)
            return ports("COM8")() if len(polls) >= 3 else []

        result = bt.connect_ev3(found(paired=False, heard=True), runner=FakeHelper(), comports=slow_ports,
                                link_factory=pc.link, sleep=pc.clock.sleep)
        self.assertEqual(result.driver.com_port, "COM8")

    def test_a_refused_pairing_tells_the_child_what_to_press(self) -> None:
        pc = Pc()
        helper = FakeHelper(pair={"ok": False, "status": "AuthenticationFailure"})
        with self.assertRaises(Ev3Error) as caught:
            self.connect(pc, found(paired=False, heard=True), helper)
        self.assertEqual(caught.exception.code, "PAIRING_FAILED")
        self.assertIn("centre button", caught.exception.fix)

    def test_paired_without_a_port_is_stale_and_repaired(self) -> None:
        pc = Pc()
        pc.add_brick("COM8")
        helper = FakeHelper(on_pair=lambda: pc.coms.append("COM8"))
        result = self.connect(pc, found(paired=True, com=""), helper)
        self.assertEqual(helper.calls, ["repair"])
        self.assertEqual(result.steps[0], "repairing")

    def test_a_robot_not_heard_on_the_radio_is_never_unpaired(self) -> None:
        # Switched off or away: unpairing it would only make the child confirm
        # pairing on the brick again later.
        pc = Pc("COM8")
        pc.factory.errors["COM8"] = OSError("could not open port 'COM8': OSError(22, 'The semaphore timeout period has expired.', None, 121)")
        helper = FakeHelper()
        with self.assertRaises(Ev3Error) as caught:
            self.connect(pc, found(com="COM8", heard=False), helper)
        self.assertEqual(caught.exception.code, "OPEN_TIMEOUT")
        self.assertEqual(helper.calls, [])

    def test_a_robot_heard_but_not_answering_is_repaired_once(self) -> None:
        pc = Pc("COM8")
        pc.factory.errors["COM8"] = OSError("could not open port 'COM8': OSError(22, 'The semaphore timeout period has expired.', None, 121)")

        def after_repair():
            del pc.factory.errors["COM8"]
            pc.add_brick("COM8")

        helper = FakeHelper(on_pair=after_repair)
        result = self.connect(pc, found(com="COM8", heard=True), helper)
        self.assertEqual(helper.calls, ["repair"])
        self.assertEqual(result.steps, ["connecting", "repairing", "waiting_for_port", "connecting", "inspecting", "connected"])

    def test_no_second_repair(self) -> None:
        pc = Pc("COM8")
        pc.factory.errors["COM8"] = OSError("(1167) The device is not connected.")
        helper = FakeHelper()
        with self.assertRaises(Ev3Error) as caught:
            self.connect(pc, found(com="COM8", heard=True), helper)
        self.assertEqual(caught.exception.code, "OPEN_TIMEOUT")
        self.assertEqual(helper.calls, ["repair"])

    def test_a_busy_port_is_not_a_pairing_problem(self) -> None:
        pc = Pc("COM8")
        pc.factory.errors["COM8"] = OSError("could not open port 'COM8': PermissionError(13, 'Access is denied.')")
        helper = FakeHelper()
        with self.assertRaises(Ev3Error) as caught:
            self.connect(pc, found(com="COM8", heard=True), helper)
        self.assertEqual(caught.exception.code, "PORT_BUSY")
        self.assertEqual(helper.calls, [])

    def test_paired_but_windows_makes_no_port(self) -> None:
        pc = Pc()
        with self.assertRaises(Ev3Error) as caught:
            self.connect(pc, found(paired=False, heard=True), FakeHelper())
        self.assertEqual(caught.exception.code, "PORT_NOT_CREATED")
        # Never sends the child to Windows' Bluetooth settings.
        for lang in ("en", "ru"):
            message, fix = caught.exception.text(lang)
            self.assertNotIn("Bluetooth", fix)

    def test_stages_are_reported_as_they_happen(self) -> None:
        pc = Pc("COM8")
        pc.add_brick("COM8")
        seen = []
        self.connect(pc, found(com="COM8"), FakeHelper(), on_stage=seen.append)
        self.assertEqual(seen, ["connecting", "inspecting", "connected"])


if __name__ == "__main__":
    unittest.main()
