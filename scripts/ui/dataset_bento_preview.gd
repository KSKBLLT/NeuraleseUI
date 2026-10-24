extends VBoxContainer
## Dataset Bento, right column: one row up close — its picture, what the
## network sees in it and what it does, why it looks like a mistake, and
## «Удалить» / «Оставить» to decide about it.

signal step(delta: int)
signal delete_pressed
signal keep_pressed

const UI := preload("res://scripts/ui/dataset_bento_ui.gd")
const Draw := preload("res://scripts/ui/dataset_bento_draw.gd")

var _heading: Label
var _total: Label
var _title: Label
var _sub: Label
var _picture: Control
var _picture_data := {}
var _legend: HBoxContainer
var _see: Label
var _do: Label
var _why_box: PanelContainer
var _why: Label
var _warn_box: PanelContainer
var _warn: Label
var _body: Array[Control] = []
var _empty: Label
var _buttons: GridContainer


func _ready() -> void:
	add_theme_constant_override(&"separation", 12)
	var head := HBoxContainer.new()
	_heading = UI.label("", 13, UI.TEXT_2)
	head.add_child(_heading)
	head.add_child(UI.spacer())
	_total = UI.label("", 11, UI.TEXT_3)
	head.add_child(_total)
	add_child(head)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override(&"separation", 8)
	var titles := VBoxContainer.new()
	titles.add_theme_constant_override(&"separation", 2)
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title = UI.label("", 14, UI.INK)
	_sub = UI.label("", 11, UI.TEXT_2)
	_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_sub.clip_text = true
	titles.add_child(_title)
	titles.add_child(_sub)
	title_row.add_child(titles)
	for arrow in [["←", -1], ["→", 1]]:
		var button := UI.button(arrow[0], 13)
		button.custom_minimum_size = Vector2(28, 28)
		var tight := button.get_theme_stylebox(&"normal").duplicate() as StyleBoxFlat
		tight.set_content_margin_all(0)
		button.add_theme_stylebox_override(&"normal", tight)
		button.pressed.connect(func(): step.emit(arrow[1]))
		title_row.add_child(button)
	add_child(title_row)
	_picture = Draw.Painted.new(func(ci: Control):
		ci.draw_style_box(UI.box(UI.WELL, 10), Rect2(Vector2.ZERO, ci.size))
		if not _picture_data.is_empty():
			Draw.draw_row(ci, Rect2(Vector2.ZERO, ci.size), _picture_data, true))
	_picture.resized.connect(func(): _picture.custom_minimum_size.y = _picture.size.x * 0.6)
	add_child(_picture)
	_legend = HBoxContainer.new()
	_legend.add_theme_constant_override(&"separation", 14)
	add_child(_legend)
	var facts := UI.card(UI.CHIP, 0, 10)
	(facts.get_theme_stylebox(&"panel") as StyleBoxFlat).content_margin_left = 12.0
	(facts.get_theme_stylebox(&"panel") as StyleBoxFlat).content_margin_right = 12.0
	(facts.get_theme_stylebox(&"panel") as StyleBoxFlat).content_margin_top = 10.0
	(facts.get_theme_stylebox(&"panel") as StyleBoxFlat).content_margin_bottom = 10.0
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override(&"h_separation", 8)
	grid.add_theme_constant_override(&"v_separation", 6)
	_see = _fact(grid, "sees", UI.MINT)
	_do = _fact(grid, "does", UI.YELLOW)
	facts.add_child(grid)
	add_child(facts)
	_why_box = _note(UI.CORAL)
	_why = _why_box.get_child(0).get_child(1)
	_warn_box = _note(UI.YELLOW)
	_warn = _warn_box.get_child(0).get_child(1)
	_buttons = GridContainer.new()
	_buttons.columns = 2
	_buttons.add_theme_constant_override(&"h_separation", 6)
	var remove := (UI.tagged(UI.button("", 13, UI.TEXT_1, UI.BUTTON, 10), "delete") as Button)
	var keep := (UI.tagged(UI.button("", 13, UI.ON_VIOLET, UI.VIOLET, 10, 600), "keep") as Button)
	for button in [remove, keep]:
		button.custom_minimum_size.y = 40
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_buttons.add_child(button)
	remove.pressed.connect(func(): delete_pressed.emit())
	keep.pressed.connect(func(): keep_pressed.emit())
	add_child(_buttons)
	_empty = (UI.tagged(UI.label("", 12, UI.TEXT_3), "empty") as Label)
	_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	add_child(_empty)
	_body = [title_row, _picture, _legend, facts, _buttons]


func _fact(grid: GridContainer, key: String, colour: Color) -> Label:
	var head := UI.tagged(UI.label("", 10, colour), key)
	head.add_theme_font_override(&"font", UI.font(400, 1))
	head.custom_minimum_size.x = 58
	grid.add_child(head)
	var value := UI.label("", 12, UI.TEXT_1)
	value.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	value.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.add_child(value)
	return value


func _note(colour: Color) -> PanelContainer:
	var note := PanelContainer.new()
	var style := UI.box(Color(colour, 0.08), 10, 10)
	style.content_margin_left = 12.0
	style.border_color = Color(colour, 0.25)
	style.set_border_width_all(1)
	note.add_theme_stylebox_override(&"panel", style)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 8)
	var dot := Draw.Painted.new(func(ci: Control): ci.draw_circle(Vector2(3.5, 8.5), 3.5, colour))
	dot.custom_minimum_size = Vector2(7, 14)
	row.add_child(dot)
	var text := UI.label("", 11, Color("#4A2C24") if colour == UI.CORAL else UI.TEXT_1)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(text)
	note.add_child(row)
	add_child(note)
	return note


## info: title, sub, total, picture (see Draw.draw_row), legend ("car",
## "table" or ""), see, do, why, warn. An empty info shows «Здесь пусто».
func show_row(info: Dictionary) -> void:
	_heading.text = UI.t("preview")
	_total.text = str(info.get("total", ""))
	var has_row := info.has("title")
	for part in _body:
		part.visible = has_row
	_empty.visible = not has_row
	_why_box.visible = has_row and str(info.get("why", "")) != ""
	_warn_box.visible = str(info.get("warn", "")) != ""
	_warn.text = "%s: %s" % [UI.t("before_training"), info.get("warn", "")]
	if not has_row:
		return
	_title.text = info["title"]
	_sub.text = info.get("sub", "")
	_picture_data = info.get("picture", {})
	_picture.queue_redraw()
	_see.text = info.get("see", "")
	_do.text = info.get("do", "")
	_why.text = info.get("why", "")
	UI.clear(_legend)
	var legend: String = info.get("legend", "")
	if legend == "car":
		_legend.add_child(_key(UI.t("ray_legend"), UI.MINT, true))
		_legend.add_child(_key(UI.t("way_legend"), UI.YELLOW, false))
	elif legend == "table":
		_legend.add_child(_key(UI.t("inputs_legend"), UI.MINT, false))


func _key(text: String, colour: Color, dot: bool) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 6)
	var mark := Draw.Painted.new(func(ci: Control):
		if dot:
			ci.draw_circle(Vector2(3, ci.size.y * 0.5), 3.0, colour)
		else:
			ci.draw_rect(Rect2(0, ci.size.y * 0.5 - 1.5, 12, 3), colour))
	mark.custom_minimum_size = Vector2(6 if dot else 12, 12)
	row.add_child(mark)
	row.add_child(UI.label(text, 10, UI.TEXT_2))
	return row
