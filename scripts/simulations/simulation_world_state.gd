class_name SimulationWorldState
extends RefCounted

## Data-oriented simulation document. No scene nodes or engine resources are stored here,
## so immutable snapshots can safely be handed to worker threads.

const ObjectCatalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")
const RandomizationProfile = preload("res://scripts/simulations/simulation_randomization_profile.gd")

const FORMAT_VERSION := 2
const LEGACY_FORMAT_VERSION := 1

signal changed
signal structure_changed
signal object_changed(object_id: String)
signal metadata_changed

var world_name: String = "Untitled simulation"
var metadata: Dictionary = {}
var perspective_mode: StringName = &"auto"

var _ids := PackedStringArray()
var _types := PackedStringArray()
var _positions := PackedVector2Array()
var _rotations := PackedFloat32Array()
var _scales := PackedVector2Array()
var _sizes := PackedVector2Array()
var _properties: Array[Dictionary] = []
var _id_to_index: Dictionary = {}
var _next_id := 1


func add_object(
	type_id: StringName,
	transform: Transform2D,
	properties: Dictionary = {}
) -> String:
	if not ObjectCatalog.has_type(type_id):
		return ""
	var object_id := str(properties.get("id", ""))
	if object_id.is_empty() or _id_to_index.has(object_id):
		object_id = _generate_id()
	else:
		_track_id(object_id)
	var definition := ObjectCatalog.definition(type_id)
	var clean_properties: Dictionary = properties.duplicate(true)
	for key in ["id", "position", "rotation", "scale", "size"]:
		clean_properties.erase(key)
	var data := {
		"id": object_id,
		"type_id": str(type_id),
		"position": transform.origin,
		"rotation": transform.get_rotation(),
		"scale": transform.get_scale(),
		"size": _as_vector2(properties.get("size"), definition.get("default_size", Vector2(64.0, 64.0))),
		"properties": clean_properties,
	}
	insert_object_data(data)
	return object_id


func insert_object_data(data: Dictionary, at_index: int = -1) -> bool:
	var normalized := _normalize_object(data)
	if normalized.is_empty():
		return false
	var object_id := str(normalized["id"])
	if _id_to_index.has(object_id):
		return false
	var index := clampi(at_index, 0, _ids.size()) if at_index >= 0 else _ids.size()
	_ids.insert(index, object_id)
	_types.insert(index, str(normalized["type_id"]))
	_positions.insert(index, normalized["position"])
	_rotations.insert(index, normalized["rotation"])
	_scales.insert(index, normalized["scale"])
	_sizes.insert(index, normalized["size"])
	_properties.insert(index, normalized["properties"])
	_track_id(object_id)
	_reindex_from(index)
	structure_changed.emit()
	changed.emit()
	return true


func update_object(object_id: String, patch: Dictionary) -> bool:
	var index := index_of(object_id)
	if index < 0:
		return false
	if patch.has("type_id"):
		var next_type := StringName(patch["type_id"])
		if ObjectCatalog.has_type(next_type):
			_types[index] = str(next_type)
	if patch.has("position"):
		_positions[index] = _as_vector2(patch["position"], _positions[index])
	if patch.has("rotation"):
		_rotations[index] = float(patch["rotation"])
	if patch.has("scale"):
		_scales[index] = _as_vector2(patch["scale"], _scales[index])
	if patch.has("size"):
		var next_size := _as_vector2(patch["size"], _sizes[index])
		_sizes[index] = Vector2(maxf(8.0, next_size.x), maxf(8.0, next_size.y))
	if patch.has("properties") and patch["properties"] is Dictionary:
		var merged := _properties[index].duplicate(true)
		merged.merge(patch["properties"], true)
		_properties[index] = merged
	object_changed.emit(object_id)
	changed.emit()
	return true


func replace_object(data: Dictionary) -> bool:
	var object_id := str(data.get("id", ""))
	var index := index_of(object_id)
	var normalized := _normalize_object(data)
	if index < 0 or normalized.is_empty():
		return false
	_types[index] = normalized["type_id"]
	_positions[index] = normalized["position"]
	_rotations[index] = normalized["rotation"]
	_scales[index] = normalized["scale"]
	_sizes[index] = normalized["size"]
	_properties[index] = normalized["properties"]
	object_changed.emit(object_id)
	changed.emit()
	return true


