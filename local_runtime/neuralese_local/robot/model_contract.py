"""What a trained model's inputs and outputs *mean*, read from its training dataset.

The robot window needs to say "these eight inputs are rays, these two outputs
are steering and throttle" so the child can connect them to sensors and wheels.
Nothing has to be invented for that: the dataset the model was trained on
already carries its column names (``car_track`` names its inputs ``ray_0`` ...
``ray_7`` and its outputs ``steer``, ``throttle``; a dataset generated in the
simulation names every column after the sensor or actuator it came from, and
records the agent in ``metadata.binding``).

This module only *describes*. It never connects anything: which port is the left
motor cannot be guessed, so the child does that. What it adds is

* the meaning of each neuron (``kind``), used to group neurons and to highlight
  the robot parts that could take them;
* whether this model may run on a robot at all: a model trained with the
  side-view car (it learned a world seen from the side, with gravity, jumps and a
  speed sensor) is refused, and a model that is not trained yet is too;
* which neurons the robot cannot feed or drive yet, so the child is told before
  pressing Start instead of after a robot drives off.

All child-facing text is in English, Russian and Kazakh.
"""

from __future__ import annotations

import re
from typing import Any, Dict, List, Optional, Sequence, Tuple

#: The simulation's ray fan: ``ray_0`` is the leftmost, rays are spread evenly
#: over this arc (``simulation_canvas_draw.gd``: 132 degrees). The robotics
#: prototype used the same convention (66 ... -66).
RAY_ARC_DEG = 132.0

KIND_RAY = "ray"
KIND_SPEED = "speed"
KIND_STEER = "steer"
KIND_THROTTLE = "throttle"
KIND_BRAKE = "brake"
KIND_GOAL = "goal"
KIND_OTHER = "other"

PERSPECTIVE_TOP_DOWN = "top_down"
PERSPECTIVE_SIDE_VIEW = "side_view"
PERSPECTIVE_UNKNOWN = "unknown"

#: Simulation agents and the world they were trained in
#: (``simulation_definition_registry.gd``, ``compatible_perspective``).
AGENT_PERSPECTIVES = {
    "side_view_car": PERSPECTIVE_SIDE_VIEW,
    "flying_agent": PERSPECTIVE_SIDE_VIEW,
    "top_down_rover": PERSPECTIVE_TOP_DOWN,
}

#: What a robot's sensors and wheels can take today (models without a binding,
#: recognised by their column names only).
SUPPORTED_INPUT_KINDS = (KIND_RAY, KIND_SPEED)
SUPPORTED_OUTPUT_KINDS = (KIND_STEER, KIND_THROTTLE, KIND_BRAKE)

