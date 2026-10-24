class_name SimulationSpatialIndex
extends RefCounted

## Main-thread editor index. Physics is deliberately not used for picking.

var cell_size := 256.0
var _document: SimulationWorldState
var _cells: Dictionary = {}
var _object_cells: Dictionary = {}


func rebuild(document: SimulationWorldState) -> void:
	_document = document
	_cells.clear()
	_object_cells.clear()
	if _document == null:
		return
	for index in _document.object_count():
		_insert_bounds(index, _document.object_bounds_at(index))


func update_object(object_id: String) -> void:
	if _document == null:
		return
	var index := _document.index_of(object_id)
	if index < 0:
		return
	for key in _object_cells.get(index, []):
		var bucket: PackedInt32Array = _cells.get(key, PackedInt32Array())
		var at := bucket.find(index)
		if at >= 0:
			bucket.remove_at(at)
		if bucket.is_empty():
			_cells.erase(key)
		else:
			_cells[key] = bucket
	_insert_bounds(index, _document.object_bounds_at(index))


func object_at(point: Vector2, preferred_id: String = "") -> String:
	if _document == null:
		return ""
	var candidates := _indices_for_cell(_cell(point))
	if not preferred_id.is_empty():
		var preferred_index := _document.index_of(preferred_id)
		if preferred_index >= 0 and candidates.has(preferred_index) and _contains_point(preferred_index, point):
			return preferred_id
	for candidate_offset in candidates.size():
		var index := int(candidates[candidates.size() - 1 - candidate_offset])
		if _contains_point(index, point):
			return _document.id_at(index)
	return ""


func objects_in_rect(rect: Rect2) -> Array[String]:
	var result: Array[String] = []
	if _document == null or rect.size == Vector2.ZERO:
		return result
	var seen := {}
	var minimum := _cell(rect.position)
	var maximum := _cell(rect.end)
	for y in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			for index in _indices_for_cell(Vector2i(x, y)):
				if seen.has(index):
					continue
				seen[index] = true
				if rect.intersects(_document.object_bounds_at(index), true):
					result.append(_document.id_at(index))
	return result


func _insert_bounds(index: int, bounds: Rect2) -> void:
	var minimum := _cell(bounds.position)
	var maximum := _cell(bounds.end)
	var occupied: Array[Vector2i] = []
	for y in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			var key := Vector2i(x, y)
			var bucket: PackedInt32Array = _cells.get(key, PackedInt32Array())
			bucket.append(index)
			_cells[key] = bucket
			occupied.append(key)
	_object_cells[index] = occupied


func _indices_for_cell(key: Vector2i) -> PackedInt32Array:
	return _cells.get(key, PackedInt32Array())


func _cell(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / cell_size), floori(point.y / cell_size))


func _contains_point(index: int, point: Vector2) -> bool:
	var position := _document.position_at(index)
	var rotation := _document.rotation_at(index)
	var scale := _document.scale_at(index)
	var size := _document.size_at(index)
	var local := (point - position).rotated(-rotation)
	local = Vector2(
		local.x / maxf(absf(scale.x), 0.0001),
		local.y / maxf(absf(scale.y), 0.0001)
	)
	var definition := SimulationObjectCatalog.definition(_document.type_at(index))
	match str(definition.get("shape_kind", "rectangle")):
		"circle":
			var normalized := Vector2(local.x / maxf(size.x * 0.5, 0.001), local.y / maxf(size.y * 0.5, 0.001))
			return normalized.length_squared() <= 1.0
		"slope":
			return Geometry2D.is_point_in_polygon(local, PackedVector2Array([
				Vector2(-size.x * 0.5, size.y * 0.5),
				Vector2(size.x * 0.5, size.y * 0.5),
				Vector2(size.x * 0.5, -size.y * 0.5),
			]))
		_:
			return Rect2(-size * 0.5, size).has_point(local)

func raycast(origin: Vector2, direction: Vector2, max_distance: float, exclude_id: String = "") -> float:
	if _document == null:
		return max_distance
	var step_size := 4.0
	var distance := 0.0
	while distance <= max_distance:
		var point := origin + direction * distance
		var hit_id := object_at(point)
		if hit_id != "" and hit_id != exclude_id:
			return distance
		distance += step_size
	return max_distance