func remove_object(object_id: String) -> bool:
	var index := index_of(object_id)
	if index < 0:
		return false
	_ids.remove_at(index)
	_types.remove_at(index)
	_positions.remove_at(index)
	_rotations.remove_at(index)
	_scales.remove_at(index)
	_sizes.remove_at(index)
	_properties.remove_at(index)
	_id_to_index.erase(object_id)
	_reindex_from(index)
	structure_changed.emit()
	changed.emit()
	return true


func clear() -> void:
	_ids.clear()
	_types.clear()
	_positions.clear()
	_rotations.clear()
	_scales.clear()
	_sizes.clear()
	_properties.clear()
	_id_to_index.clear()
	_next_id = 1
	structure_changed.emit()
	changed.emit()


func set_metadata(next_metadata: Dictionary) -> void:
	metadata = next_metadata.duplicate(true)
	metadata_changed.emit()
	changed.emit()


func object_count() -> int:
	return _ids.size()


func has_object(object_id: String) -> bool:
	return _id_to_index.has(object_id)


func index_of(object_id: String) -> int:
	return int(_id_to_index.get(object_id, -1))


func id_at(index: int) -> String:
	return _ids[index] if index >= 0 and index < _ids.size() else ""


func type_at(index: int) -> StringName:
	return StringName(_types[index]) if index >= 0 and index < _types.size() else &""


func position_at(index: int) -> Vector2:
	return _positions[index] if index >= 0 and index < _positions.size() else Vector2.ZERO


func rotation_at(index: int) -> float:
	return _rotations[index] if index >= 0 and index < _rotations.size() else 0.0


func scale_at(index: int) -> Vector2:
	return _scales[index] if index >= 0 and index < _scales.size() else Vector2.ONE


func size_at(index: int) -> Vector2:
	return _sizes[index] if index >= 0 and index < _sizes.size() else Vector2.ZERO


func properties_at(index: int) -> Dictionary:
	return _properties[index].duplicate(true) if index >= 0 and index < _properties.size() else {}


func ordered_ids() -> Array[String]:
	var result: Array[String] = []
	result.assign(Array(_ids))
	return result


func object_data(object_id: String) -> Dictionary:
	return object_data_at(index_of(object_id))


func object_data_at(index: int) -> Dictionary:
	if index < 0 or index >= _ids.size():
		return {}
	return {
		"id": _ids[index],
		"type_id": _types[index],
		"position": _positions[index],
		"rotation": _rotations[index],
		"scale": _scales[index],
		"size": _sizes[index],
		"properties": _properties[index].duplicate(true),
	}


func render_data_at(index: int) -> Dictionary:
	if index < 0 or index >= _ids.size():
		return {}
	return {
		"id": _ids[index],
		"type_id": _types[index],
		"position": _positions[index],
		"rotation": _rotations[index],
		"scale": _scales[index],
		"size": _sizes[index],
		"properties": _properties[index],
	}


func objects_array() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	result.resize(object_count())
	for index in object_count():
		result[index] = object_data_at(index)
	return result


func world_bounds() -> Rect2:
	var result := Rect2()
	var initialized := false
	for index in object_count():
		var bounds := object_bounds_at(index)
		result = result.merge(bounds) if initialized else bounds
		initialized = true
	return result


func world_bounds_islands(padding: float = 256.0) -> Array[Rect2]:
	var rects: Array[Rect2] = []
	for index in object_count():
		rects.append(object_bounds_at(index).grow(padding))

	# Sort left to right by minimum X coordinate
	rects.sort_custom(func(a, b): return a.position.x < b.position.x)

	var active_islands: Array[Rect2] = []
	var final_islands: Array[Rect2] = []

	for r in rects:
		# Finalize active islands that are completely behind the sweep line
		var i = 0
		while i < active_islands.size():
			if active_islands[i].position.x + active_islands[i].size.x < r.position.x:
				final_islands.append(active_islands[i])
				active_islands.remove_at(i)
			else:
				i += 1

		# Merge current rect with overlapping active islands
		var current = r
		i = 0
		while i < active_islands.size():
			if active_islands[i].intersects(current, true):
				current = current.merge(active_islands[i])
				active_islands.remove_at(i)
				i = 0 # Restart check since merging can expand bounds
			else:
				i += 1

		active_islands.append(current)

	final_islands.append_array(active_islands)
	return final_islands


