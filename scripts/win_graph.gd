extends Node2D
class_name TabWindow
const DUMMY_MENU_SCENE_PATH := "res://scenes/dummy_menu.tscn"

@export var window_name: String = ""
@export var camera: Camera2D


func get_background() -> CanvasLayer:
	return get_node_or_null("bg") as CanvasLayer

func _ready() -> void:
	if window_name == "graph" and glob.MENU_PLAY_AROUND and not has_node("dummy_menu"):
		# Keep the debug-only menu out of TabWindow's compile-time dependency
		# graph. Its BlockComponent scene depends back on global graph classes,
		# which makes a clean exported build fail while the editor cache masks it.
		var dummy_menu_scene := load(DUMMY_MENU_SCENE_PATH) as PackedScene
		if dummy_menu_scene == null:
			push_error("Could not load debug menu: %s" % DUMMY_MENU_SCENE_PATH)
			return
		add_child(dummy_menu_scene.instantiate())

func _enter_tree() -> void:
	assert(!glob.tree_windows.has(window_name), "occupied")
	glob.tree_windows[window_name] = self
	_set_camera_enabled(false)

func _window_show():
	process_mode = Node.PROCESS_MODE_ALWAYS
	glob.set_graph_splines_visible(true)
	graphs.show()
	$menus.show()
	$follow_menus.show()
	_set_canvas_layer_visible("NodePalette", true)
	$bg.activate()
	show()
	if glob.cam is GraphViewport:
		glob.cam.reset()

func _window_hide():
	glob.set_graph_splines_visible(false)
	if glob.cam is GraphViewport:
		glob.cam.reset()
	process_mode = Node.PROCESS_MODE_DISABLED
	glob.hide_all_menus()
	graphs.hide()
	#(get_children())
	$menus.hide()
	$follow_menus.hide()
	_set_canvas_layer_visible("NodePalette", false)
	$bg.deactivate()
	hide()


func _set_canvas_layer_visible(node_path: NodePath, value: bool) -> void:
	var canvas_layer := get_node_or_null(node_path) as CanvasLayer
	if is_instance_valid(canvas_layer):
		canvas_layer.visible = value


func window_hide():
	# A window may only release the camera it owns. Startup creates and hides
	# several inactive tabs; clearing another window's active camera here leaves
	# per-frame graph consumers with a null Camera2D.
	if glob.cam == camera:
		glob.cam = null
	_set_camera_enabled(false)
	_window_hide()
	if is_instance_valid(glob.selector_box):
		glob.selector_box.hide()

func window_show():
	#glob.selector_box.clamp_rect = Rect2(0, glob.space_begin.y, 99999, 99999)
	glob.cam = camera
	print(window_name)
	if is_instance_valid(camera):
		if camera.has_method("resume"):
			camera.resume()
		camera.make_current()
	_set_camera_enabled(true)
	_window_show()

	#$GraphStorage.process_mode = Node.PROCESS_MODE_DISABLED


func _set_camera_enabled(value: bool) -> void:
	if is_instance_valid(camera):
		camera.enabled = value
		if value:
			IdleCamera.apply(camera)
