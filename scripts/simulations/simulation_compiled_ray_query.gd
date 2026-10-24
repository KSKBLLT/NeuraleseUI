class_name SimulationCompiledRayQuery
extends RefCounted

## Thread-local ray sensor broadphase over a compiled simulation blueprint.
## PhysicsServer2D still owns motion and collision response; this class only
## replaces direct-space ray queries, which Godot does not expose to workers.

const CELL_SIZE: float = 192.0
const EPSILON: float = 0.000001
const NO_HIT: float = 1.0e30

var _definitions: Array[Dictionary] = []
var _positions: PackedVector2Array = PackedVector2Array()
var _rotations: PackedFloat32Array = PackedFloat32Array()
var _base_positions: PackedVector2Array = PackedVector2Array()
var _base_rotations: PackedFloat32Array = PackedFloat32Array()
var _sizes: PackedVector2Array = PackedVector2Array()
var _scales: PackedVector2Array = PackedVector2Array()
var _dynamic_indices: PackedInt32Array = PackedInt32Array()
var _static_flags: PackedByteArray = PackedByteArray()
var _cells: Dictionary = {}
var _cells_by_index: Array = []
var _visited: PackedInt32Array = PackedInt32Array()
var _query_serial: int = 0


func configure(blueprint: Dictionary) -> void:
	_definitions.clear()
	var raw_definitions: Variant = blueprint.get("definitions", [])
	if raw_definitions is Array:
		for raw_definition in raw_definitions:
			var definition: Dictionary = raw_definition if raw_definition is Dictionary else {}
			_definitions.append(definition)
	_positions = PackedVector2Array(blueprint.get("positions", PackedVector2Array()))
	_rotations = PackedFloat32Array(blueprint.get("rotations", PackedFloat32Array()))
	_base_positions = _positions.duplicate()
	_base_rotations = _rotations.duplicate()
	_sizes = PackedVector2Array(blueprint.get("sizes", PackedVector2Array()))
	_scales = PackedVector2Array(blueprint.get("scales", PackedVector2Array()))
	_dynamic_indices = PackedInt32Array(blueprint.get("dynamic_indices", PackedInt32Array()))

	var object_count: int = _positions.size()
	_static_flags.resize(object_count)
	_static_flags.fill(0)
	_visited.resize(object_count)
	_visited.fill(0)
	_cells_by_index.resize(object_count)
	for index in object_count:
		_cells_by_index[index] = []
	var dynamic_flags: PackedByteArray = PackedByteArray()
	dynamic_flags.resize(object_count)
	dynamic_flags.fill(0)
	for dynamic_index in _dynamic_indices:
		if dynamic_index >= 0 and dynamic_index < object_count:
			dynamic_flags[dynamic_index] = 1
	for physical_index in blueprint.get("physical_indices", PackedInt32Array()):
		if physical_index < 0 or physical_index >= object_count or dynamic_flags[physical_index] != 0:
			continue
		if _definitions[physical_index].get("body_kind", "static") == "area":
			continue
		_static_flags[physical_index] = 1
		_insert_static(physical_index)


func clear() -> void:
	_definitions.clear()
	_positions.clear()
	_rotations.clear()
	_base_positions.clear()
	_base_rotations.clear()
	_sizes.clear()
	_scales.clear()
	_dynamic_indices.clear()
	_static_flags.clear()
	_cells.clear()
	_cells_by_index.clear()
	_visited.clear()
	_query_serial = 0


func reset_to_blueprint() -> void:
	_positions = _base_positions.duplicate()
	_rotations = _base_rotations.duplicate()
	_rebuild_static_grid()


func set_transform(index: int, position: Vector2, rotation: float) -> void:
	if index < 0 or index >= _positions.size():
		return
	if _static_flags[index] != 0:
		_remove_static(index)
	_positions[index] = position
	_rotations[index] = rotation
	if _static_flags[index] != 0:
		_insert_static(index)


func live_update_object(index: int, object_data: Dictionary) -> void:
	if index < 0 or index >= _positions.size():
		return
	if _static_flags[index] != 0:
		_remove_static(index)
	_positions[index] = object_data.get("position", Vector2.ZERO)
	_rotations[index] = float(object_data.get("rotation", 0.0))
	_sizes[index] = object_data.get("size", Vector2.ZERO)
	_scales[index] = object_data.get("scale", Vector2.ONE)
	if _static_flags[index] != 0:
		_insert_static(index)


func raycast_fan(index: int, count: int, distance: float, arc_degrees: float) -> PackedFloat32Array:
	var ray_count: int = maxi(1, count)
	var result: PackedFloat32Array = PackedFloat32Array()
	result.resize(ray_count)
	result.fill(1.0)
	if index < 0 or index >= _positions.size() or distance <= EPSILON:
		return result
	var origin: Vector2 = _positions[index]
	var heading: float = _rotations[index]
	for ray_index in ray_count:
		var ratio: float = 0.5 if ray_count == 1 else float(ray_index) / float(ray_count - 1)
		var angle: float = heading + deg_to_rad(arc_degrees * (ratio - 0.5))
		var direction: Vector2 = Vector2.RIGHT.rotated(angle)
		result[ray_index] = raycast(origin, direction, distance, index)
	return result


