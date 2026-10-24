extends Node

var failures: Array[String] = []
var theme_changes := 0


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 30:
		await get_tree().process_frame
	var simulation_tab: Node = glob.tree_windows.get("env")
	_expect(simulation_tab != null, "simulation tab must exist")
	if simulation_tab == null:
		_finish()
		return
	glob.go_window("env")
	for _frame in 5:
		await get_tree().process_frame

	var camera: Camera2D = simulation_tab.camera
	_expect(camera.enabled, "simulation camera must be enabled after window_show")
	_expect(
		not camera.is_processing_internal(),
		"simulation camera must not poll internally while active"
	)

	var controls: Control = simulation_tab.editor.runtime_controls
	controls.set_script(load("res://tests/godot/support/theme_change_counter.gd"))
	controls.set("owner_test", self)
	for _frame in 5:
		await get_tree().process_frame
	theme_changes = 0
	for _frame in 30:
		simulation_tab.editor.set_content_top(48.0)
		await get_tree().process_frame
	_expect(
		theme_changes == 0,
		"settled Simulation layout must send no theme changes; got %d" % theme_changes
	)

	glob.go_window("ds")
	for _frame in 10:
		await get_tree().process_frame
	var dataset_tab: Node = glob.tree_windows.get("ds")
	_expect(dataset_tab != null, "dataset tab must exist")
	if dataset_tab == null:
		_finish()
		return
	var backdrop := dataset_tab.get_node("Control/ColorRect") as Control
	var console := dataset_tab.get_node("Control/console") as Control
	var rect_changes := [0]
	backdrop.item_rect_changed.connect(func() -> void: rect_changes[0] += 1)
	console.item_rect_changed.connect(func() -> void: rect_changes[0] += 1)
	for _frame in 30:
		await get_tree().process_frame
	_expect(
		rect_changes[0] == 0,
		"settled Dataset layout must not resize; got %d changes" % rect_changes[0]
	)
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_tabs_idle")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
