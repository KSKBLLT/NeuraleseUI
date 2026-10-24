"""``request.json`` -> ``response.json`` entry point for the Godot client.

Follows the same contract as ``export_yolk.py``: the client writes a request
file, runs this module with its path, and reads back a response with
``{"status": "ok"|"error", ...}``. All of the robot feature's read-only queries
go through here too, so the UI needs exactly one process-launch pattern for the
whole thing rather than one per screen.

Actions
-------
``list_platforms``   the whole registry: robots, sensors, motors, transports
``model_meta``       a trained model's input/output arity
``default_config``   a ready-to-run mapping, guessed from the model and dataset
``validate``         check a mapping, returning every problem at once
``preview_script``   the device program a mapping would produce, as text
``list_devices``     which robots are plugged in right now
``list_robots``      robots driven from the host (Dummy, stock EV3), as IR dicts
``save_robot_profile`` remember a robot's name and geometry for next time
``export``           write the bundle (the default action)
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from neuralese_local.robot import config as config_mod
from neuralese_local.robot import platforms as platforms_mod
from neuralese_local.robot import profiles as profiles_mod
from neuralese_local.robot import transport as transport_mod
from neuralese_local.robot.bundle import write_bundle
from neuralese_local.robot.codec import PROTOCOL_VERSION
from neuralese_local.robot.errors import ERR_BAD_CONFIG, ERR_EXPORT_FAILED, RobotError, ValidationReport
from neuralese_local.robot.generate import generate_script_for_plan
from neuralese_local.robot.model_meta import read_model_meta


def _model_meta_or_empty(request: Dict[str, Any]) -> Dict[str, Any]:
    """Model shape when a model path was given, otherwise nothing.

    Read-only actions stay usable without a trained model so the UI can show the
    mapping screen before the child has trained anything.
    """
    model_path = request.get("model_path")
    if not model_path:
        return {}
    return read_model_meta(model_path)


def action_list_platforms(request: Dict[str, Any]) -> Dict[str, Any]:
    return {
        "status": "ok",
        "protocol_version": PROTOCOL_VERSION,
        "platforms": platforms_mod.list_platforms(),
    }


def action_model_meta(request: Dict[str, Any]) -> Dict[str, Any]:
    meta = read_model_meta(request["model_path"])
    return {"status": "ok", "model": meta}


def action_default_config(request: Dict[str, Any]) -> Dict[str, Any]:
    platform_id = str(request.get("platform", ""))
    meta = _model_meta_or_empty(request)
    report = ValidationReport()
    config = config_mod.default_config(
        platform_id,
        meta,
        request.get("train_signature") or {},
        report=report,
    )
    # Run the real validator over the guess too: a model with more inputs than
    # the robot has sensors produces a config the child must fix, and they
    # should be told that on the mapping screen, not at export time.
    checks = config_mod.validate_config(config, meta)
    return {
        "status": "ok",
        "config": config,
        "config_hash": config_mod.config_hash(config),
        "model": meta,
        "validation": {
            "ok": checks.ok,
            "errors": checks.errors,
            "warnings": checks.warnings + report.warnings,
        },
    }


def action_validate(request: Dict[str, Any]) -> Dict[str, Any]:
    config = request.get("config") or {}
    meta = _model_meta_or_empty(request)
    report = config_mod.validate_config(config, meta)
    return {
        "status": "ok",
        "validation": report.to_dict(),
        "config_hash": config_mod.config_hash(config) if report.ok else "",
        "model": meta,
    }


def action_preview_script(request: Dict[str, Any]) -> Dict[str, Any]:
    _refuse_for_ir(request, "program")
    config = request.get("config") or {}
    meta = _model_meta_or_empty(request)
    plan = config_mod.compile_config(config, meta)
    return {
        "status": "ok",
        "filename": plan.platform.script_filename,
        "script": generate_script_for_plan(plan),
        "config_hash": config_mod.config_hash(config),
    }


def action_list_devices(request: Dict[str, Any]) -> Dict[str, Any]:
    return {"status": "ok", "devices": transport_mod.list_available_devices(str(request.get("platform", "")))}


def action_list_robots(request: Dict[str, Any]) -> Dict[str, Any]:
    """Every robot that can be connected now, as IR dicts, across IR families.

    With ``profiles_dir``, each robot comes back with the name and geometry the
    child saved for it last time (``profile_saved`` says whether there was one).
    """
    profiles_dir = request.get("profiles_dir")
    robots: List[Dict[str, Any]] = []
    for family in platforms_mod.list_ir_platforms():
        for robot in transport_mod.list_ir_robots(family["id"])["robots"]:
            if profiles_dir:
                robot = profiles_mod.apply_profile(robot, profiles_mod.load_profile(profiles_dir, robot["robot_id"]))
            robots.append(robot)
    return {"status": "ok", "platforms": platforms_mod.list_ir_platforms(), "robots": robots}


def action_save_robot_profile(request: Dict[str, Any]) -> Dict[str, Any]:
    """Remember a robot's name and geometry for its next connection."""
    profile = profiles_mod.save_profile(str(request["profiles_dir"]), request.get("robot") or {})
    return {"status": "ok", "profile": profile}


