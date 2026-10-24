extends Node

const StartupFlowCoordinatorCore := preload("res://scripts/startup/startup_flow_coordinator.gd")
const StartupOnboardingStateCore := preload("res://scripts/startup/startup_onboarding_state.gd")

var failures: Array[String] = []
var _launch_coordinator: Node = null
var _launch_learner: Node = null
var _launch_expected_key := ""
var _launch_observed_key := ""
var _launch_probe_frames := 0


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	# The project scene supplies the same base/UI tree that Learner requires in a
	# normal launch. Do not use --script for this test: that omits the base scene.
	await get_tree().process_frame
	await get_tree().process_frame
	var learner_service: Node = get_node_or_null("/root/learner")
	var ui_service: Node = get_node_or_null("/root/ui")
	_expect(learner_service != null, "learner autoload is available")
	_expect(ui_service != null, "ui autoload is available")
	_verify_tutorial_bubble_layout()
	if learner_service != null and ui_service != null:
		await _verify_real_tour_launch(learner_service, ui_service)
	if failures.is_empty():
		print("PASS test_interface_tour_launch")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)


func _verify_real_tour_launch(learner_service: Node, ui_service: Node) -> void:
	var expected_key := str(learner_service.find_offline_lesson_key("00_interface_tour"))
	_expect(not expected_key.is_empty(), "real learner finds the interface tour")
	if expected_key.is_empty():
		return
	var state_path := "user://interface_tour_launch_test_%s.json" % Time.get_ticks_usec()
	var state := StartupOnboardingStateCore.new(state_path)
	state.select_account("interface-tour-launch-test")
	var coordinator := StartupFlowCoordinatorCore.new()
	coordinator.configure_dependencies({
		"state": state,
		"learner": learner_service,
		"ui": ui_service,
	})
	add_child(coordinator)
	_expect(coordinator._select_state("interface-tour-launch-test"), "tour state selects its test account")
	_launch_coordinator = coordinator
	_launch_learner = learner_service
	_launch_expected_key = expected_key
	_launch_observed_key = ""
	_launch_probe_frames = 0
	var probe := Timer.new()
	probe.wait_time = 0.01
	probe.timeout.connect(_resolve_after_real_lesson_starts)
	add_child(probe)
	probe.start()
	var result: Dictionary = await coordinator.start_interface_tour(true)
	probe.stop()
	probe.queue_free()
	_expect(result.get("ok", false), "startup coordinator starts the real interface tour")
	_expect_equal(
		_launch_observed_key, expected_key,
		"coordinator opened the actual offline interface-tour lesson"
	)
	_expect_equal(state.get_value("interface_tour_status"), "completed", "tour result is persisted")
	coordinator.queue_free()
	if FileAccess.file_exists(state_path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(state_path))


func _verify_tutorial_bubble_layout() -> void:
	var project_root := get_parent()
	var quest := project_root.get_node_or_null("fg/TutorialBubbleLayer/Control2") as Control
	var palette := project_root.get_node_or_null("WIN_GRAPH/NodePalette") as CanvasLayer
	var panel := project_root.get_node_or_null("WIN_GRAPH/NodePalette/Root/Panel") as Control
	_expect(quest != null, "project exposes the tutorial bubble")
	_expect(palette != null and panel != null, "project exposes the graph palette")
	if quest == null or palette == null or panel == null:
		return
	var bubble_layer := quest.get_parent() as CanvasLayer
	_expect(
		bubble_layer != null and bubble_layer.layer > palette.layer,
		"tutorial bubble renders above selection and palette canvas layers"
	)
	palette.visible = true
	quest.call("_sync_workspace_position")
	_expect(
		quest.position.x >= panel.get_global_rect().end.x + quest.workspace_margin_x,
		"visible node palette cannot cover the tutorial bubble (quest=%s palette=%s margin=%s)" % [
			quest.position.x,
			panel.get_global_rect().end.x,
			quest.workspace_margin_x,
		]
	)
	palette.visible = false
	quest.call("_sync_workspace_position")
	_expect(
		is_equal_approx(quest.position.x, 37.0),
		"tutorial bubble returns to its authored position when the palette is hidden"
	)
	palette.visible = true
	quest.call("_sync_workspace_position")


func _resolve_after_real_lesson_starts() -> void:
	if _launch_coordinator == null or _launch_learner == null:
		return
	_launch_probe_frames += 1
	if str(_launch_learner.current_lesson_key) == _launch_expected_key:
		_launch_observed_key = str(_launch_learner.current_lesson_key)
		_launch_coordinator.interface_tour_resolved.emit({"ok": true, "lesson_key": _launch_expected_key})
		_launch_coordinator = null
		return
	if _launch_probe_frames >= 120:
		failures.append("real interface-tour lesson did not start within 120 frames")
		_launch_coordinator.interface_tour_resolved.emit({"ok": false, "error": "tour_start_timeout"})
		_launch_coordinator = null


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
