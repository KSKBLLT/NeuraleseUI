func _build_ui() -> void:
	for child in get_children():
		child.free()
	
	var style := StyleBoxEmpty.new()
	add_theme_stylebox_override("panel", style)
	
	var bg := ColorRect.new()
	bg.name = "Background"
	add_child(bg)
	NodePaletteStyle.apply_project_blur_background(bg)

	var margin := MarginContainer.new()
	margin.name = "Margin"
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 9)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	margin.add_child(layout)

	layout.add_child(_header())

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	layout.add_child(scroll)

	var content := VBoxContainer.new()
	content.name = "Content"
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 8)
	scroll.add_child(content)

	var in_label := "Inputs  .  %d" % mapped_input_width()
	if _target_input_width > 0:
		in_label += " / %d" % _target_input_width
	content.add_child(_section_label(in_label, "inputs", "Сенсоры", "Сенсорлар"))
	content.add_child(_sensor_toggles())

	var div1 := HSeparator.new()
	var dstyle = StyleBoxLine.new()
	dstyle.color = Color(1, 1, 1, 0.05)
	div1.add_theme_stylebox_override("separator", dstyle)
	content.add_child(div1)

	var out_label := "Outputs  .  %d" % mapped_output_width()
	if _target_output_width > 0:
		out_label += " / %d" % _target_output_width
	content.add_child(_section_label(out_label, "outputs", "Моторы", "Моторлар"))
	content.add_child(_actuator_toggles())

	var div2 := HSeparator.new()
	div2.add_theme_stylebox_override("separator", dstyle)
	content.add_child(div2)
	content.add_child(_status_label())


func _header() -> Control:
	var row := HBoxContainer.new()
	row.name = "Header"
	row.custom_minimum_size.y = 39.0
	
	var title := Label.new()
	var agent_label = Registry.agent(_agent_id).get("label", "Agent")
	title.text = agent_label
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_override("font", PaletteTitleFont)
	title.add_theme_font_size_override("font_size", 23)
	
	var loc := Loc.new()
	loc.auto = true
	var l = agent_label.to_lower()
	var ru_name = {"car": "Машина", "top-down rover": "Ровер", "flying agent": "Дрон"}.get(l, agent_label)
	var kz_name = {"car": "Көлік", "top-down rover": "Ровер", "flying agent": "Дрон"}.get(l, agent_label)
	loc.localizations_ru = {l: ru_name}
	loc.localizations_kz = {l: kz_name}
	title.add_child(loc)
	row.add_child(title)
	
	var close := Button.new()
	close.name = "Close"
	close.text = "x"
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(30.0, 28.0)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.08, 0.085, 0.095, 0.9)
	normal.border_color = Color(0.28, 0.3, 0.34, 0.9)
	normal.set_border_width_all(1)
	normal.set_corner_radius_all(4)
	var hover := normal.duplicate()
	hover.bg_color = Color(0.13, 0.14, 0.16, 1.0)
	hover.border_color = Color(0.5, 0.53, 0.58, 1.0)
	close.add_theme_stylebox_override("normal", normal)
	close.add_theme_stylebox_override("hover", hover)
	close.pressed.connect(request_close)
	row.add_child(close)
	return row


func _sensor_toggles() -> Control:
	var list := VBoxContainer.new()
	list.name = "SensorToggles"
	list.add_theme_constant_override("separation", 2)

	var fixed_width := 0
	var flexible_sensor := &""
	for sensor_id in Registry.agent(_agent_id).get("sensors", []):
		if not _active_sensor_ids.has(StringName(sensor_id)):
			continue
		var def := Registry.sensor(StringName(sensor_id))
		if def.get("dimension_kind") == &"range":
			if flexible_sensor.is_empty():
				flexible_sensor = StringName(sensor_id)
		else:
			fixed_width += int(def.get("channels", 1))
	var flexible_width := 7
	if not flexible_sensor.is_empty() and _target_input_width > 0:
		flexible_width = maxi(0, _target_input_width - fixed_width)

	for sensor_id in Registry.agent(_agent_id).get("sensors", []):
		var source: Dictionary = Registry.sensor(StringName(sensor_id))
		if source.is_empty():
			continue
		var is_active = _active_sensor_ids.has(StringName(sensor_id))
		var is_flex = source.get("dimension_kind") == &"range"
		var display_length = flexible_width if is_flex else int(source.get("channels", 1))

		list.add_child(_toggle_row(
			StringName(sensor_id),
			str(source.get("label", "Sensor")),
			str(source.get("detail", "")),
			source.get("accent", Color.WHITE),
			is_active,
			display_length,
			true
		))
	return list


