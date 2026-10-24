"""Maps, stand-in networks and a run helper for driving the Dummy like the window does.

The robot window (``scripts/robot/robot_panel.gd``, ``build_config``) turns the
child's drawing into a run configuration: rays between the placed sonars, scaled
so they reach as far as the rover's rays at the robot's size; speed, rotation,
place and goal from the wheels (and the gyro) in the training world shrunk to the
robot's size; steering and throttle to the wheels found by the wheel check.
:func:`window_config` builds the same configuration here, so a run on the Dummy
is a run of what the window would start.

The networks are stand-ins with a known policy (head for the goal, steer away
from what the rays see close), as a Python engine and as a real ONNX model, so a
failure means the mapping is wrong, not that a network was badly trained.
"""

from __future__ import annotations

import math
from pathlib import Path
from typing import Any, Dict, List, Optional, Sequence, Tuple

from support import CAR_TRACK_RAY_ANGLES, KIRISIMA_SONARS, FakeClock

from neuralese_local.robot.config import compile_config
from neuralese_local.robot.drivers.dummy import DummyDriver, DummyHardware, DummyWorld
from neuralese_local.robot.ir import DriveGeometry, Geometry, SensorPose
from neuralese_local.robot.model_meta import InferenceEngine
from neuralese_local.robot.odometry import cm_per_unit_for, ray_reach_cm
from neuralese_local.robot.runtime import DriveLoop

#: KIRISIMA's length; the window's default for an EV3 drawing is close to it.
ROBOT_LENGTH_CM = 14.0
#: A world centred like the simulation's default one (SimulationKernel's bounds).
BOUNDS = [-480.0, -260.0, 960.0, 520.0]


# -- maps (Dummy coordinates: centimetres, y up, heading counter-clockwise) ----------

def room(*boxes: Tuple[float, float, float, float], start=(60.0, 150.0, 0.0), size=(400.0, 300.0)) -> DummyWorld:
    world = DummyWorld()
    world.add_box(0.0, 0.0, size[0], size[1])
    for box in boxes:
        world.add_box(*box)
    world.start = start
    return world


#: name -> (world, goal in Dummy centimetres)
MAPS: Dict[str, Tuple[DummyWorld, Tuple[float, float]]] = {
    "open_ahead": (room(), (330.0, 150.0)),
    "goal_to_the_left": (room(), (300.0, 250.0)),
    "goal_behind": (room(start=(300.0, 150.0, 0.0)), (70.0, 70.0)),
    "box_in_the_way": (room((170.0, 100.0, 60.0, 70.0)), (340.0, 150.0)),
    "zigzag": (room((130.0, 0.0, 30.0, 170.0), (250.0, 130.0, 30.0, 170.0), start=(50.0, 60.0, 0.0)), (350.0, 240.0)),
    "pillars": (room((120.0, 120.0, 30.0, 30.0), (200.0, 180.0, 30.0, 30.0), (200.0, 60.0, 30.0, 30.0), (280.0, 130.0, 30.0, 30.0)),
                (360.0, 150.0)),
    "big_room_far_goal": (room((250.0, 150.0, 100.0, 100.0), (450.0, 50.0, 60.0, 200.0), size=(700.0, 400.0), start=(60.0, 200.0, 0.0)),
                          (640.0, 330.0)),
}


def godot_point(world: DummyWorld, point: Tuple[float, float], cm_per_unit: float) -> List[float]:
    """A point of the room in the training world: the rover starts at the
    origin facing +x, and Godot's y points down where the room's points up."""
    sx, sy, heading = world.start
    dx, dy = point[0] - sx, point[1] - sy
    h = math.radians(heading)
    forward = dx * math.cos(h) + dy * math.sin(h)
    left = -dx * math.sin(h) + dy * math.cos(h)
    return [forward / cm_per_unit, -left / cm_per_unit]


# -- the window's configuration ------------------------------------------------------

#: The sim_top_down_full dataset: 8 rays, speed, the local way to the goal; steer, throttle, brake.
FULL_INPUTS = ["ray"] * 8 + ["speed", "local_goal_x", "local_goal_y"]
FULL_OUTPUTS = ["steering", "throttle", "brake"]


