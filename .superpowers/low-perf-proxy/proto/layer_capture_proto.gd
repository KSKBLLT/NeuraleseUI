extends Node

## Bench prototype (not app code): High's UI panels without the screen texture.
##
## The objects layer, that is the root viewport's world canvas and the
## CanvasLayers between the background and the top bar, is attached to a second,
## smaller viewport and so drawn twice: once on screen as before, once here at
## 1/downscale. A 1/8 bake of it (bg_blur.gdshader, as scripts/bg.gd bakes the
## background) is what the top bar's panels read over bg_soft. SubViewports
## render before the root and siblings in tree order, so the capture, its bake
## and the frame on screen are the same frame.

const BAKE_SHADER := preload("res://shaders/bg_blur.gdshader")
const LAYERED_SHADER := preload("res://.superpowers/low-perf-proxy/proto/block_layered.gdshader")
const SCREEN_SHADER := preload("res://shaders/block_screen.gdshader")
const BG_SCRIPT := "res://scripts/bg.gd"
const BAKE_DOWNSCALE := 8

var downscale := 2
## Panels on this CanvasLayer and above read the capture; layers below it are captured.
var panel_layer := 126
var capture: SubViewport
var bake: SubViewport
var _root: Window
var _layers: Array[CanvasLayer] = []
var _world_canvas := RID()


func install(root: Window, p_downscale: int) -> void:
	_root = root
	downscale = maxi(p_downscale, 1)
	capture = SubViewport.new()
	capture.name = "ObjectsCapture"
	capture.disable_3d = true
	capture.transparent_bg = true
	capture.gui_disable_input = true
	capture.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(capture)
	bake = SubViewport.new()
	bake.name = "ObjectsBake"
	bake.disable_3d = true
	bake.transparent_bg = true
	bake.gui_disable_input = true
	bake.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	add_child(bake)
	var source := TextureRect.new()
	source.texture = capture.get_texture()
	source.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	source.stretch_mode = TextureRect.STRETCH_SCALE
	source.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	var material := ShaderMaterial.new()
	material.shader = BAKE_SHADER
	source.material = material
	bake.add_child(source)
	source.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_world_canvas = root.world_2d.canvas
	RenderingServer.viewport_attach_canvas(capture.get_viewport_rid(), _world_canvas)
	attach_layers()
	RenderingServer.frame_pre_draw.connect(_sync)
	_sync()


## The CanvasLayers below the panels, without the background ones (bg_soft has them).
func attach_layers() -> void:
	var names := []
	for node in _all_nodes(_root):
		var layer := node as CanvasLayer
		if layer == null or layer in _layers or layer.get_viewport() != _root:
			continue
		if layer.layer >= panel_layer:
			continue
		var script: Script = layer.get_script()
		if script != null and script.resource_path == BG_SCRIPT:
			continue
		RenderingServer.viewport_attach_canvas(capture.get_viewport_rid(), layer.get_canvas())
		RenderingServer.viewport_set_canvas_stacking(capture.get_viewport_rid(), layer.get_canvas(), layer.layer, layer.get_index())
		_layers.append(layer)
		names.append("%s:%d" % [layer.get_path(), layer.layer])
	print("LAYERCAPTURE attached world canvas + %s" % [names])


## The top bar's live-screen panels read the bake; its strip copy goes away.
func swap_panels(root: Node) -> int:
	var swapped := 0
	for node in _all_nodes(root):
		if node is BackBufferCopy:
			var copy_layer := (node as CanvasItem).get_canvas_layer_node()
			if copy_layer != null and copy_layer.layer >= panel_layer:
				(node as CanvasItem).visible = false
			continue
		var item := node as CanvasItem
		if item == null:
			continue
		var material := item.material as ShaderMaterial
		if material == null or material.shader != SCREEN_SHADER:
			continue
		var item_layer := item.get_canvas_layer_node()
		if item_layer == null or item_layer.layer < panel_layer:
			continue
		var replacement := material.duplicate(true) as ShaderMaterial
		replacement.shader = LAYERED_SHADER
		replacement.set_shader_parameter("objects_soft", bake.get_texture())
		item.material = replacement
		swapped += 1
	return swapped


func save_bake(path: String) -> void:
	bake.get_texture().get_image().save_png(path)
	capture.get_texture().get_image().save_png(path.get_basename() + "_capture.png")


## Detector calibration only: >1 refreshes the capture every Nth frame, the kind
## of stale-frame bug a cached layer has (flicker_check.py must flag it).
var refresh_every := 1
var _frame := 0


func _sync() -> void:
	if not is_instance_valid(_root):
		return
	_frame += 1
	if refresh_every > 1:
		var mode := SubViewport.UPDATE_ALWAYS if _frame % refresh_every == 0 else SubViewport.UPDATE_DISABLED
		capture.render_target_update_mode = mode
		bake.render_target_update_mode = mode
	var size := Vector2i((Vector2(_root.size) / downscale).ceil())
	if capture.size != size:
		capture.size = size
		bake.size = Vector2i(maxi(_root.size.x / BAKE_DOWNSCALE, 1), maxi(_root.size.y / BAKE_DOWNSCALE, 1))
	var rid := capture.get_viewport_rid()
	capture.global_canvas_transform = _root.global_canvas_transform.scaled(Vector2.ONE / downscale)
	RenderingServer.viewport_set_canvas_transform(rid, _world_canvas, _root.canvas_transform)
	for layer in _layers:
		if is_instance_valid(layer):
			RenderingServer.viewport_set_canvas_transform(rid, layer.get_canvas(), layer.get_final_transform())


func _all_nodes(node: Node) -> Array[Node]:
	var result: Array[Node] = [node]
	for child in node.get_children(true):
		result.append_array(_all_nodes(child))
	return result
