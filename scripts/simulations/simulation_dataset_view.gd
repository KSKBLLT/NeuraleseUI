class_name SimulationDatasetView
extends Control

const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

const ObjectCatalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const ENVIRONMENT_COUNT := 1
const PREVIEW_SMOOTHING_SPEED := 12.0

var _previews: Array[Dictionary] = []
var _preview_targets: Array[Dictionary] = []
var _world_state: Dictionary = {}
var _world_objects: Array[Dictionary] = []


func _init() -> void:
	for _index in ENVIRONMENT_COUNT:
		_previews.append({})
		_preview_targets.append({})


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(queue_redraw)
	queue_redraw()


func environment_count() -> int:
	return ENVIRONMENT_COUNT


func configure_world(world_state: Dictionary) -> void:
	_world_state = world_state.duplicate(true)
	_world_objects = SimulationWorldState.objects_from_dictionary(_world_state)
	for index in ENVIRONMENT_COUNT:
		_previews[index] = {}
		_preview_targets[index] = {}
	queue_redraw()


func update_environment(index: int, preview: Dictionary) -> void:
	if index < 0 or index >= ENVIRONMENT_COUNT:
		return
	var target: Dictionary = preview.duplicate(true)
	_preview_targets[index] = target
	if _previews[index].is_empty():
		_previews[index] = target.duplicate(true)
	else:
		# Publish counters/status immediately while retaining the previous pose as
		# the interpolation origin. Worker previews stay sparse and inexpensive.
		var previous_position: Variant = _previews[index].get("world_position")
		var previous_goal: Variant = _previews[index].get("goal_world_position")
		var previous_rotation: float = float(_previews[index].get("rotation", target.get("rotation", 0.0)))
		var previous_rays: Variant = _previews[index].get("ray_values")
		_previews[index] = target.duplicate(true)
		if previous_position is Vector2:
			_previews[index]["world_position"] = previous_position
		if previous_goal is Vector2:
			_previews[index]["goal_world_position"] = previous_goal
		_previews[index]["rotation"] = previous_rotation
		if previous_rays is Array:
			_previews[index]["ray_values"] = previous_rays.duplicate()
	queue_redraw()


func _process(delta: float) -> void:
	if not visible:
		return
	var redraw_needed: bool = false
	for index in ENVIRONMENT_COUNT:
		redraw_needed = _smooth_preview(_previews[index], _preview_targets[index], delta) or redraw_needed
	if redraw_needed:
		queue_redraw()


func _smooth_preview(current: Dictionary, target: Dictionary, delta: float) -> bool:
	if current.is_empty() or target.is_empty():
		return false
	var weight: float = clampf(1.0 - exp(-PREVIEW_SMOOTHING_SPEED * maxf(delta, 0.0)), 0.0, 1.0)
	var changed: bool = false
	for key in ["world_position", "goal_world_position"]:
		var current_value: Variant = current.get(key)
		var target_value: Variant = target.get(key)
		if current_value is not Vector2 or target_value is not Vector2:
			continue
		var distance: float = current_value.distance_to(target_value)
		if distance <= 0.01:
			current[key] = target_value
			continue
		var teleport_threshold: float = _generation_bounds().size.length() * 0.4
		current[key] = target_value if distance > teleport_threshold else current_value.lerp(target_value, weight)
		changed = true
	var current_rotation: float = float(current.get("rotation", target.get("rotation", 0.0)))
	var target_rotation: float = float(target.get("rotation", current_rotation))
	if not is_equal_approx(current_rotation, target_rotation):
		current["rotation"] = lerp_angle(current_rotation, target_rotation, weight)
		changed = true
	var current_rays: Variant = current.get("ray_values", [])
	var target_rays: Variant = target.get("ray_values", [])
	if current_rays is Array and target_rays is Array and current_rays.size() == target_rays.size():
		for ray_index in current_rays.size():
			var current_ray: float = float(current_rays[ray_index])
			var target_ray: float = float(target_rays[ray_index])
			if not is_equal_approx(current_ray, target_ray):
				current_rays[ray_index] = lerpf(current_ray, target_ray, weight)
				changed = true
		current["ray_values"] = current_rays
	return changed