def window_config(
    *,
    inputs: Sequence[str] = FULL_INPUTS,
    outputs: Sequence[str] = FULL_OUTPUTS,
    sonars: Sequence[Tuple[str, float]] = KIRISIMA_SONARS,
    sides: Optional[Dict[str, List[Tuple[str, bool]]]] = None,
    heading: str = "wheels",
    world: Optional[DummyWorld] = None,
    goal: Optional[Tuple[float, float]] = None,
    hardware: Optional[DummyHardware] = None,
    robot_length_cm: float = ROBOT_LENGTH_CM,
    ray_angles: Optional[Sequence[float]] = None,
) -> Dict[str, Any]:
    """What ``RobotPanel.build_config`` starts a run with, for the Dummy.

    ``inputs`` lists the network's inputs in order: ``"ray"`` or a pose quantity.
    ``sides`` is the wheel check's answer: side -> [(motor port, reversed)].
    """
    hardware = hardware or DummyHardware()
    sides = sides or {"left": [("outD", False)], "right": [("outB", False)]}
    cm_per_unit = cm_per_unit_for(robot_length_cm)
    reach_mm = ray_reach_cm(cm_per_unit) * 10.0
    sources = [{"channel": "%s.distance_mm" % port, "angle_deg": angle} for port, angle in sorted(sonars)]
    scale = {"kind": "linear", "in_min": 0, "in_max": reach_mm, "out_min": 0.0, "out_max": 1.0}
    angles = list(ray_angles) if ray_angles is not None else [66.0 - i * 132.0 / 7.0 for i in range(8)]
    config_inputs: List[Dict[str, Any]] = []
    ray = 0
    for name in inputs:
        if name == "ray":
            angle = angles[ray] if ray < len(angles) else 0.0
            ray += 1
            config_inputs.append({"derive": "ray", "angle_deg": angle, "sources": [dict(s) for s in sources], "scale": dict(scale)})
        else:
            config_inputs.append({"derive": "pose", "quantity": name})
    output: Dict[str, Any] = {
        "mode": "drive",
        "channels": [[port + ".power" for port, _ in sides["left"]], [port + ".power" for port, _ in sides["right"]]],
        "invert": [[rev for _, rev in sides["left"]], [rev for _, rev in sides["right"]]],
        "steer_index": list(outputs).index("steering") if "steering" in outputs else -1,
        "throttle_index": list(outputs).index("throttle") if "throttle" in outputs else -1,
        "throttle_scale": 100.0,
    }
    if "brake" in outputs:
        output["brake_index"] = list(outputs).index("brake")
    user = Geometry(
        sensors={port: SensorPose(angle) for port, angle in sonars},
        drive=DriveGeometry(sides["left"][0][0], sides["right"][0][0], sides["left"][0][1], sides["right"][0][1]),
    )
    robot = DummyDriver(hardware=hardware, geometry=user).inventory().to_dict()
    config: Dict[str, Any] = {
        "schema_version": 1,
        "platform": "dummy",
        "robot": robot,
        "transport": {"kind": "virtual", "seed": 1},
        "rate_hz": 20,
        "watchdog_ms": 400,
        "inputs": config_inputs,
        "outputs": [output],
    }
    # The wheels always travel with the run: the window draws the room from
    # where they say the robot is, and a network that takes its movement reads them.
    world = world or room()
    config["world"] = {"cm_per_unit": cm_per_unit, "bounds": list(BOUNDS), "start": [0.0, 0.0, 0.0]}
    if goal is not None:
        config["world"]["goal"] = godot_point(world, goal, cm_per_unit)
    gyro = next((port for port, device in hardware.ports.items() if device == "gyro"), "")
    config["odometry"] = {
        "left": [{"channel": port + ".position_deg", "invert": rev} for port, rev in sides["left"]],
        "right": [{"channel": port + ".position_deg", "invert": rev} for port, rev in sides["right"]],
        "wheel_diameter_cm": hardware.wheel_diameter_cm,
        "track_cm": hardware.effective_track_cm,
        "heading": {"source": "gyro", "channel": gyro + ".angle_deg"} if heading == "gyro" else {"source": "wheels"},
    }
    return config


# -- stand-in networks ------------------------------------------------------------------

def goal_seeking_policy(values: Sequence[float], layout: Sequence[str], angles: Optional[Sequence[float]] = None) -> List[float]:
    """What a network trained to reach the goal does, written out: of the
    directions its rays see clear, take the one closest to the goal; with
    nothing clear, turn towards the more open side. Without rays, head straight
    for the goal; without a goal, take the clearest way. Returns steer,
    throttle, brake (steer > 0 turns right, ray angles are positive to the left).
    """
    rays = [values[i] for i, name in enumerate(layout) if name == "ray"]
    angles = list(angles) if angles is not None else [66.0 - i * 132.0 / max(len(rays) - 1, 1) for i in range(len(rays))]
    value = {name: values[i] for i, name in enumerate(layout) if name != "ray"}
    goal_angle = 0.0
    if "local_goal_y" in value:
        gx, gy = value.get("local_goal_x", 1.0), value["local_goal_y"]
        goal_angle = math.degrees(math.atan2(-gy, gx))       # positive to the left
    if not rays:
        return [max(-1.0, min(1.0, -goal_angle / 45.0)), 0.6, 0.0]
    # A way is clear when its ray and both neighbours see far enough for the body to pass.
    clear = []
    for i, (angle, ray) in enumerate(zip(angles, rays)):
        neighbours = rays[max(i - 1, 0): i + 2]
        if ray > 0.75 and min(neighbours) > 0.55:
            clear.append((abs(angle - goal_angle), angle))
    half = len(rays) // 2
    left, right = min(rays[:half]), min(rays[len(rays) - half:])
    if clear:
        _, angle = min(clear)
        # Arcs, not spins: below the drive conversion's turn lock (0.55) the
        # robot keeps rolling forward while it turns.
        steer = max(-0.5, min(0.5, -angle / 60.0))
        throttle = 0.65 if abs(angle) < 30.0 else 0.5
    else:
        steer = 1.0 if sum(rays[len(rays) - half:]) > sum(rays[:half]) else -1.0
        throttle = 0.2
    # Something right beside the robot: turn away from it first.
    if min(left, right) < 0.45:
        steer = 0.5 if right > left else -0.5
    return [steer, throttle, 0.0]


