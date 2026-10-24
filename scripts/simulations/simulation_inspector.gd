class_name SimulationInspector
extends PanelContainer

signal transform_changed(position: Vector2, rotation: float, scale: Vector2, size: Vector2)
signal duplicate_requested
signal delete_requested

var _position_x: SpinBox
var _position_y: SpinBox
var _rotation: SpinBox
var _scale_x: SpinBox
var _scale_y: SpinBox
var _size_x: SpinBox
var _size_y: SpinBox
var _title: Label
var _syncing := false


func _ready() -> void:
	_build()
	hide()


func show_object(object: Node) -> void:
	if not is_instance_valid(object):
		hide()
		return
	_syncing = true
	_title.text = str(object.get_definition().get("label", object.type_id))
	_position_x.value = object.position.x
	_position_y.value = object.position.y
	_rotation.value = rad_to_deg(object.rotation)
	_scale_x.value = object.scale.x
	_scale_y.value = object.scale.y
	_size_x.value = object.object_size.x
	_size_y.value = object.object_size.y
	
	var is_agent = str(object.get_definition().get("body_kind", "")) == "agent"
	_scale_x.editable = not is_agent
	_scale_y.editable = not is_agent
	_size_x.editable = not is_agent
	_size_y.editable = not is_agent
	var alpha = 0.4 if is_agent else 1.0
	_scale_x.modulate.a = alpha
	_scale_y.modulate.a = alpha
	_size_x.modulate.a = alpha
	_size_y.modulate.a = alpha
	
	_syncing = false
	hide()


func clear_object() -> void:
	hide()


func _build() -> void:
	var panel_style := StyleBoxFlat.new()
	panel_style.bg_color = Color(0.055, 0.058, 0.064, 0.975)
	panel_style.border_color = Color(0.43, 0.45, 0.49, 0.92)
	panel_style.set_border_width_all(1)
	panel_style.set_corner_radius_all(4)
	add_theme_stylebox_override("panel", panel_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 10)
	margin.add_theme_constant_override("margin_right", 12)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 6)
	margin.add_child(layout)

	var header := HBoxContainer.new()
	layout.add_child(header)
	_title = Label.new()
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.add_theme_font_size_override("font_size", 15)
	header.add_child(_title)
	var close_button := Button.new()
	close_button.text = "x"
	close_button.flat = true
	close_button.focus_mode = Control.FOCUS_NONE
	close_button.tooltip_text = "Close properties"
	var cloc = Loc.new()
	cloc.auto = true
	cloc.localizations_ru["close properties"] = "Закрыть свойства"
	cloc.localizations_kz["close properties"] = "Қасиеттерді жабу"
	close_button.add_child(cloc)
	close_button.pressed.connect(hide)
	header.add_child(close_button)
	layout.add_child(HSeparator.new())

	_position_x = _add_pair(layout, "Position", "X")
	_position_y = _last_pair_second
	_rotation = _add_single(layout, "Rotation", -360.0, 360.0, 1.0)
	_scale_x = _add_pair(layout, "Scale", "X", 0.1, 10.0, 0.05)
	_scale_y = _last_pair_second
	_size_x = _add_pair(layout, "Size", "W", 8.0, 2048.0, 1.0)
	_size_y = _last_pair_second

	for spin_box in [_position_x, _position_y, _rotation, _scale_x, _scale_y, _size_x, _size_y]:
		spin_box.value_changed.connect(_emit_transform.unbind(1))

	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	layout.add_child(actions)
	var duplicate_button := Button.new()
	duplicate_button.text = "Duplicate"
	var dup_loc = Loc.new()
	dup_loc.auto = true
	dup_loc.localizations_ru["duplicate"] = "Дублировать"
	dup_loc.localizations_kz["duplicate"] = "Көшіру"
	duplicate_button.add_child(dup_loc)
	duplicate_button.focus_mode = Control.FOCUS_NONE
	duplicate_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	duplicate_button.pressed.connect(func(): duplicate_requested.emit())
	actions.add_child(duplicate_button)
	var delete_button := Button.new()
	delete_button.text = "Delete"
	var del_loc = Loc.new()
	del_loc.auto = true
	del_loc.localizations_ru["delete"] = "Удалить"
	del_loc.localizations_kz["delete"] = "Жою"
	delete_button.add_child(del_loc)
	delete_button.focus_mode = Control.FOCUS_NONE
	delete_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	delete_button.add_theme_color_override("font_color", Color(1.0, 0.58, 0.58))
	delete_button.pressed.connect(func(): delete_requested.emit())
	actions.add_child(delete_button)


var _last_pair_second: SpinBox


func _add_pair(
	parent: VBoxContainer,
	label_text: String,
	first_prefix: String,
	minimum := -4096.0,
	maximum := 4096.0,
	step := 1.0
) -> SpinBox:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	var loc = Loc.new()
	loc.auto = true
	var tl = label_text.to_lower()
	loc.localizations_ru[tl] = {"position": "Позиция", "scale": "Масштаб", "size": "Размер"}.get(tl, label_text)
	loc.localizations_kz[tl] = {"position": "Позиция", "scale": "Масштаб", "size": "Өлшем"}.get(tl, label_text)
	label.add_child(loc)
	label.custom_minimum_size.x = 66
	row.add_child(label)
	var first := _spin_box(first_prefix, minimum, maximum, step)
	var second := _spin_box("Y" if first_prefix == "X" else "H", minimum, maximum, step)
	row.add_child(first)
	row.add_child(second)
	_last_pair_second = second
	return first


func _add_single(
	parent: VBoxContainer,
	label_text: String,
	minimum: float,
	maximum: float,
	step: float
) -> SpinBox:
	var row := HBoxContainer.new()
	parent.add_child(row)
	var label := Label.new()
	label.text = label_text
	var loc = Loc.new()
	loc.auto = true
	var tl = label_text.to_lower()
	loc.localizations_ru[tl] = {"rotation": "Вращение"}.get(tl, label_text)
	loc.localizations_kz[tl] = {"rotation": "Бұрылу"}.get(tl, label_text)
	label.add_child(loc)
	label.custom_minimum_size.x = 66
	row.add_child(label)
	var spin_box := _spin_box("", minimum, maximum, step)
	row.add_child(spin_box)
	return spin_box


func _spin_box(prefix: String, minimum: float, maximum: float, step: float) -> SpinBox:
	var spin_box := SpinBox.new()
	spin_box.prefix = prefix
	spin_box.min_value = minimum
	spin_box.max_value = maximum
	spin_box.step = step
	spin_box.custom_minimum_size.x = 78
	spin_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spin_box


func _emit_transform() -> void:
	if _syncing:
		return
	transform_changed.emit(
		Vector2(_position_x.value, _position_y.value),
		deg_to_rad(_rotation.value),
		Vector2(_scale_x.value, _scale_y.value),
		Vector2(_size_x.value, _size_y.value)
	)
