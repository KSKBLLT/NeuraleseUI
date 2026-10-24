extends CanvasLayer
class_name NodePalette

const NodePaletteCatalog = preload("res://scripts/node_palette_catalog.gd")
const GraphCreationCatalog = preload("res://scripts/graph_creation_catalog.gd")
const BlurBackgroundFallback = preload("res://resources/fg_block.tres")
const GraphicsQualityConfigScript = preload("res://scripts/graphics_quality.gd")
const ScreenBlurShader = preload("res://shaders/block_screen.gdshader")
const BackgroundBlurShader = preload("res://shaders/block.gdshader")
const TUTORIAL_CARD_ANCHOR_GROUP := &"tutorial_node_palette_anchor"
const SearchTheme = preload("res://resources/theme_headers.tres")
const SearchFont: FontFile = preload("res://game_assets/fonts/JetBrainsSans[wght]-VF.ttf")
const WorkspaceScript = preload("res://scripts/ui/workspace.gd")

@export var panel_width := 248.0
@export var top_inset := 52.0
@export var search_corner_radius := 10
@export var toggle_duration := 0.22
@export var hidden_types: Array[StringName] = []
@export var item_scene: PackedScene = preload("res://scenes/node_palette_item.tscn")

@onready var drop_surface: Control = $Root/DropSurface
@onready var panel: PanelContainer = $Root/Panel
@onready var panel_background: ColorRect = $Root/Panel/Background
@onready var items: VBoxContainer = $Root/Panel/Content/Scroll/Items
@onready var scroll: ScrollContainer = $Root/Panel/Content/Scroll
@onready var title: Label = $Root/Panel/Content/TitleContainer/Title
@onready var search: LineEdit = $Root/Panel/Content/Header/Controls/Search
@onready var collapse_button: Button = $Root/Panel/Content/Header/Controls/Collapse
@onready var reopen_button: Button = $Root/Reopen

var _entries: Array[Dictionary] = []
var _collapsed := false
var _toggle_tween: Tween = null
var _lesson_header: Control = null
## Pixel design: the palette is a column left of the canvas card (see _dock_setup).
var _dock := false
## Where entries go: the scene's list, or the dock's own row.
var _rows: BoxContainer = null


func _ready() -> void:
	add_to_group(TUTORIAL_CARD_ANCHOR_GROUP)
	_rows = items
	if design.pixel:
		_dock_setup()
	set_collapsed(false, false)
	_copy_search_style()
	reuse_project_styles()
	reuse_project_styles.call_deferred()
	drop_surface.node_type_dropped.connect(_on_node_type_dropped)
	search.text_changed.connect(_on_search_changed)
	collapse_button.pressed.connect(set_collapsed.bind(true))
	reopen_button.pressed.connect(set_collapsed.bind(false))
	panel.mouse_entered.connect(_occupy_palette_input.bind(panel))
	panel.mouse_exited.connect(_release_palette_input.bind(panel))
	reopen_button.mouse_entered.connect(_occupy_palette_input.bind(reopen_button))
	reopen_button.mouse_exited.connect(_release_palette_input.bind(reopen_button))
	get_viewport().size_changed.connect(_sync_geometry)
	_connect_tutorial_progress_panel()
	_connect_tutorial_progress_panel.call_deferred()
	if not glob.language_changed.is_connected(rebuild):
		glob.language_changed.connect(rebuild)

	if not glob.project_opened.is_connected(rebuild):
		glob.project_opened.connect(rebuild)
	if not glob.project_opening.is_connected(rebuild):
		glob.project_opening.connect(rebuild)
	if not graphs.node_added.is_connected(_on_graph_changed):
		graphs.node_added.connect(_on_graph_changed)
	if not graphs.model_updated.is_connected(_on_model_updated):
		graphs.model_updated.connect(_on_model_updated)
	if is_instance_valid(graphs.storage) and not graphs.storage.child_exiting_tree.is_connected(_on_graph_removed):
		graphs.storage.child_exiting_tree.connect(_on_graph_removed)
	rebuild()