def _refuse_for_ir(request: Dict[str, Any], what: str) -> None:
    platform_id = str(request.get("platform") or (request.get("config") or {}).get("platform", ""))
    if platforms_mod.is_ir_platform(platform_id):
        raise RobotError(
            "This robot is driven directly from Neuralese; there is no %s to copy onto it." % what,
            code=ERR_BAD_CONFIG,
            field="platform",
        )


def action_export(request: Dict[str, Any]) -> Dict[str, Any]:
    _refuse_for_ir(request, "program")
    model_path = Path(str(request["model_path"]))
    output_path = Path(str(request["output_path"]))
    meta = read_model_meta(model_path)

    warnings: List[Dict[str, Any]] = []
    config = request.get("config")
    if not config:
        report = ValidationReport()
        config = config_mod.default_config(
            str(request.get("platform", "")),
            meta,
            request.get("train_signature") or {},
            report=report,
        )
        warnings.extend(report.warnings)

    report = config_mod.validate_config(config, meta)
    warnings.extend(report.warnings)
    report.raise_if_failed()

    plan = config_mod.MappingPlan(config)
    result = write_bundle(
        plan,
        model_path,
        output_path,
        lang=str(request.get("lang", "en")),
        as_zip=bool(request.get("zip", False)),
        warnings=warnings,
    )
    result["model"] = meta
    return result


ACTIONS = {
    "list_platforms": action_list_platforms,
    "model_meta": action_model_meta,
    "default_config": action_default_config,
    "validate": action_validate,
    "preview_script": action_preview_script,
    "list_devices": action_list_devices,
    "list_robots": action_list_robots,
    "save_robot_profile": action_save_robot_profile,
    "export": action_export,
}


def handle_request(request: Dict[str, Any]) -> Dict[str, Any]:
    action = str(request.get("action", "export"))
    handler = ACTIONS.get(action)
    if handler is None:
        raise RobotError(
            "Unknown robot export action '%s'. Known: %s" % (action, ", ".join(sorted(ACTIONS))),
            code=ERR_BAD_CONFIG,
        )
    return handler(request)


def main(argv: List[str]) -> int:
    if len(argv) != 2:
        print("usage: export_robot.py <request.json>", file=sys.stderr)
        return 2

    request_path = Path(argv[1]).resolve()
    response_path = request_path.with_name("response.json")
    try:
        request = json.loads(request_path.read_text(encoding="utf-8-sig"))
        result = handle_request(request)
    except RobotError as exc:
        result = {"status": "error", "error": exc.message, **exc.to_dict()}
    except Exception as exc:
        result = {"status": "error", "error": str(exc), "code": ERR_EXPORT_FAILED, "message": str(exc)}

    text = json.dumps(result, indent=2, ensure_ascii=False)
    response_path.write_text(text, encoding="utf-8")
    if result.get("status") == "ok":
        print(text)
        return 0
    print(text, file=sys.stderr)
    return 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
