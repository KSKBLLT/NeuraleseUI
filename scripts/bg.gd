extends CanvasLayer

@export var register_global := true

const GraphicsQualityConfigScript := preload("res://scripts/graphics_quality.gd")
const _BlurShader := preload("res://shaders/bg_blur.gdshader")
const _BLUR_DOWNSCALE := 8
const _SAFETY_REFRESH_FRAMES := 120

var active_texture: Texture2D
var _active := false
var _last_signature: Array = []
var _frames_since_render := 0
var _bake_blur := false
var _blur_viewport: SubViewport
var _blur_pending := false
var _sharp_update_armed := false
var _blur_update_armed := false

func _enter_tree():
	if register_global:
		glob.bg_trect = self

@onready var base_bgcol =  ui.get_uni($SubViewport/bg/ColorRect, "bg_color")
@onready var base_grcol =  ui.get_uni($SubViewport/bg/ColorRect, "grid_color")


func _ready() -> void:
	if design.pixel:
		_apply_pixel_look()
	# This runs after the camera/parallax process callbacks but before drawing, so
	# the cached texture is invalidated without introducing a frame of camera lag.
	RenderingServer.frame_pre_draw.connect(_on_frame_pre_draw)
	IdleCamera.apply($SubViewport/Camera2D)


## Pixel design: a white canvas with a faint dot grid instead of the wallpaper.
func _apply_pixel_look() -> void:
	var grid := $SubViewport/bg/ColorRect
	ui.set_uni(grid, "bg_color", design.SC_LOWEST)
	ui.set_uni(grid, "grid_color", design.CANVAS_DOTS)
	ui.set_uni(grid, "mult", 1.0)
	ui.set_uni(grid, "width", 4.0)
	ui.set_uni(grid, "spacing", 32.0)
	base_bgcol = design.SC_LOWEST
	base_grcol = design.CANVAS_DOTS
	$SubViewport/bg/Ffff.visible = false
	$ColorRect.color = design.SURFACE


func activate() -> void:
	visible = true
	var sharp_texture: Texture2D = $SubViewport.get_texture()
	$TextureRect.texture = sharp_texture
	$TextureRect.show()
	_active = true
	_sync_quality_mode(true)
	$SubViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED


func deactivate() -> void:
	_active = false
	_blur_pending = false
	_sharp_update_armed = false
	_blur_update_armed = false
	$TextureRect.hide()
	$SubViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if is_instance_valid(_blur_viewport):
		_blur_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	visible = false


## Forces one sharp render followed by one Medium blur bake.
func mark_dirty() -> void:
	_last_signature = []


func _on_frame_pre_draw() -> void:
	if not _active:
		return
	_sync_quality_mode()
	# Godot 4.7 keeps the exposed UPDATE_ONCE value after the render. Explicitly
	# disarm it one frame later so the viewport cannot keep invalidating forever.
	if _sharp_update_armed:
		$SubViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_sharp_update_armed = false
	if _blur_update_armed and is_instance_valid(_blur_viewport):
		_blur_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
		_blur_update_armed = false

	_frames_since_render += 1
	var signature := _signature()
	if signature != _last_signature or _frames_since_render >= _SAFETY_REFRESH_FRAMES:
		_last_signature = signature
		_frames_since_render = 0
		# A newly dirty sharp source supersedes a pending bake of its old frame.
		# The bake follows every new frame on High too: it is the blurred
		# background (bg_soft) the blocks read where `bg` has no mipmaps.
		_blur_pending = true
		$SubViewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		_sharp_update_armed = true
		# We NO LONGER return here! If we return, the continuous camera movement 
		# prevents the second if block from ever running, freezing the blurred background.

	if _blur_pending and is_instance_valid(_blur_viewport):
		# Because they render in tree order, updating them on the same frame is safe 
		# and prevents the blur from lagging indefinitely during a pan.
		_blur_pending = false
		_blur_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
		_blur_update_armed = true