func object_bounds_at(index: int) -> Rect2:
	if index < 0 or index >= object_count():
		return Rect2()
	var half := _sizes[index] * _scales[index].abs() * 0.5
	var transform := Transform2D(_rotations[index], _positions[index])
	var corners := [
		transform * Vector2(-half.x, -half.y),
		transform * Vector2(half.x, -half.y),
		transform * Vector2(half.x, half.y),
		transform * Vector2(-half.x, half.y),
	]
	var minimum: Vector2 = corners[0]
	var maximum: Vector2 = corners[0]
	for corner: Vector2 in corners:
		minimum = minimum.min(corner)
		maximum = maximum.max(corner)
	return Rect2(minimum, maximum - minimum)


func to_dictionary() -> Dictionary:
	var sparse_properties := {}
	for index in _properties.size():
		if not _properties[index].is_empty():
			sparse_properties[_ids[index]] = _properties[index].duplicate(true)
	return {
		"version": FORMAT_VERSION,
		"world_name": world_name,
		"perspective_mode": str(perspective_mode),
		"metadata": metadata.duplicate(true),
		"objects": {
			"ids": _ids.duplicate(),
			"types": _types.duplicate(),
			"positions": _positions.duplicate(),
			"rotations": _rotations.duplicate(),
			"scales": _scales.duplicate(),
			"sizes": _sizes.duplicate(),
			"properties": sparse_properties,
		},
	}


func thread_snapshot() -> Dictionary:
	# Every mutable container is detached. Worker threads own the returned snapshot.
	return to_dictionary()


func load_dictionary(data: Dictionary) -> void:
	_clear_without_signals()
	world_name = str(data.get("world_name", "Untitled simulation"))
	perspective_mode = StringName(data.get("perspective_mode", "auto"))
	metadata = data.get("metadata", {}).duplicate(true) if data.get("metadata", {}) is Dictionary else {}
	for raw_object in objects_from_dictionary(data):
		var normalized := _normalize_object(raw_object)
		if normalized.is_empty() or _id_to_index.has(str(normalized["id"])):
			continue
		_append_without_signals(normalized)
	structure_changed.emit()
	metadata_changed.emit()
	changed.emit()


static func objects_from_dictionary(data: Dictionary) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var raw_objects: Variant = data.get("objects", [])
	if raw_objects is Array:
		for raw_object in raw_objects:
			if raw_object is Dictionary:
				result.append(raw_object.duplicate(true))
		return result
	if raw_objects is not Dictionary:
		return result
	var columns: Dictionary = raw_objects
	var ids: Variant = columns.get("ids", PackedStringArray())
	var types: Variant = columns.get("types", PackedStringArray())
	var positions: Variant = columns.get("positions", PackedVector2Array())
	var rotations: Variant = columns.get("rotations", PackedFloat32Array())
	var scales: Variant = columns.get("scales", PackedVector2Array())
	var sizes: Variant = columns.get("sizes", PackedVector2Array())
	var sparse: Variant = columns.get("properties", {})
	if ids is not PackedStringArray and ids is not Array:
		return result
	for index in ids.size():
		if index >= types.size() or index >= positions.size() or index >= rotations.size() or index >= scales.size() or index >= sizes.size():
			break
		var object_id := str(ids[index])
		result.append({
			"id": object_id,
			"type_id": str(types[index]),
			"position": positions[index],
			"rotation": rotations[index],
			"scale": scales[index],
			"size": sizes[index],
			"properties": sparse.get(object_id, {}).duplicate(true) if sparse is Dictionary else {},
		})
	return result


static func has_serialized_objects(data: Dictionary) -> bool:
	var raw: Variant = data.get("objects", [])
	if raw is Array:
		return not raw.is_empty()
	if raw is Dictionary:
		return raw.get("ids", []).size() > 0
	return false


