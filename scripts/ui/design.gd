extends Node
## Pixel design: a light Material 3 look (seed #8C52FF, the logo violet) laid
## over the classic UI without rewriting every scene.
##
## The colour work happens in the shaders (shaders/design.gdshaderinc): every
## block and label recolours itself while the `_design_pixel` global is on.
## This autoload only tells blocks which role they play (graph node, field
## inside a node, panel...) and recolours what the shaders never see: plain
## ColorRects, Line2Ds, icons and Godot theme styleboxes.
##
## Run the app with the user argument `--classic-ui` (after `--`) for the
## classic look. Keep the colours in sync with shaders/design.gdshaderinc.

const SURFACE := Color("#FEF7FF")
const SC_LOWEST := Color("#FFFFFF")
const SC_LOW := Color("#F8F1FA")
const SC := Color("#F2ECF4")
const SC_HIGH := Color("#ECE6EE")
const SC_HIGHEST := Color("#E6E0EA")
const ON_SURFACE := Color("#1D1B20")
const ON_SURFACE_VAR := Color("#4A4455")
const OUTLINE := Color("#7B7487")
const OUTLINE_VAR := Color("#CCC3D8")
const PRIMARY := Color("#6F2DE1")
const ON_PRIMARY := Color("#FFFFFF")
const TONAL := Color("#EADDFF")
const ON_TONAL := Color("#3A1D71")
const CANVAS_DOTS := Color("#DCD5E4")

## The workspace frame of the team's light theme: a pale blue bar and
## background around white cards, a near-black active tab, the deep violet
## Axon button and the mint Axon panel.
const BAR_BG := Color("#DAE9FC")
const FRAME_BG := Color("#F3F6FB")
const TAB_ACTIVE := Color("#17161B")
## Ink: "where I am" and the main action of a screen (a black pill).
const INK := Color("#17161B")
## Green only means "run"; red only means "stop" or an error.
const GO := Color("#12A150")
const STOP := Color("#E5484D")
const PROJECT_ICON_BG := Color("#D5F0FF")
const AXON := Color("#5F2691")
const AXON_MINT := Color("#96E1CA")
const AXON_MINT_SOFT := Color("#EFFBF7")
const AXON_ACTION := Color("#D2F3E8")
const AXON_ACTION_ICON := Color("#328372")

## Must match the D_ROLE_* constants in shaders/design.gdshaderinc.
enum Role { AUTO, NODE, FIELD, PRIMARY, TONAL, PANEL, QUIET }

## Node colour families, keyed by `display.category` in node_defs/*.json.
## fill = node body (HCT tone 91, chroma 18), line = its edge (tone 76,
## chroma 36), accent = ports and wires (tone 40), all on the accent's hue.
const CATEGORY := {
	&"data": {"fill": Color("#F8E3B8"), "line": Color("#DBB762"), "accent": Color("#775A00")},
	&"learn": {"fill": Color("#CDECDE"), "line": Color("#7ECAAE"), "accent": Color("#006C53")},
	&"ops": {"fill": Color("#ECE0FE"), "line": Color("#C5B1F2"), "accent": Color("#694DAB")},
	&"shape": {"fill": Color("#FFDCED"), "line": Color("#EDA6D0"), "accent": Color("#953E79")},
	&"output": {"fill": Color("#FFDFCF"), "line": Color("#F9A97B"), "accent": Color("#9A4604")},
	&"train": {"fill": Color("#DAE6FF"), "line": Color("#9DBCF4"), "accent": Color("#185EAF")},
}

## Group titles in the node dock, in the order the dock shows them.
const CATEGORY_TITLES := {
	&"data": {"ru": "Вход", "kz": "Кіріс", "en": "Input"},
	&"learn": {"ru": "Слои", "kz": "Қабаттар", "en": "Layers"},
	&"ops": {"ru": "Операции", "kz": "Операциялар", "en": "Operations"},
	&"shape": {"ru": "Форма", "kz": "Пішін", "en": "Shape"},
	&"output": {"ru": "Выход", "kz": "Шығыс", "en": "Output"},
	&"train": {"ru": "Обучение", "kz": "Оқыту", "en": "Training"},
}

