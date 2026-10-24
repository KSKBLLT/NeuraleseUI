extends VBoxContainer
## Dataset Bento, left column: the project's datasets under «Таблицы» and
## «Изображения», the selected one tinted. The selected dataset also offers
## deleting it, confirmed by a second press.

signal chosen(dataset_name: String)
signal create_pressed
signal delete_pressed

const UI := preload("res://scripts/ui/dataset_bento_ui.gd")

var _title: Label
var _sections: VBoxContainer
var _confirming := false


func _ready() -> void:
	add_theme_constant_override(&"separation", 10)
	var head := HBoxContainer.new()
	var inset := MarginContainer.new()
	inset.add_theme_constant_override(&"margin_left", 6)
	inset.add_theme_constant_override(&"margin_right", 6)
	inset.add_child(head)
	add_child(inset)
	_title = UI.label("", 13, UI.TEXT_2)
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_title)
	head.add_child(UI.spacer())
	var plus := UI.button("+", 18, UI.TEXT_1, UI.BUTTON, 8)
	plus.custom_minimum_size = Vector2(28, 28)
	var tight := plus.get_theme_stylebox(&"normal").duplicate() as StyleBoxFlat
	tight.set_content_margin_all(0)
	plus.add_theme_stylebox_override(&"normal", tight)
	plus.pressed.connect(func(): create_pressed.emit())
	head.add_child(plus)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(scroll)
	_sections = VBoxContainer.new()
	_sections.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sections.add_theme_constant_override(&"separation", 14)
	scroll.add_child(_sections)


func refresh(current: String) -> void:
	_confirming = false
	var names: Array = glob.ds_dump.keys()
	_title.text = "%s · %d" % [UI.t("datasets"), names.size()]
	UI.clear(_sections)
	for kind in ["table", "image"]:
		var items: Array = names.filter(func(dataset_name): return _kind(dataset_name) == kind)
		if items.is_empty():
			continue
		var section := VBoxContainer.new()
		section.add_theme_constant_override(&"separation", 3)
		var heading := UI.label(UI.t("tables" if kind == "table" else "images"), 10, UI.TEXT_3)
		heading.add_theme_font_override(&"font", UI.font(400, 1))
		var heading_inset := MarginContainer.new()
		heading_inset.add_theme_constant_override(&"margin_left", 8)
		heading_inset.add_theme_constant_override(&"margin_bottom", 4)
		heading_inset.add_child(heading)
		section.add_child(heading_inset)
		for dataset_name in items:
			section.add_child(_item(str(dataset_name), str(dataset_name) == current))
		_sections.add_child(section)


func _item(dataset_name: String, picked: bool) -> Control:
	var item := PanelContainer.new()
	item.add_theme_stylebox_override(&"panel", UI.box(UI.PICKED if picked else Color.TRANSPARENT, 12))
	item.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 4)
	var text := MarginContainer.new()
	for side in [&"margin_left", &"margin_right"]:
		text.add_theme_constant_override(side, 10)
	text.add_theme_constant_override(&"margin_top", 9)
	text.add_theme_constant_override(&"margin_bottom", 9 if not picked else 2)
	var lines := VBoxContainer.new()
	lines.add_theme_constant_override(&"separation", 4)
	var title := UI.label(dataset_name, 13, UI.INK if picked else UI.LIST_TEXT)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.clip_text = true
	lines.add_child(title)
	lines.add_child(UI.label(_meta(dataset_name), 11, UI.TEXT_2))
	text.add_child(lines)
	column.add_child(text)
	if picked:
		var actions := MarginContainer.new()
		for side in [&"margin_left", &"margin_right", &"margin_bottom"]:
			actions.add_theme_constant_override(side, 10)
		var remove := UI.button(UI.t("delete_dataset"), 11, UI.VIOLET_TEXT, UI.PICKED_SOFT, 6)
		remove.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		remove.pressed.connect(func():
			if _confirming:
				delete_pressed.emit()
			else:
				_confirming = true
				remove.text = UI.t("sure"))
		actions.add_child(remove)
		column.add_child(actions)
	item.add_child(column)
	item.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not picked:
			chosen.emit(dataset_name))
	return item


func _kind(dataset_name: String) -> String:
	var data: Dictionary = glob.dataset_datas.get(dataset_name, {})
	for column in data.get("col_names", []):
		if str(column).ends_with(":image"):
			return "image"
	return "table"


## «2 → 1 · 162»: inputs, answers and rows at a glance.
func _meta(dataset_name: String) -> String:
	var data: Dictionary = glob.dataset_datas.get(dataset_name, {})
	var columns: int = data.get("col_names", []).size()
	var split: int = int(data.get("outputs_from", columns))
	var rows: int = data.get("arr", []).size()
	return "%d → %d · %s" % [split, columns - split, UI.short(rows)]
