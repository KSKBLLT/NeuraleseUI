class_name SimulationModelBinding
extends RefCounted

const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")
const FORMAT_VERSION := 1


static func validate(payload: Dictionary) -> Dictionary:
	var errors: Array[Dictionary] = []
	var input_width := int(payload.get("input_width", 0))
	var output_width := int(payload.get("output_width", 0))
	var agent_id := StringName(payload.get("agent_id", ""))
	if int(payload.get("version", FORMAT_VERSION)) != FORMAT_VERSION:
		_add_error(errors, "unsupported_version", "Unsupported model binding version.")
	if Registry.agent(agent_id).is_empty():
		_add_error(errors, "unknown_agent", "Choose a supported simulation agent.")
	if input_width <= 0:
		_add_error(errors, "invalid_input_width", "The model must have at least one input.")
	if output_width <= 0:
		_add_error(errors, "invalid_output_width", "The model must have at least one output.")

	var input_coverage := _coverage(input_width)
	var output_coverage := _coverage(output_width)
	_validate_inputs(payload.get("inputs", []), agent_id, input_width, input_coverage, errors)
	_validate_outputs(payload.get("outputs", []), agent_id, output_width, output_coverage, errors)
	var unbound_inputs := _unbound_indices(input_coverage)
	var unbound_outputs := _unbound_indices(output_coverage)
	if not unbound_inputs.is_empty():
		_add_error(errors, "unbound_inputs", "Map every model input before running.")
	if not unbound_outputs.is_empty():
		_add_error(errors, "unbound_outputs", "Map every model output before running.")
	return {
		"valid": errors.is_empty(),
		"errors": errors,
		"unbound_inputs": unbound_inputs,
		"unbound_outputs": unbound_outputs,
	}


static func create_default(
	agent_id: StringName,
	model: Dictionary = {}
) -> Dictionary:
	var mappings := Registry.default_binding(agent_id)
	var inputs: Array = mappings.get("inputs", []).duplicate(true)
	var outputs: Array = mappings.get("outputs", []).duplicate(true)
	return {
		"version": FORMAT_VERSION,
		"agent_id": str(agent_id),
		"model": model.duplicate(true),
		"input_width": _mapped_width(inputs),
		"output_width": _mapped_width(outputs),
		"inputs": inputs,
		"outputs": outputs,
	}


static func create_auto(
	agent_id: StringName,
	input_width: int,
	output_width: int,
	model: Dictionary = {}
) -> Dictionary:
	if Registry.agent(agent_id).is_empty() or input_width <= 0 or output_width <= 0:
		return {}
	var inputs := _auto_inputs(agent_id, input_width)
	var outputs := _auto_outputs(agent_id, output_width)
	if inputs.is_empty() or outputs.is_empty():
		return {}
	var binding := {
		"version": FORMAT_VERSION,
		"agent_id": str(agent_id),
		"model": model.duplicate(true),
		"input_width": input_width,
		"output_width": output_width,
		"inputs": inputs,
		"outputs": outputs,
	}
	return binding if validate(binding).get("valid", false) else {}


static func _auto_inputs(agent_id: StringName, width: int) -> Array:
	var defaults: Array = Registry.default_binding(agent_id).get("inputs", []).duplicate(true)
	defaults.sort_custom(_sort_by_start)
	var flexible_index := -1
	var fixed_width := 0
	for index in defaults.size():
		var mapping: Dictionary = defaults[index]
		var definition := Registry.sensor(StringName(mapping.get("sensor_id", "")))
		if definition.get("dimension_kind") == &"range" and flexible_index < 0:
			flexible_index = index
		else:
			fixed_width += int(mapping.get("length", 0))
	if flexible_index >= 0:
		var flexible: Dictionary = defaults[flexible_index]
		var flexible_id := StringName(flexible.get("sensor_id", ""))
		var flexible_width := width - fixed_width
		if Registry.sensor_accepts_width(flexible_id, flexible_width):
			flexible["length"] = flexible_width
			defaults[flexible_index] = flexible
			return _reindex_mappings(defaults)

	for sensor_id in Registry.agent(agent_id).get("sensors", []):
		if Registry.sensor_accepts_width(StringName(sensor_id), width):
			return [{"sensor_id": StringName(sensor_id), "start": 0, "length": width}]
	return []


static func _auto_outputs(agent_id: StringName, width: int) -> Array:
	var candidates: Array = Registry.default_binding(agent_id).get("outputs", []).duplicate(true)
	var existing: Dictionary = {}
	for mapping in candidates:
		if mapping is Dictionary:
			existing[StringName(mapping.get("actuator_id", ""))] = true
	for actuator_id in Registry.agent(agent_id).get("actuators", []):
		if existing.has(StringName(actuator_id)):
			continue
		var definition := Registry.actuator(StringName(actuator_id))
		candidates.append({
			"actuator_id": StringName(actuator_id),
			"start": 0,
			"length": int(definition.get("channels", 0)),
		})
	var selected: Array = []
	var used_width := 0
	for mapping in candidates:
		if mapping is not Dictionary:
			continue
		var length := int(mapping.get("length", 0))
		if length <= 0 or used_width + length > width:
			continue
		selected.append(mapping.duplicate(true))
		used_width += length
		if used_width == width:
			return _reindex_mappings(selected)
	return []