const _BLOCK_SHADERS := ["res://shaders/block.gdshader", "res://shaders/block_screen.gdshader"]
const _TEXT_SHADER := "res://shaders/simple_alphamult.gdshader"
const _CARD_SHADER := "res://shaders/card_alphamult.gdshader"
const _ICON_DIRS := ["res://game_assets/icons/"]
const _SANS_PATH := "res://game_assets/fonts/GoogleSans-LatinCyrillic[GRAD,opsz,wght].ttf"
const _CLASSIC_FONT_HINT := "JetBrains"
const _CLASSIC_FONTS := [
	"res://game_assets/fonts/JetBrainsMono-VariableFont_wght.ttf",
	"res://game_assets/fonts/JetBrainsSans[wght]-VF.ttf",
]

var pixel := true

var _text_material: ShaderMaterial
## Google Sans at the body weight; `sans_title` is the node title weight.
var sans: FontVariation
var sans_title: FontVariation
## The real monospace face, kept for code editors after the swap below.
var mono: FontFile
var _category_by_scene := {}
var _recoloured := {}


func _enter_tree() -> void:
	pixel = not OS.get_cmdline_user_args().has("--classic-ui")
	RenderingServer.global_shader_parameter_set(&"_design_pixel", pixel)
	if not pixel:
		return
	RenderingServer.set_default_clear_color(SURFACE)
	_text_material = ShaderMaterial.new()
	_text_material.shader = load(_TEXT_SHADER)
	sans = _sans_at(400)
	sans_title = _sans_at(600)
	_swap_classic_fonts()
	for type_id in GeneratedNodeCatalog.DEFINITIONS:
		var definition: Dictionary = GeneratedNodeCatalog.DEFINITIONS[type_id]
		_category_by_scene[definition.source_path] = definition.get("category", &"")
	recolour_theme(ThemeDB.get_default_theme())
	get_tree().node_added.connect(_on_node_added)


## Colours for a node category, or an empty dictionary when it has none.
func category_colours(category: StringName) -> Dictionary:
	return CATEGORY.get(category, {})


## The category of a graph node (empty when it has none).
func category_of(graph: Node) -> StringName:
	return _category_by_scene.get(graph.scene_file_path, &"") if graph else &""


## Gives a block its own fill that survives the block re-entering the tree
## (block buttons move into wrappers), which would otherwise recolour it.
func set_fill(item: CanvasItem, colour: Color) -> void:
	item.set_meta(&"design_fill", colour)
	set_colour(item, &"design_fill", colour)


## Sets an exact design colour on a block. Sent as a Vector4: the engine turns
## Color instance parameters into linear values, which darkens them on this sRGB canvas.
func set_colour(item: CanvasItem, param: StringName, colour: Color) -> void:
	item.set_instance_shader_parameter(param, Vector4(colour.r, colour.g, colour.b, colour.a))


## Marks a block (a ColorRect drawn with the block shader) with a role.
## A primary block also turns the labels added under it white.
func set_role(item: CanvasItem, role: Role) -> void:
	if not pixel or not _is_block(item):
		return
	if role == Role.PRIMARY:
		# A screen's main action is an ink pill; violet is kept for Axon alone.
		_mark_primary(item)
		set_colour(item, &"design_fill", INK)
	else:
		item.set_instance_shader_parameter(&"design_role", role)


## Marks a label that sits on a filled primary button.
func set_text_on_primary(label: CanvasItem) -> void:
	set_text_role(label, 1)


## Sets how the text shader recolours a label: 0 dark ink, 1 white (on a
## filled button), 2 keep its colours, 3 the darkest ink (titles).
func set_text_role(label: CanvasItem, role: int) -> void:
	if pixel and _uses_shader(label, _TEXT_SHADER):
		label.set_instance_shader_parameter(&"design_text_role", role)


## Gives an icon its own colour. It survives the icon re-entering the tree
## (block buttons move into wrappers), which would otherwise re-tint it.
func set_icon_tint(icon: CanvasItem, colour: Color) -> void:
	icon.set_meta(&"design_tint", colour)
	icon.self_modulate = colour


