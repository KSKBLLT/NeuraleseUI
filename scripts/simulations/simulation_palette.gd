class_name SimulationPalette
extends PanelContainer

const ObjectCatalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const PaletteEntryScript = preload("res://scripts/simulations/simulation_palette_entry.gd")
const NodePaletteStyle = preload("res://scripts/node_palette.gd")
const ValidInputScript = preload("res://scripts/validate_line.gd")
const SearchTheme = preload("res://resources/theme_headers.tres")
const PaletteTitleFont = preload("res://game_assets/fonts/JetBrainsSans[wght]-VF.ttf")
const PaletteArrowFont = preload("res://game_assets/fonts/JetBrainsMono-VariableFont_wght.ttf")

signal object_requested(type_id: StringName)
signal collapsed_changed(is_collapsed: bool)

const PANEL_WIDTH := 248.0

var _search: LineEdit
var _entries: Array[Control] = []
var _collapsed := false
var _toggle_tween: Tween = null
var _reopen_button: Button = null
var _collapse_button: Button = null
@onready var _background: ColorRect = $Background


func _ready() -> void:
	_reuse_blur_background()
	_reuse_blur_background.call_deferred()
	_build()
	_setup_reopen_button.call_deferred()


func is_collapsed() -> bool:
	return _collapsed