func preview_for(index: int) -> Dictionary:
	if index < 0 or index >= ENVIRONMENT_COUNT:
		return {}
	return _previews[index].duplicate(true)


func displayed_type_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for raw_object in _world_objects:
		if raw_object is not Dictionary:
			continue
		var type_id := StringName(raw_object.get("type_id", ""))
		if ObjectCatalog.has_type(type_id):
			result.append(type_id)
	return result


func _draw() -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"dataset.preview_draw")
	_profiled_draw()
	PerformanceProbe.end_scope(&"dataset.preview_draw", perf_token)


func _profiled_draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), Color("191b1e"), true)
	var rect := Rect2(Vector2(16.0, 14.0), Vector2(maxf(120.0, size.x - 32.0), maxf(78.0, size.y - 28.0)))
	_draw_environment(rect, _previews[0])


func _draw_environment(rect: Rect2, preview: Dictionary) -> void:
	var accent := Color("75dc9b")
	var badge := Rect2(rect.position, Vector2(84.0, 28.0))
	draw_style_box(_outline_box(Color(0.04, 0.045, 0.052, 0.98), accent, 4), badge)
	draw_string(ThemeDB.fallback_font, badge.position + Vector2(10.0, 19.0), "Live world", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color("e2e5e9"))

	var world_rect := Rect2(
		rect.position + Vector2(0.0, 40.0),
		Vector2(rect.size.x, maxf(38.0, rect.size.y - 40.0))
	)
	_draw_grid(world_rect)
	var bounds := _generation_bounds()
	var displayed_objects: Variant = preview.get("world_objects", _world_objects)
	for raw_object in displayed_objects:
		if raw_object is Dictionary:
			_draw_world_object(raw_object, preview, world_rect, bounds)


func _draw_world_object(
	data: Dictionary,
	preview: Dictionary,
	world_rect: Rect2,
	bounds: Rect2
) -> void:
	var type_id := StringName(data.get("type_id", ""))
	if not ObjectCatalog.has_type(type_id):
		return
	var definition := ObjectCatalog.definition(type_id)
	var role := str(definition.get("dataset_role", ""))
	var world_position := _as_vector2(data.get("position"), Vector2.ZERO)
	var rotation := float(data.get("rotation", 0.0))
	if role == "agent" and not preview.is_empty():
		world_position = _as_vector2(
			preview.get("world_position"),
			_world_from_normalized(preview.get("normalized_position", Vector2.ZERO), bounds)
		)
		rotation = float(preview.get("rotation", rotation))
	elif role == "goal" and not preview.is_empty():
		world_position = _as_vector2(
			preview.get("goal_world_position"),
			_world_from_normalized(preview.get("normalized_goal", Vector2.ONE * 0.5), bounds)
		)

	var center := _world_to_screen(world_position, world_rect, bounds)
	var object_size := _as_vector2(data.get("size"), definition.get("default_size", Vector2(40.0, 40.0)))
	var object_scale := _as_vector2(data.get("scale"), Vector2.ONE).abs()
	var screen_size := _world_size_to_screen(object_size * object_scale, world_rect, bounds)
	_draw_object_shape(type_id, definition, center, screen_size, rotation)
	if role == "agent" and not preview.is_empty():
		_draw_rays(center, rotation, preview.get("ray_values", []), maxf(screen_size.x, screen_size.y))