## The title of a node category in the given language (ru, kz or en).
func category_title(category: StringName, language: String) -> String:
	var titles: Dictionary = CATEGORY_TITLES.get(category, {})
	return titles.get(language, titles.get("ru", ""))


## A wire end in the colour of its port, deep enough for the white card.
func wire_colour(source: Color) -> Color:
	if source.s < 0.15:
		return OUTLINE
	var c := source
	c.s = clampf(c.s * 1.25, 0.0, 1.0)
	c.v = minf(c.v, 0.62)
	return c


func _on_node_added(node: Node) -> void:
	if node is Label or node is RichTextLabel:
		_adapt_text(node)
	elif node is ColorRect:
		_adapt_rect(node)
	elif node is LineEdit or node is TextEdit:
		_adapt_edit(node)
	elif node is Line2D:
		_adapt_line(node)
	elif node is TextureButton or node is Sprite2D or node is TextureRect:
		_adapt_icon(node)
	if node is Control and (node as Control).theme:
		recolour_theme((node as Control).theme)


func _adapt_text(label: Control) -> void:
	if label.material == null:
		label.material = _text_material
	elif _uses_shader(label, _CARD_SHADER) and label.name != &"Emoji":
		label.set_instance_shader_parameter(&"design_text_role", 0)
	var parent := label.get_parent()
	if label is Label and parent and parent.name == &"root" and (label as Label).text.begins_with("/"):
		_retitle_dialog(label)
	if parent and parent.has_meta(&"design_primary"):
		label.set_instance_shader_parameter(&"design_text_role", 1)
	elif parent and parent.name == &"root" and parent.get_parent() and parent.get_parent().has_meta(&"design_node_body"):
		label.set_instance_shader_parameter(&"design_text_role", 3)
		label.add_theme_font_override(&"font", sans_title)
	for font_name in [&"font", &"normal_font"]:
		if label.has_theme_font_override(font_name) and _is_classic_font(label.get_theme_font(font_name)):
			label.add_theme_font_override(font_name, sans)
	var settings: LabelSettings = label.get(&"label_settings")
	if settings and _is_classic_font(settings.font):
		settings.font = sans


## Dialog headers written as paths ("/projects/create") read as names; a dialog
## that has its own title just loses the path.
const _DIALOG_TITLES := {
	"/projects/create": {"ru": "Новый проект", "kz": "Жаңа жоба", "en": "New project"},
	"/dataset_create": {"ru": "Новый датасет", "kz": "Жаңа датасет", "en": "New dataset"},
	"/world_create": {"ru": "Новая сцена", "kz": "Жаңа сахна", "en": "New scene"},
	"/classrooms/create": {"ru": "Новый класс", "kz": "Жаңа сынып", "en": "New class"},
	"/profile": {"ru": "Настройки", "kz": "Баптаулар", "en": "Settings"},
	"/login": {"ru": "Вход", "kz": "Кіру", "en": "Sign in"},
	"/signup": {"ru": "Регистрация", "kz": "Тіркелу", "en": "Sign up"},
}


func _retitle_dialog(label: Label) -> void:
	var titles: Dictionary = _DIALOG_TITLES.get(label.text, {})
	if not titles.is_empty():
		label.text = titles.get(str(glob.get_lang()), titles["ru"])
		return
	label.hide()
	var icon := label.get_parent().get_node_or_null("i") as CanvasItem
	if icon:
		icon.hide()