#: What each simulation sensor needs on the robot:
#:   sensors  distance sensors the child puts on the drawing
#:   wheels   the wheel check (encoders: speed, how far it went)
#:   heading  a gyro or the wheels (which way it faces)
#:   field    the robot's place in the training world (start position)
#:   goal     the field plus where the goal is
NEED_SENSORS = "sensors"
NEED_WHEELS = "wheels"
NEED_HEADING = "heading"
NEED_FIELD = "field"
NEED_GOAL = "goal"
SENSOR_NEEDS: Dict[str, Tuple[str, ...]] = {
    "ray_distance": (NEED_SENSORS,),
    "speed": (NEED_WHEELS,),
    "velocity_x": (NEED_WHEELS, NEED_HEADING),
    "velocity_y": (NEED_WHEELS, NEED_HEADING),
    "rotation": (NEED_HEADING,),
    "heading_sincos": (NEED_HEADING,),
    "normalized_position": (NEED_WHEELS, NEED_HEADING, NEED_FIELD),
    "gps": (NEED_WHEELS, NEED_HEADING, NEED_FIELD),
    "goal_vector": (NEED_WHEELS, NEED_HEADING, NEED_FIELD, NEED_GOAL),
    "goal_direction": (NEED_WHEELS, NEED_HEADING, NEED_FIELD, NEED_GOAL),
    "local_goal_direction": (NEED_WHEELS, NEED_HEADING, NEED_FIELD, NEED_GOAL),
    "goal_distance": (NEED_WHEELS, NEED_HEADING, NEED_FIELD, NEED_GOAL),
}
#: The pose quantity of each channel of a sensor (see odometry.SENSOR_QUANTITIES).
SENSOR_QUANTITIES: Dict[str, Tuple[str, ...]] = {
    "speed": ("speed",),
    "velocity_x": ("velocity_x",),
    "velocity_y": ("velocity_y",),
    "rotation": ("rotation",),
    "heading_sincos": ("heading_sin", "heading_cos"),
    "normalized_position": ("position_x", "position_y"),
    "gps": ("position_x", "position_y"),
    "goal_vector": ("goal_x", "goal_y"),
    "goal_direction": ("goal_x", "goal_y"),
    "local_goal_direction": ("local_goal_x", "local_goal_y"),
    "goal_distance": ("goal_distance",),
}
#: Simulation actuators -> what they do on a robot. ``ignored``: the rover does
#: not use them in the simulation either (only the flying agent does).
ACTUATOR_ROLES: Dict[str, str] = {
    "steering": KIND_STEER,
    "throttle": KIND_THROTTLE,
    "brake": KIND_BRAKE,
    "horizontal_thrust": "ignored",
    "vertical_thrust": "ignored",
}
#: The kind (for grouping and older callers) of each simulation sensor.
SENSOR_KINDS: Dict[str, str] = {
    "ray_distance": KIND_RAY,
    "speed": KIND_SPEED,
    "goal_vector": KIND_GOAL,
    "goal_direction": KIND_GOAL,
    "local_goal_direction": KIND_GOAL,
    "goal_distance": KIND_GOAL,
}

TEXTS: Dict[str, Dict[str, str]] = {
    "not_trained": {
        "ru": "Сначала обучите модель.",
        "en": "Train the model first.",
        "kz": "Алдымен модельді оқытыңыз.",
    },
    "side_view": {
        "ru": "Эта модель обучена в симуляции с видом сбоку, а робот ездит по полу. Обучите модель в симуляции с видом сверху.",
        "en": "This model was trained in the side-view simulation, where the car drives over ledges and jumps. A robot on the floor cannot drive like that. Train the model in the top-down simulation.",
        "kz": "Бұл модель бүйірден көрінетін симуляцияда оқытылған: онда машина кедір-бұдырмен жүріп, секіреді. Еденде робот олай жүре алмайды. Модельді үстінен көрінетін симуляцияда оқытыңыз.",
    },
    "no_binding": {
        "ru": "Эта модель обучена не в симуляции. Проверьте, подходят ли роботу её входы и выходы.",
        "en": "This model was not trained in the simulation. Check that its inputs and outputs fit the robot.",
        "kz": "Модель симуляцияда оқытылмаған. Оның кірістері мен шығыстары роботқа сәйкес келетінін тексеріңіз.",
    },
    "unsupported_inputs": {
        "ru": "У настоящего робота нет некоторых датчиков, которые были у машинки в симуляции. Отключите их в Brain Mapping, сгенерируйте датасет заново и обучите модель ещё раз.",
        "en": "A real robot lacks some of the sensors the car had in the simulation. Turn them off in Brain Mapping, generate the dataset again and train the model again.",
        "kz": "Нақты роботта симуляциядағы машинаның кейбір датчиктері жоқ. Оларды Brain Mapping-те өшіріп, датасетті қайта жасап, модельді қайта оқытыңыз.",
    },
    "unsupported_outputs": {
        "ru": "Настоящий робот умеет только рулить, ехать и тормозить. Остального, чему научилась модель, он делать не будет.",
        "en": "A real robot can only steer, drive and brake. It will not do anything else the model learned.",
        "kz": "Нақты робот тек бұрылып, жүріп, тежей алады. Модель үйренген басқа әрекеттерді ол жасамайды.",
    },
    "ignored_outputs": {
        "ru": "Некоторые моторы модели и в симуляции ни на что не влияли, поэтому робот их пропустит.",
        "en": "Some of the model's motors did nothing in the simulation either, so the robot skips them.",
        "kz": "Модельдің кейбір моторлары симуляцияда да ешнәрсеге әсер етпеген, сондықтан робот оларды елемейді.",
    },
    "dataset_changed": {
        "ru": "Датасет изменился после обучения. Обучите модель заново.",
        "en": "The model was trained on a different dataset. Train it again.",
        "kz": "Модель басқа датасетте оқытылған. Оны қайта оқытыңыз.",
    },
    "labels_mismatch": {
        "ru": "Колонки датасета не совпадают с моделью, поэтому вместо названий стоят номера.",
        "en": "The dataset's column names do not match the model, so numbers are shown instead.",
        "kz": "Датасет бағандарының атаулары модельге сәйкес келмейді, сондықтан нөмірлер көрсетілген.",
    },
    "no_names": {
        "ru": "У колонок датасета нет названий, поэтому вместо них стоят номера.",
        "en": "The dataset has no column names, so numbers are shown.",
        "kz": "Датасетте баған атаулары жоқ, сондықтан нөмірлер көрсетілген.",
    },
}

