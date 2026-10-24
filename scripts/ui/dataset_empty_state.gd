extends Control
## Pixel design: the Datasets tab before the project has any dataset. The
## mascot, one sentence on what a dataset is and one main action; it sits
## over the empty table and follows its size.

signal create_pressed

const AxonMascot = preload("res://scripts/ui/axon_mascot.gd")
const TEXT := {
	"title": {"ru": "Датасетов пока нет.", "kz": "Әзірге датасет жоқ.", "en": "No datasets yet."},
	"lead": {
		"ru": "Датасет — это примеры с правильными ответами. На них сеть учится.",
		"kz": "Датасет — дұрыс жауабы бар мысалдар. Желі солар арқылы үйренеді.",
		"en": "A dataset is a set of examples with the right answers. The network learns from them.",
	},
	"create": {"ru": "Создать датасет", "kz": "Датасет жасау", "en": "Create dataset"},
}

var _plain := CanvasItemMaterial.new()
var _title: Label
var _lead: Label
var _create: Button
var _lang := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	var backdrop := Panel.new()
	backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	var face := StyleBoxFlat.new()
	face.bg_color = design.SC_LOWEST
	face.set_corner_radius_all(24)
	backdrop.add_theme_stylebox_override(&"panel", face)
	add_child(backdrop)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var column := VBoxContainer.new()
	column.custom_minimum_size = Vector2(460, 0)
	column.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_theme_constant_override(&"separation", 14)
	center.add_child(column)
	# Axon waves when the empty tab is shown and blinks at the main action.
	var mascot := AxonMascot.new()
	mascot.custom_minimum_size = Vector2(0, 140)
	mascot.greet_on_show = true
	column.add_child(mascot)
	_title = _label(28, design.ON_SURFACE, true)
	column.add_child(_title)
	_lead = _label(17, design.ON_SURFACE_VAR, false)
	_lead.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(_lead)
	_create = Button.new()
	_create.custom_minimum_size = Vector2(0, 52)
	_create.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	_create.focus_mode = Control.FOCUS_NONE
	_create.add_theme_font_size_override(&"font_size", 17)
	for colour_name in [&"font_color", &"font_hover_color", &"font_pressed_color"]:
		_create.add_theme_color_override(colour_name, Color.WHITE)
	for state in [&"normal", &"hover", &"pressed"]:
		var pill := StyleBoxFlat.new()
		pill.bg_color = design.INK if state == &"normal" else design.INK.lightened(0.15)
		pill.set_corner_radius_all(999)
		pill.content_margin_left = 30.0
		pill.content_margin_right = 30.0
		_create.add_theme_stylebox_override(state, pill)
	_create.pressed.connect(func(): create_pressed.emit())
	_create.mouse_entered.connect(func(): mascot.react(&"blink"))
	column.add_child(_create)


func _process(_delta: float) -> void:
	if not visible:
		return
	var table := get_parent().get_node_or_null("CodeEdit") as Control
	if table:
		position = table.position
		size = table.size
	var lang := str(glob.get_lang())
	if lang != _lang:
		_lang = lang
		_title.text = _t("title")
		_lead.text = _t("lead")
		_create.text = _t("create")


func _label(font_size: int, colour: Color, bold: bool) -> Label:
	var label := Label.new()
	label.material = _plain
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", colour)
	if bold:
		label.add_theme_font_override(&"font", design.sans_title)
	return label


func _t(key: String) -> String:
	var variants: Dictionary = TEXT[key]
	return variants.get(_lang, variants["ru"])