func raycast_direction(index: int, direction: Vector2, distance: float) -> float:
	if index < 0 or index >= _positions.size():
		return 1.0
	return raycast(_positions[index], direction, distance, index)


func raycast(origin: Vector2, direction: Vector2, distance: float, excluded_index: int = -1) -> float:
	if distance <= EPSILON or direction.length_squared() <= EPSILON:
		return 1.0
	var normalized_direction: Vector2 = direction.normalized()
	var end: Vector2 = origin + normalized_direction * distance
	var minimum: Vector2 = Vector2(minf(origin.x, end.x), minf(origin.y, end.y))
	var maximum: Vector2 = Vector2(maxf(origin.x, end.x), maxf(origin.y, end.y))
	var minimum_cell: Vector2i = _cell_for(minimum)
	var maximum_cell: Vector2i = _cell_for(maximum)
	var serial: int = _next_query_serial()
	var nearest: float = NO_HIT

	for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
		for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
			var cell_key: Vector2i = Vector2i(cell_x, cell_y)
			var bucket: Variant = _cells.get(cell_key)
			if bucket is not Array:
				continue
			for candidate_value in bucket:
				var candidate: int = int(candidate_value)
				if candidate == excluded_index or _visited[candidate] == serial:
					continue
				_visited[candidate] = serial
				nearest = minf(nearest, _hit_distance(candidate, origin, normalized_direction, distance))
	for candidate in _dynamic_indices:
		if candidate == excluded_index or candidate < 0 or candidate >= _positions.size():
			continue
		nearest = minf(nearest, _hit_distance(candidate, origin, normalized_direction, distance))
	return 1.0 if nearest == NO_HIT else clampf(nearest / distance, 0.0, 1.0)


func _next_query_serial() -> int:
	_query_serial += 1
	if _query_serial >= 2147483000:
		_visited.fill(0)
		_query_serial = 1
	return _query_serial


func _hit_distance(index: int, origin: Vector2, direction: Vector2, maximum_distance: float) -> float:
	if index < 0 or index >= _definitions.size():
		return NO_HIT
	var definition: Dictionary = _definitions[index]
	var shape_kind: String = str(definition.get("shape_kind", "rectangle"))
	var scaled_size: Vector2 = _sizes[index] * _scales[index].abs()
	match shape_kind:
		"circle":
			return _circle_hit(origin, direction, maximum_distance, _positions[index], minf(scaled_size.x, scaled_size.y) * 0.5)
		"slope":
			return _slope_hit(index, origin, direction, maximum_distance, scaled_size * 0.5)
		_:
			return _rectangle_hit(index, origin, direction, maximum_distance, scaled_size * 0.5)


func _circle_hit(origin: Vector2, direction: Vector2, maximum_distance: float, center: Vector2, radius: float) -> float:
	var offset: Vector2 = origin - center
	var projection: float = offset.dot(direction)
	var constant: float = offset.length_squared() - radius * radius
	if constant <= 0.0:
		return 0.0
	var discriminant: float = projection * projection - constant
	if discriminant < 0.0:
		return NO_HIT
	var distance: float = -projection - sqrt(discriminant)
	return distance if distance >= 0.0 and distance <= maximum_distance else NO_HIT


func _rectangle_hit(index: int, origin: Vector2, direction: Vector2, maximum_distance: float, half_size: Vector2) -> float:
	var local_origin: Vector2 = (origin - _positions[index]).rotated(-_rotations[index])
	var local_direction: Vector2 = direction.rotated(-_rotations[index])
	var minimum_distance: float = 0.0
	var maximum_hit: float = maximum_distance
	var x_interval: Vector2 = _slab_interval(local_origin.x, local_direction.x, half_size.x)
	if x_interval.x > x_interval.y:
		return NO_HIT
	minimum_distance = maxf(minimum_distance, x_interval.x)
	maximum_hit = minf(maximum_hit, x_interval.y)
	if minimum_distance > maximum_hit:
		return NO_HIT
	var y_interval: Vector2 = _slab_interval(local_origin.y, local_direction.y, half_size.y)
	if y_interval.x > y_interval.y:
		return NO_HIT
	minimum_distance = maxf(minimum_distance, y_interval.x)
	maximum_hit = minf(maximum_hit, y_interval.y)
	return minimum_distance if minimum_distance <= maximum_hit else NO_HIT


