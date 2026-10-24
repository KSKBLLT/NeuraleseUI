"""Finding, pairing and connecting an EV3 over Bluetooth, without the child
ever opening Windows' Bluetooth settings.

Ported from the robotics prototype (``neuralese-robotics-prototype`` at
``be2a4a5``): ``core/discovery.py`` (which COM ports are LEGO robots),
``run_robot_full_cycle.py`` (pair with the PIN, then wait for Windows to create
the COM port, then connect) and ``tools/bt_pair.cs`` / ``tools/bt_helper.ps1``,
now one helper, ``robot_helpers/neuralese_bt.exe``.

Where this goes beyond the prototype, and why:

* **Robots are found over the air.** The prototype's runner listed paired COM
  ports plus two MAC addresses written into the code, with made-up distances.
  Its over-the-air scan (``bt_helper.ps1``) was never called, and its query
  returns nothing on Windows 11. The helper's scan works and reports signal
  strength.
* **Distance is only shown when it is real.** Windows reports a switched-off
  paired robot as present, with the last signal strength it ever heard; only a
  strength heard during this scan is used (see :func:`fresh_rssi`).
* **Forgetting the device is automatic, and only when the pairing is stale.**
  The prototype's runner never unpaired. Unpairing a robot that is simply
  switched off would make things worse (the child would have to confirm
  pairing on the brick again), so it happens only on evidence: Windows says
  paired but has no COM port for it, or the robot is heard on the radio yet the
  connection fails. See :func:`connect_ev3`. This branch is not yet tried on a
  real EV3.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import time
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Sequence

from .drivers.ev3_direct import LEGO_OUI, ERROR_TEXTS, Ev3DirectDriver, Ev3Error, Ev3Link, ev3_error

HELPER_PATH = Path(__file__).resolve().parents[2] / "robot_helpers" / "windows-x64" / "neuralese_bt.exe"

DEFAULT_PIN = "1234"
SCAN_SECONDS = 8.0
PAIR_TIMEOUT_S = 45
#: After pairing, Windows needs a moment to create the COM port (prototype: 2 s,
#: then up to 5 rescans one second apart).
PORT_SETTLE_S = 2.0
PORT_RESCANS = 5
PORT_RESCAN_INTERVAL_S = 1.0
#: RSSI -> metres: free-space path loss with -59 dBm at 1 m (the prototype's formula).
RSSI_AT_1M_DBM = -59.0
PATH_LOSS_EXPONENT = 2.0

ERROR_TEXTS.update({
    "NO_HELPER": {
        "ru": ("Не найдена программа для Bluetooth (neuralese_bt.exe).",
               "Переустановите Neuralese или обратитесь к учителю."),
        "en": ("The Bluetooth helper (neuralese_bt.exe) is missing.",
               "Reinstall Neuralese or ask your teacher."),
        "kz": ("Bluetooth бағдарламасы (neuralese_bt.exe) табылмады.",
               "Neuralese-ті қайта орнатыңыз немесе мұғалімге хабарласыңыз."),
    },
    "PAIRING_FAILED": {
        "ru": ("Робот не подтвердил подключение.",
               "Когда на экране EV3 появится вопрос о подключении, нажмите центральную кнопку "
               "и проверьте код (обычно 1234). Потом попробуйте ещё раз."),
        "en": ("The robot did not accept the connection.",
               "When the robot's screen asks, press the centre button twice "
               "and check the code (usually 1234). Then try again."),
        "kz": ("Робот қосылуды қабылдамады.",
               "Робот экранында сұрау шыққанда, ортаңғы батырманы екі рет басып, "
               "кодты тексеріңіз (әдетте 1234). Содан кейін қайталап көріңіз."),
    },
    # Not the prototype's NO_PORT, whose advice is to pair in Windows settings:
    # here Neuralese did the pairing, and the child must never be sent there.
    "PORT_NOT_CREATED": {
        "ru": ("Робот подключился, но связь с ним не заработала.",
               "Выключите и включите робота, потом снова нажмите «Подключить»."),
        "en": ("The robot paired, but the computer did not open a connection channel to it.",
               "Switch the robot off and on, then press Connect again."),
        "kz": ("Робот қосылды, бірақ компьютер онымен байланыс арнасын ашпады.",
               "Роботты өшіріп, қайта қосыңыз да, «Қосу» түймесін тағы басыңыз."),
    },
    "NOT_FOUND": {
        "ru": ("Робот не найден.",
               "Включите робота, а на нём — Bluetooth (Settings → Bluetooth → Visible). Поставьте робота поближе к компьютеру."),
        "en": ("The robot was not found nearby.",
               "Switch the robot and its Bluetooth on (Settings → Bluetooth → Visible) and bring it to the computer."),
        "kz": ("Робот табылмады.",
               "Роботты және ондағы Bluetooth-ты қосыңыз (Settings → Bluetooth → Visible), оны компьютерге жақындатыңыз."),
    },
})


# ---------------------------------------------------------------------------
# The helper
# ---------------------------------------------------------------------------

Runner = Callable[[List[str], float], Dict[str, Any]]


def run_helper(args: Sequence[str], timeout_s: float) -> Dict[str, Any]:
    """Run neuralese_bt.exe and return its one JSON line."""
    if sys.platform != "win32" or not HELPER_PATH.exists():
        raise ev3_error("NO_HELPER", str(HELPER_PATH))
    try:
        proc = subprocess.run([str(HELPER_PATH)] + list(args), capture_output=True, text=True,
                              encoding="utf-8", errors="replace", timeout=timeout_s)
    except subprocess.TimeoutExpired:
        return {"ok": False, "error": "HELPER_TIMEOUT", "detail": " ".join(args)}
    lines = [line.strip() for line in proc.stdout.splitlines() if line.strip().startswith("{")]
    if not lines:
        return {"ok": False, "error": "HELPER_NO_OUTPUT", "detail": (proc.stderr or proc.stdout)[-400:]}
    return json.loads(lines[-1])


def normalize_mac(raw: str) -> str:
    """Any spelling of a MAC address as XX:XX:XX:XX:XX:XX."""
    cleaned = re.sub(r"[^0-9A-Fa-f]", "", str(raw)).upper()
    if len(cleaned) == 12:
        return ":".join(cleaned[i:i + 2] for i in range(0, 12, 2))
    return str(raw).upper()


def is_lego(mac: str) -> bool:
    return normalize_mac(mac).replace(":", "").startswith(LEGO_OUI)


def fresh_rssi(device: Dict[str, Any]) -> Optional[int]:
    """Signal strength heard during this scan, or None.

    A paired device's first reported strength is Windows' memory of it, kept
    even when the robot is switched off; only updates during the scan count.
    An unpaired device is only listed because the radio just heard it, so its
    first strength is fresh.
    """
    if device.get("rssi_dbm") is not None:
        return int(device["rssi_dbm"])
    if not device.get("paired") and device.get("rssi_cached_dbm") is not None:
        return int(device["rssi_cached_dbm"])
    return None


def distance_from_rssi(rssi_dbm: Optional[int]) -> Optional[float]:
    """Rough distance in metres, the prototype's way: 10^((-59 - rssi) / 20)."""
    if rssi_dbm is None:
        return None
    return round(10.0 ** ((RSSI_AT_1M_DBM - float(rssi_dbm)) / (10.0 * PATH_LOSS_EXPONENT)), 1)