func _draw_object_shape(
	type_id: StringName,
	definition: Dictionary,
	center: Vector2,
	screen_size: Vector2,
	rotation: float
) -> void:
	var color := Color(definition.get("color", Color("7f858f")))
	var outline := color.lightened(0.3)
	var shape_kind := str(definition.get("shape_kind", "rectangle"))
	if type_id == &"spikes":
		_draw_spikes(center, screen_size, rotation, color, outline)
		return
	var points := _shape_points(shape_kind, center, screen_size, rotation)
	if points.size() < 3:
		return
	draw_colored_polygon(points, Color(color, 0.3 if str(definition.get("dataset_role", "")) != "agent" else 0.12))
	var closed := points.duplicate()
	closed.append(points[0])
	draw_polyline(closed, outline, 1.4, true)

	match type_id:
		&"finish":
			draw_line(center - Vector2(0.0, screen_size.y * 0.34), center + Vector2(0.0, screen_size.y * 0.4), Color("72e0a0"), 2.0, true)
		&"checkpoint":
			draw_line(center + Vector2(-screen_size.x * 0.18, -screen_size.y * 0.38), center + Vector2(-screen_size.x * 0.18, screen_size.y * 0.4), outline, 1.6, true)
		&"coin":
			draw_arc(center, minf(screen_size.x, screen_size.y) * 0.24, 0.0, TAU, 20, outline, 1.2, true)
		&"car":
			_draw_wheels(center, screen_size, rotation, outline)
		&"rover":
			_draw_rover_axes(center, screen_size, rotation, outline)
		&"flying_agent":
			_draw_rotors(center, screen_size, rotation, outline)


func _shape_points(
	shape_kind: String,
	center: Vector2,
	screen_size: Vector2,
	rotation: float
) -> PackedVector2Array:
	var local_points := PackedVector2Array()
	var half := screen_size * 0.5
	match shape_kind:
		"circle":
			for index in 24:
				var angle := TAU * float(index) / 24.0
				local_points.append(Vector2(cos(angle) * half.x, sin(angle) * half.y))
		"slope":
			local_points = PackedVector2Array([
				Vector2(-half.x, half.y),
				Vector2(half.x, half.y),
				Vector2(half.x, -half.y),
			])
		_:
			local_points = PackedVector2Array([
				Vector2(-half.x, -half.y),
				Vector2(half.x, -half.y),
				Vector2(half.x, half.y),
				Vector2(-half.x, half.y),
			])
	var result := PackedVector2Array()
	for point in local_points:
		result.append(center + point.rotated(rotation))
	return result


func _draw_spikes(
	center: Vector2,
	screen_size: Vector2,
	rotation: float,
	color: Color,
	outline: Color
) -> void:
	var count := maxi(2, int(screen_size.x / 14.0))
	var width := screen_size.x / float(count)
	for index in count:
		var left := -screen_size.x * 0.5 + float(index) * width
		var triangle := PackedVector2Array([
			center + Vector2(left, screen_size.y * 0.5).rotated(rotation),
			center + Vector2(left + width * 0.5, -screen_size.y * 0.5).rotated(rotation),
			center + Vector2(left + width, screen_size.y * 0.5).rotated(rotation),
		])
		draw_colored_polygon(triangle, Color(color, 0.34))
		var closed := triangle.duplicate()
		closed.append(triangle[0])
		draw_polyline(closed, outline, 1.2, true)


func _draw_wheels(center: Vector2, screen_size: Vector2, rotation: float, color: Color) -> void:
	for local_center in [Vector2(-screen_size.x * 0.28, screen_size.y * 0.42), Vector2(screen_size.x * 0.28, screen_size.y * 0.42)]:
		var wheel_center: Vector2 = center + local_center.rotated(rotation)
		draw_circle(wheel_center, maxf(2.5, screen_size.y * 0.16), Color("111318"))
		draw_arc(wheel_center, maxf(2.5, screen_size.y * 0.16), 0.0, TAU, 16, color, 1.2, true)


func _draw_rover_axes(center: Vector2, screen_size: Vector2, rotation: float, color: Color) -> void:
	for y in [-screen_size.y * 0.38, screen_size.y * 0.38]:
		var start := center + Vector2(-screen_size.x * 0.35, y).rotated(rotation)
		var finish := center + Vector2(screen_size.x * 0.35, y).rotated(rotation)
		draw_line(start, finish, color, 2.2, true)


