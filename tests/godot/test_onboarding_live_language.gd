extends SceneTree

const DIALOG_SCENE_PATH := "res://scenes/multipurpose_dialog.tscn"

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var glob_service: Node = root.get_node("glob")
	var previous_base_node: Node2D = glob_service.base_node
	var previous_follow_menus: Node = glob_service.follow_menus
	var fake_app := Node2D.new()
	var fake_follow_menus := CanvasLayer.new()
	root.add_child(fake_app)
	root.add_child(fake_follow_menus)
	glob_service.base_node = fake_app
	glob_service.follow_menus = fake_follow_menus

	var packed: PackedScene = load(DIALOG_SCENE_PATH)
	if packed == null:
		push_error("multipurpose dialog scene is missing")
		quit(1)
		return
	var dialog = packed.instantiate()
	dialog.show_on_ready = false
	dialog.process_mode = Node.PROCESS_MODE_DISABLED
	dialog.configure({
		"id": "live_language_test",
		"title": {"en": "Who are you?", "ru": "Как вас зовут?"},
		"size": {"width": 560, "height": 340},
		"appearance": {"field_columns": 2},
		"fields": [
			{
				"id": "first_name",
				"type": "text",
				"label": {"en": "First name", "ru": "Имя"},
				"value": "",
			},
			{
				"id": "last_name",
				"type": "text",
				"label": {"en": "Last name", "ru": "Фамилия"},
				"value": "",
			},
			{
				"id": "language",
				"type": "choice",
				"live_language": true,
				"label": {"en": "Language", "ru": "Язык"},
				"value": "en",
				"options": [
					{"value": "en", "text": "English"},
					{"value": "ru", "text": "Русский"},
				],
			},
		],
		"buttons": [{
			"id": "continue",
			"text": {"en": "Continue", "ru": "Продолжить"},
		}],
	}, "en", Vector2(1280, 720))
	root.add_child(dialog)
	await process_frame

	dialog.get_field_control("first_name").text = "Анна"
	var language_control: Variant = dialog.get_field_control("language")
	_expect_equal(language_control.base_size.x, language_control.size.x, "dropdown hitbox width matches its visible width")
	var layout_host := language_control.get_parent() as Control
	_expect_equal(layout_host.name, "ChoiceHost_language", "dropdown keeps a stable layout host")
	var action_y_before: float = dialog.get_action_buttons()[0].global_position.y
	var original_position: Vector2 = language_control.position
	language_control.reparent(root.get_node("ChoiceMenuLayer"))
	await process_frame
	_expect_equal(dialog.get_action_buttons()[0].global_position.y, action_y_before, "detaching an open dropdown does not move the Continue button")
	language_control.reparent(layout_host)
	language_control.position = original_position
	await process_frame
	var russian_options: Array = language_control.get("_contained").filter(
		func(option): return str(option.hint) == "ru"
	)
	if russian_options.is_empty():
		failures.append("Russian language option is missing")
	else:
		russian_options[0].released.emit()
		await process_frame
		_expect_equal(dialog.get_node("ColorRect/Margin/VBox/Header/Title").text, "Как вас зовут?", "open dialog title is retranslated")
		_expect_equal(dialog.get_field_label("first_name").text, "Имя", "field labels are retranslated")
		_expect_equal(dialog.get_action_buttons()[0].text, "Продолжить", "actions are retranslated")
		_expect_equal(dialog.get_field_control("first_name").text, "Анна", "entered text survives language change")
		_expect_equal(dialog.get_field_control("language").text, "Русский", "selected language survives retranslation")

	dialog.queue_free()
	await process_frame
	glob_service.base_node = previous_base_node
	glob_service.follow_menus = previous_follow_menus
	fake_app.queue_free()
	fake_follow_menus.queue_free()
	await process_frame

	if failures.is_empty():
		print("PASS test_onboarding_live_language")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
