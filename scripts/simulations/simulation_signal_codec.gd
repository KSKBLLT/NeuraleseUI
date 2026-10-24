class_name SimulationSignalCodec
extends RefCounted

const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")
const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")


static func encode(
	provider: Object,
	binding: Dictionary,
	context: Dictionary = {}
) -> Dictionary:
	var binding_validation := ModelBinding.validate(binding)
	if not binding_validation.get("valid", false):
		return _failure(binding_validation.get("errors", []))
	if provider == null:
		return _single_failure("missing_provider", "The selected agent cannot provide sensor data.")

	var values := PackedFloat32Array()
	values.resize(int(binding.get("input_width", 0)))
	var mappings: Array = binding.get("inputs", []).duplicate(true)
	mappings.sort_custom(_sort_by_start)
	for mapping_index in mappings.size():
		var mapping: Dictionary = mappings[mapping_index]
		var sensor_id := StringName(mapping.get("sensor_id", ""))
		var definition := Registry.sensor(sensor_id)
		var encoder := StringName(definition.get("encoder", ""))
		if encoder.is_empty() or not provider.has_method(encoder):
			return _single_failure(
				"missing_encoder",
				"The selected agent does not implement sensor '%s'." % sensor_id,
				mapping_index
			)
		var length := int(mapping.get("length", 0))
		var encoded = provider.callv(encoder, [length, context])
		var sensor_values := _as_float_array(encoded)
		if sensor_values.size() != length:
			return _single_failure(
				"encoder_width_mismatch",
				"Sensor '%s' returned %d values instead of %d." % [sensor_id, sensor_values.size(), length],
				mapping_index
			)
		if not _finite_values(sensor_values):
			return _single_failure(
				"non_finite_sensor_value",
				"Sensor '%s' returned a non-finite value." % sensor_id,
				mapping_index
			)
		var start := int(mapping.get("start", 0))
		for value_index in length:
			values[start + value_index] = sensor_values[value_index]
	return {"valid": true, "values": values, "errors": []}


static func decode(
	provider: Object,
	binding: Dictionary,
	model_outputs: PackedFloat32Array,
	context: Dictionary = {}
) -> Dictionary:
	var binding_validation := ModelBinding.validate(binding)
	if not binding_validation.get("valid", false):
		return _failure(binding_validation.get("errors", []))
	if provider == null:
		return _single_failure("missing_provider", "The selected agent cannot receive model actions.")
	var expected_width := int(binding.get("output_width", 0))
	if model_outputs.size() != expected_width:
		return _single_failure(
			"output_width_mismatch",
			"The model returned %d outputs instead of %d." % [model_outputs.size(), expected_width]
		)
	if not _finite_values(model_outputs):
		return _single_failure("non_finite_model_output", "The model returned a non-finite output.")

	var calls: Array[Dictionary] = []
	var mappings: Array = binding.get("outputs", []).duplicate(true)
	mappings.sort_custom(_sort_by_start)
	for mapping_index in mappings.size():
		var mapping: Dictionary = mappings[mapping_index]
		var actuator_id := StringName(mapping.get("actuator_id", ""))
		var definition := Registry.actuator(actuator_id)
		var decoder := StringName(definition.get("decoder", ""))
		if decoder.is_empty() or not provider.has_method(decoder):
			return _single_failure(
				"missing_decoder",
				"The selected agent does not implement actuator '%s'." % actuator_id,
				mapping_index
			)
		var start := int(mapping.get("start", 0))
		var length := int(mapping.get("length", 0))
		var actuator_values := PackedFloat32Array()
		var value_range: Vector2 = definition.get("range", Vector2(-INF, INF))
		for value_index in length:
			actuator_values.append(clampf(
				model_outputs[start + value_index],
				value_range.x,
				value_range.y
			))
		calls.append({"decoder": decoder, "values": actuator_values})

	for call_data in calls:
		provider.callv(call_data["decoder"], [call_data["values"], context])
	return {"valid": true, "errors": []}


static func _as_float_array(value: Variant) -> PackedFloat32Array:
	if value is PackedFloat32Array:
		return value
	var result := PackedFloat32Array()
	if value is Array or value is PackedFloat64Array:
		for item in value:
			if item is not float and item is not int:
				return PackedFloat32Array()
			result.append(float(item))
	return result


static func _finite_values(values: PackedFloat32Array) -> bool:
	for value in values:
		if is_nan(value) or is_inf(value):
			return false
	return true


static func _failure(errors: Variant) -> Dictionary:
	return {
		"valid": false,
		"errors": errors.duplicate(true) if errors is Array else [],
		"values": PackedFloat32Array(),
	}


static func _single_failure(
	code: String,
	message: String,
	mapping_index: int = -1
) -> Dictionary:
	var error := {"code": code, "message": message}
	if mapping_index >= 0:
		error["mapping_index"] = mapping_index
	return _failure([error])


static func _sort_by_start(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("start", 0)) < int(right.get("start", 0))
