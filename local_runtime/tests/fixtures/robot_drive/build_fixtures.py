#!/usr/bin/env python3
"""Rebuild the drive-controller fixtures from the robotics prototype.

    python build_fixtures.py --prototype D:/NRLSE/nnets/neuralese-robotics-prototype

The expected outputs in these fixtures are produced by the prototype's own
``AdaptiveRobotController`` (imported, not copied), so the test compares the
port in ``neuralese_local/robot/drive.py`` against the code that actually drove
the robot. Rerun only when the prototype or its logs change; the files record
the prototype commit and the sha256 of every log they were built from.

Outputs, next to this script:

* ``kirisima_runs.json.gz`` -- the two recorded EV3 runs: the controller inputs
  and clock of every frame, what the robot logged, and what the prototype
  controller returns when replayed on that clock.
* ``random_sequences.json.gz`` -- seeded input sequences that cross every
  threshold of the controller, with the prototype controller's outputs.
* ``kirisima_sensors.json.gz`` -- the three ultrasonic readings of every
  recorded frame and the eight model rays the prototype's ``SensorAdapter3to8``
  builds from them (the input side of the same pipeline).
* ``car_brain.onnx`` -- the model the robot ran (8 rays -> steer, throttle),
  trained on Neuralese's ``car_track`` dataset.
* ``kirisima_lidar.json.gz`` -- every frame of the two runs as the lidar map
  takes it (tests/godot/test_robot_lidar_map.gd): time, the logged pose in
  metres and the usual maths angle, and the three ranges in metres.
"""

from __future__ import annotations

import argparse
import gzip
import hashlib
import json
import math
import random
import subprocess
import sys
import types
from pathlib import Path

HERE = Path(__file__).resolve().parent

LOGS = ("datalog_20261007_222935.jsonl", "datalog_20261007_223501.jsonl")

#: The prototype builds its controller before the start beeps, at least 0.3 s
#: before the loop clock starts, so its first call sees dt clamped to 0.1 s.
#: Replays construct the controller at this time on the log's own clock.
INIT_TIME = -1.0

STATUS_CODES = {
    "Вперёд": "forward",
    "Руление (Влево)": "steer_left",
    "Руление (Вправо)": "steer_right",
    "↩ РАЗВОРОТ ВЛЕВО": "spin_left",
    "↪ РАЗВОРОТ ВПРАВО": "spin_right",
    "Обход стены влево": "wall_bypass_left",
    "Обход стены вправо": "wall_bypass_right",
}


class _Clock:
    def __init__(self) -> None:
        self.t = 0.0

    def __call__(self) -> float:
        return self.t


def _load_prototype_module(prototype: Path):
    sys.path.insert(0, str(prototype))
    # Imported at module level by the prototype script, unused by the parts we call.
    sys.modules.setdefault("onnxruntime", types.ModuleType("onnxruntime"))
    import run_real_model_drive as module  # type: ignore

    return module


def _load_prototype_controller(prototype: Path):
    module = _load_prototype_module(prototype)
    clock = _Clock()
    module.time.monotonic = clock
    return module.AdaptiveRobotController, clock


def _git_state(prototype: Path) -> dict:
    def run(*args: str) -> str:
        return subprocess.run(["git", "-C", str(prototype), *args], capture_output=True, text=True).stdout.strip()

    return {"commit": run("rev-parse", "HEAD"), "dirty_files": run("status", "--porcelain", "--", "run_real_model_drive.py", "logs")}


def _replay(controller_cls, clock, inputs, init_time):
    """inputs: [[t, steer, throttle_pct, left, center, right], ...] -> prototype outputs."""
    clock.t = init_time
    ctrl = controller_cls()
    out = []
    for t, steer, throttle_pct, left, center, right in inputs:
        clock.t = t
        ml, mr, info = ctrl.compute(steer, throttle_pct, center, left, right)
        out.append([ml, mr, info["turn_lock_dir"], info["target_left"], info["target_right"],
                    info["v_forward"], info["v_turn"], info["throttle_governor"], STATUS_CODES[info["status"]]])
    return out