func rebuild(...args) -> void:
	var next_entries: Array[Dictionary] = NodePaletteCatalog.build_entries(
		graphs.graph_buttons,
		_add_graph_type_ids(),
		hidden_types,
		glob.curr_lang
	)
	if _entry_signature(next_entries) == _entry_signature(_entries):
		return

	var previous_scroll := scroll.scroll_vertical
	_entries = next_entries
	_render_entries(previous_scroll)


func _render_entries(previous_scroll: int = -1) -> void:
	for child in _rows.get_children():
		_rows.remove_child(child)
		child.queue_free()

	var row: Control = _rows
	var group: Variant = null
	for entry in _grouped(NodePaletteCatalog.filter_entries(_entries, search.text)):
		if _dock and entry.get("category", &"") != group:
			group = entry.get("category", &"")
			row = _dock_group(group)
		var item: Control = item_scene.instantiate()
		item.setup(entry)
		if _dock:
			item.set_compact()
			item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		item.drag_started.connect(_on_item_drag_started)
		item.drag_finished.connect(_on_item_drag_finished)
		row.add_child(item)

	if previous_scroll >= 0:
		_restore_scroll_position.call_deferred(previous_scroll)


func entry_type_ids() -> Array[StringName]:
	var result: Array[StringName] = []
	for entry in _entries:
		result.append(StringName(entry.get("type_id", "")))
	return result


func _add_graph_type_ids() -> Array[StringName]:
	var add_graph := glob.base_node.get_node_or_null("WIN_GRAPH/menus/add_graph")
	if is_instance_valid(add_graph) and add_graph.has_method("ordered_creation_type_ids"):
		return add_graph.ordered_creation_type_ids()

	var ordered_definitions := GraphCreationCatalog.ordered_definitions(
		graphs.graph_buttons,
		[],
		[],
		[],
		not glob.multi_input and graphs.has_input()
	)
	return GraphCreationCatalog.type_ids(ordered_definitions)


static func _entry_signature(entries: Array[Dictionary]) -> Array:
	var signature: Array = []
	for entry in entries:
		signature.append([
			entry.get("type_id", StringName()),
			entry.get("title", ""),
			entry.get("icon_path", ""),
			entry.get("outline_color", Color.WHITE),
		])
	return signature


func _restore_scroll_position(value: int) -> void:
	await get_tree().process_frame
	if is_instance_valid(scroll):
		scroll.scroll_vertical = value


static func toggle_offset(collapsed: bool, width: float) -> float:
	return -width if collapsed else 0.0


static func palette_search_style(source: StyleBox, radius: int) -> StyleBox:
	var copied := source.duplicate() as StyleBox
	if copied is StyleBoxFlat:
		copied.corner_radius_top_left = radius
		copied.corner_radius_top_right = radius
		copied.corner_radius_bottom_right = radius
		copied.corner_radius_bottom_left = radius
		copied.border_width_left = 0
		copied.border_width_top = 0
		copied.border_width_right = 0
		copied.border_width_bottom = 0
	return copied


static func top_bar_bottom(top_bar: Control, fallback: float) -> float:
	if is_instance_valid(top_bar):
		return top_bar.get_global_rect().end.y
	return fallback


static func effective_top_inset(
	top_bar_inset: float,
	progress_panel_visible: bool,
	progress_panel_bottom: float
) -> float:
	return maxf(top_bar_inset, progress_panel_bottom) if progress_panel_visible else top_bar_inset


func _sync_geometry(preserve_horizontal := false) -> void:
	if _dock:
		_sync_dock_geometry()
		return
	var tween_is_running := _toggle_tween != null and _toggle_tween.is_running()
	var panel_x := panel.position.x if preserve_horizontal or tween_is_running else toggle_offset(_collapsed, panel_width)
	var top_bar := glob.base_node.get_node_or_null("fg/ColorRect") as Control
	var live_top_inset := top_bar_bottom(top_bar, top_inset)
	if is_instance_valid(_lesson_header):
		live_top_inset = effective_top_inset(
			live_top_inset,
			bool(_lesson_header.call("is_progress_panel_visible")),
			float(_lesson_header.call("get_progress_panel_bottom"))
		)
	panel.offset_top = live_top_inset
	panel.offset_left = panel_x
	panel.offset_right = panel_x + panel_width
	reopen_button.offset_top = live_top_inset
	drop_surface.configure(0.0 if _collapsed else panel_width, live_top_inset)