func _adapt_rect(rect: ColorRect) -> void:
	if _is_block(rect):
		var graph := _graph_of(rect)
		if graph == null:
			return
		if rect is Connection:
			# Ports keep their data-type colour: the lessons name ports by it
			# ("yellow output", "the blue port on top").
			rect.set_instance_shader_parameter(&"design_role", Role.NODE)
			set_colour(rect, &"design_fill", _port_fill(rect.color))
			set_colour(rect, &"design_line", wire_colour(rect.color))
		elif rect.get_parent() == graph and rect.name == &"ColorRect":
			_mark_node_body(rect, graph)
		elif rect is BlockComponent and rect.button_type == BlockComponent.ButtonType.BLOCK_BUTTON and rect.color.s > 0.3:
			# A node's main action keeps its hue: "Учись!" stays green, as in the lessons.
			_mark_primary(rect)
			var fill: Color = rect.get_meta(&"design_fill", Color.from_hsv(rect.color.h, clampf(rect.color.s, 0.55, 0.9), 0.6))
			set_colour(rect, &"design_fill", fill)
		else:
			rect.set_instance_shader_parameter(&"design_role", Role.FIELD)
		return
	# Only dark neutral backdrops: a saturated rect is content (a swatch, a marker).
	if rect.material == null and rect.color.a > 0.02 and rect.color.get_luminance() < 0.4 and rect.color.s < 0.25:
		rect.color = Color(SURFACE, rect.color.a)


## A filled button with white text: the node's main action ("Учись!") or a
## dialog's primary action.
func _mark_primary(button: CanvasItem) -> void:
	button.set_meta(&"design_primary", true)
	button.set_instance_shader_parameter(&"design_role", Role.PRIMARY)


## A port's fill: its classic colour, a little deeper so it shows on white.
func _port_fill(c: Color) -> Color:
	if c.s < 0.15:
		return OUTLINE_VAR
	return Color.from_hsv(c.h, clampf(c.s * 1.1, 0.0, 1.0), minf(c.v, 0.86))


func _mark_node_body(body: ColorRect, graph: Node) -> void:
	body.set_meta(&"design_node_body", true)
	body.set_instance_shader_parameter(&"design_role", Role.NODE)
	var colours := category_colours(_category_by_scene.get(graph.scene_file_path, &""))
	if colours.is_empty():
		return
	set_colour(body, &"design_fill", colours.fill)
	set_colour(body, &"design_line", colours.line)


func _adapt_edit(edit: Control) -> void:
	if edit is CodeEdit and mono:
		edit.add_theme_font_override(&"font", mono)
	if edit.has_theme_font_override(&"font") and _is_classic_font(edit.get_theme_font(&"font")):
		edit.add_theme_font_override(&"font", sans)
	edit.add_theme_color_override(&"font_color", ON_SURFACE)
	edit.add_theme_color_override(&"font_placeholder_color", ON_SURFACE_VAR)
	edit.add_theme_color_override(&"caret_color", PRIMARY)
	edit.add_theme_color_override(&"selection_color", TONAL)
	edit.add_theme_color_override(&"font_selected_color", ON_TONAL)
	for state in [&"normal", &"focus", &"read_only"]:
		var box := edit.get_theme_stylebox(state)
		if box is StyleBoxFlat:
			var field := _light_box(box, 999)
			# Panel fields: M3 filled pill, a step darker than the surface, with room
			# for the curve. Fields inside nodes keep their compact tinted look.
			if _graph_of(edit) == null:
				if field.bg_color.a > 0.0:
					field.bg_color = SC_HIGHEST
				field.content_margin_left = maxf(field.content_margin_left, 14.0)
				field.content_margin_right = maxf(field.content_margin_right, 14.0)
			edit.add_theme_stylebox_override(state, field)


func _adapt_line(line: Line2D) -> void:
	if line.gradient == null and line.default_color.s < 0.15 and line.default_color.get_luminance() > 0.55:
		line.default_color = Color(ON_SURFACE_VAR, line.default_color.a)


func _adapt_icon(icon: CanvasItem) -> void:
	if icon.has_meta(&"design_tint"):
		icon.self_modulate = icon.get_meta(&"design_tint")
		return
	var texture: Texture2D = icon.get(&"texture_normal") if icon is TextureButton else icon.get(&"texture")
	if texture == null:
		return
	for dir in _ICON_DIRS:
		if texture.resource_path.begins_with(dir):
			icon.self_modulate = Color(ON_SURFACE_VAR, icon.self_modulate.a)
			return


