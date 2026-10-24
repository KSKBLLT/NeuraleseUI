extends TabWindow

const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

@onready var editor: Node2D = $SimulationEditor

var _legacy_texts: Dictionary = {}
var _preview_initialized := false
var _demo_capture_started := false


func _ready() -> void:
	_legacy_texts = glob.env_dump.duplicate(true)
	if editor.get_world_state().object_count() == 0:
		editor.load_default_world()
	editor.get_world_state().changed.connect(func(): glob.request_autosave("simulation"))
	_layout_editor()


func get_background() -> CanvasLayer:
	return $Background


func _process(_delta: float) -> void:
	if visible and PerformanceProbe.is_feature_enabled("continuous_layout"):
		var perf_token: int = PerformanceProbe.begin_scope(&"tab.continuous_layout")
		_layout_editor()
		PerformanceProbe.end_scope(&"tab.continuous_layout", perf_token)


func window_show() -> void:
	# The graph and simulation cameras keep independent targets. Snap this camera
	# to its own saved transform before it becomes current, rather than lerping
	# from an old target that may have existed while the tab was hidden.
	camera.reset()
	glob.cam = camera
	_set_camera_enabled(true)
	if is_instance_valid(camera):
		if camera.has_method("resume"):
			camera.resume()
		camera.make_current()
		IdleCamera.apply(camera)
	_window_show()


func window_hide() -> void:
	if glob.cam == camera:
		glob.cam = null
	_set_camera_enabled(false)
	_window_hide()


func _window_show() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	$Background.activate()
	editor.get_node("UI").show()
	show()
	_initialize_preview_if_requested()
	_layout_editor()


func _window_hide() -> void:
	process_mode = Node.PROCESS_MODE_DISABLED
	$Background.deactivate()
	var editor_ui := get_node_or_null("SimulationEditor/UI")
	if is_instance_valid(editor_ui):
		editor_ui.hide()
	hide()


func get_simulation_state() -> Dictionary:
	return editor.get_state_dictionary()


func load_simulation_state(data: Dictionary) -> void:
	if not SimulationWorldState.has_serialized_objects(data):
		editor.load_default_world()
	else:
		editor.load_state_dictionary(data)


func request_texts() -> Dictionary:
	_legacy_texts = glob.env_dump.duplicate(true)
	return _legacy_texts


func get_texts() -> Dictionary:
	return _legacy_texts.duplicate(true)


func reset() -> void:
	_legacy_texts.clear()
	editor.load_default_world()


func _initialize_preview_if_requested() -> void:
	if _preview_initialized:
		return
	var preview_args := OS.get_cmdline_user_args()
	if "--simulation-preview" not in preview_args:
		return
	_preview_initialized = true
	editor.load_default_world()
	if "--simulation-demo-capture" in preview_args:
		_start_demo_capture.call_deferred()
		return
	if "--simulation-mapping-preview" in preview_args:
		editor.select_first_agent()
	elif "--simulation-dataset-preview" in preview_args:
		editor.start_dataset_generation.call_deferred()


func _start_demo_capture() -> void:
	if _demo_capture_started:
		return
	_demo_capture_started = true
	var driver: Node = load("res://tools/capture_simulations_demo.gd").new()
	add_child(driver)
	driver.call("run", editor)


func _layout_editor() -> void:
	editor.set_content_top(maxf(0.0, glob.space_begin.y))