func _connect_tutorial_progress_panel() -> void:
	if is_instance_valid(_lesson_header) or not is_instance_valid(glob.base_node):
		return
	var header := glob.base_node.get_node_or_null("fg/ColorRect/ColorRect") as Control
	if not is_instance_valid(header):
		return
	if not header.has_method("is_progress_panel_visible") or not header.has_method("get_progress_panel_bottom"):
		return
	_lesson_header = header
	if not _lesson_header.progress_panel_layout_changed.is_connected(_on_progress_panel_layout_changed):
		_lesson_header.progress_panel_layout_changed.connect(_on_progress_panel_layout_changed)
	_sync_geometry(true)


func _on_progress_panel_layout_changed(_visible: bool, _bottom: float) -> void:
	_sync_geometry(true)


func set_collapsed(value: bool, animated: bool = true) -> void:
	_collapsed = value
	if value:
		search.release_focus()
	if _toggle_tween != null:
		_toggle_tween.kill()
		_toggle_tween = null

	reopen_button.visible = false
	panel.visible = true
	_sync_geometry(true)
	_update_selection_blocker(get_viewport().get_mouse_position())

	var target := _toggle_target(value)
	var target_alpha := 0.0 if value else 1.0
	if not animated or not is_inside_tree():
		_apply_toggle_endpoint(value, target, target_alpha)
		return

	_toggle_tween = create_tween()
	_toggle_tween.set_parallel(true)
	var easing := Tween.EASE_OUT if not value else Tween.EASE_IN
	_toggle_tween.tween_property(panel, "position:x", target, toggle_duration).set_trans(Tween.TRANS_CUBIC).set_ease(easing)
	_toggle_tween.tween_property(panel, "modulate:a", target_alpha, toggle_duration).set_trans(Tween.TRANS_CUBIC).set_ease(easing)
	_toggle_tween.chain().tween_callback(_finish_toggle.bind(value, _toggle_tween))


func _finish_toggle(value: bool, tween: Tween) -> void:
	if tween != _toggle_tween:
		return
	_toggle_tween = null
	_apply_toggle_endpoint(value, _toggle_target(value), 0.0 if value else 1.0)


func _apply_toggle_endpoint(value: bool, target: float, target_alpha: float) -> void:
	panel.position.x = target
	print_stack()
	panel.modulate.a = target_alpha
	panel.visible = not value
	reopen_button.visible = value
	_update_selection_blocker(get_viewport().get_mouse_position())


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion or event is InputEventMouseButton:
		_update_selection_blocker(event.position)


func _process(_delta: float) -> void:
	if _dock:
		WorkspaceScript.palette_open = not _collapsed
		_sync_dock_geometry()
		var card := WorkspaceScript.card_rect()
		glob.space_begin.x = card.position.x
		glob.space_end = card.end
	else:
		glob.space_begin.x = panel.get_rect().end.x
	_update_selection_blocker(get_viewport().get_mouse_position())


## The tutorial card follows the rendered background, rather than the palette's
## configured width. This remains correct while the palette is tweening and at
## non-default UI scales.  The value is in viewport coordinates so a card in a
## different CanvasLayer does not accidentally use stale local offsets.
func tutorial_card_anchor_x() -> float:
	if _dock:
		return WorkspaceScript.card_rect().position.x
	if not is_instance_valid(panel_background):
		return 0.0
	return (panel_background.get_global_transform_with_canvas() * Vector2(panel_background.size.x, 0.0)).x


func _exit_tree() -> void:
	if _toggle_tween != null:
		_toggle_tween.kill()
		_toggle_tween = null
	_release_palette_input(panel)
	_release_palette_input(reopen_button)


