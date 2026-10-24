class_name SimulationIOSchema
extends RefCounted

const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")
const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")
const DEFAULT_AGENT_ID := &"side_view_car"


static func active_inputs() -> Array:
	var binding := default_binding()
	var result: Array = []
	for mapping in binding.get("inputs", []):
		if mapping is not Dictionary:
			continue
		var sensor_id := StringName(mapping.get("sensor_id", ""))
		var definition := Registry.sensor(sensor_id)
		if definition.is_empty():
			continue
		definition["id"] = sensor_id
		definition["channels"] = int(mapping.get("length", 0))
		definition["columns"] = Registry.sensor_columns(sensor_id, definition["channels"])
		result.append(definition)
	return result


static func input_options() -> Array:
	var result: Array = active_inputs()
	var active_ids: Dictionary = {}
	for source in result:
		active_ids[StringName(source.get("id", ""))] = true
	for sensor_id in Registry.sensors():
		if active_ids.has(sensor_id) or not Registry.agent_supports_sensor(DEFAULT_AGENT_ID, sensor_id):
			continue
		var definition := Registry.sensor(sensor_id)
		definition["id"] = sensor_id
		definition["channels"] = _display_width(definition)
		result.append(definition)
	return result


static func outputs() -> Array:
	var binding := default_binding()
	var result: Array = []
	for mapping in binding.get("outputs", []):
		if mapping is not Dictionary:
			continue
		var actuator_id := StringName(mapping.get("actuator_id", ""))
		var definition := Registry.actuator(actuator_id)
		if definition.is_empty():
			continue
		definition["id"] = actuator_id
		definition["range"] = _range_label(definition.get("range", Vector2.ZERO))
		definition["column"] = Registry.actuator_columns(actuator_id)[0]
		result.append(definition)
	return result


static func default_binding() -> Dictionary:
	return ModelBinding.create_default(DEFAULT_AGENT_ID)


static func input_width() -> int:
	return int(default_binding().get("input_width", 0))


static func output_width() -> int:
	return int(default_binding().get("output_width", 0))


static func input_columns() -> Array[String]:
	return input_columns_for(default_binding())


static func output_columns() -> Array[String]:
	return output_columns_for(default_binding())


static func input_columns_for(binding: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var mappings: Array = binding.get("inputs", []).duplicate(true)
	mappings.sort_custom(_sort_by_start)
	for mapping in mappings:
		if mapping is not Dictionary:
			continue
		result.append_array(Registry.sensor_columns(
			StringName(mapping.get("sensor_id", "")),
			int(mapping.get("length", 0))
		))
	return result


static func output_columns_for(binding: Dictionary) -> Array[String]:
	var result: Array[String] = []
	var mappings: Array = binding.get("outputs", []).duplicate(true)
	mappings.sort_custom(_sort_by_start)
	for mapping in mappings:
		if mapping is not Dictionary:
			continue
		result.append_array(Registry.actuator_columns(StringName(mapping.get("actuator_id", ""))))
	return result


static func dataset_schema_for(binding: Dictionary) -> Dictionary:
	var validation := ModelBinding.validate(binding)
	if not validation.get("valid", false):
		return {"valid": false, "errors": validation.get("errors", []).duplicate(true)}
	var columns := input_columns_for(binding)
	columns.append_array(output_columns_for(binding))
	return {
		"valid": true,
		"col_names": columns,
		"outputs_from": int(binding.get("input_width", 0)),
		"col_args": _column_args_for(binding),
	}


static func _display_width(definition: Dictionary) -> int:
	if definition.get("dimension_kind") == &"range":
		return int(definition.get("min_channels", 1))
	return int(definition.get("channels", 0))


static func _range_label(value: Variant) -> String:
	if value is Vector2:
		return "%s...%s" % [_short_number(value.x), _short_number(value.y)]
	return str(value)


static func _short_number(value: float) -> String:
	return str(int(value)) if is_equal_approx(value, roundf(value)) else str(value)


static func _column_args_for(binding: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var input_mappings: Array = binding.get("inputs", []).duplicate(true)
	input_mappings.sort_custom(_sort_by_start)
	for mapping_value in input_mappings:
		if mapping_value is not Dictionary:
			continue
		var mapping: Dictionary = mapping_value
		var definition: Dictionary = Registry.sensor(StringName(mapping.get("sensor_id", "")))
		var value_range: Vector2 = definition.get("range", Vector2(0.0, 1.0))
		for _channel in int(mapping.get("length", 0)):
			result.append({"min": value_range.x, "max": value_range.y})
	var output_mappings: Array = binding.get("outputs", []).duplicate(true)
	output_mappings.sort_custom(_sort_by_start)
	for mapping_value in output_mappings:
		if mapping_value is not Dictionary:
			continue
		var mapping: Dictionary = mapping_value
		var definition: Dictionary = Registry.actuator(StringName(mapping.get("actuator_id", "")))
		var value_range: Vector2 = definition.get("range", Vector2(0.0, 1.0))
		for _channel in int(mapping.get("length", 0)):
			result.append({"min": value_range.x, "max": value_range.y})
	return result


static func _sort_by_start(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("start", 0)) < int(right.get("start", 0))