static func _reindex_mappings(mappings: Array) -> Array:
	var result: Array = []
	var start := 0
	for mapping in mappings:
		if mapping is not Dictionary:
			continue
		var copy: Dictionary = mapping.duplicate(true)
		copy["start"] = start
		start += int(copy.get("length", 0))
		result.append(copy)
	return result


static func _validate_inputs(
	mappings: Variant,
	agent_id: StringName,
	width: int,
	coverage: Array[bool],
	errors: Array[Dictionary]
) -> void:
	if mappings is not Array:
		_add_error(errors, "invalid_inputs", "Input mappings must be a list.")
		return
	for mapping_index in mappings.size():
		var raw_mapping = mappings[mapping_index]
		if raw_mapping is not Dictionary:
			_add_error(errors, "invalid_input_mapping", "An input mapping is malformed.", mapping_index)
			continue
		var mapping: Dictionary = raw_mapping
		var sensor_id := StringName(mapping.get("sensor_id", ""))
		var start := int(mapping.get("start", -1))
		var length := int(mapping.get("length", 0))
		if Registry.sensor(sensor_id).is_empty():
			_add_error(errors, "unknown_sensor", "Choose a supported sensor.", mapping_index)
		elif not Registry.agent_supports_sensor(agent_id, sensor_id):
			_add_error(errors, "incompatible_sensor", "This sensor is not available for the selected agent.", mapping_index)
		if not Registry.sensor_accepts_width(sensor_id, length):
			_add_error(errors, "invalid_sensor_width", "The selected sensor does not fit this input range.", mapping_index)
		_mark_range(coverage, start, length, width, "input", mapping_index, errors)


static func _validate_outputs(
	mappings: Variant,
	agent_id: StringName,
	width: int,
	coverage: Array[bool],
	errors: Array[Dictionary]
) -> void:
	if mappings is not Array:
		_add_error(errors, "invalid_outputs", "Output mappings must be a list.")
		return
	for mapping_index in mappings.size():
		var raw_mapping = mappings[mapping_index]
		if raw_mapping is not Dictionary:
			_add_error(errors, "invalid_output_mapping", "An output mapping is malformed.", mapping_index)
			continue
		var mapping: Dictionary = raw_mapping
		var actuator_id := StringName(mapping.get("actuator_id", ""))
		var start := int(mapping.get("start", -1))
		var length := int(mapping.get("length", 0))
		if Registry.actuator(actuator_id).is_empty():
			_add_error(errors, "unknown_actuator", "Choose a supported actuator.", mapping_index)
		elif not Registry.agent_supports_actuator(agent_id, actuator_id):
			_add_error(errors, "incompatible_actuator", "This actuator is not available for the selected agent.", mapping_index)
		if not Registry.actuator_accepts_width(actuator_id, length):
			_add_error(errors, "invalid_actuator_width", "The selected actuator does not fit this output range.", mapping_index)
		_mark_range(coverage, start, length, width, "output", mapping_index, errors)


static func _mark_range(
	coverage: Array[bool],
	start: int,
	length: int,
	width: int,
	kind: String,
	mapping_index: int,
	errors: Array[Dictionary]
) -> void:
	if start < 0 or length <= 0 or start + length > width:
		_add_error(errors, "%s_range_out_of_bounds" % kind, "The mapped range is outside the model shape.", mapping_index)
		return
	for channel_index in range(start, start + length):
		if coverage[channel_index]:
			_add_error(errors, "%s_overlap" % kind, "Mapped ranges cannot overlap.", mapping_index)
		else:
			coverage[channel_index] = true


static func _coverage(width: int) -> Array[bool]:
	var result: Array[bool] = []
	result.resize(maxi(0, width))
	result.fill(false)
	return result


static func _unbound_indices(coverage: Array[bool]) -> Array[int]:
	var result: Array[int] = []
	for index in coverage.size():
		if not coverage[index]:
			result.append(index)
	return result


static func _mapped_width(mappings: Array) -> int:
	var width := 0
	for mapping in mappings:
		if mapping is Dictionary:
			width = maxi(width, int(mapping.get("start", 0)) + int(mapping.get("length", 0)))
	return width


static func _sort_by_start(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("start", 0)) < int(right.get("start", 0))


static func _add_error(
	errors: Array[Dictionary],
	code: String,
	message: String,
	mapping_index: int = -1
) -> void:
	var error := {"code": code, "message": message}
	if mapping_index >= 0:
		error["mapping_index"] = mapping_index
	errors.append(error)