func _update_selection_blocker(pointer_position: Vector2) -> void:
	var blocker: Control = panel
	if _collapsed:
		blocker = reopen_button
	if blocker.visible and blocker.get_global_rect().has_point(pointer_position):
		_occupy_palette_input(blocker)
	else:
		_release_palette_input(panel)
		_release_palette_input(reopen_button)


func _occupy_palette_input(control: Control) -> void:
	glob.occupy(control, &"menu_inside")
	glob.set_scroll_impossible(control)


func _release_palette_input(control: Control) -> void:
	if is_instance_valid(control):
		glob.un_occupy(control, &"menu_inside")
		glob.set_scroll_possible(control)


func reuse_project_styles() -> void:
	if not is_instance_valid(glob.base_node):
		return

	apply_project_blur_background(panel_background, 0.0)

	var source_search := glob.base_node.get_node_or_null("WIN_GRAPH/menus/add_graph/Label2") as LineEdit
	if is_instance_valid(source_search):
		_copy_search_style(source_search)
	_sync_geometry(true)


static func apply_project_blur_background(target: ColorRect, gaussian_mix_override := -1.0) -> bool:
	if not is_instance_valid(target):
		return false
	if is_instance_valid(glob.base_node):
		var top_panel := glob.base_node.get_node_or_null("fg/ColorRect") as ColorRect
		if is_instance_valid(top_panel) and top_panel.material is ShaderMaterial:
			var styled_material := (top_panel.material as ShaderMaterial).duplicate(true) as ShaderMaterial
			# Medium/Low may have replaced the top bar's shader at runtime. The
			# authored copy must still restore live-screen blur when High returns.
			if styled_material.shader == BackgroundBlurShader:
				styled_material.shader = ScreenBlurShader
			if gaussian_mix_override >= 0.0:
				styled_material.set_shader_parameter(&"gaussian_mix", gaussian_mix_override)
			GraphicsQualityConfigScript.set_authored_screen_material(target, styled_material)
			target.color = top_panel.color
			for parameter_name in [&"outline_color", &"tuning"]:
				var parameter_value = top_panel.get_instance_shader_parameter(parameter_name)
				if parameter_value != null:
					target.set_instance_shader_parameter(parameter_name, parameter_value)
			return true
	# Standalone simulation tests and tools can open before the main top panel.
	# They still get the same project blur shader instead of an opaque fallback.
	var fallback := BlurBackgroundFallback.duplicate(true) as ShaderMaterial
	if gaussian_mix_override >= 0.0:
		fallback.set_shader_parameter(&"gaussian_mix", gaussian_mix_override)
	GraphicsQualityConfigScript.set_authored_screen_material(target, fallback)
	target.color = Color.WHITE
	target.set_instance_shader_parameter(&"outline_color", Color(0.32, 0.34, 0.39, 0.9))
	target.set_instance_shader_parameter(&"tuning", Color(0.04, 0.045, 0.055, 0.82))
	return true


func _copy_search_style(_source: LineEdit = null) -> void:
	search.theme = SearchTheme
	search.clear_button_enabled = true
	for style_name in [&"normal", &"focus", &"read_only"]:
		var theme_style := SearchTheme.get_stylebox(style_name, &"LineEdit")
		if theme_style != null:
			search.add_theme_stylebox_override(
				style_name,
				palette_search_style(theme_style, search_corner_radius)
			)

	for color_name in [
		&"font_color",
		&"font_placeholder_color",
		&"font_selected_color",
		&"caret_color",
		&"selection_color",
	]:
		if search.has_theme_color_override(color_name):
			search.remove_theme_color_override(color_name)

	search.add_theme_font_override(&"font", SearchFont)
	search.add_theme_font_size_override(&"font_size", 18)


func _on_search_changed(_query: String) -> void:
	_render_entries()


func _on_item_drag_started(_type_id: StringName) -> void:
	drop_surface.set_drag_active(true)


func _on_item_drag_finished() -> void:
	drop_surface.set_drag_active.call_deferred(false)


func _on_node_type_dropped(type_id: StringName, screen_position: Vector2) -> void:
	drop_surface.set_drag_active(false)
	graphs.create_graph_at_screen_position(type_id, screen_position)