#: Titles of a group of neurons, by kind.
GROUP_TITLES: Dict[str, Dict[str, str]] = {
    KIND_RAY: {"ru": "Зрение", "en": "Vision", "kz": "Көру"},
    KIND_SPEED: {"ru": "Скорость", "en": "Speed", "kz": "Жылдамдық"},
    KIND_STEER: {"ru": "Руль", "en": "Steering", "kz": "Руль"},
    KIND_THROTTLE: {"ru": "Газ", "en": "Throttle", "kz": "Газ"},
    KIND_BRAKE: {"ru": "Тормоз", "en": "Brake", "kz": "Тежегіш"},
    KIND_GOAL: {"ru": "Цель", "en": "Goal", "kz": "Мақсат"},
    KIND_OTHER: {"ru": "Другое", "en": "Other", "kz": "Басқа"},
}


def texts(code: str) -> Dict[str, str]:
    return dict(TEXTS[code])


def ray_layout(count: int) -> List[float]:
    """Angle of each ray in degrees, positive to the left, ``ray_0`` leftmost."""
    if count <= 0:
        return []
    if count == 1:
        return [0.0]
    half = RAY_ARC_DEG / 2.0
    return [half - i * RAY_ARC_DEG / (count - 1) for i in range(count)]


def _ray_angles(input_groups: List[Dict[str, Any]]) -> List[float]:
    """The angle of every ray input, in model order. Each ray sensor of the
    simulation casts its own fan (``raycast_fan``), so two ray groups are two
    fans, not one fan twice as dense."""
    angles: List[float] = []
    for group in sorted(input_groups, key=lambda g: int(g.get("start", 0))):
        if group.get("sensor_id") == "ray_distance":
            angles.extend(ray_layout(len(group.get("indices") or [])))
    return angles


def _clean(name: Any) -> str:
    """A column name without its ``:float`` type suffix."""
    return str(name).split(":", 1)[0].strip()


def classify(name: str, *, is_output: bool) -> str:
    """The meaning of a neuron, from its name. Only a hint for grouping and highlighting."""
    key = re.sub(r"[\s\-_]+", " ", _clean(name).lower()).strip()
    if not is_output:
        if re.fullmatch(r"(ray|луч|лучи)( ?\d+)?", key) or key.startswith("ray "):
            return KIND_RAY
        if key == "speed" or key == "скорость":
            return KIND_SPEED
        if "goal" in key or "цель" in key or key in ("gps x", "gps y"):
            return KIND_GOAL
        return KIND_OTHER
    if key.startswith("steer") or key.startswith("руль") or key.startswith("поворот"):
        return KIND_STEER
    if key.startswith("throttle") or key.startswith("газ") or key.startswith("педаль газа"):
        return KIND_THROTTLE
    if key.startswith("brake") or key.startswith("тормоз") or key.startswith("педаль тормоза"):
        return KIND_BRAKE
    return KIND_OTHER


