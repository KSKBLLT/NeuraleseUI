extends SceneTree

const DialogSpec = preload("res://scripts/dialog_spec.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_localization_and_defaults()
	_test_fallback_order()
	_test_validation_and_viewport_clamp()
	_test_progress_and_public_button_normalization()
	_test_onboarding_layout_and_fields()
	_test_large_menu_appearance()

	if failures.is_empty():
		print("PASS test_dialog_spec: 3 cases")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_localization_and_defaults() -> void:
	var result: Dictionary = DialogSpec.normalize({
		"id": "update_available",
		"title": {"en": "Update", "ru": "Обновление"},
		"body": {"en": "Ready", "ru": "Готово"},
		"buttons": [
			{"id": "download", "text": {"en": "Download", "ru": "Скачать"}, "style": "primary"}
		]
	}, "ru", Vector2(1280, 720))

	_expect_equal(result.get("id"), "update_available", "dialog id")
	_expect_equal(result.get("title"), "Обновление", "localized title")
	_expect_equal(result.get("body"), "Готово", "localized body")
	_expect_equal(result.get("format"), "plain", "default format")
	_expect_equal(result.get("icon_path"), "res://game_assets/icons/warn.png", "default icon")
	_expect_equal(result.get("size"), Vector2(480, 280), "default size")
	_expect_equal(result["buttons"][0]["text"], "Скачать", "localized button")
	_expect_equal(result["buttons"][0]["style"], "primary", "button style")


func _test_fallback_order() -> void:
	var english: Dictionary = DialogSpec.normalize({
		"title": {"en": "English", "kz": "Қазақша"},
		"body": "Body"
	}, "ru", Vector2(800, 600))
	_expect_equal(english.get("title"), "English", "English fallback")

	var first_available: Dictionary = DialogSpec.normalize({
		"title": {"kz": "Қазақша"},
		"body": "Body"
	}, "ru", Vector2(800, 600))
	_expect_equal(first_available.get("title"), "Қазақша", "first available fallback")


func _test_validation_and_viewport_clamp() -> void:
	var result: Dictionary = DialogSpec.normalize({
		"id": "  ",
		"format": "html",
		"icon_path": "https://example.com/icon.png",
		"size": {"width": 1200, "height": 900},
		"dismiss_on_escape": false,
		"buttons": [
			{"id": "ok", "text": "OK", "style": "primary"},
			{"id": "ok", "text": "Duplicate", "style": "danger"},
			{"id": "", "text": "Missing id"}
		]
	}, "en", Vector2(320, 220))

	_expect_equal(result.get("id"), "dialog", "blank id fallback")
	_expect_equal(result.get("format"), "plain", "unsupported format fallback")
	_expect_equal(result.get("icon_path"), "res://game_assets/icons/warn.png", "remote icon rejection")
	_expect_equal(result.get("size"), Vector2(272, 172), "viewport clamp")
	_expect_equal(result.get("dismiss_on_escape"), false, "dismiss policy")
	_expect_equal(result.get("dismiss_on_outside_click"), true, "outside-click default")
	_expect_equal(result["buttons"].size(), 1, "invalid and duplicate buttons removed")

	var sized := DialogSpec.normalize({"size": {"width": 700, "height": 500}}, "en", Vector2(800, 600))
	var renormalized := DialogSpec.normalize(sized, "en", Vector2(800, 600))
	_expect_equal(renormalized.get("size"), sized.get("size"), "normalization is idempotent")


func _test_progress_and_public_button_normalization() -> void:
	var result := DialogSpec.normalize({
		"progress": {
			"visible": true,
			"value": 142.5,
			"status": {"ru": "Загрузка", "en": "Downloading"},
			"detail": "51 of 120 MB",
		}
	}, "ru", Vector2(1280, 720))
	_expect_equal(result["progress"], {
		"visible": true,
		"value": 100.0,
		"status": "Загрузка",
		"detail": "51 of 120 MB",
	}, "progress normalization")

	var buttons: Array[Dictionary] = DialogSpec.normalize_buttons([
		{"id": "retry", "text": {"ru": "Повторить", "en": "Retry"}, "style": "primary"},
		{"id": "retry", "text": "Duplicate"},
	], "ru")
	_expect_equal(buttons, [{"id": "retry", "text": "Повторить", "style": "primary"}], "public button normalization")


func _test_onboarding_layout_and_fields() -> void:
	var result := DialogSpec.normalize({
		"surface": "transparent",
		"action_layout": "vertical",
		"fields": [
			{
				"id": "first_name",
				"type": "text",
				"label": {"ru": "Имя", "en": "First name"},
				"placeholder": {"ru": "Как вас зовут?", "en": "Your name"},
				"required": true,
				"value": "Алия",
			},
			{
				"id": "role",
				"type": "choice",
				"live_language": true,
				"label": {"ru": "Роль", "en": "Role"},
				"value": "teacher",
				"options": [
					{"value": "student", "text": {"ru": "Ученик", "en": "Student"}},
					{"value": "teacher", "text": {"ru": "Учитель", "en": "Teacher"}},
				],
			},
			{"id": "unsupported", "type": "checkbox"},
			{"id": "role", "type": "text"},
		],
	}, "ru", Vector2(1280, 720))

	_expect_equal(result["surface"], "transparent", "transparent onboarding surface")
	_expect_equal(result["action_layout"], "vertical", "vertical onboarding actions")
	_expect_equal(result["fields"].size(), 2, "unsupported and duplicate fields removed")
	_expect_equal(result["fields"][0], {
		"id": "first_name",
		"type": "text",
		"label": "Имя",
		"placeholder": "Как вас зовут?",
		"required": true,
		"value": "Алия",
	}, "localized text field")
	_expect_equal(result["fields"][1]["options"], [
		{"value": "student", "text": "Ученик"},
		{"value": "teacher", "text": "Учитель"},
	], "localized choice options preserve machine values")
	_expect_equal(result["fields"][1]["value"], "teacher", "choice initial value")
	_expect_equal(result["fields"][1].get("live_language"), true, "live language behavior survives normalization")


func _test_large_menu_appearance() -> void:
	var result := DialogSpec.normalize({
		"appearance": {
			"show_icon": false,
			"title_font_size": 38,
			"body_font_size": 20,
			"button_height": 56,
			"button_width": 540,
			"button_font_scale": 0.72,
			"button_text_alignment": "left",
			"button_text_padding": 18,
			"field_columns": 2,
			"action_separation": 14,
		},
	}, "ru", Vector2(1280, 720))

	_expect_equal(result["appearance"], {
		"show_icon": false,
		"title_font_size": 38,
		"body_font_size": 20,
		"button_height": 56.0,
		"button_width": 540.0,
		"button_font_scale": 0.72,
		"button_text_alignment": "left",
		"button_text_padding": 18.0,
		"field_columns": 2,
		"field_height": 40.0,
		"field_font_size": 18,
		"field_font_scale": 0.5,
		"field_label_font_size": 14,
		"action_separation": 14,
		"hide_node_palette": false,
	}, "large menu appearance")


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