def build_runs(prototype: Path, controller_cls, clock) -> dict:
    runs = []
    for name in LOGS:
        path = prototype / "logs" / name
        raw = path.read_bytes()
        header = None
        frames = []
        for line in raw.decode("utf-8").splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get("_record_type") == "session_header":
                header = rec
                continue
            mo, sn, c, m = rec["model_output"], rec["sensors_norm"], rec["controller"], rec["motors"]
            frames.append([
                rec["step"], rec["timestamp_s"], rec["dt_ms"],
                mo["steer"], mo["throttle_pct"], sn["left"], sn["center"], sn["right"],
                c["turn_lock_dir"], c["target_left"], c["target_right"], m["left"], m["right"],
                STATUS_CODES[c["status"]],
            ])
        inputs = [[f[1], f[3], f[4], f[5], f[6], f[7]] for f in frames]
        runs.append({
            "name": name,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "header": header,
            "frame_fields": ["step", "timestamp_s", "dt_ms", "steer", "throttle_pct", "left", "center", "right",
                             "logged_turn_lock_dir", "logged_target_left", "logged_target_right",
                             "logged_motor_left", "logged_motor_right", "logged_status"],
            "frames": frames,
            "prototype_fields": ["motor_left", "motor_right", "turn_lock_dir", "target_left", "target_right",
                                 "v_forward", "v_turn", "throttle_governor", "status"],
            "prototype": _replay(controller_cls, clock, inputs, INIT_TIME),
        })
    return {"init_time": INIT_TIME, "runs": runs}


def _random_sequence(rng: random.Random, steps: int) -> list:
    t = 1000.0
    seq = []
    steer = 0.0
    throttle = 50.0
    for _ in range(steps):
        # Time steps below 10 ms, inside, and above 100 ms exercise both dt clamps.
        t += rng.choice([0.0, 0.004, 0.02, 0.05, 0.05, 0.05, 0.07, 0.12, 0.3, rng.uniform(0.0, 0.2)])
        kind = rng.random()
        if kind < 0.15:
            pass  # hold the previous output, as a model does on a quiet stretch
        elif kind < 0.40:
            # Values right at the controller's thresholds.
            steer = rng.choice([1, -1]) * rng.choice([0.25, 0.2499, 0.2501, 0.4, 0.55, 0.5499, 0.5501, 0.85, 1.0, 0.0])
        else:
            steer = rng.uniform(-1.0, 1.0)
        throttle = rng.choice([0.0, 25.0, 100.0, rng.uniform(0.0, 100.0), rng.uniform(0.0, 100.0)])
        # Some frames with something close straight ahead, so the prototype's
        # wall-bypass branch fires and is captured in the expected outputs.
        center = rng.choice([1.0, rng.uniform(0.0, 1.0), rng.uniform(0.0, 0.5), 0.49, 0.5])
        left = rng.choice([rng.uniform(0.0, 1.0), center, 1.0])
        right = rng.choice([rng.uniform(0.0, 1.0), center, 1.0])
        seq.append([round(t, 6), steer, throttle, left, center, right])
    return seq


def build_random(controller_cls, clock, seeds=range(20), steps=500) -> dict:
    sequences = []
    for seed in seeds:
        rng = random.Random(seed)
        inputs = _random_sequence(rng, steps)
        sequences.append({
            "seed": seed,
            "init_time": inputs[0][0] - 1.0,
            "inputs": inputs,
            "prototype": _replay(controller_cls, clock, inputs, inputs[0][0] - 1.0),
        })
    return {
        "input_fields": ["t", "steer", "throttle_pct", "left", "center", "right"],
        "prototype_fields": ["motor_left", "motor_right", "turn_lock_dir", "target_left", "target_right",
                             "v_forward", "v_turn", "throttle_governor", "status"],
        "sequences": sequences,
    }


def build_sensors(prototype: Path) -> dict:
    """Raw ultrasonic readings -> the prototype's eight model rays, per frame."""
    module = _load_prototype_module(prototype)
    adapter = module.SensorAdapter3to8
    runs = []
    for name in LOGS:
        frames = []
        for line in (prototype / "logs" / name).read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get("_record_type") == "session_header":
                continue
            raw = rec["sensors_raw_cm"]
            left, center, right = raw["left_p4"], raw["center_p3"], raw["right_p2"]
            rays = [float(v) for v in adapter.transform(left, center, right)]
            frames.append([rec["step"], left, center, right, rays, rec["rays_8"]])
        runs.append({"name": name, "frames": frames})
    return {
        "frame_fields": ["step", "left_p4_cm", "center_p3_cm", "right_p2_cm", "prototype_rays", "logged_rays"],
        "sensor_angles_deg": {"left_p4": 45.0, "center_p3": 0.0, "right_p2": -45.0},
        "ray_angles_deg": [round(float(a), 6) for a in module.QUERY_ANGLES_ASC[::-1]],
        "max_distance_cm": module.MAX_DISTANCE_CM,
        "runs": runs,
    }


