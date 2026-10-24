"""Sets up the open-source EV3 emulator used by the emulator test tier.

Two GitHub projects together give a genuine EV3 emulation that runs on an
ordinary desktop with no VM and no brick:

* ``ev3dev/ev3dev-lang-python`` -- the real ``ev3dev2`` library that runs on a
  real brick, unmodified.
* ``ddemidov/ev3dev-lang-fake-sys`` -- a fake ``/sys`` device tree. ``ev3dev2``
  drives motors and reads sensors by reading and writing sysfs attribute files,
  so pointing it at a directory of ordinary files makes every device call real:
  a motor command genuinely lands in ``.../motor0/command``.

That means the emulator tests run the *actual generated device script* against
the *actual* ev3dev library, and assert on what the motors were really told.

Checkouts are cached under ``local_runtime/.emulators``. Cloning is opt-in via
``NEURALESE_EMULATORS=1`` so an offline or sandboxed test run skips this tier
instead of hanging on the network; point ``NEURALESE_EMULATOR_DIR`` at an
existing checkout to run it without any download at all.
"""

from __future__ import annotations

import os
import shutil
import subprocess
import sys
from pathlib import Path
from typing import List, Optional, Tuple

RUNTIME_ROOT = Path(__file__).resolve().parents[2]
CACHE_DIR = Path(os.environ.get("NEURALESE_EMULATOR_DIR") or (RUNTIME_ROOT / ".emulators"))

EV3DEV_REPO = "https://github.com/ev3dev/ev3dev-lang-python.git"
FAKE_SYS_REPO = "https://github.com/ddemidov/ev3dev-lang-fake-sys.git"

EV3DEV_DIR = CACHE_DIR / "ev3dev-lang-python"
FAKE_SYS_DIR = CACHE_DIR / "ev3dev-lang-fake-sys"


class EmulatorUnavailable(Exception):
    """Raised when the emulator is not present and may not be fetched."""


def downloads_allowed() -> bool:
    return os.environ.get("NEURALESE_EMULATORS", "") not in ("", "0", "false", "no")


def _clone(repo: str, target: Path) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    result = subprocess.run(
        ["git", "clone", "--depth", "1", "--quiet", repo, str(target)],
        capture_output=True,
        text=True,
        timeout=180,
    )
    if result.returncode != 0:
        raise EmulatorUnavailable("Could not clone %s: %s" % (repo, result.stderr.strip()))


def ensure_emulator() -> Tuple[Path, Path]:
    """Return (ev3dev2 checkout, fake-sys checkout), cloning if allowed."""
    for repo, target in ((EV3DEV_REPO, EV3DEV_DIR), (FAKE_SYS_REPO, FAKE_SYS_DIR)):
        if target.exists():
            continue
        if not downloads_allowed():
            raise EmulatorUnavailable(
                "The EV3 emulator is not downloaded. Run with NEURALESE_EMULATORS=1 to "
                "fetch it from GitHub, or set NEURALESE_EMULATOR_DIR to a checkout."
            )
        _clone(repo, target)
    return EV3DEV_DIR, FAKE_SYS_DIR


#: Device layout the emulator test builds. Ports match the channel ids in the
#: platform registry (``touch_1`` is a touch sensor on input 1, and so on).
DEFAULT_DEVICES: List[Tuple[str, int, str]] = [
    ("large_motor", 0, "outA"),
    ("large_motor", 1, "outB"),
    ("touch_sensor", 0, "in1"),
    ("infrared_sensor", 1, "in4"),
]


class Ev3Arena:
    """A populated fake sysfs tree plus the imports that point at it."""

    def __init__(self, devices: Optional[List[Tuple[str, int, str]]] = None) -> None:
        self.devices = list(devices if devices is not None else DEFAULT_DEVICES)
        self.ev3dev_dir, self.fake_sys_dir = ensure_emulator()
        self.arena: Optional[Path] = None
        self._ev3dev2 = None

    def start(self):
        for path in (str(self.fake_sys_dir), str(self.ev3dev_dir)):
            if path not in sys.path:
                sys.path.insert(0, path)
        os.environ["FAKE_SYS"] = "1"

        arena = self.fake_sys_dir / "arena"
        if arena.exists():
            shutil.rmtree(arena)

        from populate_arena import populate_arena  # type: ignore

        populate_arena(self.devices)
        self.arena = arena

        # ev3dev2 decides whether an attribute file is writable from its *group*
        # permission bits, mirroring how udev sets sysfs up on a real brick. A
        # plain checkout is group-read-only, so without this every motor write
        # fails with "file not open for writing".
        subprocess.run(["chmod", "-R", "g+rw", str(arena)], check=False)

        import ev3dev2  # type: ignore

        ev3dev2.Device.DEVICE_ROOT_PATH = str(arena)
        self._patch_attribute_buffering(ev3dev2)
        self._ev3dev2 = ev3dev2
        return ev3dev2

    @staticmethod
    def _patch_attribute_buffering(ev3dev2) -> None:
        """Make file-backed attributes behave like sysfs ones.

        On a real brick an attribute write replaces the value. On disk it
        overwrites only the leading bytes, so writing "50" over "1000" leaves
        "5000". Upstream's own test suite solves it the same way -- append a
        newline on write, split on it when reading.
        """
        if getattr(ev3dev2.Device, "_neuralese_patched", False):
            return

        original_set = ev3dev2.Device._set_attribute
        original_get = ev3dev2.Device._get_attribute

        def _set_attribute(self, attribute, name, value):
            attribute = original_set(self, attribute, name, value)
            attribute.write(b"\n")
            return attribute

        def _get_attribute(self, attribute, name):
            attribute, value = original_get(self, attribute, name)
            return attribute, value.split("\n", 1)[0]

        ev3dev2.Device._set_attribute = _set_attribute
        ev3dev2.Device._get_attribute = _get_attribute
        ev3dev2.Device._neuralese_patched = True

    # -- reading what the script actually did --------------------------------

    def motor_path(self, index: int) -> Path:
        assert self.arena is not None
        return self.arena / "tacho-motor" / ("motor%d" % index)

    def sensor_path(self, index: int) -> Path:
        assert self.arena is not None
        return self.arena / "lego-sensor" / ("sensor%d" % index)

    @staticmethod
    def _read(path: Path) -> str:
        return path.read_text(encoding="utf-8").split("\n", 1)[0].strip()

    def motor_command(self, index: int) -> str:
        return self._read(self.motor_path(index) / "command")

    def motor_speed_sp(self, index: int) -> int:
        return int(self._read(self.motor_path(index) / "speed_sp") or 0)

    def set_sensor_value(self, index: int, value: int) -> None:
        """Move the emulated world: set what a sensor reports."""
        path = self.sensor_path(index) / "value0"
        path.write_text("%d\n" % value, encoding="utf-8")

    def stop(self) -> None:
        if self.arena is not None and self.arena.exists():
            shutil.rmtree(self.arena, ignore_errors=True)
        self.arena = None
