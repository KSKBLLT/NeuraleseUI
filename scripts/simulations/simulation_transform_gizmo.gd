class_name SimulationTransformGizmo
extends Node2D

const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

const HANDLE_DISTANCE := 24.0
const HANDLE_RADIUS := 7.0
const HANDLE_HIT_RADIUS := 13.0

var _target: Node2D = null
var _zoom := 1.0
var _is_agent := false


func _ready() -> void:
	z_index = 4095
	visible = false
	set_process(true)


func _process(_delta: float) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"gizmo.process")
	if not is_instance_valid(_target):
		clear_target()
		PerformanceProbe.end_scope(&"gizmo.process", perf_token)
		return
	queue_redraw()
	PerformanceProbe.end_scope(&"gizmo.process", perf_token)


func show_for(target: Node2D, zoom_value: float = 1.0, is_agent: bool = false) -> void:
	_target = target
	_zoom = maxf(zoom_value, 0.001)
	_is_agent = is_agent
	visible = is_instance_valid(_target)
	queue_redraw()


func clear_target() -> void:
	_target = null
	visible = false
	queue_redraw()


func set_zoom_value(zoom_value: float) -> void:
	_zoom = maxf(zoom_value, 0.001)
	queue_redraw()


func handle_at(world_position: Vector2) -> StringName:
	if not is_instance_valid(_target):
		return &""
	var hit_radius := HANDLE_HIT_RADIUS / _zoom
	if world_position.distance_to(resize_handle_position()) <= hit_radius:
		return &"resize"
	if world_position.distance_to(rotate_handle_position()) <= hit_radius:
		return &"rotate"
	return &""


func resize_handle_position() -> Vector2:
	if not is_instance_valid(_target) or _is_agent:
		return Vector2.INF
	return _target.to_global(_target.object_size * 0.5)


func rotate_handle_position() -> Vector2:
	if not is_instance_valid(_target):
		return Vector2.ZERO
	var local_offset := Vector2(
		0.0,
		-_target.object_size.y * 0.5 - HANDLE_DISTANCE / maxf(_target.scale.y, 0.001) / _zoom
	)
	return _target.to_global(local_offset)


func _draw() -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"gizmo.draw")
	_profiled_draw()
	PerformanceProbe.end_scope(&"gizmo.draw", perf_token)


func _profiled_draw() -> void:
	if not is_instance_valid(_target):
		return
	var half_size: Vector2 = _target.object_size * 0.5
	var corners := PackedVector2Array([
		_target.to_global(Vector2(-half_size.x, -half_size.y)),
		_target.to_global(Vector2(half_size.x, -half_size.y)),
		_target.to_global(Vector2(half_size.x, half_size.y)),
		_target.to_global(Vector2(-half_size.x, half_size.y)),
	])
	var outline := PackedVector2Array(corners)
	outline.append(corners[0])
	var color := Color("65d8dc")
	draw_polyline(outline, color, 2.0 / _zoom, true)
	var rotate_position := rotate_handle_position()
	var top_center := (corners[0] + corners[1]) * 0.5
	draw_line(top_center, rotate_position, color, 1.5 / _zoom, true)
	if not _is_agent:
		draw_circle(resize_handle_position(), HANDLE_RADIUS / _zoom, Color("111419"))
		draw_circle(resize_handle_position(), HANDLE_RADIUS / _zoom, color, false, 2.0 / _zoom, true)
	draw_circle(rotate_position, HANDLE_RADIUS / _zoom, Color("111419"))
	draw_circle(rotate_position, HANDLE_RADIUS / _zoom, color, false, 2.0 / _zoom, true)