## Turns a dark-theme Theme light in place: styleboxes become light surfaces
## with Material radii, light text colours become dark ink.
func recolour_theme(theme: Theme) -> void:
	if theme == null or _recoloured.has(theme):
		return
	_recoloured[theme] = true
	if theme.default_font == null or _is_classic_font(theme.default_font):
		theme.default_font = sans
	for type in theme.get_font_type_list():
		for name in theme.get_font_list(type):
			if _is_classic_font(theme.get_font(name, type)):
				theme.set_font(name, type, sans)
	for type in theme.get_stylebox_type_list():
		var radius := 999 if type in [&"Button", &"OptionButton", &"MenuButton", &"CheckButton", &"LineEdit"] else 16
		for name in theme.get_stylebox_list(type):
			var box := theme.get_stylebox(name, type)
			if box is StyleBoxFlat:
				theme.set_stylebox(name, type, _light_box(box, radius))
	for type in theme.get_color_type_list():
		for name in theme.get_color_list(type):
			var c := theme.get_color(name, type)
			if String(name).contains("font") or String(name).contains("icon"):
				theme.set_color(name, type, _ink(c))


func _light_box(box: StyleBoxFlat, radius: int) -> StyleBoxFlat:
	var light := box.duplicate() as StyleBoxFlat
	var bg := box.bg_color
	if bg.a > 0.0:
		light.bg_color = Color(_surface_for(bg), bg.a)
	if box.border_color.a > 0.0:
		light.border_color = Color(OUTLINE_VAR, box.border_color.a)
	light.shadow_color = Color(0, 0, 0, minf(box.shadow_color.a, 0.12))
	light.set_corner_radius_all(radius)
	return light


func _surface_for(c: Color) -> Color:
	# A style copied from one already adapted (the theme's LineEdit) keeps its
	# surface instead of being lightened a second time.
	if c in [SURFACE, SC_LOWEST, SC_LOW, SC_HIGH, SC_HIGHEST, TONAL]:
		return c
	if c.s > 0.25 and c.v > 0.3:
		return TONAL
	if c.get_luminance() < 0.12:
		return SC_LOW
	if c.get_luminance() < 0.3:
		return SC_HIGH
	return SC_HIGHEST


func _ink(c: Color) -> Color:
	if c.s > 0.25:
		var dark := c
		dark.v = minf(c.v, 0.45)
		return Color(dark, c.a)
	return Color(ON_SURFACE if c.get_luminance() > 0.7 else ON_SURFACE_VAR, c.a)


## Scripts load the classic faces directly in many places, so the faces
## themselves take Google Sans' outlines; every user follows without edits.
func _swap_classic_fonts() -> void:
	var sans_data: PackedByteArray = (load(_SANS_PATH) as FontFile).data
	for path in _CLASSIC_FONTS:
		var face := load(path) as FontFile
		if face == null:
			continue
		if mono == null:
			mono = FontFile.new()
			mono.data = face.data
		face.data = sans_data
		face.clear_cache()


func _sans_at(weight: int) -> FontVariation:
	var font := FontVariation.new()
	font.base_font = load(_SANS_PATH)
	font.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
	return font


## True for the classic monospace face, which the Pixel design replaces.
func _is_classic_font(font: Font) -> bool:
	# A screen drawn in the classic face on purpose (Dataset Bento) marks its fonts.
	if font == null or font.has_meta(&"design_keep"):
		return false
	var base: Font = font.base_font if font is FontVariation else font
	return base != null and base.resource_path.contains(_CLASSIC_FONT_HINT)


func _uses_shader(item: CanvasItem, path: String) -> bool:
	var mat := item.material as ShaderMaterial
	return mat != null and mat.shader != null and mat.shader.resource_path == path


func _is_block(item: CanvasItem) -> bool:
	var mat := item.material as ShaderMaterial
	return mat != null and mat.shader != null and mat.shader.resource_path in _BLOCK_SHADERS


func _graph_of(node: Node) -> Graph:
	var n := node.get_parent()
	for i in 12:
		if n == null:
			return null
		if n is Graph:
			return n
		n = n.get_parent()
	return null