# ---------------------------------------------------------------------------
# COM ports (core/discovery.py)
# ---------------------------------------------------------------------------

def extract_mac_from_hwid(hwid: str) -> Optional[str]:
    """The Bluetooth MAC in a Windows HWID, e.g. ``BTHENUM\\{...}\\7&...&0016534EDBAB_C00000000``."""
    m = re.search(r"([0-9A-Fa-f]{12})_", hwid)
    if m:
        mac = m.group(1)
        if mac != "000000000000":
            return normalize_mac(mac)
    return None


def _default_comports() -> List[Any]:
    try:
        import serial.tools.list_ports as list_ports
    except ImportError:
        return []
    return list(list_ports.comports())


def lego_com_ports(comports: Optional[Callable[[], List[Any]]] = None) -> Dict[str, str]:
    """MAC -> outgoing COM port, for every paired LEGO robot Windows made a port for.

    Incoming ports (MAC 000000000000) are skipped: nobody answers on them, and
    opening one can hang.
    """
    ports: Dict[str, str] = {}
    for p in (comports or _default_comports)():
        hwid = (getattr(p, "hwid", "") or "").upper()
        if "&000000000000_" in hwid:
            continue
        if LEGO_OUI in hwid:
            mac = extract_mac_from_hwid(hwid)
            if mac:
                ports[mac] = p.device
    return ports


