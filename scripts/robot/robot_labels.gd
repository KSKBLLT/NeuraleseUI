class_name RobotLabels
extends RefCounted
## The names of a network's inputs and outputs, as Brain Mapping shows them.
##
## Labels and accents are the simulation registry's
## (simulation_definition_registry.gd); the Russian and Kazakh names are the ones
## Brain Mapping translates them to (simulation_brain_mapping_panel.gd,
## _toggle_row), copied here because they live inside that function.

const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")

const RU := {
	"ray sensor": "Датчик зрения", "speed": "Датчик скорости", "horizontal speed": "Скорость влево/вправо", "vertical speed": "Скорость вверх/вниз",
	"rotation": "Вращение", "gps": "Датчик GPS", "goal vector": "Вектор цели", "goal direction": "Направление к цели",
	"local goal direction": "Поворот к цели", "goal distance": "Расстояние до цели",
	"normalized position": "Мое расположение (от 0 до 1)", "heading (sin/cos)": "Направление", "on ground": "На земле",
	"height": "Как высоко я нахожусь?",
	"position": "Расположение",
	"heading": "Куда я смотрю?",
	"steering": "Поворот руля", "throttle": "Педаль газа", "brake": "Педаль тормоза", "horizontal thrust": "Полет влево/вправо",
	"vertical thrust": "Полет вверх/вниз", "jump": "Умение прыгать",
}
const KZ := {
	"ray sensor": "Сәуле", "speed": "Жылдамдық", "horizontal speed": "Көл. жылдамдық", "vertical speed": "Тік жылдамдық",
	"rotation": "Бұрылу", "gps": "GPS", "goal vector": "Мақсат векторы", "goal direction": "Мақсат бағыты",
	"local goal direction": "Жерг. мақсат бағыты", "goal distance": "Мақсатқа дейінгі қашықтық",
	"normalized position": "Норм. позиция", "heading (sin/cos)": "Бағыт", "grounded": "Жерде",
	"height": "Биіктік",
	"steering": "Рөл", "throttle": "Газ", "brake": "Тежегіш", "horizontal thrust": "Көл. тарту",
	"vertical thrust": "Тік тарту", "jump": "Секіру",
}


static func _translate(english: String) -> String:
	var key := english.to_lower()
	match glob.get_lang():
		"ru":
			return str(RU.get(key, english))
		"kz":
			return str(KZ.get(key, RU.get(key, english)))
	return english


## The name of a simulation sensor, in the current language.
static func sensor(sensor_id: String) -> String:
	var definition := Registry.sensor(StringName(sensor_id))
	return _translate(str(definition.get("label", sensor_id))) if not definition.is_empty() else sensor_id


static func actuator(actuator_id: String) -> String:
	var definition := Registry.actuator(StringName(actuator_id))
	return _translate(str(definition.get("label", actuator_id))) if not definition.is_empty() else actuator_id


static func sensor_accent(sensor_id: String) -> Color:
	return Registry.sensor(StringName(sensor_id)).get("accent", Color("8b8e95"))


static func actuator_accent(actuator_id: String) -> Color:
	return Registry.actuator(StringName(actuator_id)).get("accent", Color("8b8e95"))


## A model group (from robot/model_contract.py) by its registry id, or its
## own neuron labels for a model without a binding.
static func group(group: Dictionary, is_output: bool) -> String:
	var id := str(group.get("actuator_id" if is_output else "sensor_id", ""))
	if not id.is_empty():
		return actuator(id) if is_output else sensor(id)
	var labels: Array = group.get("labels", [])
	return str(labels[0]) if not labels.is_empty() else "?"


static func group_accent(group: Dictionary, is_output: bool) -> Color:
	var id := str(group.get("actuator_id" if is_output else "sensor_id", ""))
	if id.is_empty():
		return Color("8b8e95")
	return actuator_accent(id) if is_output else sensor_accent(id)
