class_name SimulationCompiler
extends RefCounted

const WorldState = preload("res://scripts/simulations/simulation_world_state.gd")
const Catalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")


static func compile(world_data: Dictionary) -> Dictionary:
	var objects: Array[Dictionary] = WorldState.objects_from_dictionary(world_data)
	var ids := PackedStringArray()
	var types := PackedStringArray()
	var positions := PackedVector2Array()
	var rotations := PackedFloat32Array()
	var scales := PackedVector2Array()
	var sizes := PackedVector2Array()
	var properties: Array[Dictionary] = []
	var definitions: Array[Dictionary] = []
	var physical := PackedInt32Array()
	var dynamic := PackedInt32Array()
	var agents := PackedInt32Array()
	var triggers := PackedInt32Array()
	var goals := PackedInt32Array()
	var id_to_index := {}

	for raw_object in objects:
		var type_id := StringName(raw_object.get("type_id", ""))
		if not Catalog.has_type(type_id):
			continue
		var definition := Catalog.definition(type_id)
		var index := ids.size()
		var object_id := str(raw_object.get("id", "object-%d" % index))
		ids.append(object_id)
		types.append(str(type_id))
		positions.append(_as_vector2(raw_object.get("position"), Vector2.ZERO))
		rotations.append(float(raw_object.get("rotation", 0.0)))
		scales.append(_as_vector2(raw_object.get("scale"), Vector2.ONE))
		sizes.append(_as_vector2(raw_object.get("size"), definition.get("default_size", Vector2(64.0, 64.0))))
		properties.append(_session_properties(raw_object.get("properties", {})))
		definitions.append(definition)
		id_to_index[object_id] = index
		var body_kind := str(definition.get("body_kind", ""))
		var role := str(definition.get("dataset_role", ""))
		if body_kind in ["static", "rigid", "agent", "area"]:
			physical.append(index)
		if body_kind in ["rigid", "agent"]:
			dynamic.append(index)
		if body_kind == "agent":
			agents.append(index)
			var binding: Variant = properties[index].get("model_binding", {})
			if binding is not Dictionary or not ModelBinding.validate(binding).get("valid", false):
				properties[index]["model_binding"] = ModelBinding.create_default(StringName(definition.get("agent_id", "side_view_car")))
		if body_kind == "area":
			triggers.append(index)
		if role == "goal":
			goals.append(index)

	return {
		"version": 1,
		"world_name": str(world_data.get("world_name", "Untitled simulation")),
		"metadata": _session_metadata(world_data.get("metadata", {})),
		"perspective_mode": StringName(world_data.get("perspective_mode", "auto")),
		"ids": ids,
		"types": types,
		"positions": positions,
		"rotations": rotations,
		"scales": scales,
		"sizes": sizes,
		"properties": properties,
		"definitions": definitions,
		"physical_indices": physical,
		"dynamic_indices": dynamic,
		"agent_indices": agents,
		"trigger_indices": triggers,
		"goal_indices": goals,
		"id_to_index": id_to_index,
		"bounds": _generation_bounds(world_data),
	}


## The world a dataset was made in, in the form a robot needs to stand in it:
## the bounds positions are normalised against, where the first agent starts
## and how big it is, and where the goal is (null when there is none). Plain
## arrays, so it survives JSON and the dataset's metadata.
static func training_world(blueprint: Dictionary) -> Dictionary:
	var bounds: Rect2 = blueprint.get("bounds", Rect2(-480.0, -260.0, 960.0, 520.0))
	var result := {
		"bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y],
		"agent_start": null,
		"agent_size": null,
		"agent_type": "",
		"goal": null,
	}
	var agents: PackedInt32Array = blueprint.get("agent_indices", PackedInt32Array())
	if not agents.is_empty():
		var index := agents[0]
		var position: Vector2 = blueprint["positions"][index]
		var size: Vector2 = blueprint["sizes"][index] * (blueprint["scales"][index] as Vector2).abs()
		result["agent_start"] = [position.x, position.y, float(blueprint["rotations"][index])]
		result["agent_size"] = [size.x, size.y]
		result["agent_type"] = str(blueprint["types"][index])
	var goals: PackedInt32Array = blueprint.get("goal_indices", PackedInt32Array())
	if not goals.is_empty():
		var goal: Vector2 = blueprint["positions"][goals[0]]
		result["goal"] = [goal.x, goal.y]
	return result


static func clone_for_thread(blueprint: Dictionary) -> Dictionary:
	# A worker receives ownership of every mutable nested container.
	return blueprint.duplicate(true)


static func _generation_bounds(world_data: Dictionary) -> Rect2:
	var metadata: Variant = world_data.get("metadata", {})
	var raw: Variant = metadata.get("generation_bounds", [-480.0, -260.0, 480.0, 260.0]) if metadata is Dictionary else []
	if raw is Array and raw.size() >= 4:
		var left := float(raw[0])
		var top := float(raw[1])
		var right := float(raw[2])
		var bottom := float(raw[3])
		return Rect2(Vector2(minf(left, right), minf(top, bottom)), Vector2(maxf(1.0, absf(right - left)), maxf(1.0, absf(bottom - top))))
	return Rect2(-480.0, -260.0, 960.0, 520.0)


static func _as_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


static func _session_properties(raw: Variant) -> Dictionary:
	# Session blueprints cross thread boundaries. Keep only the pure-data fields
	# consumed by the kernel and never forward arbitrary Objects/Resources.
	var result := {}
	if raw is not Dictionary:
		return result
	for key in ["model_binding", "randomization"]:
		var value: Variant = raw.get(key)
		if value is Dictionary:
			result[key] = value.duplicate(true)
	return result


static func _session_metadata(raw: Variant) -> Dictionary:
	var result := {}
	if raw is not Dictionary:
		return result
	for key in ["randomization", "expert_waypoints", "expert_waypoint_radius"]:
		var value: Variant = raw.get(key)
		if value is Dictionary or value is Array:
			result[key] = value.duplicate(true)
		elif value is PackedVector2Array:
			result[key] = value.duplicate()
		elif value is int or value is float or value is bool or value is String:
			result[key] = value
	return result
