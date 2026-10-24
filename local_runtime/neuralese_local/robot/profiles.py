"""What the child told us about each robot, remembered between sessions.

A robot reports its ports and devices itself, but not how it is built: which
motor turns the left wheel, which way each sonar points, a name the child gave
it. That is entered once in the robot editor and saved here, one small JSON
file per robot, keyed by the robot's own id (a Bluetooth address for an EV3),
so the next connection of the same robot comes back set up.

The directory is the client's to choose (Godot passes a folder under
``user://``); nothing here assumes where it is.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path
from typing import Any, Dict, Optional

from .errors import ERR_BAD_CONFIG, RobotError
from .ir import Geometry, validate_ir

PROFILE_SCHEMA_VERSION = 1


def profile_path(directory: Any, robot_id: str) -> Path:
    """One file per robot. Ids contain ':' and other characters a file name cannot."""
    readable = re.sub(r"[^A-Za-z0-9_-]+", "_", str(robot_id)).strip("_")[:48] or "robot"
    digest = hashlib.sha256(str(robot_id).encode("utf-8")).hexdigest()[:10]
    return Path(directory) / ("%s-%s.json" % (readable, digest))


def load_profile(directory: Any, robot_id: str) -> Optional[Dict[str, Any]]:
    """The saved profile, or None when there is none or it cannot be read.

    A damaged file must not stop the robot from being listed; the child simply
    sets it up again.
    """
    path = profile_path(directory, robot_id)
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    if not isinstance(data, dict) or data.get("robot_id") != robot_id:
        return None
    if int(data.get("schema_version", 0) or 0) > PROFILE_SCHEMA_VERSION:
        return None
    return data


def _write(directory: Any, robot_id: str, profile: Dict[str, Any]) -> None:
    path = profile_path(directory, robot_id)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".tmp")
        tmp.write_text(json.dumps(profile, indent=2, ensure_ascii=False), encoding="utf-8")
        os.replace(tmp, path)  # never leave a half-written profile behind
    except OSError as exc:
        raise RobotError("Could not save the robot's settings: %s" % exc, code=ERR_BAD_CONFIG) from exc


def save_profile(directory: Any, robot: Dict[str, Any]) -> Dict[str, Any]:
    """Save the user-entered parts of an IR dict. Returns what was saved.

    Mappings saved earlier for this robot are kept.
    """
    report = validate_ir(robot)
    report.raise_if_failed()
    robot_id = str(robot["robot_id"])
    previous = load_profile(directory, robot_id) or {}
    profile = {
        "schema_version": PROFILE_SCHEMA_VERSION,
        "robot_id": robot_id,
        "platform": str(robot.get("platform", "")),
        "name": str(robot.get("name", "")),
        "geometry": Geometry.from_dict(robot.get("geometry")).to_dict(),
        "mappings": dict(previous.get("mappings") or {}),
    }
    _write(directory, robot_id, profile)
    return profile


def load_mapping(directory: Any, robot_id: str, key: str) -> Optional[Dict[str, Any]]:
    """The mapping the child made for this robot and this model, if any."""
    profile = load_profile(directory, robot_id)
    if not profile:
        return None
    mapping = (profile.get("mappings") or {}).get(str(key))
    return mapping if isinstance(mapping, dict) else None


def save_mapping(directory: Any, robot_id: str, key: str, mapping: Dict[str, Any]) -> Dict[str, Any]:
    """Remember a mapping (neurons to sensors and wheels) for this robot and model.

    ``key`` names the model (its training dataset), so the next run of the same
    model on the same robot needs no mapping at all.
    """
    profile = load_profile(directory, robot_id)
    if profile is None:
        profile = {"schema_version": PROFILE_SCHEMA_VERSION, "robot_id": robot_id, "platform": "", "name": "",
                   "geometry": Geometry().to_dict(), "mappings": {}}
    mappings = dict(profile.get("mappings") or {})
    mappings[str(key)] = dict(mapping)
    profile["mappings"] = mappings
    _write(directory, robot_id, profile)
    return profile


def apply_profile(robot: Dict[str, Any], profile: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """A discovered robot with its saved name and geometry filled in.

    The ports always come from the robot as it is now. A saved sensor position
    or wheel motor whose port no longer holds that kind of device is dropped,
    so a rebuilt robot is never driven with a stale geometry.
    """
    out = dict(robot)
    out["profile_saved"] = profile is not None
    if not profile:
        return out
    if profile.get("name"):
        out["name"] = str(profile["name"])
    geometry = Geometry.from_dict(profile.get("geometry"))
    devices = {str(p.get("id")): str(p.get("device", "")) for p in robot.get("ports") or [] if isinstance(p, dict)}
    geometry.sensors = {port: pose for port, pose in geometry.sensors.items()
                        if devices.get(port) and not devices[port].endswith("motor")}
    drive = geometry.drive
    if drive is not None and not all(devices.get(p, "").endswith("motor") for p in (drive.left_port, drive.right_port)):
        geometry.drive = None
    sides = geometry.drive_sides or {}
    if any(not devices.get(m["port"], "").endswith("motor") for side in sides.values() for m in side):
        geometry.drive_sides = None   # rebuilt: the wheel check has to be done again
    if geometry.heading and geometry.heading != "wheels" and devices.get(geometry.heading) != "gyro":
        geometry.heading = ""
    out["geometry"] = geometry.to_dict()
    return out
