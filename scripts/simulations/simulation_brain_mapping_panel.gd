class_name SimulationBrainMappingPanel
extends PanelContainer

const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")
const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")
const NodePaletteStyle = preload("res://scripts/node_palette.gd")
const PaletteTitleFont = preload("res://game_assets/fonts/JetBrainsSans[wght]-VF.ttf")

signal close_requested
signal binding_changed(binding: Dictionary)

var _model_name := "Project model"
var _agent_id: StringName = &"side_view_car"
var _binding: Dictionary = {}
var _inputs_label: Control
var _outputs_label: Control
var _inputs_container: Control
var _outputs_container: Control
var _status_label_node: Control
var _ui_built_for_agent: StringName = &""
var _agent: Node = null
var _active_sensor_ids := {}
var _active_actuator_ids := {}
var _target_input_width := 0
var _target_output_width := 0


func _ready() -> void:
	_binding = ModelBinding.create_default(_agent_id)
	_build_ui()

func _process(_delta: float) -> void:
	if visible and get_global_rect().has_point(get_global_mouse_position()):
		glob.occupy(self, &"scroll")
	else:
		glob.un_occupy(self, &"scroll")


func mapped_input_width() -> int:
	return int(_binding.get("input_width", 0))


func mapped_output_width() -> int:
	return int(_binding.get("output_width", 0))


func show_for_agent(
	agent: Node = null,
	model_name: String = "Project model",
	model_contract: Dictionary = {}
) -> void:
	_agent = agent
	_model_name = model_name if not model_name.strip_edges().is_empty() else "Project model"
	if is_instance_valid(agent) and agent.has_method("get_agent_id"):
		_agent_id = agent.get_agent_id()
	if is_instance_valid(agent) and agent.has_method("get_model_binding"):
		var candidate: Dictionary = agent.get_model_binding()
		if ModelBinding.validate(candidate).get("valid", false):
			_binding = candidate
	if _binding.is_empty() or StringName(_binding.get("agent_id", "")) != _agent_id:
		_binding = ModelBinding.create_default(_agent_id)

	_target_input_width = int(model_contract.get("input_width", 0))
	_target_output_width = int(model_contract.get("output_width", 0))
	if (
		_target_input_width > 0
		and _target_output_width > 0
		and (
			mapped_input_width() != _target_input_width
			or mapped_output_width() != _target_output_width
		)
	):
		var automatic := ModelBinding.create_auto(
			_agent_id,
			_target_input_width,
			_target_output_width,
			_binding.get("model", {})
		)
		if not automatic.is_empty():
			_binding = automatic

	_active_sensor_ids.clear()
	for mapping in _binding.get("inputs", []):
		if mapping is Dictionary:
			_active_sensor_ids[StringName(mapping.get("sensor_id", ""))] = true
	_active_actuator_ids.clear()
	for mapping in _binding.get("outputs", []):
		if mapping is Dictionary:
			_active_actuator_ids[StringName(mapping.get("actuator_id", ""))] = true

	_recompute_binding()
	show()


func _on_sensor_toggled(enabled: bool, sensor_id: StringName) -> void:
	if enabled:
		if _target_input_width > 0:
			var def := Registry.sensor(sensor_id)
			if def.get("dimension_kind") != &"range":
				var needed = int(def.get("channels", 1))
				var current_fixed = 0
				for sid in _active_sensor_ids:
					var sdef := Registry.sensor(StringName(sid))
					if sdef.get("dimension_kind") != &"range":
						current_fixed += int(sdef.get("channels", 1))
				if current_fixed + needed > _target_input_width:
					if glob.get_lang() == "ru":
						ui.error("Невозможно включить этот сенсор: не хватает входных портов у агента! Освободите место, отключив другой сенсор.")
					elif glob.get_lang() == "kz":
						ui.error("Бұл сенсорды қосу мүмкін емес: агентте кіріс порттары жеткіліксіз! Басқа сенсорды өшіріп, орын босатыңыз.")
					else:
						ui.error("Cannot enable this sensor: not enough input ports on the agent! Free up space by disabling another sensor.")
					_refresh_toggles.call_deferred()
					return
		_active_sensor_ids[sensor_id] = true
	else:
		_active_sensor_ids.erase(sensor_id)
	_recompute_binding()