class PolicyEngine(InferenceEngine):
    def __init__(self, layout: Sequence[str] = FULL_INPUTS, outputs: Sequence[str] = FULL_OUTPUTS) -> None:
        self.layout = list(layout)
        self.outputs = list(outputs)
        self.calls: List[List[float]] = []

    def infer(self, values: Sequence[float]) -> List[float]:
        self.calls.append([float(v) for v in values])
        steer, throttle, brake = goal_seeking_policy(values, self.layout)
        by_name = {"steering": steer, "throttle": throttle, "brake": brake}
        return [by_name.get(name, 0.0) for name in self.outputs]


def linear_goal_model(path: Path, layout: Sequence[str] = FULL_INPUTS, outputs: Sequence[str] = FULL_OUTPUTS) -> Path:
    """A real ONNX model, ``tanh(x W + b)``: steers towards the goal and away
    from the side whose rays see closer; constant throttle; no brake."""
    import numpy as np  # type: ignore
    import onnx  # type: ignore
    from onnx import TensorProto, helper, numpy_helper  # type: ignore

    n_in, n_out = len(layout), len(outputs)
    weights = np.zeros((n_in, n_out), dtype=np.float32)
    bias = np.zeros((n_out,), dtype=np.float32)
    rays = [i for i, name in enumerate(layout) if name == "ray"]
    if "steering" in outputs:
        steer = list(outputs).index("steering")
        half = len(rays) // 2
        for i in rays[:half]:
            weights[i, steer] = -1.2 / max(half, 1)       # close on the left -> value small -> less "left" pull
        for i in rays[len(rays) - half:]:
            weights[i, steer] = 1.2 / max(half, 1)
        if "local_goal_y" in layout:
            weights[list(layout).index("local_goal_y"), steer] = 2.0
    if "throttle" in outputs:
        bias[list(outputs).index("throttle")] = float(np.arctanh(0.6))
    graph = helper.make_graph(
        [
            helper.make_node("MatMul", ["input", "W"], ["xw"]),
            helper.make_node("Add", ["xw", "b"], ["z"]),
            helper.make_node("Tanh", ["z"], ["output"]),
        ],
        "goal_seeker",
        [helper.make_tensor_value_info("input", TensorProto.FLOAT, [1, n_in])],
        [helper.make_tensor_value_info("output", TensorProto.FLOAT, [1, n_out])],
        initializer=[numpy_helper.from_array(weights, "W"), numpy_helper.from_array(bias, "b")],
    )
    model = helper.make_model(graph, opset_imports=[helper.make_opsetid("", 13)])
    model.ir_version = 8
    onnx.checker.check_model(model)
    onnx.save(model, str(path))
    return path


# -- a run --------------------------------------------------------------------------------

def drive(driver: DummyDriver, config: Dict[str, Any], engine: InferenceEngine, *,
          goal: Optional[Tuple[float, float]] = None, seconds: float = 60.0, reach_cm: float = 22.0) -> Dict[str, Any]:
    """Drive until the goal is reached (or ``seconds`` pass), 20 times a second.

    Returns what happened: reached, when, bumps (ticks pushing against a wall),
    the last record and the Dummy's trail.
    """
    clock = FakeClock(0.0)
    driver.open(clock())
    loop = DriveLoop(driver, compile_config(config), engine, clock=clock)
    loop.start()
    bumps = 0
    record: Dict[str, Any] = {}
    reached_at: Optional[float] = None
    steps = int(seconds * 20)
    for step in range(steps):
        clock.advance(0.05)
        record = loop.tick()
        bumps += 1 if driver.bumped else 0
        if goal is not None and math.hypot(driver.x - goal[0], driver.y - goal[1]) < reach_cm:
            reached_at = clock.now
            break
    loop.halt()
    return {"reached": reached_at is not None, "seconds": reached_at, "bumps": bumps, "record": record,
            "trail": list(driver.trail), "pose": driver.pose()}
