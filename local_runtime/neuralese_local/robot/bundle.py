"""Assembles the folder a child actually receives.

One export produces one folder holding everything needed to run the model on the
robot: the trained model, the device program, the mapping that ties them
together, and instructions. Keeping it to a single output path means the UI
wiring is identical to the existing ONNX and executable exports.
"""

from __future__ import annotations

import json
import shutil
import zipfile
from pathlib import Path
from typing import Any, Dict, List, Optional

from .config import config_hash, validate_config
from .generate import generate_script_for_plan
from .platforms import get_platform

CONFIG_FILENAME = "robot_config.json"
MODEL_FILENAME = "model.onnx"
README_FILENAME = "HOW_TO_USE.txt"


_DEPLOY_STEPS_EN = {
    "deploy_microbit": [
        "Open python.microbit.org in a browser.",
        "Open the file main.py from this folder there.",
        "Plug the micro:bit in with a USB cable and press Send to micro:bit.",
        "Come back to Neuralese and press Connect.",
    ],
    "deploy_ev3": [
        "Switch the EV3 on. It must be running ev3dev, not the LEGO firmware.",
        "Plug the EV3 into the computer with the USB cable.",
        "Copy neuralese_robot.py onto the brick (through the ev3dev file browser,",
        "  or with: scp neuralese_robot.py robot@ev3dev.local:~/).",
        "Start the program on the brick. It will say it is waiting.",
        "Come back to Neuralese and press Connect.",
    ],
    "deploy_spike": [
        "Install the Pybricks firmware on the hub once, from pybricks.com/install.",
        "Open code.pybricks.com and open main.py from this folder there.",
        "Plug the hub in with a USB cable and press Run.",
        "Come back to Neuralese and press Connect.",
    ],
}

_DEPLOY_STEPS_RU = {
    "deploy_microbit": [
        "Откройте python.microbit.org в браузере.",
        "Откройте там файл main.py из этой папки.",
        "Подключите micro:bit кабелем USB и нажмите «Send to micro:bit».",
        "Вернитесь в Neuralese и нажмите «Подключить».",
    ],
    "deploy_ev3": [
        "Включите EV3. На нём должен стоять ev3dev, а не прошивка LEGO.",
        "Подключите EV3 к компьютеру кабелем USB.",
        "Скопируйте neuralese_robot.py на блок (через файловый браузер ev3dev",
        "  или командой: scp neuralese_robot.py robot@ev3dev.local:~/).",
        "Запустите программу на блоке — она напишет, что ждёт подключения.",
        "Вернитесь в Neuralese и нажмите «Подключить».",
    ],
    "deploy_spike": [
        "Один раз установите прошивку Pybricks на хаб: pybricks.com/install.",
        "Откройте code.pybricks.com и откройте там main.py из этой папки.",
        "Подключите хаб кабелем USB и нажмите «Run».",
        "Вернитесь в Neuralese и нажмите «Подключить».",
    ],
}