static func validate_dictionary(data: Dictionary) -> Dictionary:
	var errors: Array[Dictionary] = []
	var version := int(data.get("version", LEGACY_FORMAT_VERSION))
	if version not in [LEGACY_FORMAT_VERSION, FORMAT_VERSION]:
		_add_validation_error(errors, "unsupported_version", "Unsupported simulation world version.")
	if str(data.get("world_name", "")).strip_edges().is_empty():
		_add_validation_error(errors, "missing_world_name", "Simulation world name is required.")
	var raw_metadata: Variant = data.get("metadata", {})
	if raw_metadata is not Dictionary:
		_add_validation_error(errors, "invalid_metadata", "Simulation metadata must be an object.")
	elif raw_metadata.has("randomization"):
		for error in RandomizationProfile.validate(raw_metadata["randomization"]).get("errors", []):
			if error is Dictionary:
				errors.append(error.duplicate(true))
	var objects := objects_from_dictionary(data)
	var seen := {}
	for index in objects.size():
		var raw_object := objects[index]
		var object_id := str(raw_object.get("id", ""))
		var type_id := StringName(raw_object.get("type_id", ""))
		if object_id.is_empty():
			_add_validation_error(errors, "missing_object_id", "Simulation object id is required.", index)
		elif seen.has(object_id):
			_add_validation_error(errors, "duplicate_object_id", "Simulation object ids must be unique.", index)
		else:
			seen[object_id] = true
		if not ObjectCatalog.has_type(type_id):
			_add_validation_error(errors, "unknown_object_type", "Simulation object type is not registered.", index)
		for key in ["position", "scale", "size"]:
			if not _finite_vector(raw_object.get(key, Vector2.ZERO)):
				_add_validation_error(errors, "invalid_object_%s" % key, "Simulation object %s must be finite." % key, index)
		var rotation := float(raw_object.get("rotation", 0.0))
		if is_nan(rotation) or is_inf(rotation):
			_add_validation_error(errors, "invalid_object_rotation", "Simulation object rotation must be finite.", index)
		var properties: Variant = raw_object.get("properties", {})
		if properties is Dictionary and properties.has("model_binding"):
			var binding: Variant = properties["model_binding"]
			var definition := ObjectCatalog.definition(type_id)
			if binding is not Dictionary or not ModelBinding.validate(binding).get("valid", false) or StringName(binding.get("agent_id", "")) != StringName(definition.get("agent_id", "")):
				_add_validation_error(errors, "invalid_model_binding", "The saved model mapping is not compatible with this agent.", index)
		if properties is Dictionary and properties.get("randomization") is Dictionary:
			var object_randomization: Dictionary = properties["randomization"]
			var variants: Variant = object_randomization.get("material_variants", [])
			if variants is Array:
				for variant in variants:
					if not ObjectCatalog.is_surface_type(StringName(variant)):
						_add_validation_error(errors, "invalid_material_variant", "Surface randomization can only use registered surface materials.", index)
						break
	return {"valid": errors.is_empty(), "errors": errors}


func _normalize_object(data: Dictionary) -> Dictionary:
	var type_id := StringName(data.get("type_id", ""))
	var object_id := str(data.get("id", ""))
	if object_id.is_empty() or not ObjectCatalog.has_type(type_id):
		return {}
	var definition := ObjectCatalog.definition(type_id)
	return {
		"id": object_id,
		"type_id": str(type_id),
		"position": _as_vector2(data.get("position"), Vector2.ZERO),
		"rotation": float(data.get("rotation", 0.0)),
		"scale": _as_vector2(data.get("scale"), Vector2.ONE),
		"size": _as_vector2(data.get("size"), definition.get("default_size", Vector2(64.0, 64.0))),
		"properties": data.get("properties", {}).duplicate(true) if data.get("properties", {}) is Dictionary else {},
	}


func _append_without_signals(data: Dictionary) -> void:
	var index := _ids.size()
	_ids.append(data["id"])
	_types.append(data["type_id"])
	_positions.append(data["position"])
	_rotations.append(data["rotation"])
	_scales.append(data["scale"])
	_sizes.append(data["size"])
	_properties.append(data["properties"])
	_id_to_index[data["id"]] = index
	_track_id(data["id"])


func _clear_without_signals() -> void:
	_ids.clear()
	_types.clear()
	_positions.clear()
	_rotations.clear()
	_scales.clear()
	_sizes.clear()
	_properties.clear()
	_id_to_index.clear()
	_next_id = 1


func _reindex_from(start: int) -> void:
	for index in range(maxi(start, 0), _ids.size()):
		_id_to_index[_ids[index]] = index


func _generate_id() -> String:
	while _id_to_index.has("object-%d" % _next_id):
		_next_id += 1
	var result := "object-%d" % _next_id
	_next_id += 1
	return result


func _track_id(object_id: String) -> void:
	if not object_id.begins_with("object-"):
		return
	var suffix := object_id.trim_prefix("object-")
	if suffix.is_valid_int():
		_next_id = maxi(_next_id, suffix.to_int() + 1)


static func _as_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


static func _finite_vector(value: Variant) -> bool:
	var vector := _as_vector2(value, Vector2(NAN, NAN))
	return vector.is_finite()


static func _add_validation_error(errors: Array[Dictionary], code: String, message: String, object_index: int = -1) -> void:
	var error := {"code": code, "message": message}
	if object_index >= 0:
		error["object_index"] = object_index
	errors.append(error)
