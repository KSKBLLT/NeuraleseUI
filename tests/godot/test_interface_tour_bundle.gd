extends SceneTree

const TutorialLocalizationCore := preload("res://scripts/startup/tutorial_localization.gd")

var failures: Array[String] = []
signal lesson_loaded_during_registration


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var learner_service: Node = root.get_node_or_null("learner")
	_expect(learner_service != null, "learner autoload is available")
	var compiled: Dictionary = learner_service._compile_offline_bundle("res://offline_tutorials/bundle", false)
	var lesson: Dictionary = compiled.get("lessons", {}).get("00_interface_tour", {})
	_expect(not lesson.is_empty(), "interface tour is part of the built-in bundle")
	_expect_equal(
		lesson.get("tutorial_ui", {}).get("show_progress", true),
		false,
		"interface tour hides the optional progress line"
	)
	var tutorial_ui: Dictionary = lesson.get("tutorial_ui", {})
	var arrow_style: Dictionary = tutorial_ui.get("arrow_style", {})
	var highlight_style: Dictionary = tutorial_ui.get("highlight_style", {})
	_expect_equal(arrow_style.get("thickness"), 11.0, "interface tour uses a thick arrow shaft")
	_expect_equal(arrow_style.get("head_size"), 30.0, "interface tour uses a large arrow head")
	_expect_equal(arrow_style.get("shadow", {}).get("enabled"), true, "interface tour arrow has a shadow")
	_expect_equal(highlight_style.get("center_opacity"), 0.5, "interface tour highlight opacity is compiled")
	_expect_equal(highlight_style.get("padding"), 30.0, "interface tour highlight padding is compiled")
	_expect_equal(highlight_style.get("fade_in"), 0.16, "interface tour highlight fade-in is compiled")
	_expect_equal(highlight_style.get("fade_out"), 0.18, "interface tour highlight fade-out is compiled")
	var steps: Array = lesson.get("code", {}).get("flows", {}).get("flow", [])
	_expect_equal(steps.size(), 15, "interface tour covers navigation, a two-node chain, and Axon")
	var expected_ui_targets := ["projects", "simulations", "datasets", "graphs", "node_palette", "axon"]
	var actual_ui_targets: Array[String] = []
	var highlighted_ui_targets: Array[String] = []
	var waited_ui_targets: Array[String] = []
	var waited_dialog_ids: Array[String] = []
	for step in steps:
		for action in step.get("actions", []):
			if action.get("type") == "arrow" and action.get("mode") == "ui":
				actual_ui_targets.append(str(action.get("target", "")))
			if action.get("type") == "highlight_ui":
				highlighted_ui_targets.append(str(action.get("target", "")))
			if action.get("type") == "wait_ui":
				waited_ui_targets.append(str(action.get("target", "")))
			if action.get("type") == "wait_dialog_closed":
				waited_dialog_ids.append(str(action.get("dialog_id", "")))
	_expect_equal(actual_ui_targets, expected_ui_targets, "tour points to the main interface controls")
	_expect_equal(highlighted_ui_targets, expected_ui_targets, "each pointed interface control is also highlighted")
	_expect_equal(waited_ui_targets, ["projects", "simulations", "datasets", "graphs"], "navigation steps wait for the requested click")
	_expect_equal(waited_dialog_ids, ["workslist"], "folder step waits for the regular project list instead of reopening the startup chooser")
	var declared_targets: Array[String] = []
	for scene_path in ["res://scenes/fg.tscn", "res://scenes/node_palette.tscn"]:
		var packed := load(scene_path) as PackedScene
		_expect(packed != null, "%s can be loaded" % scene_path)
		if packed == null:
			continue
		var instance := packed.instantiate()
		_collect_tutorial_targets(instance, declared_targets)
		instance.free()
	var foreground: Node = load("res://scenes/fg.tscn").instantiate()
	root.add_child(foreground)
	await process_frame
	await process_frame
	var lesson_header: Node = foreground.get_node_or_null("ColorRect/ColorRect")
	_expect(lesson_header != null and lesson_header.has_method("set_interface_tour_controls"), "tour header exposes a localized skip control")
	if lesson_header != null and lesson_header.has_method("set_interface_tour_controls"):
		lesson_header.size.x = 1156.0
		lesson_header.set_interface_tour_controls(true, false)
		await process_frame
		var skip_button: Control = lesson_header.get("_skip_tour_button")
		var rendered_control: Control = skip_button.get("_wrapped_in") if skip_button != null else null
		_expect(skip_button != null and skip_button.visible, "tour skip button is visible while the tour runs")
		_expect(
			skip_button != null and bool(skip_button.get("top")),
			"tour skip button accepts input above the graph workspace"
		)
		_expect(skip_button != null and skip_button.color == Color(0.49, 0.83, 0.614), "tour skip button uses the Neuralese green accent")
		_expect(not lesson_header.get_node("backline").visible, "tour can hide the progress background")
		_expect(not lesson_header.get_node("actual").visible, "tour can hide the progress value")
		_expect(not lesson_header.get_node("Label").visible, "tour can hide the progress lesson label")
		_expect(not lesson_header.get_node("Label2").visible, "tour can hide the progress step label")
		_expect(is_zero_approx(lesson_header.color.a), "tour can hide the entire progress panel surface")
		_expect(not lesson_header.is_progress_panel_visible(), "hidden progress panel reports no reserved layout")
		_expect(skip_button != null and not skip_button.gui_input.get_connections().is_empty(), "tour skip handles native mouse input")
		_expect(
			rendered_control != null
			and rendered_control.position.x >= lesson_header.size.x - rendered_control.size.x - 9.0
			and rendered_control.position.x + rendered_control.size.x <= lesson_header.size.x + 1.0,
			"tour skip button stays visible at the right side after BlockComponent wrapping"
		)
		lesson_header.set_interface_tour_controls(false, true)
		_expect(lesson_header.get_node("backline").visible, "regular tutorial progress can be restored")
		_expect(lesson_header.get_node("actual").visible, "regular tutorial progress value can be restored")
		_expect(lesson_header.get_node("Label").visible, "regular tutorial lesson label can be restored")
		_expect(lesson_header.get_node("Label2").visible, "regular tutorial step label can be restored")
	foreground.free()
	for target in expected_ui_targets:
		_expect(target in declared_targets, "%s is declared by an interface scene" % target)
	_expect_equal(
		TutorialLocalizationCore.text(lesson.get("lesson_title", {}), "ru"),
		"Первые шаги",
		"Russian lesson title is available"
	)
	_expect_equal(
		TutorialLocalizationCore.text(lesson.get("lesson_title", {}), "kz"),
		"Алғашқы қадамдар",
		"Kazakh lesson title is available"
	)
	_expect_equal(
		TutorialLocalizationCore.text(lesson.get("lesson_title", {}), "en"),
		"First steps",
		"English lesson title is available"
	)


	_load_lesson_during_registration(learner_service, lesson.get("code", {}))
	learner_service.lesson_re_reg()
	await lesson_loaded_during_registration
	await process_frame
	_expect_equal(
		learner_service.lesson.get_main_total_steps(),
		steps.size(),
		"a stale overlapping registration cannot replace the loaded lesson runtime"
	)

	for step in steps:
		var explanation_found := false
		var hides_previous_arrow := false
		var hides_previous_highlight := false
		var arrow_targets_in_step: Array[String] = []
		var highlight_targets_in_step: Array[String] = []
		for action in step.get("actions", []):
			if action.get("type") == "hide_arrows":
				hides_previous_arrow = true
			if action.get("type") == "hide_ui_highlights":
				hides_previous_highlight = true
			if action.get("type") == "arrow" and action.get("mode") == "ui":
				arrow_targets_in_step.append(str(action.get("target", "")))
			if action.get("type") == "highlight_ui":
				highlight_targets_in_step.append(str(action.get("target", "")))
			if action.get("type") == "wait_ui":
				var waited_target := str(action.get("target", ""))
				_expect(waited_target in arrow_targets_in_step, "%s points to a control before waiting for it" % step.get("id", "step"))
				_expect(waited_target in highlight_targets_in_step, "%s highlights a control before waiting for it" % step.get("id", "step"))
			if action.get("type") != "explain":
				continue
			explanation_found = true
			for language in ["en", "ru", "kz"]:
				_expect(
					not TutorialLocalizationCore.segments(action.get("text", {}), language).is_empty(),
					"%s has %s explanation" % [step.get("id", "step"), language]
				)
		_expect(explanation_found, "%s contains an explanation" % step.get("id", "step"))
		_expect(hides_previous_arrow, "%s clears the previous pointer" % step.get("id", "step"))
		_expect(hides_previous_highlight, "%s clears the previous highlight" % step.get("id", "step"))

	var russian_text := _lesson_text(steps, "ru")
	_expect("Привет! Добро пожаловать в Neuralese." in russian_text, "tour starts with the approved welcome")
	_expect(
		"Видишь три кнопки посередине? Это главные вкладки: «Симуляции», «Графы» и «Датасеты»." in russian_text,
		"colon-containing tutorial text remains a plain localized sentence"
	)
	_expect("как в Scratch" in russian_text, "tour uses the familiar Scratch comparison")
	_expect("Первая нода появилась на рабочем поле." in russian_text, "tour confirms the first visible graph change")
	_expect("Теперь на рабочем поле две ноды." in russian_text, "tour confirms the second visible graph change")
	_expect("теория" not in russian_text.to_lower(), "tour stays focused on the interface")
	_expect("тензор" not in russian_text.to_lower(), "tour does not introduce ML implementation terms")
	_expect("Аксон" in russian_text, "tour introduces Axon")

	learner_service._scan_offline_tutorials(true)
	var lesson_key := str(learner_service.find_offline_lesson_key("00_interface_tour"))
	_expect(not lesson_key.is_empty(), "learner finds the tour by stable source key")
	_expect(learner_service.has_signal("lesson_completed"), "learner exposes lesson completion")
	var completed_keys: Array[String] = []
	learner_service.lesson_completed.connect(func(key: String): completed_keys.append(key))
	var lesson_runtime: Node = load("res://scripts/lesson_code.gd").new()
	root.add_child(lesson_runtime)
	learner_service.lesson = lesson_runtime
	learner_service.current_lesson_key = lesson_key
	learner_service.current_lesson = lesson
	learner_service.lesson.load_code(lesson.get("code", {}))
	learner_service._on_step_completed(steps.size() - 1, steps.back())
	learner_service._on_step_completed(steps.size() - 1, steps.back())
	_expect_equal(completed_keys, [lesson_key], "lesson completion is emitted once")
	lesson_runtime.queue_free()

	if failures.is_empty():
		print("PASS test_interface_tour_bundle")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _load_lesson_during_registration(learner_service: Node, code: Dictionary) -> void:
	await learner_service.lesson_re_reg()
	learner_service.lesson.load_code(code)
	lesson_loaded_during_registration.emit()


func _collect_tutorial_targets(node: Node, output: Array[String]) -> void:
	if node.is_in_group("tutorial_ui_target"):
		var target_id := str(node.get_meta("tutorial_target_id", ""))
		if not target_id.is_empty():
			output.append(target_id)
	for child in node.get_children():
		_collect_tutorial_targets(child, output)


func _lesson_text(steps: Array, language: String) -> String:
	var parts: Array[String] = []
	for step in steps:
		for action in step.get("actions", []):
			if action.get("type") != "explain":
				continue
			parts.append_array(TutorialLocalizationCore.segments(action.get("text", {}), language))
	return "\n".join(parts)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