func set_collapsed(value: bool, animated: bool = true) -> void:
	_collapsed = value
	if _toggle_tween != null:
		_toggle_tween.kill()
		_toggle_tween = null

	var target_x: float = -PANEL_WIDTH if value else 0.0
	var target_alpha: float = 0.0 if value else 1.0

	if not animated:
		position.x = target_x
		offset_left = target_x
		offset_right = target_x + PANEL_WIDTH
		modulate.a = target_alpha
		visible = not value
		if is_instance_valid(_reopen_button):
			_reopen_button.visible = value
		collapsed_changed.emit(value)
		return

	if not value:
		position.x = -PANEL_WIDTH
		offset_left = -PANEL_WIDTH
		offset_right = 0.0
		modulate.a = 0.0
		visible = true
		if is_instance_valid(_reopen_button):
			_reopen_button.visible = false
	else:
		if is_instance_valid(_reopen_button):
			_reopen_button.visible = false

	_toggle_tween = create_tween()
	_toggle_tween.set_parallel(true)
	var easing := Tween.EASE_OUT if not value else Tween.EASE_IN
	_toggle_tween.tween_property(self, "position:x", target_x, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(easing)
	_toggle_tween.tween_property(self, "modulate:a", target_alpha, 0.22).set_trans(Tween.TRANS_CUBIC).set_ease(easing)
	_toggle_tween.chain().tween_callback(func():
		position.x = target_x
		offset_left = target_x
		offset_right = target_x + PANEL_WIDTH
		modulate.a = target_alpha
		visible = not value
		if is_instance_valid(_reopen_button):
			_reopen_button.visible = value
		collapsed_changed.emit(value)
	)


func _setup_reopen_button() -> void:
	if not is_inside_tree() or get_parent() == null:
		return
	_reopen_button = Button.new()
	_reopen_button.text = ">"
	_reopen_button.visible = false
	_reopen_button.custom_minimum_size = Vector2(38, 40)
	_reopen_button.offset_left = 0.0
	_reopen_button.offset_top = 7.0
	_reopen_button.offset_right = 38.0
	_reopen_button.offset_bottom = 47.0
	_reopen_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_reopen_button.tooltip_text = "Show objects palette"
	_style_toggle_button(_reopen_button)
	_reopen_button.pressed.connect(func(): set_collapsed(false))
	get_parent().add_child(_reopen_button)


func _style_toggle_button(btn: Button) -> void:
	btn.add_theme_color_override("font_color", Color(0.82, 0.82, 0.82, 1.0))
	btn.add_theme_font_override("font", PaletteArrowFont)
	btn.add_theme_font_size_override("font_size", 17)
	var normal := StyleBoxEmpty.new()
	var pressed := StyleBoxFlat.new()
	pressed.bg_color = Color(0.28, 0.28, 0.28, 0.3)
	pressed.set_corner_radius_all(10)
	var hover := StyleBoxFlat.new()
	hover.bg_color = Color(0.42, 0.42, 0.42, 0.215686)
	hover.set_corner_radius_all(10)
	btn.add_theme_stylebox_override("normal", normal)
	btn.add_theme_stylebox_override("pressed", pressed)
	btn.add_theme_stylebox_override("hover", hover)


func _copy_search_style() -> void:
	_search.theme = SearchTheme
	_search.clear_button_enabled = true
	for style_name in [&"normal", &"focus", &"read_only"]:
		var theme_style := SearchTheme.get_stylebox(style_name, &"LineEdit")
		if theme_style != null:
			_search.add_theme_stylebox_override(
				style_name,
				NodePaletteStyle.palette_search_style(theme_style, 10)
			)
	for color_name in [
		&"font_color",
		&"font_placeholder_color",
		&"font_selected_color",
		&"caret_color",
		&"selection_color",
	]:
		if _search.has_theme_color_override(color_name):
			_search.remove_theme_color_override(color_name)

	_search.add_theme_font_override(&"font", PaletteTitleFont)
	_search.add_theme_font_size_override(&"font_size", 18)
	_search.offset_transform_enabled = true
	_search.offset_transform_position.x = 3
	_search.offset_transform_position.y = -2


func _exit_tree() -> void:
	if is_instance_valid(_reopen_button):
		_reopen_button.queue_free()
		_reopen_button = null


func sync_perspective(current_mode: StringName) -> void:
	for button in _entries:
		var type_id = button.get_meta("type_id", &"")
		if type_id.is_empty(): continue
		var def = ObjectCatalog.definition(type_id)
		var obj_persp = StringName(def.get("compatible_perspective", &"any"))
		if obj_persp != &"any" and current_mode != &"auto" and obj_persp != current_mode:
			button.modulate.a = 0.4
		else:
			button.modulate.a = 1.0


func _reuse_blur_background() -> void:
	NodePaletteStyle.apply_project_blur_background(_background)

func _process(_delta: float) -> void:
	if visible and not _collapsed and get_global_rect().has_point(get_global_mouse_position()):
		glob.occupy(self, &"scroll")
	else:
		glob.un_occupy(self, &"scroll")


func displayed_groups() -> Dictionary:
	return ObjectCatalog.grouped_types()

func _build() -> void:
	var content := VBoxContainer.new()
	content.name = "Content"
	content.add_theme_constant_override("separation", 3)
	add_child(content)

	var title_container := PanelContainer.new()
	title_container.name = "TitleContainer"
	var title_style := StyleBoxEmpty.new()
	title_style.content_margin_left = 12.0
	title_style.content_margin_top = 10.0
	title_style.content_margin_right = 10.0
	title_style.content_margin_bottom = 0.0
	title_container.add_theme_stylebox_override("panel", title_style)
	content.add_child(title_container)

	var title := Label.new()
	title.name = "Title"
	title.text = "Objects"
	title.custom_minimum_size = Vector2(0, 39)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.add_theme_font_override("font", PaletteTitleFont)
	title.add_theme_font_size_override("font_size", 23)
	var title_loc := Loc.new()
	title_loc.auto = true
	title_loc.localizations_ru = {"objects": "Объекты"}
	title_loc.localizations_kz = {"objects": "Нысандар"}
	title.add_child(title_loc)
	title_container.add_child(title)

	var header := PanelContainer.new()
	header.name = "Header"
	var header_style := StyleBoxEmpty.new()
	header_style.content_margin_left = 10.0
	header_style.content_margin_top = 9.0
	header_style.content_margin_right = 10.0
	header_style.content_margin_bottom = 7.0
	header.add_theme_stylebox_override("panel", header_style)
	content.add_child(header)

	var controls := HBoxContainer.new()
	controls.name = "Controls"
	controls.add_theme_constant_override("separation", 7)
	header.add_child(controls)

	_search = LineEdit.new()
	_search.name = "Search"
	_search.placeholder_text = "Find an object..."
	_search.custom_minimum_size = Vector2(0, 33.03)
	_search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_copy_search_style()
	var search_loc := Loc.new()
	search_loc.auto = true
	search_loc.localizations_ru = {"find an object": "Найти объект..."}
	search_loc.localizations_kz = {"find an object": "Нысанды табу..."}
	_search.add_child(search_loc)
	_search.text_changed.connect(_filter)
	controls.add_child(_search)

	_collapse_button = Button.new()
	_collapse_button.name = "Collapse"
	_collapse_button.text = "<"
	
	_collapse_button.offset_transform_enabled = 1
	_collapse_button.offset_transform_position.y = -1
	_collapse_button.custom_minimum_size = Vector2(32, 34)
	_collapse_button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	_collapse_button.tooltip_text = "Hide objects palette"
	_style_toggle_button(_collapse_button)
	_collapse_button.pressed.connect(func(): set_collapsed(true))
	controls.add_child(_collapse_button)

	var scroll := ScrollContainer.new()
	scroll.name = "ObjectScroll"
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	content.add_child(scroll)

	var scroll_margin := MarginContainer.new()
	scroll_margin.name = "ScrollMargin"
	scroll_margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll_margin.add_theme_constant_override("margin_left", 12)
	scroll_margin.add_theme_constant_override("margin_right", 10)
	scroll_margin.add_theme_constant_override("margin_bottom", 8)
	scroll.add_child(scroll_margin)

	var groups := VBoxContainer.new()
	groups.name = "Groups"
	groups.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	groups.add_theme_constant_override("separation", 8)
	scroll_margin.add_child(groups)

	var group_locs_ru := {
		"geometry": "Геометрия",
		"materials": "Материалы",
		"hazards": "Опасности",
		"dynamics": "Динамика",
		"agents": "Агенты",
	}
	var group_locs_kz := {
		"geometry": "Геометрия",
		"materials": "Материалдар",
		"hazards": "Қауіптер",
		"dynamics": "Динамика",
		"agents": "Агенттер",
	}

	for group_name in ObjectCatalog.grouped_types():
		var group := VBoxContainer.new()
		group.set_meta("group_name", group_name)
		group.add_theme_constant_override("separation", 2)
		groups.add_child(group)

		var group_header := HBoxContainer.new()
		group_header.add_theme_constant_override("separation", 7)
		group.add_child(group_header)
		var accent := ColorRect.new()
		var type_ids: Array = ObjectCatalog.grouped_types()[group_name]
		var group_color: Color = (
			ObjectCatalog.definition(type_ids[0]).get("color", Color.WHITE)
			if not type_ids.is_empty()
			else Color.WHITE
		)
		accent.color = group_color.lightened(0.12)
		accent.custom_minimum_size = Vector2(3.0, 14.0)
		accent.mouse_filter = Control.MOUSE_FILTER_IGNORE
		group_header.add_child(accent)
		var group_label := Label.new()
		group_label.text = group_name
		group_label.modulate = Color(0.78, 0.8, 0.84, 0.96)
		group_label.add_theme_font_size_override("font_size", 18)
		var gloc := Loc.new()
		gloc.auto = true
		gloc.localizations_ru = {group_name.to_lower(): group_locs_ru.get(group_name.to_lower(), group_name)}
		gloc.localizations_kz = {group_name.to_lower(): group_locs_kz.get(group_name.to_lower(), group_name)}
		group_label.add_child(gloc)
		group_header.add_child(group_label)

		# Pixel design: two tiles per row, as in the team's light theme.
		var entry_parent: Control = group
		if design.pixel:
			var tiles := GridContainer.new()
			tiles.columns = 2
			tiles.add_theme_constant_override("h_separation", 8)
			tiles.add_theme_constant_override("v_separation", 8)
			group.add_child(tiles)
			entry_parent = tiles
		for type_id in type_ids:
			var definition: Dictionary = ObjectCatalog.definition(type_id)
			var button: Button = PaletteEntryScript.new()
			button.tile = design.pixel
			button.configure(definition)
			button.alignment = HORIZONTAL_ALIGNMENT_LEFT
			button.custom_minimum_size = Vector2(0.0, 45.0)
			button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			button.focus_mode = Control.FOCUS_NONE
			button.set_meta("type_id", type_id)
			button.set_meta("search_text", str(definition["label"]).to_lower())
			button.add_theme_font_size_override("font_size", 20)
			var normal := StyleBoxFlat.new()
			normal.bg_color = Color(0.08, 0.083, 0.091, 0.0)
			normal.set_corner_radius_all(3)
			# The two-space prefix clears the drawn icon in a mono font; Google Sans
			# spaces are narrower, so the pixel design pads the difference.
			normal.content_margin_left = 21 if design.pixel else 7
			var hover := normal.duplicate()
			hover.bg_color = Color(0.16, 0.17, 0.19, 0.76)
			button.add_theme_stylebox_override("normal", normal)
			button.add_theme_stylebox_override("hover", hover)
			button.add_theme_stylebox_override("pressed", hover)
			button.pressed.connect(_request.bind(type_id))
			if design.pixel:
				_style_tile(button)

			button.set_meta("loc_prefix", "" if design.pixel else "  ")
			button.set_meta("original_loc_text", str(definition["label"]))
			var bloc := Loc.new()
			bloc.auto = true
			var dlabel := str(definition["label"]).to_lower()

			var obj_locs_ru := {
				"block": "Блок", "circle": "Круг", "slope": "Склон",
				"ice": "Лёд", "sand": "Песок", "trampoline": "Батут", "finish": "Финиш",
				"spikes": "Шипы", "lava": "Лава", "water": "Вода",
				"crate": "Ящик", "ball": "Мяч",
				"car": "Машина", "side-view car": "Машина", "top-down rover": "Ровер", "flying agent": "Дрон",
			}
			var obj_locs_kz := {
				"block": "Блок", "circle": "Шеңбер", "slope": "Беткей",
				"ice": "Мұз", "sand": "Құм", "trampoline": "Батут", "finish": "Мәре",
				"spikes": "Тікенектер", "lava": "Лава", "water": "Су",
				"crate": "Жәшік", "ball": "Доп",
				"car": "Көлік", "side-view car": "Көлік", "top-down rover": "Ровер", "flying agent": "Дрон",
			}

			bloc.localizations_ru = {dlabel: obj_locs_ru.get(dlabel, str(definition["label"]))}
			bloc.localizations_kz = {dlabel: obj_locs_kz.get(dlabel, str(definition["label"]))}
			button.add_child(bloc)

			entry_parent.add_child(button)
			_entries.append(button)

		if group_name != ObjectCatalog.grouped_types().keys()[-1]:
			var divider := HSeparator.new()
			divider.modulate = Color(1.0, 1.0, 1.0, 0.2)
			group.add_child(divider)


## Pixel design: a soft tile, the name under the drawn icon.
func _style_tile(button: Button) -> void:
	button.alignment = HORIZONTAL_ALIGNMENT_CENTER
	button.custom_minimum_size = Vector2(0.0, 92.0)
	button.add_theme_font_size_override("font_size", 15)
	button.add_theme_color_override("font_color", design.ON_SURFACE)
	button.add_theme_color_override("font_hover_color", design.ON_SURFACE)
	for state in ["normal", "hover", "pressed"]:
		var face := StyleBoxFlat.new()
		face.bg_color = design.SC_LOW if state == "normal" else design.SC_HIGH
		face.set_corner_radius_all(16)
		face.content_margin_top = 56.0
		face.content_margin_bottom = 8.0
		button.add_theme_stylebox_override(state, face)


func _request(type_id: StringName) -> void:
	object_requested.emit(type_id)


func _filter(query: String) -> void:
	var normalized := query.strip_edges().to_lower()
	for entry in _entries:
		entry.visible = normalized.is_empty() or str(entry.get_meta("search_text", "")).contains(normalized)
