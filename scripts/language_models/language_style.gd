extends RefCounted
const ACCENT := Color("7f9eff")
const INK := Color("e3e7f0")
const MUTED := Color("939bae")
const FONT = preload("res://game_assets/fonts/JetBrainsMono-VariableFont_wght.ttf")
const THEME = preload("res://resources/theme_base.tres")

static func box(fill: Color, border: Color = Color.TRANSPARENT, radius: int = 6) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = fill
	style.border_color = border
	style.set_border_width_all(1 if border.a > 0 else 0)
	style.set_corner_radius_all(radius)
	style.content_margin_left = 8
	style.content_margin_right = 8
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	return style

# Reuse native node field and existing AI text editor appearance.
const LINE_FIELD = preload("res://scenes/validate.tscn")
const TEXT_EDITOR = preload("res://scenes/language_models/text_editor.tscn")
static func line_field() -> LineEdit:
	var field: LineEdit = LINE_FIELD.instantiate()
	field.set_script(null)
	field.scale=Vector2.ONE
	field.position=Vector2.ZERO
	field.size=Vector2(56,22)
	field.max_length=0
	field.placeholder_text=""
	field.add_theme_font_size_override("font_size",12)
	for state in ["normal","focus","read_only"]:
		var style: StyleBoxFlat = field.get_theme_stylebox(state).duplicate()
		style.set_corner_radius_all(8)
		style.set_border_width_all(1)
		style.expand_margin_left=2; style.expand_margin_right=2; style.expand_margin_top=2; style.expand_margin_bottom=2
		field.add_theme_stylebox_override(state,style)
	return field

# Conv2D/Y: preserve its native scale, theme, font and border proportions.
static func parameter_field() -> LineEdit:
	var field: LineEdit=LINE_FIELD.instantiate()
	field.set_script(null)
	field.scale=Vector2(0.238192,0.238192)
	field.position=Vector2.ZERO
	field.size=Vector2(110,48)
	field.max_length=4
	field.placeholder_text=""
	return field

static func text_editor() -> TextEdit:
	return TEXT_EDITOR.instantiate()

static func input_editor() -> TextEdit:
	var editor: TextEdit=TEXT_EDITOR.instantiate()
	var field: LineEdit=LINE_FIELD.instantiate()
	var ratio:=float(editor.get_theme_font_size("font_size"))/field.get_theme_font_size("font_size")
	for state in ["normal","focus","read_only"]:
		var native: StyleBoxFlat=field.theme.get_stylebox(state,"LineEdit")
		var style: StyleBoxFlat=native.duplicate()
		for property in [&"border_width_left",&"border_width_right",&"border_width_top",&"border_width_bottom",&"corner_radius_top_left",&"corner_radius_top_right",&"corner_radius_bottom_left",&"corner_radius_bottom_right"]:
			style.set(property,maxi(1,roundi(style.get(property)*ratio)))
		for side in [SIDE_LEFT,SIDE_RIGHT,SIDE_TOP,SIDE_BOTTOM]:
			style.set_content_margin(side,native.get_margin(side)*ratio)
			style.set_expand_margin(side,style.get_expand_margin(side)*ratio)
		style.anti_aliasing_size*=ratio
		editor.add_theme_stylebox_override(state,style)
	field.free()
	return editor

static func token_editor() -> TextEdit:
	var editor: TextEdit = input_editor()
	editor.editable = false
	editor.context_menu_enabled = false
	editor.selecting_enabled = false
	for state in ["normal", "focus", "read_only"]:
		var style: StyleBoxFlat = editor.get_theme_stylebox(state).duplicate()
		style.bg_color = Color(0.1, 0.12, 0.2, 0.85)
		style.border_color = Color(0.49804, 0.61961, 1, 0.45)
		editor.add_theme_stylebox_override(state, style)
	editor.add_theme_color_override("font_color", INK)
	editor.add_theme_color_override("font_readonly_color", INK)
	return editor

static func field(control: Control) -> void:
	control.add_theme_font_size_override("font_size",12)

# Derived from train_begin/train: same material, corner adjustment and ButtonConfig.
const ACTION = preload("res://scenes/language_models/action_button.tscn")
static func button(text: String, action: Callable) -> Control:
	var b = ACTION.instantiate()
	b.auto_wrap = false
	b.base_scale_x = 0.34375
	b.text = text
	if _translations.has(text): b.set_meta("language_ui_text",_translations[text])
	b.base_size = Vector2(maxf(28, FONT.get_string_size(text,HORIZONTAL_ALIGNMENT_LEFT,-1,11).x+18),25)
	b.size = b.base_size
	b.custom_minimum_size = b.base_size
	b.resized.connect(func(): b.base_size=b.size)
	if action.is_valid(): b.pressed.connect(action)
	return b

static func label(text: String, color: Color = MUTED, font_size: int = 10) -> Label:
	var label := Label.new()
	if not text.is_empty():
		label.text = text
		if _translations.has(text): label.set_meta("language_ui_text",_translations[text])
	label.theme = THEME
	label.add_theme_color_override("font_color",color)
	label.add_theme_font_size_override("font_size",font_size)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label

static func fit_button(button: Control) -> void:
	var label: Label=button.get_node("Label")
	var font: Font=label.get_theme_font("font")
	var font_size:=label.get_theme_font_size("font_size")
	var width:=font.get_string_size(button.text,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x
	button.base_scale_x=minf(0.328125,maxf(0.15,(button.size.x-12)/maxf(width,1)))
	button.text=button.text

static var _translations: Dictionary = {}

static func retranslate(root: Node) -> void:
	if (root is Label or root is BlockComponent) and root.has_meta("language_ui_text"):
		var texts: Array=_translations.get(root.text,root.get_meta("language_ui_text"))
		root.set_meta("language_ui_text",texts)
		root.text=localized(texts[0],texts[1],texts[2])
		if root is BlockComponent: fit_button(root)
	for child in root.get_children(): retranslate(child)

static func localized(en: String, ru: String, kz: String) -> String:
	for value in [en,ru,kz]: _translations[value]=[en,ru,kz]
	var main_loop = Engine.get_main_loop()
	if not main_loop is SceneTree: return en
	var global_state = main_loop.root.get_node_or_null("glob")
	var language := str(global_state.get_lang()) if global_state != null else "en"
	return ru if language == "ru" else kz if language == "kz" else en
