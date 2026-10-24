extends Node

var failures: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 20:
		await get_tree().process_frame
	var blur: CanvasItem = ui.blur
	blur.self_modulate.a = 0.0
	RenderingServer.frame_pre_draw.emit()
	_expect(not blur.visible, "ui.blur is hidden while its alpha is 0")

	blur.self_modulate.a = 0.6
	RenderingServer.frame_pre_draw.emit()
	_expect(blur.visible, "ui.blur is shown in the same frame its alpha rises")

	blur.self_modulate.a = 0.0
	RenderingServer.frame_pre_draw.emit()
	_expect(not blur.visible, "ui.blur is hidden again after its alpha reaches 0")

	if failures.is_empty():
		print("PASS test_ui_blur_visibility")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