func _slab_interval(origin: float, direction: float, half_extent: float) -> Vector2:
	if absf(direction) <= EPSILON:
		return Vector2(-NO_HIT, NO_HIT) if absf(origin) <= half_extent else Vector2(NO_HIT, -NO_HIT)
	var first: float = (-half_extent - origin) / direction
	var second: float = (half_extent - origin) / direction
	return Vector2(minf(first, second), maxf(first, second))


func _slope_hit(index: int, origin: Vector2, direction: Vector2, maximum_distance: float, half_size: Vector2) -> float:
	var local_origin: Vector2 = (origin - _positions[index]).rotated(-_rotations[index])
	var local_direction: Vector2 = direction.rotated(-_rotations[index])
	var first: Vector2 = Vector2(-half_size.x, half_size.y)
	var second: Vector2 = Vector2(half_size.x, -half_size.y)
	var third: Vector2 = Vector2(half_size.x, half_size.y)
	if _point_in_triangle(local_origin, first, second, third):
		return 0.0
	var nearest: float = NO_HIT
	nearest = minf(nearest, _ray_segment_hit(local_origin, local_direction, maximum_distance, first, second))
	nearest = minf(nearest, _ray_segment_hit(local_origin, local_direction, maximum_distance, second, third))
	nearest = minf(nearest, _ray_segment_hit(local_origin, local_direction, maximum_distance, third, first))
	return nearest


func _point_in_triangle(point: Vector2, first: Vector2, second: Vector2, third: Vector2) -> bool:
	var first_sign: float = (second - first).cross(point - first)
	var second_sign: float = (third - second).cross(point - second)
	var third_sign: float = (first - third).cross(point - third)
	var has_negative: bool = first_sign < 0.0 or second_sign < 0.0 or third_sign < 0.0
	var has_positive: bool = first_sign > 0.0 or second_sign > 0.0 or third_sign > 0.0
	return not (has_negative and has_positive)


func _ray_segment_hit(origin: Vector2, direction: Vector2, maximum_distance: float, first: Vector2, second: Vector2) -> float:
	var segment: Vector2 = second - first
	var divisor: float = direction.cross(segment)
	if absf(divisor) <= EPSILON:
		return NO_HIT
	var relative: Vector2 = first - origin
	var ray_distance: float = relative.cross(segment) / divisor
	var segment_ratio: float = relative.cross(direction) / divisor
	return ray_distance if ray_distance >= 0.0 and ray_distance <= maximum_distance and segment_ratio >= 0.0 and segment_ratio <= 1.0 else NO_HIT


func _rebuild_static_grid() -> void:
	_cells.clear()
	for index in _cells_by_index.size():
		_cells_by_index[index] = []
	for index in _static_flags.size():
		if _static_flags[index] != 0 and _definitions[index].get("body_kind", "static") != "area":
			_insert_static(index)


func _insert_static(index: int) -> void:
	var bounds: Rect2 = _bounds_for(index)
	var minimum_cell: Vector2i = _cell_for(bounds.position)
	var maximum_cell: Vector2i = _cell_for(bounds.end)
	var occupied_cells: Array[Vector2i] = []
	for cell_y in range(minimum_cell.y, maximum_cell.y + 1):
		for cell_x in range(minimum_cell.x, maximum_cell.x + 1):
			var cell_key: Vector2i = Vector2i(cell_x, cell_y)
			var bucket: Array = _cells.get(cell_key, [])
			bucket.append(index)
			_cells[cell_key] = bucket
			occupied_cells.append(cell_key)
	_cells_by_index[index] = occupied_cells


func _remove_static(index: int) -> void:
	var occupied_cells: Variant = _cells_by_index[index]
	if occupied_cells is not Array:
		return
	for cell_key_value in occupied_cells:
		var cell_key: Vector2i = cell_key_value
		var bucket: Variant = _cells.get(cell_key)
		if bucket is not Array:
			continue
		var position_in_bucket: int = bucket.find(index)
		if position_in_bucket >= 0:
			bucket.remove_at(position_in_bucket)
		if bucket.is_empty():
			_cells.erase(cell_key)
		else:
			_cells[cell_key] = bucket
	_cells_by_index[index] = []


func _bounds_for(index: int) -> Rect2:
	var scaled_size: Vector2 = _sizes[index] * _scales[index].abs()
	var shape_kind: String = str(_definitions[index].get("shape_kind", "rectangle"))
	if shape_kind == "circle":
		var radius: float = minf(scaled_size.x, scaled_size.y) * 0.5
		return Rect2(_positions[index] - Vector2(radius, radius), Vector2(radius * 2.0, radius * 2.0))
	var half_size: Vector2 = scaled_size * 0.5
	var cosine: float = absf(cos(_rotations[index]))
	var sine: float = absf(sin(_rotations[index]))
	var extent: Vector2 = Vector2(cosine * half_size.x + sine * half_size.y, sine * half_size.x + cosine * half_size.y)
	return Rect2(_positions[index] - extent, extent * 2.0)


func _cell_for(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / CELL_SIZE), floori(point.y / CELL_SIZE))