func _on_actuator_toggled(enabled: bool, actuator_id: StringName) -> void:
	if enabled:
		if _target_output_width > 0:
			var def := Registry.actuator(actuator_id)
			var needed = int(def.get("channels", 1))
			var current_fixed = 0
			for aid in _active_actuator_ids:
				var sdef := Registry.actuator(StringName(aid))
				current_fixed += int(sdef.get("channels", 1))
			if current_fixed + needed > _target_output_width:
				if glob.get_lang() == "ru":
					ui.error("Невозможно включить этот мотор: не хватает выходных портов у агента! Освободите место, отключив другой мотор.")
				elif glob.get_lang() == "kz":
					ui.error("Бұл моторды қосу мүмкін емес: агентте шығыс порттары жеткіліксіз! Басқа моторды өшіріп, орын босатыңыз.")
				else:
					ui.error("Cannot enable this actuator: not enough output ports on the agent! Free up space by disabling another actuator.")
				_refresh_toggles.call_deferred()
				return
		_active_actuator_ids[actuator_id] = true
	else:
		_active_actuator_ids.erase(actuator_id)
	_recompute_binding()


func _recompute_binding() -> void:
	var inputs: Array = []
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

	var current_start := 0
	for sensor_id in Registry.agent(_agent_id).get("sensors", []):
		if not _active_sensor_ids.has(StringName(sensor_id)):
			continue
		var def := Registry.sensor(StringName(sensor_id))
		var length := int(def.get("channels", 1))
		if StringName(sensor_id) == flexible_sensor:
			length = flexible_width
			if length <= 0:
				continue
		inputs.append({
			"sensor_id": StringName(sensor_id),
			"start": current_start,
			"length": length
		})
		current_start += length

	var outputs: Array = []
	var current_out_start := 0
	for actuator_id in Registry.agent(_agent_id).get("actuators", []):
		if not _active_actuator_ids.has(StringName(actuator_id)):
			continue
		var def := Registry.actuator(StringName(actuator_id))
		var length := int(def.get("channels", 1))
		outputs.append({
			"actuator_id": StringName(actuator_id),
			"start": current_out_start,
			"length": length
		})
		current_out_start += length

	_binding["inputs"] = inputs
	_binding["outputs"] = outputs
	_binding["input_width"] = current_start
	_binding["output_width"] = current_out_start

	if is_instance_valid(_agent):
		_agent.set_model_binding(_binding)
	binding_changed.emit(_binding.duplicate(true))
	if _ui_built_for_agent != _agent_id or find_child("Scroll", true, false) == null:
		_build_ui.call_deferred()
	else:
		_refresh_toggles.call_deferred()


func request_close() -> void:
	hide()
	close_requested.emit()