def _label_names(outputs: Any) -> List[str]:
    names: List[str] = []
    if isinstance(outputs, list):
        for entry in outputs:
            if isinstance(entry, dict) and isinstance(entry.get("label_names"), list):
                names.extend(str(n) for n in entry["label_names"])
            elif isinstance(entry, dict):
                # A labelled output block: "label 1", "label 2". Without a label
                # the names stay empty and the window shows numbers (no English
                # word invented here ends up in a Russian window).
                label = str(entry.get("label", "") or "")
                names.extend(("%s %d" % (label, i + 1)) if label else "" for i in range(int(entry.get("x", 0) or 0)))
    return names


def _names_from_meta(meta: Dict[str, Any]) -> Dict[str, Any]:
    """The dataset's own names for inputs and outputs, and where they came from."""
    col_names = meta.get("col_names")
    split = meta.get("outputs_from")
    if isinstance(col_names, list) and col_names and isinstance(split, int) and 0 < split < len(col_names):
        return {
            "source": "col_names",
            "inputs": [_clean(n) for n in col_names[:split]],
            "outputs": [_clean(n) for n in col_names[split:]],
        }
    hints = meta.get("input_hints")
    inputs: List[str] = []
    if isinstance(hints, list):
        for hint in hints:
            if isinstance(hint, dict) and hint.get("name"):
                inputs.append(_clean(hint["name"]))
    outputs = _label_names(meta.get("outputs"))
    if inputs or any(outputs):
        return {"source": "input_hints", "inputs": inputs, "outputs": outputs}
    return {"source": "generic", "inputs": [], "outputs": []}


def _width_from_meta(meta: Dict[str, Any]) -> Dict[str, int]:
    inputs = meta.get("inputs")
    outputs = meta.get("outputs")
    in_width = int(inputs.get("x", 0) or 0) if isinstance(inputs, dict) else 0
    out_width = 0
    if isinstance(outputs, list):
        out_width = sum(int(o.get("x", 0) or 0) for o in outputs if isinstance(o, dict))
    return {"input": in_width, "output": out_width}


def _neurons(names: Sequence[str], width: int, *, is_output: bool) -> List[Dict[str, Any]]:
    result: List[Dict[str, Any]] = []
    for index in range(width):
        name = names[index] if index < len(names) else ""
        # No name: a language-neutral number; the window words it ("Вход 3").
        label = name or "#%d" % (index + 1)
        kind = classify(name, is_output=is_output) if name else KIND_OTHER
        supported = kind in (SUPPORTED_OUTPUT_KINDS if is_output else SUPPORTED_INPUT_KINDS)
        result.append({"index": index, "name": name, "label": label, "kind": kind, "supported": supported})
    return result


