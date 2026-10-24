extends RefCounted
## Dataset Bento: the words on the cards — a situation's name and action, what
## a row shows the network and what it does, and why a row looks like a mistake.

const UI := preload("res://scripts/ui/dataset_bento_ui.gd")
const Situations := preload("res://scripts/ui/dataset_bento_situations.gd")


static func cluster_text(owner_view: Node, j: int) -> String:
	var group: Dictionary = owner_view.analysis["clusters"][j]
	var label: Dictionary = group["label"]
	if label.has("car"):
		return UI.t(label["car"])
	var features: Array = label.get("features", [])
	if not features.is_empty():
		return " · ".join(features.map(func(f): return "%s %s" % [f[0], "↑" if f[1] else "↓"]))
	var action: Dictionary = group["action"]
	return str(action["word"]) if action.has("word") else UI.t("typical")


static func action_text(action: Dictionary) -> String:
	if action.has("car"):
		return UI.t(action["car"])
	if action.has("values"):
		return ", ".join(action["values"])
	return str(action.get("word", ""))


## «ВИДИТ» and «ДЕЛАЕТ» for one row.
static func row_facts(owner_view: Node, row: int) -> Array:
	var data: Dictionary = owner_view.data
	var cells: Array = owner_view._rows()[row]
	var columns: Array = data["columns"]
	var split: int = data["split"]
	var car: Dictionary = data["car"]
	if not car.is_empty():
		var picture: Dictionary = owner_view.describe(row)
		var speed := 1.0
		if car["speed"] >= 0:
			speed = absf(Situations.finite(Situations.cell_number(cells[car["speed"]]))) / maxf(car["speed_max"], 0.000001)
		var see := UI.t(Situations.car_key(picture["rays"], speed)) + " · %s %d%%" % [UI.t("speed"), roundi(speed * 100.0)]
		var act := UI.t(Situations.car_action(picture["steer"], picture["gas"])) + " · %s %d%%" % [UI.t("gas"), roundi(picture["gas"] * 100.0)]
		return [see, act]
	var outputs := PackedStringArray()
	for c in range(split, columns.size()):
		outputs.append("%s: %s" % [columns[c], Situations.cell_text(cells[c])])
	if data["image"]:
		return [UI.t("camera_frame"), " · ".join(outputs)]
	var inputs := PackedStringArray()
	for c in mini(split, 3):
		inputs.append("%s %s" % [columns[c], Situations.cell_text(cells[c])])
	var see := " · ".join(inputs) + (" …" if split > 3 else "")
	return [see, " · ".join(outputs)]


## Why a row looks like a mistake, in the words of its alike rows.
static func why(owner_view: Node, row: int) -> String:
	var errors: Dictionary = owner_view.analysis.get("errors", {})
	if not errors.has(row) or owner_view.kept.has(row):
		return ""
	var expected: Variant = errors[row]["expected"]
	var data: Dictionary = owner_view.data
	var cells: Array = owner_view._rows()[row]
	var split: int = data["split"]
	var car: Dictionary = data["car"]
	var wanted := ""
	var actual := ""
	if expected is PackedFloat32Array and not car.is_empty():
		var gas_at: int = car["throttle"] - split
		wanted = UI.t(Situations.car_action(expected[car["steer"] - split], expected[gas_at] if gas_at >= 0 else 1.0))
		var picture: Dictionary = owner_view.describe(row)
		actual = UI.t(Situations.car_action(picture["steer"], picture["gas"]))
	elif expected is PackedFloat32Array:
		wanted = ", ".join(Array(expected).map(func(v): return String.num(v, 2)))
		actual = ", ".join(range(split, data["columns"].size()).map(func(c): return Situations.cell_text(cells[c])))
	else:
		wanted = str(expected)
		actual = ", ".join(range(split, data["columns"].size()).map(func(c): return Situations.cell_text(cells[c])))
	return UI.t("why") % [wanted, actual]
