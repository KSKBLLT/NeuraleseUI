extends Node

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	var settings := load("res://scenes/settings.tscn").instantiate() as SplashMenu
	settings.show_on_ready = false
	settings.process_mode = Node.PROCESS_MODE_DISABLED
	add_child(settings)
	await get_tree().process_frame
	settings.show()

	var settings_panel := settings.get_node_or_null("ColorRect") as ColorRect
	var language_button := settings.find_child("lang", true, false) as BlockComponent
	var quality_button := settings.find_child("quality", true, false) as BlockComponent
	glob.set_graphics_quality("high")
	settings.call("update_graphics_quality")
	_expect(language_button != null, "settings must retain the language carousel")
	_expect(quality_button != null, "settings must contain the quality carousel next to language")
	_expect(settings_panel != null, "settings must contain its shader-backed panel")
	if settings_panel != null:
		_expect(
			settings_panel.get_instance_shader_parameter("tuning") == Color(0, 0, 0, 0.7529412),
			"settings panel must retain its dark glass tuning"
		)
		_expect(
			settings_panel.get_instance_shader_parameter("outline_color") == Color(0.85, 0.85, 0.85, 1),
			"settings panel must retain its outline color"
		)
		_expect(
			settings_panel.get_instance_shader_parameter("corner_radius_width_add") == Vector2(9.365, 1),
			"settings panel must retain its rounded-corner offset"
		)
	_expect(
		settings.get_node_or_null("ColorRect/graphics_quality_row") == null,
		"settings must not contain the removed graphics-quality dropdown footer"
	)
	if language_button != null and quality_button != null:
		_expect(quality_button.global_position.x > language_button.global_position.x, "quality must appear after language")
		_expect(quality_button.button_type == BlockComponent.ButtonType.BLOCK_BUTTON, "quality must be a carousel button, not a dropdown")
		_expect(quality_button.config == language_button.config, "quality must duplicate the language button styling")
		_expect(quality_button.scale == language_button.scale, "quality must duplicate the language button scale")
		_expect(
			quality_button.get_instance_shader_parameter("corner_radius_width_add")
			== language_button.get_instance_shader_parameter("corner_radius_width_add"),
			"quality must duplicate the language button corner-radius offset"
		)
		_expect(
			quality_button.get_instance_shader_parameter("extents")
			== language_button.get_instance_shader_parameter("extents"),
			"quality must duplicate the language button shader extents"
		)
		_expect(quality_button.base_size.x > language_button.base_size.x, "quality must be wider for its text")
		_expect(quality_button.text == "Макс. качество", "quality starts at the maximum-quality label")

		glob.set_graphics_quality("high")
		settings.call("_on_quality_released")
		_expect(glob.get_graphics_quality() == "medium", "first quality click must select medium")
		_expect(quality_button.text == "Сред. качество", "medium must update the carousel label")
		settings.call("_on_quality_released")
		_expect(glob.get_graphics_quality() == "low", "second quality click must select low")
		_expect(quality_button.text == "Низк. качество", "low must update the carousel label")
		settings.call("_on_quality_released")
		_expect(glob.get_graphics_quality() == "high", "third quality click must return to maximum")
		_expect(quality_button.text == "Макс. качество", "maximum must restore the carousel label")
		var language := str(glob.get_lang())
		glob.change_lang("en")
		_expect(quality_button.text == "Max quality", "the carousel follows the interface language: %s" % quality_button.text)
		glob.change_lang("kz")
		_expect(quality_button.text == "Жоғары сапа", "the carousel speaks Kazakh: %s" % quality_button.text)
		glob.change_lang(language)

	settings.queue_free()
	await get_tree().process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_settings_quality_carousel")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
