extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager = root.get_node_or_null("ui")
	_expect(manager != null, "UI manager must be available")
	if manager == null:
		_finish()
		return
	for index in range(6):
		manager.error("Ошибка %d" % index)
	manager.error("Very long diagnostic text " + "with wrapped details ".repeat(80))
	await process_frame
	await process_frame
	var toasts := get_nodes_in_group("ui_error_toast")
	_expect(toasts.size() == 4, "error stack must keep the four newest visible notifications")
	var target_positions: Array[float] = []
	for toast in toasts:
		_expect(toast.size.y <= 144.0, "error notifications must never grow to full-screen height")
		target_positions.append(float(toast.get_meta("target_y", toast.position.y)))
	target_positions.sort()
	for index in range(1, target_positions.size()):
		_expect(target_positions[index] > target_positions[index - 1], "error notifications must occupy distinct stacked rows")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_error_toast_stack")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
