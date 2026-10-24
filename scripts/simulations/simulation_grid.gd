extends Node2D

const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")
const GridShader = preload("res://shaders/cells.gdshader")

const GRAPH_GRID_MULT: float = 0.5
const GRAPH_GRID_WIDTH: float = 7.98
const GRAPH_GRID_SPACING: float = 110.0
const GRAPH_GRID_COLOR: Color = Color(0.38, 0.38, 0.38, 1.0)
const GRAPH_GRID_BACKGROUND: Color = Color(0.25, 0.25, 0.25, 1.0)
const GRAPH_GRID_AA_PIXELS: float = 1.0

var _last_camera_position := Vector2.INF
var _last_camera_zoom := Vector2.ZERO
var _last_viewport_size := Vector2.ZERO


func _ready() -> void:
	z_index = -100
	var shader_material: ShaderMaterial = ShaderMaterial.new()
	shader_material.shader = GridShader
	material = shader_material
	queue_redraw()


func _process(_delta: float) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"grid.process")
	var viewport_size := get_viewport_rect().size
	var active_camera := get_viewport().get_camera_2d()
	var camera_position := Vector2.ZERO
	var camera_zoom := Vector2.ONE
	if is_instance_valid(active_camera):
		camera_position = active_camera.get_screen_center_position()
		camera_zoom = active_camera.zoom
	if (
		not camera_position.is_equal_approx(_last_camera_position)
		or not camera_zoom.is_equal_approx(_last_camera_zoom)
		or not viewport_size.is_equal_approx(_last_viewport_size)
	):
		_last_camera_position = camera_position
		_last_camera_zoom = camera_zoom
		_last_viewport_size = viewport_size
		queue_redraw()
	PerformanceProbe.end_scope(&"grid.process", perf_token)


func estimated_visible_dot_count(viewport_size: Vector2, zoom: Vector2) -> int:
	var safe_zoom := Vector2(maxf(absf(zoom.x), 0.001), maxf(absf(zoom.y), 0.001))
	var columns := ceili(viewport_size.x / (GRAPH_GRID_SPACING * safe_zoom.x)) + 4
	var rows := ceili(viewport_size.y / (GRAPH_GRID_SPACING * safe_zoom.y)) + 4
	return columns * rows


func _draw() -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"grid.draw")
	var viewport_size := get_viewport_rect().size
	var active_camera := get_viewport().get_camera_2d()
	var camera_position := Vector2.ZERO
	var camera_zoom := Vector2.ONE
	if is_instance_valid(active_camera):
		camera_position = active_camera.get_screen_center_position()
		camera_zoom = active_camera.zoom

	var safe_zoom := Vector2(
		maxf(absf(camera_zoom.x), 0.001),
		maxf(absf(camera_zoom.y), 0.001)
	)
	var visible_size := Vector2(
		viewport_size.x / safe_zoom.x,
		viewport_size.y / safe_zoom.y
	)
	var visible_rect := Rect2(camera_position - visible_size * 0.5, visible_size)
	var padded_rect := visible_rect.grow(GRAPH_GRID_SPACING * 2.0)
	var shader_material: ShaderMaterial = material as ShaderMaterial
	if is_instance_valid(shader_material):
		shader_material.set_shader_parameter(&"mult", GRAPH_GRID_MULT)
		shader_material.set_shader_parameter(&"width", GRAPH_GRID_WIDTH)
		shader_material.set_shader_parameter(&"spacing", GRAPH_GRID_SPACING)
		shader_material.set_shader_parameter(&"grid_color", GRAPH_GRID_COLOR)
		shader_material.set_shader_parameter(&"bg_color", GRAPH_GRID_BACKGROUND)
		shader_material.set_shader_parameter(&"aa_pixels", GRAPH_GRID_AA_PIXELS)
		shader_material.set_shader_parameter(&"parallax_offset", -camera_position * 0.2)
	draw_rect(padded_rect, Color.WHITE)
	PerformanceProbe.end_scope(&"grid.draw", perf_token)