def registry_name(mac: str) -> Optional[str]:
    """A paired robot's name (e.g. KIRISIMA) from the Windows registry."""
    if sys.platform != "win32":
        return None
    try:
        import winreg

        key_path = r"SYSTEM\CurrentControlSet\Services\BTHPORT\Parameters\Devices\%s" % mac.replace(":", "").lower()
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key_path) as k:
            raw_name, _ = winreg.QueryValueEx(k, "Name")
        if isinstance(raw_name, bytes):
            return raw_name.split(b"\x00")[0].decode("utf-8", "ignore").strip() or None
        return str(raw_name).strip() or None
    except Exception:
        return None


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

@dataclass
class FoundRobot:
    mac: str
    name: str
    paired: bool
    com_port: str = ""
    rssi_dbm: Optional[int] = None
    heard: bool = False            # the radio heard it during this scan
    last_used: bool = False

    @property
    def robot_id(self) -> str:
        return "ev3:%s" % self.mac

    @property
    def distance_m(self) -> Optional[float]:
        return distance_from_rssi(self.rssi_dbm)

    def to_dict(self) -> Dict[str, Any]:
        return {
            "robot_id": self.robot_id,
            "mac": self.mac,
            "name": self.name,
            "paired": self.paired,
            "com_port": self.com_port,
            "rssi_dbm": self.rssi_dbm,
            "distance_m": self.distance_m,
            "heard": self.heard,
            "last_used": self.last_used,
        }


def discover_ev3(
    *,
    seconds: float = SCAN_SECONDS,
    runner: Runner = run_helper,
    comports: Optional[Callable[[], List[Any]]] = None,
    names: Callable[[str], Optional[str]] = registry_name,
    last_used: Sequence[str] = (),
) -> List[FoundRobot]:
    """Every EV3 the computer can see or already knows, nearest and last used first."""
    robots: Dict[str, FoundRobot] = {}
    scan_error = None
    try:
        result = runner(["scan", "--seconds", str(seconds)], seconds + 15.0)
    except Ev3Error as exc:
        result, scan_error = {"ok": False}, exc
    devices = (result.get("devices") or []) if result.get("ok") else []
    for device in devices:
        mac = normalize_mac(device.get("address") or "")
        if not is_lego(mac):
            continue
        rssi = fresh_rssi(device)
        robots[mac] = FoundRobot(mac, str(device.get("name") or "EV3"), bool(device.get("paired")),
                                 rssi_dbm=rssi, heard=rssi is not None)
    # A paired robot Windows made a COM port for, even if the scan missed it.
    for mac, com in lego_com_ports(comports).items():
        robot = robots.get(mac)
        if robot is None:
            robot = robots[mac] = FoundRobot(mac, names(mac) or "EV3", True)
        robot.paired = True
        robot.com_port = com
    for mac in last_used:
        if normalize_mac(mac) in robots:
            robots[normalize_mac(mac)].last_used = True
    if scan_error is not None and not robots:
        raise scan_error
    return sorted(robots.values(), key=lambda r: (
        not r.last_used, r.distance_m is None, r.distance_m or 0.0, r.name))


# ---------------------------------------------------------------------------
# Pairing and connecting
# ---------------------------------------------------------------------------

def pair(mac: str, pin: str = DEFAULT_PIN, *, runner: Runner = run_helper) -> Dict[str, Any]:
    return runner(["pair", "--mac", normalize_mac(mac), "--pin", str(pin), "--timeout", str(PAIR_TIMEOUT_S)],
                  PAIR_TIMEOUT_S + 15.0)