func _actuator_toggles() -> Control:
	var list := VBoxContainer.new()
	list.name = "ActuatorToggles"
	list.add_theme_constant_override("separation", 2)
	for actuator_id in Registry.agent(_agent_id).get("actuators", []):
		var source: Dictionary = Registry.actuator(StringName(actuator_id))
		if source.is_empty():
			continue
		var is_active = _active_actuator_ids.has(StringName(actuator_id))
		list.add_child(_toggle_row(
			StringName(actuator_id),
			str(source.get("label", "Actuator")),
			str(source.get("detail", "")),
			source.get("accent", Color.WHITE),
			is_active,
			int(source.get("channels", 1)),
			false
		))
	return list


func _toggle_row(
	id: StringName,
	label_text: String,
	detail_text: String,
	accent: Color,
	is_active: bool,
	channels: int,
	is_input: bool
) -> Control:
	var button := Button.new()
	button.custom_minimum_size = Vector2(0.0, 45.0)
	button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	button.focus_mode = Control.FOCUS_NONE
	
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.08, 0.083, 0.091, 0.0)
	normal.set_corner_radius_all(3)
	normal.content_margin_left = 7
	normal.content_margin_right = 7
	var hover := normal.duplicate()
	hover.bg_color = Color(0.16, 0.17, 0.19, 0.76)
	button.add_theme_stylebox_override("normal", normal)
	button.add_theme_stylebox_override("hover", hover)
	button.add_theme_stylebox_override("pressed", hover)

	var row := HBoxContainer.new()
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	button.add_child(row)

	if is_input:
		button.pressed.connect(func(): toggle_sensor_with_id(id))
	else:
		button.pressed.connect(func(): toggle_actuator_with_id(id))

	var text := VBoxContainer.new()
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_constant_override("separation", 0)
	text.alignment = BoxContainer.ALIGNMENT_CENTER
	var title := Label.new()
	title.text = label_text
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color.WHITE if is_active else Color("8b8e95"))
	
	var loc := Loc.new()
	loc.auto = true
	var tl = label_text.to_lower()
	var ru_dict = {
		"ray sensor": "Луч", "speed": "Скорость", "horizontal speed": "Гор. скорость", "vertical speed": "Верт. скорость",
		"rotation": "Вращение", "gps": "GPS", "goal vector": "Вектор цели", "goal direction": "Направление к цели",
		"local goal direction": "Лок. направление к цели", "goal distance": "Дистанция до цели",
		"normalized position": "Норм. позиция", "heading (sin/cos)": "Направление", "grounded": "На земле",
		"height": "Высота",
		"steering": "Руль", "throttle": "Газ", "brake": "Тормоз", "horizontal thrust": "Гор. тяга",
		"vertical thrust": "Верт. тяга", "jump": "Прыжок"
	}
	var kz_dict = {
		"ray sensor": "Сәуле", "speed": "Жылдамдық", "horizontal speed": "Көл. жылдамдық", "vertical speed": "Тік жылдамдық",
		"rotation": "Бұрылу", "gps": "GPS", "goal vector": "Мақсат векторы", "goal direction": "Мақсат бағыты",
		"local goal direction": "Жерг. мақсат бағыты", "goal distance": "Мақсатқа дейінгі қашықтық",
		"normalized position": "Норм. позиция", "heading (sin/cos)": "Бағыт", "grounded": "Жерде",
		"height": "Биіктік",
		"steering": "Рөл", "throttle": "Газ", "brake": "Тежегіш", "horizontal thrust": "Көл. тарту",
		"vertical thrust": "Тік тарту", "jump": "Секіру"
	}
	loc.localizations_ru = {tl: ru_dict.get(tl, label_text)}
	loc.localizations_kz = {tl: kz_dict.get(tl, label_text)}
	title.add_child(loc)
	text.add_child(title)
	
	row.add_child(text)

	var count_label := Label.new()
	if is_active:
		count_label.text = "[ %d ]" % channels
	count_label.add_theme_color_override("font_color", accent if is_active else Color("55585e"))
	count_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	count_label.add_theme_font_size_override("font_size", 16)
	row.add_child(count_label)

	return button