func _on_graph_changed(_graph: Graph) -> void:
	rebuild.call_deferred()


func _on_model_updated(_model_name: String) -> void:
	rebuild.call_deferred()


func _on_graph_removed(_graph: Node) -> void:
	rebuild.call_deferred()


## Pixel design: the palette becomes a dock under the canvas card, nodes
## grouped by category, instead of a column on the left. The workspace frame
## that turns the canvas into a card comes with it.
func _dock_setup() -> void:
	_dock = true
	add_child(WorkspaceScript.new())
	title.get_parent().hide()
	# The column gets its own list: groups stacked, two tiles per row in each.
	var column := VBoxContainer.new()
	column.name = &"Items"
	column.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	column.add_theme_constant_override(&"separation", 16)
	scroll.remove_child(items)
	items.queue_free()
	scroll.add_child(column)
	_rows = column
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel_background.hide()
	panel.custom_minimum_size = Vector2.ZERO
	panel.set_anchors_preset(Control.PRESET_TOP_LEFT, true)
	var card := StyleBoxFlat.new()
	card.bg_color = design.SC_LOWEST
	card.set_corner_radius_all(int(WorkspaceScript.CARD_RADIUS))
	card.content_margin_left = 14.0
	card.content_margin_right = 14.0
	card.content_margin_top = 10.0
	card.content_margin_bottom = 8.0
	panel.add_theme_stylebox_override(&"panel", card)
	collapse_button.text = "←"
	reopen_button.text = "→"
	reopen_button.set_anchors_preset(Control.PRESET_TOP_LEFT, true)


func _sync_dock_geometry() -> void:
	var dock := WorkspaceScript.dock_rect()
	if _toggle_tween == null or not _toggle_tween.is_running():
		var x := _dock_x(_collapsed)
		panel.offset_left = x
		panel.offset_right = x + dock.size.x
	panel.offset_top = dock.position.y
	panel.offset_bottom = dock.end.y
	var card := WorkspaceScript.card_rect()
	reopen_button.position = card.position + Vector2(12, 12)
	drop_surface.configure(card.position.x, WorkspaceScript.top())


## Where the column sits: in place, or just off the window's left edge while folded.
func _dock_x(collapsed: bool) -> float:
	var dock := WorkspaceScript.dock_rect()
	return -dock.size.x - 8.0 if collapsed else dock.position.x


func _toggle_target(collapsed: bool) -> float:
	return _dock_x(collapsed) if _dock else toggle_offset(collapsed, panel_width)


## In the dock, entries follow the category order so each group is one run.
func _grouped(entries: Array[Dictionary]) -> Array[Dictionary]:
	if not _dock:
		return entries
	var grouped: Array[Dictionary] = []
	for category in design.CATEGORY_TITLES:
		for entry in entries:
			if entry.get("category", &"") == category:
				grouped.append(entry)
	for entry in entries:
		if not design.CATEGORY_TITLES.has(entry.get("category", &"")):
			grouped.append(entry)
	return grouped


## A palette group: a coloured dot and the category title over two columns of nodes.
func _dock_group(category: StringName) -> GridContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 4)
	var title_text: String = design.category_title(category, glob.curr_lang)
	if not title_text.is_empty():
		var heading := HBoxContainer.new()
		heading.add_theme_constant_override(&"separation", 6)
		var dot := Panel.new()
		dot.custom_minimum_size = Vector2(8, 8)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var dot_style := StyleBoxFlat.new()
		dot_style.bg_color = design.category_colours(category).get("accent", design.OUTLINE)
		dot_style.set_corner_radius_all(4)
		dot.add_theme_stylebox_override(&"panel", dot_style)
		var label := Label.new()
		label.text = title_text
		label.add_theme_font_size_override(&"font_size", 15)
		heading.add_child(dot)
		heading.add_child(label)
		column.add_child(heading)
	var row := GridContainer.new()
	row.columns = 2
	row.add_theme_constant_override(&"h_separation", 8)
	row.add_theme_constant_override(&"v_separation", 8)
	column.add_child(row)
	_rows.add_child(column)
	return row