func _sync_quality_mode(force := false) -> void:
	var should_bake := GraphicsQualityConfigScript.bakes_blur()
	if not force and should_bake == _bake_blur:
		return
	# The replacement is needed only when the quality preset changes (or on
	# activation). Walking every CanvasItem from frame_pre_draw made Medium/Low
	# pay a full scene-tree traversal every rendered frame.
	GraphicsQualityConfigScript.sync_runtime_screen_materials(get_tree().root)
	_bake_blur = should_bake
	_blur_pending = false
	_sharp_update_armed = false
	_blur_update_armed = false
	$SubViewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_ensure_blur_viewport()
	_blur_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	if _bake_blur:
		_publish_background(_blur_viewport.get_texture())
	else:
		_publish_background($SubViewport.get_texture())
	mark_dirty()


## `bg`: what the blocks see behind them (sharp on High, the bake on Medium).
## `bg_soft`: always the bake, the blurred background High blends to, since a
## viewport texture has no mipmaps (shaders/block_body.gdshaderinc).
func _publish_background(texture: Texture2D) -> void:
	active_texture = texture
	RenderingServer.global_shader_parameter_set("bg", texture)
	RenderingServer.global_shader_parameter_set("bg_soft", _blur_viewport.get_texture())


func _signature() -> Array:
	var background_material := $SubViewport/bg/ColorRect.material as ShaderMaterial
	var bg_color: Variant = null
	var grid_color: Variant = null
	if background_material != null:
		bg_color = background_material.get_shader_parameter("bg_color")
		grid_color = background_material.get_shader_parameter("grid_color")
	var cam: Camera2D = glob.cam
	if not is_instance_valid(cam):
		return [$SubViewport.size, glob.window_size, bg_color, grid_color]
	return [
		cam.get_screen_center_position(),
		cam.zoom,
		$SubViewport.size,
		glob.window_size,
		bg_color,
		grid_color,
	]


func _ensure_blur_viewport() -> void:
	if is_instance_valid(_blur_viewport):
		return
	_blur_viewport = SubViewport.new()
	_blur_viewport.name = "BlurBake"
	_blur_viewport.disable_3d = true
	_blur_viewport.transparent_bg = true
	_blur_viewport.gui_disable_input = true
	_blur_viewport.render_target_update_mode = SubViewport.UPDATE_DISABLED
	_blur_viewport.size = _blur_size()
	add_child(_blur_viewport)

	var source := TextureRect.new()
	source.name = "Source"
	source.texture = $SubViewport.get_texture()
	source.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	source.stretch_mode = TextureRect.STRETCH_SCALE
	source.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var material := ShaderMaterial.new()
	material.shader = _BlurShader
	source.material = material
	_blur_viewport.add_child(source)
	source.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	$SubViewport.size_changed.connect(_on_source_viewport_size_changed)


func _on_source_viewport_size_changed() -> void:
	if not is_instance_valid(_blur_viewport):
		return
	var target_size := _blur_size()
	if _blur_viewport.size != target_size:
		_blur_viewport.size = target_size
	mark_dirty()


func _blur_size() -> Vector2i:
	return Vector2i(
		maxi($SubViewport.size.x / _BLUR_DOWNSCALE, 1),
		maxi($SubViewport.size.y / _BLUR_DOWNSCALE, 1)
	)

func set_screenshotting():
	ui.set_uni($SubViewport/bg/ColorRect, "bg_color", Color.GRAY)
	ui.set_uni($SubViewport/bg/ColorRect, "grid_color", Color.GRAY)
	mark_dirty()
	
func set_not_screenshotting():
	ui.set_uni($SubViewport/bg/ColorRect, "bg_color", base_bgcol)
	ui.set_uni($SubViewport/bg/ColorRect, "grid_color", base_grcol)
	mark_dirty()


func hide_for_capture() -> Dictionary:
	var background_image := get_node_or_null("SubViewport/bg/Ffff") as CanvasItem
	var state := {
		"layer_visible": visible,
		"background_image": background_image,
		"background_image_visible": background_image.visible if is_instance_valid(background_image) else false,
	}
	if is_instance_valid(background_image):
		background_image.visible = false
	visible = false
	return state


func restore_after_capture(state: Dictionary) -> void:
	var background_image: CanvasItem = state.get("background_image")
	if is_instance_valid(background_image):
		background_image.visible = bool(state.get("background_image_visible", true))
	visible = bool(state.get("layer_visible", true))


func is_hidden_for_capture() -> bool:
	var background_image := get_node_or_null("SubViewport/bg/Ffff") as CanvasItem
	return not visible and (
		not is_instance_valid(background_image) or not background_image.visible
	)