def build_lidar(prototype: Path) -> dict:
    """The logged pose and the three ranges of every frame, in the lidar map's units.

    The prototype's ``OdometryTracker`` dead-reckons from the motor commands;
    its heading is 0 along +y and grows clockwise, so the maths angle from +x
    is pi/2 - heading. Rounded as the lidar mockup's page packs them
    (prototypes/lidar/build_lidar_page.py), so its metrics are the reference.
    """
    runs = []
    for name in LOGS:
        raw = (prototype / "logs" / name).read_bytes()
        frames = []
        angles = None
        for line in raw.decode("utf-8").splitlines():
            if not line.strip():
                continue
            rec = json.loads(line)
            if rec.get("_record_type") == "session_header":
                angles = rec["sensor_angles_deg"]
                continue
            s, o = rec["sensors_raw_cm"], rec["odometry"]
            frames.append([
                round(rec["timestamp_s"], 3),
                round(o["x_cm"] / 100, 4), round(o["y_cm"] / 100, 4),
                round(math.pi / 2 - math.radians(o["heading_deg"]), 4),
                round(s["left_p4"] / 100, 3), round(s["center_p3"] / 100, 3), round(s["right_p2"] / 100, 3),
            ])
        runs.append({
            "name": name,
            "sha256": hashlib.sha256(raw).hexdigest(),
            "sensor_angles_deg": [angles["left"], angles["center"], angles["right"]],
            "frames": frames,
        })
    return {
        "frame_fields": ["t_s", "x_m", "y_m", "angle_rad", "left_m", "center_m", "right_m"],
        "runs": runs,
    }


def _write(name: str, payload: dict) -> None:
    data = json.dumps(payload, ensure_ascii=False, separators=(",", ":"), sort_keys=True).encode("utf-8")
    # mtime=0 keeps the archive byte-identical across rebuilds.
    with gzip.GzipFile(HERE / name, "wb", compresslevel=9, mtime=0) as fh:
        fh.write(data)
    print("wrote %s (%d bytes json)" % (name, len(data)))


def main(argv: list) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--prototype", required=True, type=Path)
    args = parser.parse_args(argv)
    prototype = args.prototype.resolve()

    controller_cls, clock = _load_prototype_controller(prototype)
    provenance = {
        "prototype": _git_state(prototype),
        "source": "run_real_model_drive.py:AdaptiveRobotController",
        "builder": "local_runtime/tests/fixtures/robot_drive/build_fixtures.py",
    }

    runs = build_runs(prototype, controller_cls, clock)
    runs["provenance"] = provenance
    _write("kirisima_runs.json.gz", runs)

    random_payload = build_random(controller_cls, clock)
    random_payload["provenance"] = provenance
    _write("random_sequences.json.gz", random_payload)

    sensors = build_sensors(prototype)
    sensors["provenance"] = dict(provenance, source="run_real_model_drive.py:SensorAdapter3to8")
    _write("kirisima_sensors.json.gz", sensors)

    lidar = build_lidar(prototype)
    lidar["provenance"] = dict(provenance, source="run_real_model_drive.py:OdometryTracker")
    _write("kirisima_lidar.json.gz", lidar)

    model =(prototype / "models" / "car_brain.onnx").read_bytes()
    (HERE / "car_brain.onnx").write_bytes(model)
    print("copied car_brain.onnx sha256=%s" % hashlib.sha256(model).hexdigest())

    # Counted by the branch's condition, not by status: the forced steer (0.85)
    # always trips the turn lock, whose status overwrites the wall-bypass one.
    fired = sum(1 for s in random_payload["sequences"] for i in s["inputs"] if i[4] < 0.5 and abs(i[1]) < 0.25)
    print("frames meeting the wall-bypass condition in random sequences: %d" % fired)
    for run in runs["runs"]:
        hit = sum(1 for f in run["frames"] if f[6] < 0.5 and abs(f[3]) < 0.25)
        print("frames meeting the wall-bypass condition in %s: %d" % (run["name"], hit))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