func _ready() -> void:
	if pixel:
		_track_lesson_progress.call_deferred()
		_start_child_scale.call_deferred()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--design-preview="):
			_open_preview(argument.trim_prefix("--design-preview="))


## Child-sized interface: the layout is drawn for a 1280×720 window and scaled
## up to fill a larger one (at most 1.5×), on top of the platform's own scale.
const CHILD_LAYOUT := Vector2(1280, 720)
var _platform_scale := 1.0


func _start_child_scale() -> void:
	_platform_scale = get_tree().root.content_scale_factor
	get_tree().root.size_changed.connect(_fit_child_scale)
	_fit_child_scale()


func _fit_child_scale() -> void:
	var logical := Vector2(DisplayServer.window_get_size()) / _platform_scale
	var child := clampf(minf(logical.x / CHILD_LAYOUT.x, logical.y / CHILD_LAYOUT.y), 1.0, 1.5)
	var factor := _platform_scale * child
	if absf(get_tree().root.content_scale_factor - factor) > 0.001:
		get_tree().root.content_scale_factor = factor


## The home screen marks a lesson done once the learner finishes it.
func _track_lesson_progress() -> void:
	var progress = load("res://scripts/ui/lesson_progress.gd")
	learner.lesson_completed.connect(func(lesson_key): progress.mark_done(str(lesson_key)))


## Dev only: `--design-preview=<local project id>` opens that project after
## launch, `--design-preview-tab=graph|env|ds` switches the tab and
## `--design-preview-splash=<name>` opens a panel (workslist, ai_help),
## `--design-preview-menu=<name>` a context menu (add_graph). Pair it
## with `--perfbench` to skip the identity dialog when taking screenshots.
## `--design-preview-shot=<png path>` saves the frame and quits (works while the
## desktop is locked, unlike a screen capture).
func _open_preview(project_id: String) -> void:
	await get_tree().create_timer(2.5).timeout
	await glob.load_scene(project_id)
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--design-preview-tab="):
			await get_tree().create_timer(1.0).timeout
			glob.go_window(argument.trim_prefix("--design-preview-tab="))
		elif argument.begins_with("--design-preview-splash="):
			await get_tree().create_timer(1.0).timeout
			# Menus built without show_on_ready (ai_help) open only once preloaded.
			ui.preload_splash_menu(argument.trim_prefix("--design-preview-splash="))
			ui.splash(argument.trim_prefix("--design-preview-splash="), glob.fg.workslist_but)
		elif argument.begins_with("--design-preview-menu="):
			await get_tree().create_timer(1.0).timeout
			glob.show_menu(argument.trim_prefix("--design-preview-menu="), Vector2(700, 300))
		elif argument.begins_with("--design-preview-lang="):
			glob.change_lang(argument.trim_prefix("--design-preview-lang="))
		elif argument == "--design-preview-ds-numbers":
			await get_tree().create_timer(1.0).timeout
			glob.tree_windows["ds"]._bento.set_numbers(true)
		elif argument.begins_with("--design-preview-csv="):
			# Adds a CSV as a dataset of the open project: the project is saved
			# with it, so run this only against a throwaway user profile.
			var csv_path := argument.trim_prefix("--design-preview-csv=")
			var dataset_name := csv_path.get_file().get_basename()
			var parsed: Dictionary = dsreader.parse_csv_dataset(csv_path)
			# Answers: from the Simulations' Steering column on, else the last column.
			var names: Array = parsed.get("col_names", [])
			parsed["outputs_from"] = names.size() - 1
			for c in names.size():
				if str(names[c]).begins_with("Steering"):
					parsed["outputs_from"] = c
					break
			glob.ds_dump[dataset_name] = glob.create_dataset(randi_range(0, 999999), dataset_name, parsed)
			glob.tree_windows["ds"].reload_scenes()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--design-preview-shot="):
			await get_tree().create_timer(3.0).timeout
			OS.low_processor_usage_mode = false  # a still screen draws no new frame otherwise
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(argument.trim_prefix("--design-preview-shot="))
			get_tree().quit()