def repair(mac: str, pin: str = DEFAULT_PIN, *, runner: Runner = run_helper) -> Dict[str, Any]:
    """Forget the robot and pair it again."""
    return runner(["repair", "--mac", normalize_mac(mac), "--pin", str(pin), "--timeout", str(PAIR_TIMEOUT_S)],
                  PAIR_TIMEOUT_S + 30.0)


def wait_for_com_port(mac: str, *, comports=None, sleep: Callable[[float], None] = time.sleep) -> Optional[str]:
    """After pairing: give Windows time to create the COM port, then look for it."""
    sleep(PORT_SETTLE_S)
    for attempt in range(PORT_RESCANS):
        com = lego_com_ports(comports).get(normalize_mac(mac))
        if com:
            return com
        if attempt + 1 < PORT_RESCANS:
            sleep(PORT_RESCAN_INTERVAL_S)
    return None


#: Connection failures that, for a robot the radio can hear, point at a stale pairing.
_STALE_PAIRING_CODES = ("OPEN_TIMEOUT", "OPEN_FAILED", "NO_REPLY", "PORT_MISSING")


@dataclass
class ConnectResult:
    driver: Ev3DirectDriver
    steps: List[str] = field(default_factory=list)   # what was done, for the log and the UI


def connect_ev3(
    robot: FoundRobot,
    pin: str = DEFAULT_PIN,
    *,
    runner: Runner = run_helper,
    comports=None,
    link_factory: Callable[[str], Ev3Link] = Ev3Link,
    sleep: Callable[[float], None] = time.sleep,
    on_stage: Optional[Callable[[str], None]] = None,
) -> ConnectResult:
    """Everything between "the child clicked this robot" and a connected driver.

    1. Not paired: pair with the PIN (the child confirms on the brick), wait for
       the COM port.
    2. Paired but Windows has no COM port for it: the pairing is stale; forget
       the robot and pair again.
    3. Connect. If that fails and the radio heard the robot during the scan,
       the robot is there but the pairing is not working: forget, pair again,
       connect once more. If the radio did not hear it, it is off or away: say
       so, and forget nothing.
    """
    steps: List[str] = []

    def stage(code: str) -> None:
        steps.append(code)
        if on_stage:
            on_stage(code)

    def ensure_paired(force_repair: bool) -> str:
        if force_repair:
            stage("repairing")
            result = repair(robot.mac, pin, runner=runner)
        else:
            stage("pairing")
            result = pair(robot.mac, pin, runner=runner)
        if not result.get("ok"):
            raise ev3_error("PAIRING_FAILED", "%s: %s" % (robot.mac, result.get("status") or result.get("error")))
        robot.paired = True
        stage("waiting_for_port")
        com = wait_for_com_port(robot.mac, comports=comports, sleep=sleep)
        if not com:
            raise ev3_error("PORT_NOT_CREATED", "%s: paired, but Windows made no COM port" % robot.mac)
        robot.com_port = com
        return com

    com = robot.com_port or lego_com_ports(comports).get(robot.mac, "")
    repaired = False
    if not robot.paired:
        com = ensure_paired(force_repair=False)
    elif not com:
        com = ensure_paired(force_repair=True)
        repaired = True

    # At most two connection attempts, with one repair between them: bounded,
    # so no failure can keep the child waiting forever.
    for attempt in (1, 2):
        stage("connecting")
        link = link_factory(com)
        try:
            link.connect()
        except Ev3Error as exc:
            if attempt == 2 or repaired or exc.code not in _STALE_PAIRING_CODES or not robot.heard:
                raise
            com = ensure_paired(force_repair=True)
            repaired = True
            continue
        driver = Ev3DirectDriver(com, mac=robot.mac, name=robot.name,
                                 proximity={"rssi_dbm": robot.rssi_dbm, "distance_m": robot.distance_m},
                                 link=link)
        stage("inspecting")
        driver.refresh_ports()
        stage("connected")
        return ConnectResult(driver, steps)
    raise ev3_error("OPEN_FAILED", "%s: no connection attempt left" % robot.mac)  # not reached