func _draw_rotors(center: Vector2, screen_size: Vector2, rotation: float, color: Color) -> void:
	var radius := minf(screen_size.x, screen_size.y) * 0.34
	var directions: Array[Vector2] = [Vector2.LEFT, Vector2.RIGHT, Vector2.UP, Vector2.DOWN]
	for direction: Vector2 in directions:
		var rotor: Vector2 = center + (direction * radius).rotated(rotation)
		draw_line(center, rotor, Color(color, 0.65), 1.0, true)
		draw_circle(rotor, 2.4, color)


func _draw_rays(origin: Vector2, rotation: float, values: Variant, agent_size: float) -> void:
	var ray_values: Array = values if values is Array else []
	if ray_values.is_empty():
		return
	for index in ray_values.size():
		var fraction := float(index) / float(maxi(1, ray_values.size() - 1))
		var angle := rotation + deg_to_rad(150.0 * (fraction - 0.5))
		var distance := lerpf(agent_size * 0.55, agent_size * 2.3, clampf(float(ray_values[index]), 0.0, 1.0))
		var endpoint := origin + Vector2.RIGHT.rotated(angle) * distance
		draw_line(origin, endpoint, Color(0.34, 0.88, 0.9, 0.7), 1.0, true)
		draw_circle(endpoint, 1.5, Color("72dfe0"))


func _draw_grid(rect: Rect2) -> void:
	# Keep the animated preview cheap: line batches need tens of draw commands,
	# while the former dot field needed hundreds on every interpolated frame.
	var spacing: float = 28.0
	var grid_color: Color = Color(0.35, 0.38, 0.42, 0.13)
	var x: float = rect.position.x
	while x <= rect.end.x:
		draw_line(Vector2(x, rect.position.y), Vector2(x, rect.end.y), grid_color, 1.0)
		x += spacing
	var y: float = rect.position.y
	while y <= rect.end.y:
		draw_line(Vector2(rect.position.x, y), Vector2(rect.end.x, y), grid_color, 1.0)
		y += spacing


func _generation_bounds() -> Rect2:
	var raw_bounds: Variant = _world_state.get("metadata", {}).get(
		"generation_bounds",
		[-480.0, -260.0, 480.0, 260.0]
	)
	if raw_bounds is Array and raw_bounds.size() >= 4:
		var left := float(raw_bounds[0])
		var top := float(raw_bounds[1])
		var right := float(raw_bounds[2])
		var bottom := float(raw_bounds[3])
		return Rect2(
			Vector2(minf(left, right), minf(top, bottom)),
			Vector2(maxf(1.0, absf(right - left)), maxf(1.0, absf(bottom - top)))
		)
	return Rect2(-480.0, -260.0, 960.0, 520.0)


func _world_to_screen(world_position: Vector2, rect: Rect2, bounds: Rect2) -> Vector2:
	return Vector2(
		lerpf(rect.position.x, rect.end.x, inverse_lerp(bounds.position.x, bounds.end.x, world_position.x)),
		lerpf(rect.position.y, rect.end.y, inverse_lerp(bounds.position.y, bounds.end.y, world_position.y))
	)


func _world_size_to_screen(world_size: Vector2, rect: Rect2, bounds: Rect2) -> Vector2:
	return Vector2(
		maxf(4.0, world_size.x * rect.size.x / bounds.size.x),
		maxf(4.0, world_size.y * rect.size.y / bounds.size.y)
	)


func _world_from_normalized(value: Variant, bounds: Rect2) -> Vector2:
	var normalized := _as_vector2(value, Vector2.ONE * 0.5)
	return Vector2(
		lerpf(bounds.position.x, bounds.end.x, normalized.x),
		lerpf(bounds.position.y, bounds.end.y, normalized.y)
	)


func _as_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


func _outline_box(background: Color, border: Color, radius: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = border
	style.corner_radius_top_left = radius
	style.corner_radius_top_right = radius
	style.corner_radius_bottom_left = radius
	style.corner_radius_bottom_right = radius
	return style