def _groups(neurons: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Neighbouring neurons of one kind become one group; ``other`` stays single."""
    groups: List[Dict[str, Any]] = []
    for neuron in neurons:
        kind = neuron["kind"]
        last = groups[-1] if groups else None
        if last is not None and last["kind"] == kind and kind != KIND_OTHER and kind in (KIND_RAY, KIND_GOAL):
            last["indices"].append(neuron["index"])
            last["labels"].append(neuron["label"])
            continue
        groups.append({
            "kind": kind,
            "indices": [neuron["index"]],
            "labels": [neuron["label"]],
            "supported": bool(neuron["supported"]),
            "title": dict(GROUP_TITLES.get(kind, GROUP_TITLES[KIND_OTHER])),
        })
    return groups


def _apply_binding(binding: Dict[str, Any], inputs: List[Dict[str, Any]], outputs: List[Dict[str, Any]]) -> Tuple[list, list]:
    """Give every neuron the simulation sensor or actuator it came from.

    The binding is exact (``sensor_id``, ``start``, ``length``), so nothing is
    guessed from names here. Returns the input and output groups, one per
    binding entry, in model order.
    """
    input_groups: List[Dict[str, Any]] = []
    for entry in sorted(binding.get("inputs") or [], key=lambda e: int(e.get("start", 0))):
        sensor_id = str(entry.get("sensor_id", ""))
        start, length = int(entry.get("start", 0)), int(entry.get("length", 0))
        needs = list(SENSOR_NEEDS.get(sensor_id, ()))
        supported = sensor_id in SENSOR_NEEDS
        quantities = SENSOR_QUANTITIES.get(sensor_id, ())
        kind = SENSOR_KINDS.get(sensor_id, KIND_OTHER)
        indices = [i for i in range(start, start + length) if i < len(inputs)]
        for offset, index in enumerate(indices):
            neuron = inputs[index]
            neuron.update({"sensor_id": sensor_id, "kind": kind, "supported": supported, "needs": needs})
            if quantities:
                neuron["quantity"] = quantities[offset] if offset < len(quantities) else quantities[-1]
        input_groups.append({
            "sensor_id": sensor_id,
            "kind": kind,
            "start": start,
            "length": length,
            "indices": indices,
            "labels": [inputs[i]["label"] for i in indices],
            "supported": supported,
            "needs": needs,
            "quantities": list(quantities),
            "title": dict(GROUP_TITLES.get(kind, GROUP_TITLES[KIND_OTHER])),
        })
    output_groups: List[Dict[str, Any]] = []
    for entry in sorted(binding.get("outputs") or [], key=lambda e: int(e.get("start", 0))):
        actuator_id = str(entry.get("actuator_id", ""))
        start, length = int(entry.get("start", 0)), int(entry.get("length", 0))
        role = ACTUATOR_ROLES.get(actuator_id, "")
        supported = bool(role)
        kind = role if role in (KIND_STEER, KIND_THROTTLE, KIND_BRAKE) else KIND_OTHER
        indices = [i for i in range(start, start + length) if i < len(outputs)]
        for index in indices:
            outputs[index].update({"actuator_id": actuator_id, "kind": kind, "supported": supported,
                                   "ignored": role == "ignored"})
        output_groups.append({
            "actuator_id": actuator_id,
            "kind": kind,
            "start": start,
            "length": length,
            "indices": indices,
            "labels": [outputs[i]["label"] for i in indices],
            "supported": supported,
            "ignored": role == "ignored",
            "title": dict(GROUP_TITLES.get(kind, GROUP_TITLES[KIND_OTHER])),
        })
    return input_groups, output_groups


def _name_groups(inputs: List[Dict[str, Any]], outputs: List[Dict[str, Any]]) -> Tuple[list, list]:
    """Groups for a model without a binding, from what its names say.

    Only what the names make certain becomes a simulation sensor: rays and a
    speed. A name saying "goal" does not say how the goal was encoded, so such
    inputs stay unsupported.
    """
    for neuron in inputs:
        if neuron["kind"] == KIND_RAY:
            neuron.update({"sensor_id": "ray_distance", "needs": [NEED_SENSORS]})
        elif neuron["kind"] == KIND_SPEED:
            neuron.update({"sensor_id": "speed", "quantity": "speed", "needs": [NEED_WHEELS]})
        else:
            neuron["needs"] = []
    actuators = {KIND_STEER: "steering", KIND_THROTTLE: "throttle", KIND_BRAKE: "brake"}
    for neuron in outputs:
        if neuron["kind"] in actuators:
            neuron["actuator_id"] = actuators[neuron["kind"]]
        neuron["ignored"] = False
    input_groups = _groups(inputs)
    for group in input_groups:
        first = inputs[group["indices"][0]]
        group.update({
            "sensor_id": first.get("sensor_id", ""),
            "start": group["indices"][0],
            "length": len(group["indices"]),
            "needs": list(first.get("needs", [])),
            "quantities": [first["quantity"]] if "quantity" in first else [],
        })
    output_groups = _groups(outputs)
    for group in output_groups:
        first = outputs[group["indices"][0]]
        group.update({
            "actuator_id": first.get("actuator_id", ""),
            "start": group["indices"][0],
            "length": len(group["indices"]),
            "ignored": False,
        })
    return input_groups, output_groups


def describe_model(
    dataset_meta: Optional[Dict[str, Any]],
    *,
    input_width: Optional[int] = None,
    output_width: Optional[int] = None,
    model_ready: bool = True,
    model_widths: Optional[Tuple[int, int]] = None,
) -> Dict[str, Any]:
    """Describe a trained model from the dataset it was trained on.

    ``dataset_meta`` is the dataset dictionary of the project's training node
    (only its small fields are needed). ``input_width`` / ``output_width`` are
    the network's sizes in the project; when given they win over the dataset's.
    ``model_widths`` are the trained model file's own sizes (inputs, outputs)
    and win over both: a model trained before its dataset was changed does not
    fit the dataset's description, and is refused here rather than at Start.
    """
    meta = dataset_meta if isinstance(dataset_meta, dict) else {}
    binding = (meta.get("metadata") or {}).get("binding") if isinstance(meta.get("metadata"), dict) else None
    binding = binding if isinstance(binding, dict) else {}
    agent_id = str(binding.get("agent_id", ""))

    declared = _width_from_meta(meta)
    if not declared["input"] and binding:
        declared["input"] = int(binding.get("input_width", 0) or 0)
    if not declared["output"] and binding:
        declared["output"] = int(binding.get("output_width", 0) or 0)
    in_width = int(input_width) if input_width else declared["input"]
    out_width = int(output_width) if output_width else declared["output"]
    file_in, file_out = (int(model_widths[0] or 0), int(model_widths[1] or 0)) if model_widths else (0, 0)
    dataset_changed = bool(
        (file_in and declared["input"] and file_in != declared["input"])
        or (file_out and declared["output"] and file_out != declared["output"]))
    in_width = file_in or in_width
    out_width = file_out or out_width

    named = _names_from_meta(meta)
    in_names, out_names = list(named["inputs"]), list(named["outputs"])
    source = named["source"]
    warnings: List[Dict[str, Any]] = []
    if in_names and len(in_names) != in_width:
        warnings.append({"code": "labels_mismatch", "texts": texts("labels_mismatch")})
        in_names = []
    if out_names and len(out_names) != out_width:
        if not any(w["code"] == "labels_mismatch" for w in warnings):
            warnings.append({"code": "labels_mismatch", "texts": texts("labels_mismatch")})
        out_names = []
    if not in_names and not out_names:
        source = "generic"
        if not meta:
            warnings.append({"code": "no_names", "texts": texts("no_names")})

    inputs = _neurons(in_names, in_width, is_output=False)
    outputs = _neurons(out_names, out_width, is_output=True)
    perspective = AGENT_PERSPECTIVES.get(agent_id, PERSPECTIVE_UNKNOWN)
    if binding.get("inputs") or binding.get("outputs"):
        input_groups, output_groups = _apply_binding(binding, inputs, outputs)
    else:
        input_groups, output_groups = _name_groups(inputs, outputs)
    needs = sorted({need for neuron in inputs if neuron["supported"] for need in neuron.get("needs", [])})

    blocked: Optional[Dict[str, Any]] = None
    if not model_ready:
        blocked = {"code": "not_trained", "texts": texts("not_trained")}
    elif dataset_changed:
        blocked = {"code": "dataset_changed", "texts": texts("dataset_changed")}
    elif perspective == PERSPECTIVE_SIDE_VIEW:
        blocked = {"code": "side_view", "texts": texts("side_view")}
    elif not agent_id:
        warnings.append({"code": "no_binding", "texts": texts("no_binding")})

    bad_inputs = [n["index"] for n in inputs if not n["supported"]]
    bad_outputs = [n["index"] for n in outputs if not n["supported"]]
    issues: List[Dict[str, Any]] = []
    if bad_inputs:
        issues.append({"code": "unsupported_inputs", "neurons": bad_inputs, "texts": texts("unsupported_inputs")})
    if bad_outputs:
        issues.append({"code": "unsupported_outputs", "neurons": bad_outputs, "texts": texts("unsupported_outputs")})

    ignored = [n["index"] for n in outputs if n.get("ignored")]
    if ignored:
        warnings.append({"code": "ignored_outputs", "neurons": ignored, "texts": texts("ignored_outputs")})
    return {
        "ok": True,
        "source": source,
        "dataset_name": str(meta.get("name", "")),
        "agent_id": agent_id,
        "perspective": perspective,
        "input_width": in_width,
        "output_width": out_width,
        "inputs": inputs,
        "outputs": outputs,
        "input_groups": input_groups,
        "output_groups": output_groups,
        "needs": needs,
        "ray_angles_deg": _ray_angles(input_groups),
        "blocked": blocked,
        "warnings": warnings,
        "issues": issues,
    }