def build_readme(plan, lang: str = "en") -> str:
    platform = plan.platform
    steps_key = str(platform.deploy.get("steps_key", ""))
    inputs = ", ".join(channel.label for channel in plan.input_channels)
    outputs = ", ".join(channel.label for channel in plan.output_channels)

    if lang == "ru":
        steps = _DEPLOY_STEPS_RU.get(steps_key, [])
        return "\n".join([
            "Ваша модель на роботе: %s" % platform.label,
            "=" * 48,
            "",
            "Что лежит в этой папке:",
            "  %-22s программа для робота" % platform.script_filename,
            "  %-22s обученная модель (её запускает компьютер)" % MODEL_FILENAME,
            "  %-22s какие датчики и моторы к чему подключены" % CONFIG_FILENAME,
            "",
            "Датчики, которые робот отправляет: %s" % (inputs or "—"),
            "Чем управляет модель: %s" % (outputs or "—"),
            "",
            "Как запустить:",
        ] + ["  %d. %s" % (i + 1, step) for i, step in enumerate(steps)] + [
            "",
            "Важно: сама нейросеть работает на компьютере, а не на роботе.",
            "Робот присылает показания датчиков, компьютер отвечает командами.",
            "Поэтому Neuralese должен оставаться открытым, пока робот работает.",
            "",
            "Безопасность: если связь пропадёт дольше чем на %d мс," % plan.watchdog_ms,
            "робот сам остановит все моторы.",
            "",
        ])

    steps = _DEPLOY_STEPS_EN.get(steps_key, [])
    return "\n".join([
        "Your model on a robot: %s" % platform.label,
        "=" * 48,
        "",
        "What is in this folder:",
        "  %-22s the program for the robot" % platform.script_filename,
        "  %-22s your trained model (the computer runs this)" % MODEL_FILENAME,
        "  %-22s which sensors and motors are connected to what" % CONFIG_FILENAME,
        "",
        "Sensors the robot sends: %s" % (inputs or "-"),
        "What the model controls: %s" % (outputs or "-"),
        "",
        "How to run it:",
    ] + ["  %d. %s" % (i + 1, step) for i, step in enumerate(steps)] + [
        "",
        "Note: the neural network runs on the computer, not on the robot. The",
        "robot sends sensor readings and the computer sends back commands, so",
        "Neuralese has to stay open while the robot is running.",
        "",
        "Safety: if the link goes quiet for more than %d ms, the robot stops" % plan.watchdog_ms,
        "all of its motors by itself.",
        "",
    ])


def write_bundle(
    plan,
    model_path: Any,
    output_path: Any,
    *,
    lang: str = "en",
    as_zip: bool = False,
    warnings: Optional[List[Dict[str, Any]]] = None,
) -> Dict[str, Any]:
    """Write the export folder (or zip) and describe what was written."""
    model_path = Path(model_path)
    output_path = Path(output_path)
    platform = get_platform(plan.config["platform"])

    folder = output_path.with_suffix("") if as_zip else output_path
    if folder.exists() and folder.is_dir():
        # Re-exporting into the same folder is the normal case: the child
        # retrains and exports again. Clear it so a stale model or a script for
        # a different mapping cannot survive alongside the new one.
        shutil.rmtree(folder)
    folder.mkdir(parents=True, exist_ok=True)

    script_path = folder / platform.script_filename
    script_path.write_text(generate_script_for_plan(plan), encoding="utf-8")

    bundled_model = folder / MODEL_FILENAME
    shutil.copy2(str(model_path), str(bundled_model))

    config_payload = dict(plan.config)
    config_payload["config_hash"] = config_hash(plan.config)
    (folder / CONFIG_FILENAME).write_text(
        json.dumps(config_payload, indent=2, ensure_ascii=False), encoding="utf-8"
    )

    (folder / README_FILENAME).write_text(build_readme(plan, lang=lang), encoding="utf-8")

    files = sorted(item.name for item in folder.iterdir())

    result: Dict[str, Any] = {
        "status": "ok",
        "platform": platform.id,
        "output_path": str(folder),
        "script_path": str(script_path),
        "config_path": str(folder / CONFIG_FILENAME),
        "model_path": str(bundled_model),
        "files": files,
        "config": config_payload,
        "config_hash": config_payload["config_hash"],
        "deploy": dict(platform.deploy),
        "warnings": list(warnings or []),
    }

    if as_zip:
        zip_path = output_path if str(output_path).endswith(".zip") else output_path.with_suffix(".zip")
        with zipfile.ZipFile(str(zip_path), "w", zipfile.ZIP_DEFLATED) as archive:
            for item in sorted(folder.iterdir()):
                archive.write(str(item), arcname=item.name)
        shutil.rmtree(folder)
        result["output_path"] = str(zip_path)
        result["zipped"] = True

    return result


def load_bundle_config(bundle_path: Any) -> Dict[str, Any]:
    """Read back a config from an exported folder, so a saved export can be
    reconnected later without re-exporting."""
    path = Path(bundle_path)
    if path.is_dir():
        path = path / CONFIG_FILENAME
    config = json.loads(path.read_text(encoding="utf-8"))
    validate_config(config).raise_if_failed()
    return config
