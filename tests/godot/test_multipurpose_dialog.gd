extends SceneTree

const SCENE_PATH := "res://scenes/multipurpose_dialog.tscn"

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(SCENE_PATH)
	if packed == null:
		push_error("multipurpose dialog scene is missing")
		quit(1)
		return

	var glob_service: Node = root.get_node_or_null("glob")
	var previous_base_node: Node2D = glob_service.base_node
	var previous_follow_menus: Node = glob_service.follow_menus
	var fake_app := Node2D.new()
	var fake_graph_window := Node2D.new()
	var fake_palette := CanvasLayer.new()
	var fake_follow_menus := CanvasLayer.new()
	fake_graph_window.name = "WIN_GRAPH"
	fake_palette.name = "NodePalette"
	fake_graph_window.add_child(fake_palette)
	fake_app.add_child(fake_graph_window)
	root.add_child(fake_app)
	root.add_child(fake_follow_menus)
	glob_service.base_node = fake_app
	glob_service.follow_menus = fake_follow_menus

	var dialog = packed.instantiate()
	dialog.show_on_ready = false
	dialog.process_mode = Node.PROCESS_MODE_DISABLED
	dialog.configure({
		"id": "scene_test",
		"title": "Test dialog",
		"body": "Text with **bold**.",
		"format": "markdown",
		"icon_path": "res://game_assets/icons/download.png",
		"size": {"width": 900, "height": 600},
		"dismiss_on_escape": false,
		"dismiss_on_outside_click": false,
		"surface": "transparent",
		"action_layout": "vertical",
		"appearance": {
			"show_icon": false,
			"title_font_size": 38,
			"body_font_size": 20,
			"button_height": 56,
			"button_width": 520,
			"button_font_scale": 0.72,
			"button_text_alignment": "left",
			"button_text_padding": 18,
			"field_columns": 2,
			"field_height": 44,
			"field_font_scale": 0.56,
			"action_separation": 14,
			"hide_node_palette": true,
		},
		"fields": [
			{
				"id": "first_name",
				"type": "text",
				"label": "First name",
				"placeholder": "Your name",
				"required": true,
				"value": "Ada",
			},
			{
				"id": "last_name",
				"type": "text",
				"label": "Last name",
				"placeholder": "Your last name",
				"required": true,
				"value": "Lovelace",
			},
			{
				"id": "role",
				"type": "choice",
				"label": "Role",
				"value": "teacher",
				"options": [
					{"value": "student", "text": "Student"},
					{"value": "teacher", "text": "Teacher"},
				],
			},
			{
				"id": "language",
				"type": "choice",
				"label": "Language",
				"value": "en",
				"options": [
					{"value": "en", "text": "English"},
					{"value": "ru", "text": "Russian"},
				],
			},
		],
		"progress": {
			"visible": true,
			"value": 0.0,
			"status": "Downloading",
			"detail": "0 MB",
		},
		"buttons": [
			{"id": "later", "text": "Later", "style": "secondary"},
			{"id": "download", "text": "Download", "style": "primary"}
		]
	}, "en", Vector2(640, 420))
	root.add_child(dialog)
	await process_frame

	_expect_equal(dialog.get_node("ColorRect").material, null, "transparent surface removes outer material")
	_expect_equal(dialog.get_node("ColorRect").color, Color.TRANSPARENT, "transparent surface color")
	_expect_equal(dialog.get_node("ColorRect/Margin/VBox/Header/Icon").visible, false, "appearance can hide icon")
	_expect_equal(dialog.get_node("ColorRect/Margin/VBox/Header/Title").get_theme_font_size("font_size"), 38, "appearance controls title size")
	_expect_equal(dialog.get_node("ColorRect/Margin/VBox/Body").theme.resource_path, "res://resources/theme_headers.tres", "original rich-text theme")
	_expect_equal(dialog.get_node("ColorRect/Margin/VBox/Body").get_theme_font_size("normal_font_size"), 20, "appearance controls body size")
	_expect_equal(dialog.get_node("ColorRect").size, Vector2(592, 372), "scene viewport clamp")
	_expect_equal(dialog.dismiss_on_escape, false, "Escape policy")
	_expect_equal(dialog.dismiss_on_outside_click, false, "outside-click policy")
	_expect_equal(dialog.get_action_buttons().size(), 2, "dynamic action count")
	_expect_equal(dialog.get_action_buttons()[0].get_parent() is VBoxContainer, true, "vertical action layout")
	_expect_equal(dialog.get_action_buttons()[0].base_size, Vector2(520, 56), "appearance controls action size")
	_expect_equal(dialog.get_action_buttons()[0].base_scale_x, 0.72, "appearance controls action font scale")
	_expect_equal(dialog.get_action_buttons()[0].text_alignment, Vector2(-1, 0), "appearance controls action text alignment")
	_expect_equal(dialog.get_action_buttons()[0].text_offset, Vector2(18, 0), "appearance controls action text inset")
	_expect_equal(fake_palette.visible, false, "dialog can hide the graph node palette while open")
	_expect_equal(dialog.get_field_control("first_name").text, "Ada", "text field initial value")
	_expect_equal(dialog.get_field_control("first_name").placeholder_text, "Your name", "text field placeholder")
	var role_control: Control = dialog.get_field_control("role")
	var role_script: Script = role_control.get_script() if role_control != null else null
	_expect_equal(
		role_script != null and role_script.resource_path == "res://scripts/block_component.gd",
		true,
		"choice uses the Neuralese BlockComponent"
	)
	if role_control != null:
		_expect_equal(role_control.button_type, 2, "choice uses dropout menu behavior")
		_expect_equal(role_control.text, "Teacher", "choice initial label")
		_expect_equal(role_control.base_size.y, 44.0, "choice height follows the dialog appearance")
		_expect_equal(
			role_control.get_signal_connection_list("gui_input").size(),
			0,
			"choice relies on one native dropout click handler"
		)
		_expect_equal(role_control.scroll.visible, false, "closed choice hides its option list")
		var options: Array = role_control.get("_contained")
		_expect_equal(options.size(), 2, "choice renders all normalized options")
	var language_control: Control = dialog.get_field_control("language")
	_expect_equal(language_control != null, true, "second choice control exists")
	if language_control != null:
		_expect_equal(language_control.visible, true, "second choice remains visible")
		_expect_equal(language_control.text, "English", "second choice initial label")
		_expect_equal(
			language_control.get_parent().get_parent().get_parent().name,
			"FieldRow_1",
			"second choice stays in the second field row"
		)
	var choice_menu_layer := root.get_node_or_null("ChoiceMenuLayer") as CanvasLayer
	_expect_equal(choice_menu_layer != null, true, "dialog creates a dedicated choice menu layer")
	if choice_menu_layer != null:
		_expect_equal(choice_menu_layer.layer > 128, true, "choice menus render above the dialog layer")
		_expect_equal(choice_menu_layer.get_parent(), root, "choice menu layer is independent from the dialog canvas")
	if role_control != null and language_control != null:
		role_control.pressed.emit()
		var opened_options: Array = role_control.get("_contained")
		for option in opened_options:
			_expect_equal(
				option.mouse_filter,
				Control.MOUSE_FILTER_PASS,
				"opening a choice restores option hit testing"
			)
		_expect_equal(
			glob_service.follow_menus,
			choice_menu_layer,
			"opening a choice routes its menu to the dialog overlay"
		)
		role_control.current_type = 0
		role_control.state.expanded = true
		language_control.pressed.emit()
		_expect_equal(
			role_control.state.tween_hide,
			true,
			"opening another choice closes the previous menu"
		)
		var options: Array = role_control.get("_contained")
		if not options.is_empty():
			options[0].released.emit()
	_expect_equal(dialog.get_field_label("first_name").text, "First name", "field label")
	_expect_equal(
		dialog.get_field_control("first_name").get_parent().get_parent().name,
		"FieldRow_0",
		"two-column fields use an explicit row"
	)
	_expect_equal(
		dialog.get_field_control("first_name").get_parent().get_parent(),
		dialog.get_field_control("last_name").get_parent().get_parent(),
		"first row contains both name fields"
	)
	_expect_equal(
		dialog.get_field_control("role").get_parent().get_parent().get_parent(),
		dialog.get_field_control("language").get_parent().get_parent().get_parent(),
		"second row contains both choice fields"
	)
	_expect_equal(dialog.get_node("ColorRect/Margin/VBox/Body").text, "Text with [b]bold[/b].", "Markdown rendering")
	_expect_equal(dialog.get_node("ColorRect/Margin/VBox/ProgressSection").visible, true, "progress visibility")
	dialog.set_progress(42.5, "Downloading", "51 of 120 MB")
	_expect_equal(dialog.get_progress_value(), 42.5, "dynamic progress")
	_expect_equal(dialog.get_node("ColorRect/Margin/VBox/ProgressSection/Status").text, "Downloading", "progress status")
	_expect_equal(dialog.get_node("ColorRect/Margin/VBox/ProgressSection/Detail").text, "51 of 120 MB", "progress detail")

	var replacement_actions: Array[Dictionary] = [
		{"id": "retry", "text": "Retry", "style": "primary"},
		{"id": "retry", "text": "Duplicate", "style": "secondary"},
	]
	dialog.set_actions(replacement_actions)
	_expect_equal(dialog.get_action_buttons().size(), 1, "dynamic actions remain unique")
	_expect_equal(dialog.get_action_buttons()[0].text, "Retry", "dynamic action text")

	var selected: Array[Dictionary] = []
	dialog.action_selected.connect(func(result: Dictionary): selected.append(result))
	var release_event := InputEventMouseButton.new()
	release_event.button_index = MOUSE_BUTTON_LEFT
	release_event.pressed = false
	dialog.get_action_buttons()[0].gui_input.emit(release_event)
	_expect_equal(
		selected[0] if not selected.is_empty() else {},
		{
			"dialog_id": "scene_test",
			"action": "retry",
			"values": {
				"first_name": "Ada",
				"last_name": "Lovelace",
				"role": "student",
				"language": "en",
			},
			"fields": {
				"first_name": "Ada",
				"last_name": "Lovelace",
				"role": "student",
				"language": "en",
			},
		},
		"native mouse release produces the action result"
	)
	_expect_equal(dialog.has_method("wait_for_result"), true, "result replay API")
	if dialog.has_method("wait_for_result"):
		var replayed: Dictionary = await dialog.wait_for_result()
		_expect_equal(replayed, selected[0], "completed result is replayed")

	if is_instance_valid(dialog):
		dialog.queue_free()
	await process_frame
	_expect_equal(fake_palette.visible, true, "node palette visibility is restored after the dialog closes")
	_expect_equal(glob_service.follow_menus, fake_follow_menus, "dialog restores the default menu layer")
	glob_service.base_node = previous_base_node
	glob_service.follow_menus = previous_follow_menus
	fake_app.queue_free()
	fake_follow_menus.queue_free()
	await process_frame

	if failures.is_empty():
		print("PASS test_multipurpose_dialog: scene and actions")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
