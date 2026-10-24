class_name SimulationSelectionMarquee
extends ColorRect

const SELECTOR_SHADER = preload("res://shaders/block_screen.gdshader")
const BACKGROUND_SHADER = preload("res://shaders/block.gdshader")
const GraphicsQualityConfigScript = preload("res://scripts/graphics_quality.gd")

const SELECTOR_COLOR := Color(0.79, 0.965, 1.0, 1.0)
const SELECTOR_OUTLINE := Color(0.87, 0.87, 0.87, 0.76862746)
const SELECTOR_TUNING := Color(0.8, 0.8, 0.8, 0.21176471)

var _start := Vector2.ZERO
var _current := Vector2.ZERO
var _active := false


func _ready() -> void:
	z_index = 4094
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	material = _selector_material()
	# Double the visible edge treatment so the world-space marquee remains as
	# legible as the screen-space selector in the Graphs workspace.
	set_instance_shader_parameter("corner_radius_width_add", Vector2(0.0, 4.0))
	set_instance_shader_parameter("outline_color", SELECTOR_OUTLINE)
	set_instance_shader_parameter("tuning", SELECTOR_TUNING)
	color = SELECTOR_COLOR
	visible = false


func begin(world_position: Vector2) -> void:
	_start = world_position
	_current = world_position
	_active = true
	position = world_position
	size = Vector2.ZERO
	visible = true


func update(world_position: Vector2) -> void:
	if not _active:
		return
	_current = world_position
	_apply_rect(current_rect())


func finish() -> Rect2:
	var result := current_rect()
	_active = false
	visible = false
	return result


func is_active() -> bool:
	return _active


func current_rect() -> Rect2:
	return Rect2(_start, _current - _start).abs()


func _apply_rect(rect: Rect2) -> void:
	position = rect.position
	size = rect.size


func _selector_material() -> ShaderMaterial:
	var result := ShaderMaterial.new()
	# The marquee can be created after the initial quality scan.  Pick the
	# background-only variant directly for Medium/Low so it never introduces a
	# fresh hint_screen_texture material.
	result.shader = SELECTOR_SHADER if GraphicsQualityConfigScript.current_level() == GraphicsQualityConfigScript.Level.High else BACKGROUND_SHADER
	result.set_shader_parameter("shape", 0)
	result.set_shader_parameter("mult_tuning", Color.WHITE)
	result.set_shader_parameter("color_mult", Color(1.0, 1.0, 1.0, 0.6627451))
	result.set_shader_parameter("smoothness", 20.0)
	result.set_shader_parameter("corner_radius", 16.0)
	result.set_shader_parameter("blurred_background", true)
	result.set_shader_parameter("outline_width", 0.0)
	result.set_shader_parameter("mult", 1.0)
	result.set_shader_parameter("blur_level", -0.0069996678)
	result.set_shader_parameter("gaussian_mix", 0.82200004)
	result.set_shader_parameter("gaussian_step", 1.8990001)
	result.set_shader_parameter("use_bg", false)
	return result