func toggle_sensor_with_id(id: StringName) -> void:
	var toggle = CheckButton.new()
	toggle.button_pressed = _active_sensor_ids.has(id)
	toggle.toggled.connect(_on_sensor_toggled.bind(id))
	toggle.button_pressed = not toggle.button_pressed
	toggle.free()


func toggle_actuator_with_id(id: StringName) -> void:
	var toggle = CheckButton.new()
	toggle.button_pressed = _active_actuator_ids.has(id)
	toggle.toggled.connect(_on_actuator_toggled.bind(id))
	toggle.button_pressed = not toggle.button_pressed
	toggle.free()


func _status_label() -> Control:
	var label := Label.new()
	label.name = "MappingStatus"
	var validation := ModelBinding.validate(_binding)
	var is_valid = validation.get("valid", false)

	if _target_input_width > 0 and mapped_input_width() != _target_input_width:
		is_valid = false
	if _target_output_width > 0 and mapped_output_width() != _target_output_width:
		is_valid = false

	if is_valid:
		label.text = "All %d ports connected" % (mapped_input_width() + mapped_output_width())
		label.add_theme_color_override("font_color", Color("77dfa2"))
		var loc = Loc.new()
		loc.auto = true
		loc.localizations_ru = {label.text.to_lower(): "Все %d портов подключены" % (mapped_input_width() + mapped_output_width())}
		loc.localizations_kz = {label.text.to_lower(): "Барлық %d порт қосылды" % (mapped_input_width() + mapped_output_width())}
		label.add_child(loc)
	else:
		var msg := _first_validation_message(validation)
		if _target_input_width > 0 and mapped_input_width() != _target_input_width:
			msg = "Mismatch! Expected %d inputs, got %d." % [_target_input_width, mapped_input_width()]
		elif _target_output_width > 0 and mapped_output_width() != _target_output_width:
			msg = "Mismatch! Expected %d outputs, got %d." % [_target_output_width, mapped_output_width()]
		label.text = msg
		label.add_theme_color_override("font_color", Color("ef795f"))
	label.add_theme_font_size_override("font_size", 14)
	return label


func _first_validation_message(validation: Dictionary) -> String:
	for error in validation.get("errors", []):
		if error is Dictionary:
			return str(error.get("message", "The model mapping is invalid."))
	return "The model mapping is invalid."


func _section_label(text: String, eng_base: String, ru: String, kz: String) -> Control:
	var group_header := HBoxContainer.new()
	group_header.add_theme_constant_override("separation", 7)
	
	var accent := ColorRect.new()
	accent.color = Color("6aa7ff").lightened(0.12)
	accent.custom_minimum_size = Vector2(3.0, 14.0)
	accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group_header.add_child(accent)
	
	var group_label := Label.new()
	group_label.text = text
	group_label.modulate = Color(0.78, 0.8, 0.84, 0.96)
	group_label.add_theme_font_size_override("font_size", 18)
	var gloc := Loc.new()
	gloc.auto = true
	gloc.localizations_ru = {text.to_lower(): ru + text.trim_prefix(eng_base.capitalize())}
	gloc.localizations_kz = {text.to_lower(): kz + text.trim_prefix(eng_base.capitalize())}
	group_label.add_child(gloc)
	group_header.add_child(group_label)
	
	return group_header
