extends Node

var failures: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 20:
		await get_tree().process_frame

	var window_scene := load("res://scenes/builtin_projects_window.tscn") as PackedScene
	var window := window_scene.instantiate()
	ui.cl.add_child(window)
	for _frame in 20:
		await get_tree().process_frame

	ui.blur.self_modulate.a = 1.0
	await window._hide_for_transition(false)

	_expect(not window.visible, "terminal built-in transition must hide its window")
	_expect(
		is_zero_approx(ui.blur.self_modulate.a),
		"terminal built-in transition must release the shared blur"
	)

	await get_tree().process_frame
	window._restore_after_transition()
	for _frame in 20:
		await get_tree().process_frame
	ui.blur.self_modulate.a = 1.0
	await window._hide_for_transition(true)

	_expect(not window.visible, "nested built-in transition must hide its old window")
	_expect(
		is_equal_approx(ui.blur.self_modulate.a, 1.0),
		"nested built-in transition must preserve blur for the next menu"
	)

	window.queue_free()
	await window.tree_exited
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_builtin_projects_blur_release")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
