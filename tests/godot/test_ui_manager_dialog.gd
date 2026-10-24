extends SceneTree

var failures: Array[String] = []
var close_wait_finished := false
var close_wait_result: Dictionary = {}
var tutorial_close_wait_finished := false
var tutorial_close_wait_result := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager = root.get_node_or_null("ui")
	var global_state = root.get_node_or_null("glob")
	if manager == null or global_state == null:
		push_error("required autoloads are unavailable")
		quit(1)
		return
	if not manager.has_method("show_dialog"):
		push_error("UIManager.show_dialog is missing")
		quit(1)
		return

	_prepare_minimal_ui(manager, global_state)
	var spec := {
		"id": "duplicate_test",
		"title": "One",
		"body": "Body",
		"size": {"width": 1200, "height": 900},
		"buttons": [{"id": "ok", "text": "OK", "style": "primary"}]
	}
	var first = manager.show_dialog(spec)
	var second = manager.show_dialog(spec)
	_expect_equal(first, second, "duplicate id returns active instance")
	_expect_equal(manager.active_dialogs.size(), 1, "one active dialog")
	_expect_equal(first.get_node("ColorRect").size, Vector2(752, 552), "dialog uses logical window dimensions")

	first.process_mode = Node.PROCESS_MODE_DISABLED
	first.queue_free()
	await process_frame
	_expect_equal(manager.active_dialogs.size(), 0, "registry cleanup")

	var close_spec := {
		"id": "close_wait_test",
		"title": "Wait for close",
		"body": "",
		"dismiss_on_outside_click": true,
		"buttons": [{"id": "open", "text": "Open", "style": "primary"}],
	}
	var closing_dialog = manager.show_dialog(close_spec)
	closing_dialog.process_mode = Node.PROCESS_MODE_DISABLED
	_capture_result_after_close(manager, close_spec)
	await process_frame
	closing_dialog.choose_action("open")
	await process_frame
	_expect_equal(close_wait_finished, false, "result waits while the selected dialog is still closing")
	closing_dialog.queue_free()
	await process_frame
	await process_frame
	_expect_equal(close_wait_finished, true, "result resumes after the selected dialog exits")
	_expect_equal(close_wait_result.get("action"), "open", "result survives the close wait")

	var handoff_spec := {
		"id": "startup_handoff_test",
		"title": "Next startup step",
		"body": "",
		"buttons": [{
			"id": "next",
			"text": "Next",
			"style": "primary",
			"can_go": false,
			"close_mode": "handoff",
		}],
	}
	var handoff_dialog = manager.show_dialog(handoff_spec)
	handoff_dialog.process_mode = Node.PROCESS_MODE_DISABLED
	handoff_dialog.choose_action("next")
	await process_frame
	_expect_equal(
		is_instance_valid(handoff_dialog),
		false,
		"handoff dialog exits in the action frame without waiting for fade processing"
	)
	_expect_equal(
		manager.active_dialogs.has("startup_handoff_test"),
		false,
		"handoff dialog releases its registry slot before the next startup dialog"
	)
	if is_instance_valid(handoff_dialog):
		handoff_dialog.queue_free()
		await process_frame

	var legacy_splash = load("res://scripts/splash_menu.gd").new()
	legacy_splash.typename = "workslist"
	legacy_splash.show_on_ready = false
	legacy_splash.process_mode = Node.PROCESS_MODE_DISABLED
	root.add_child(legacy_splash)
	manager.splashed[legacy_splash] = true
	_capture_tutorial_close(manager, "workslist")
	await process_frame
	_expect_equal(tutorial_close_wait_finished, false, "tutorial waits while the legacy project list is open")
	manager.splashed.erase(legacy_splash)
	legacy_splash.free()
	for _frame in 5:
		await process_frame
	_expect_equal(tutorial_close_wait_finished, true, "tutorial resumes after the legacy project list closes")
	_expect_equal(tutorial_close_wait_result, true, "legacy project list closure is accepted")

	if failures.is_empty():
		print("PASS test_ui_manager_dialog: duplicate and cleanup")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _capture_result_after_close(manager: Node, spec: Dictionary) -> void:
	close_wait_result = await manager.show_dialog_and_get_result(spec, true)
	close_wait_finished = true


func _capture_tutorial_close(manager: Node, dialog_id: String) -> void:
	tutorial_close_wait_result = await manager.wait_for_tutorial_dialog_closed(dialog_id)
	tutorial_close_wait_finished = true


func _prepare_minimal_ui(manager: Node, global_state: Node) -> void:
	if manager.topr == null:
		manager.topr = Control.new()
		manager.add_child(manager.topr)
	global_state.tree_windows.erase("env")
	global_state.window_size = Vector2(800, 600)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