func _build_ui() -> void:
	_ui_built_for_agent = _agent_id
	var old_scroll = 0
	var scroll_node = find_child("Scroll", true, false)
	if scroll_node != null:
		old_scroll = scroll_node.scroll_vertical
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

	var in_label := "Inputs %d" % mapped_input_width()
	if _target_input_width > 0:
		in_label += " / %d" % _target_input_width
	_inputs_label = _section_label(in_label, "inputs", "Сенсоры", "Сенсорлар")
	content.add_child(_inputs_label)
	_inputs_container = _sensor_toggles()
	content.add_child(_inputs_container)

	var div1 := HSeparator.new()
	var dstyle = StyleBoxLine.new()
	dstyle.color = Color(1, 1, 1, 0.05)
	div1.add_theme_stylebox_override("separator", dstyle)
	content.add_child(div1)

	var out_label := "Outputs %d" % mapped_output_width()
	if _target_output_width > 0:
		out_label += " / %d" % _target_output_width
	_outputs_label = _section_label(out_label, "outputs", "Моторы", "Моторлар")
	content.add_child(_outputs_label)
	_outputs_container = _actuator_toggles()
	content.add_child(_outputs_container)

	var div2 := HSeparator.new()
	div2.add_theme_stylebox_override("separator", dstyle)
	content.add_child(div2)
	_status_label_node = _status_label()
	content.add_child(_status_label_node)
	
	_refresh_toggles()
	
	if old_scroll > 0:
		var restore_scroll = func(): scroll.scroll_vertical = old_scroll
		get_tree().process_frame.connect(restore_scroll, CONNECT_ONE_SHOT)

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
	var ru_name = {"car": "Машина", "side-view car": "Машина", "top-down rover": "Ровер", "flying agent": "Дрон"}.get(l, agent_label)
	var kz_name = {"car": "Көлік", "side-view car": "Көлік", "top-down rover": "Ровер", "flying agent": "Дрон"}.get(l, agent_label)
	loc.localizations_ru[l] = str(ru_name)
	loc.localizations_kz[l] = str(kz_name)
	title.add_child(loc)
	row.add_child(title)
	
	var close := Button.new()
	close.name = "Close"
	close.icon = preload("res://game_assets/icons/check_wrong.png")
	close.expand_icon = true
	close.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	close.focus_mode = Control.FOCUS_NONE
	close.custom_minimum_size = Vector2(28.0, 28.0)
	var normal := StyleBoxEmpty.new()
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(1.0, 1.0, 1.0, 0.1)
	hover.set_corner_radius_all(14)
	close.add_theme_stylebox_override("normal", normal)
	close.add_theme_stylebox_override("hover", hover)
	close.add_theme_stylebox_override("pressed", hover)
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
	
	var accent_rect := ColorRect.new()
	accent_rect.name = "AccentRect"
	accent_rect.color = accent
	accent_rect.custom_minimum_size = Vector2(3.0, 14.0)
	accent_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	accent_rect.visible = is_active
	
	var accent_margin = MarginContainer.new()
	accent_margin.add_theme_constant_override("margin_top", 14)
	accent_margin.add_theme_constant_override("margin_bottom", 14)
	accent_margin.add_theme_constant_override("margin_left", 3)
	accent_margin.add_theme_constant_override("margin_right", 5)
	accent_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	accent_margin.add_child(accent_rect)
	row.add_child(accent_margin)
	
	var check := CheckButton.new()
	check.button_pressed = is_active
	check.mouse_filter = Control.MOUSE_FILTER_IGNORE
	check.focus_mode = Control.FOCUS_NONE
	check.name = "Check"
	row.add_child(check)
	
	button.set_meta("id", id)
	button.set_meta("accent", accent)
	
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
	title.name = "Title"
	title.text = label_text
	title.add_theme_font_size_override("font_size", 20)
	title.add_theme_color_override("font_color", Color.WHITE if is_active else Color("8b8e95"))
	
	var loc := Loc.new()
	loc.auto = true
	var tl = label_text.to_lower()
	var ru_dict = {
		"ray sensor": "Датчик зрения", "speed": "Датчик скорости", "horizontal speed": "Скорость влево/вправо", "vertical speed": "Скорость вверх/вниз",
		"rotation": "Вращение", "gps": "Датчик GPS", "goal vector": "Вектор цели", "goal direction": "Направление к цели",
		"local goal direction": "Поворот к цели", "goal distance": "Расстояние до цели",
		"normalized position": "Мое расположение (от 0 до 1)", "heading (sin/cos)": "Направление", "on ground": "На земле",
		"height": "Как высоко я нахожусь?",
		"position": "Расположение",
		"heading": "Куда я смотрю?",
		"steering": "Поворот руля", "throttle": "Педаль газа", "brake": "Педаль тормоза", "horizontal thrust": "Полет влево/вправо",
		"vertical thrust": "Полет вверх/вниз", "jump": "Умение прыгать"
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
	loc.localizations_ru[tl] = str(ru_dict.get(tl, label_text))
	loc.localizations_kz[tl] = str(kz_dict.get(tl, label_text))
	title.add_child(loc)
	text.add_child(title)
	
	row.add_child(text)

	var count_label := Label.new()
	count_label.name = "CountLabel"
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
		loc.localizations_ru[label.text.to_lower()] = "Все %d портов подключены" % (mapped_input_width() + mapped_output_width())
		loc.localizations_kz[label.text.to_lower()] = "Барлық %d порт қосылды" % (mapped_input_width() + mapped_output_width())
		label.add_child(loc)
	else:
		var msg := _first_validation_message(validation)
		if _target_input_width > 0 and mapped_input_width() != _target_input_width:
			if glob.get_lang() == "ru":
				msg = "Несовпадение! Ожидалось %d входов, получено %d." % [_target_input_width, mapped_input_width()]
			elif glob.get_lang() == "kz":
				msg = "Сәйкессіздік! %d кіріс күтілді, %d алынды." % [_target_input_width, mapped_input_width()]
			else:
				msg = "Mismatch! Expected %d inputs, got %d." % [_target_input_width, mapped_input_width()]
		elif _target_output_width > 0 and mapped_output_width() != _target_output_width:
			if glob.get_lang() == "ru":
				msg = "Несовпадение! Ожидалось %d выходов, получено %d." % [_target_output_width, mapped_output_width()]
			elif glob.get_lang() == "kz":
				msg = "Сәйкессіздік! %d шығыс күтілді, %d алынды." % [_target_output_width, mapped_output_width()]
			else:
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
	
	var group_label := Label.new()
	group_label.name = "GroupLabel"
	group_label.text = text
	group_label.modulate = Color(0.78, 0.8, 0.84, 0.96)
	group_label.add_theme_font_size_override("font_size", 18)
	var gloc := Loc.new()
	gloc.auto = true
	gloc.localizations_ru[text.to_lower()] = str(ru + text.trim_prefix(eng_base.capitalize()))
	gloc.localizations_kz[text.to_lower()] = str(kz + text.trim_prefix(eng_base.capitalize()))
	group_label.add_child(gloc)
	group_header.add_child(group_label)
	
	return group_header


func _refresh_toggles() -> void:
	if not is_instance_valid(_inputs_label) or not is_instance_valid(_outputs_label):
		return
		
	var in_label := "Inputs %d" % mapped_input_width()
	if _target_input_width > 0:
		in_label += " / %d" % _target_input_width
	var il = _inputs_label.get_node_or_null("GroupLabel") as Label
	if il:
		il.text = in_label
		if _target_input_width > 0 and mapped_input_width() != _target_input_width:
			il.modulate = Color(1.0, 0.45, 0.45, 0.96)
		else:
			il.modulate = Color(0.78, 0.8, 0.84, 0.96)
		for child in il.get_children():
			if child is Loc:
				child.localizations_ru[in_label.to_lower()] = "Список датчиков" + in_label.trim_prefix("Inputs")
				child.localizations_kz[in_label.to_lower()] = "Сенсорлар" + in_label.trim_prefix("Inputs")
				child.translate()

	var out_label := "Outputs %d" % mapped_output_width()
	if _target_output_width > 0:
		out_label += " / %d" % _target_output_width
	var ol = _outputs_label.get_node_or_null("GroupLabel") as Label
	if ol:
		ol.text = out_label
		if _target_output_width > 0 and mapped_output_width() != _target_output_width:
			ol.modulate = Color(1.0, 0.45, 0.45, 0.96)
		else:
			ol.modulate = Color(0.78, 0.8, 0.84, 0.96)
		for child in ol.get_children():
			if child is Loc:
				child.localizations_ru[out_label.to_lower()] = "Список моторов" + out_label.trim_prefix("Outputs")
				child.localizations_kz[out_label.to_lower()] = "Моторлар" + out_label.trim_prefix("Outputs")
				child.translate()

	if is_instance_valid(_status_label_node):
		var validation := ModelBinding.validate(_binding)
		var is_valid = validation.get("valid", false)
		if _target_input_width > 0 and mapped_input_width() != _target_input_width:
			is_valid = false
		if _target_output_width > 0 and mapped_output_width() != _target_output_width:
			is_valid = false
			
		var sl = _status_label_node as Label
		var child_loc = null
		for child in sl.get_children():
			if child is Loc:
				child_loc = child
				break
				
		if is_valid:
			sl.text = "All %d ports connected" % (mapped_input_width() + mapped_output_width())
			sl.add_theme_color_override("font_color", Color("77dfa2"))
			if not child_loc:
				child_loc = Loc.new()
				child_loc.auto = true
				sl.add_child(child_loc)
			child_loc.localizations_ru[sl.text.to_lower()] = "Все %d портов подключены" % (mapped_input_width() + mapped_output_width())
			child_loc.localizations_kz[sl.text.to_lower()] = "Барлық %d порт қосылды" % (mapped_input_width() + mapped_output_width())
			child_loc.translate()
		else:
			var msg := _first_validation_message(validation)
			if _target_input_width > 0 and mapped_input_width() != _target_input_width:
				if glob.get_lang() == "ru":
					msg = "Несовпадение! Ожидалось %d входов, получено %d." % [_target_input_width, mapped_input_width()]
				elif glob.get_lang() == "kz":
					msg = "Сәйкессіздік! %d кіріс күтілді, %d алынды." % [_target_input_width, mapped_input_width()]
				else:
					msg = "Mismatch! Expected %d inputs, got %d." % [_target_input_width, mapped_input_width()]
			elif _target_output_width > 0 and mapped_output_width() != _target_output_width:
				if glob.get_lang() == "ru":
					msg = "Несовпадение! Ожидалось %d выходов, получено %d." % [_target_output_width, mapped_output_width()]
				elif glob.get_lang() == "kz":
					msg = "Сәйкессіздік! %d шығыс күтілді, %d алынды." % [_target_output_width, mapped_output_width()]
				else:
					msg = "Mismatch! Expected %d outputs, got %d." % [_target_output_width, mapped_output_width()]
			sl.text = msg
			sl.add_theme_color_override("font_color", Color("ef795f"))
			if child_loc:
				child_loc.free()
				
	for button in _inputs_container.get_children():
		if button.has_meta("id"):
			var id = button.get_meta("id")
			var is_active = _active_sensor_ids.has(id)
			var check = button.find_child("Check", true, false)
			if check: check.button_pressed = is_active
			var accent_rect = button.find_child("AccentRect", true, false)
			if accent_rect: accent_rect.visible = is_active
			var title = button.find_child("Title", true, false)
			var accent = button.get_meta("accent") as Color
			if title: title.add_theme_color_override("font_color", Color.WHITE if is_active else Color("8b8e95"))
			var count = button.find_child("CountLabel", true, false)
			if count:
				count.add_theme_color_override("font_color", accent if is_active else Color("55585e"))
				if is_active:
					# Find length from binding
					var length = 1
					for item in _binding.get("inputs", []):
						if item.get("sensor_id") == id:
							length = item.get("length", 1)
							break
					count.text = "[ %d ]" % length
				else:
					count.text = ""

	for button in _outputs_container.get_children():
		if button.has_meta("id"):
			var id = button.get_meta("id")
			var is_active = _active_actuator_ids.has(id)
			var check = button.find_child("Check", true, false)
			if check: check.button_pressed = is_active
			var accent_rect = button.find_child("AccentRect", true, false)
			if accent_rect: accent_rect.visible = is_active
			var title = button.find_child("Title", true, false)
			var accent = button.get_meta("accent") as Color
			if title: title.add_theme_color_override("font_color", Color.WHITE if is_active else Color("8b8e95"))
			var count = button.find_child("CountLabel", true, false)
			if count:
				count.add_theme_color_override("font_color", accent if is_active else Color("55585e"))
