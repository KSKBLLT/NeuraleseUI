extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_test_palette_scene_is_data_driven()
	_test_palette_reuses_project_ui_and_blocks_graph_navigation()
	_test_palette_search_style_is_a_local_copy()
	_test_palette_uses_the_live_top_bar_bottom()
	_test_palette_reserves_visible_tutorial_header()
	_test_tutorial_bubble_stays_outside_the_palette()
	_test_tutorial_bubble_tracks_the_tutorial_header()
	_test_tutorial_bubble_layout_is_idempotent()
	_test_tutorial_card_uses_rendered_palette_edge()
	_test_item_scene_renders_an_unframed_preview()
	_test_drop_surface_has_no_drag_outline()
	_test_palette_occupant_is_safe_for_connections()
	_test_palette_toggle_animation_contract()

	if failures.is_empty():
		print("PASS test_node_palette_scene: 13 cases")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_palette_scene_is_data_driven() -> void:
	var scene_path := "res://scenes/node_palette.tscn"
	_expect(ResourceLoader.exists(scene_path), "node palette scene must exist")
	if not ResourceLoader.exists(scene_path):
		return
	var palette = load(scene_path).instantiate()
	_expect(palette is CanvasLayer, "node palette must stay in screen space")
	_expect(palette.has_method("rebuild"), "node palette script must load without parse errors")
	var items = palette.get_node_or_null("Root/Panel/Content/Scroll/Items")
	var panel = palette.get_node_or_null("Root/Panel")
	var title = palette.get_node_or_null("Root/Panel/Content/TitleContainer/Title")
	var search = palette.get_node_or_null("Root/Panel/Content/Header/Controls/Search")
	var collapse = palette.get_node_or_null("Root/Panel/Content/Header/Controls/Collapse")
	var reopen = palette.get_node_or_null("Root/Reopen")
	_expect(items != null, "node palette must expose a scrollable item container")
	_expect(title is Label and title.text == "Nodes", "node palette must expose Title label with default text Nodes")
	var title_loc = title.get_node_or_null("Loc") if title != null else null
	_expect(title_loc != null and title_loc.localizations_ru.get("nodes") == "Ноды", "palette title must localize to ru")
	_expect(title_loc != null and title_loc.localizations_kz.get("nodes") == "Нодтар", "palette title must localize to kz")
	_expect(search is LineEdit, "palette header must expose node search")
	_expect(search != null and search.placeholder_text == "Find a node...", "palette search must match the graph add menu copy")
	_expect(collapse is Button, "expanded palette must expose a collapse button")
	_expect(reopen is Button, "collapsed palette must leave a reopen button")
	_expect(palette.has_method("set_collapsed"), "palette must expose one collapse state API")
	_expect(panel != null and panel.visible and reopen != null and not reopen.visible, "palette must start expanded")
	_expect(
		panel != null and panel.anchor_left == 0.0 and panel.anchor_right == 0.0 and panel.anchor_top == 0.0 and panel.anchor_bottom == 1.0,
		"node palette panel must be anchored to the left viewport edge"
	)
	if items != null:
		_expect(items.get_child_count() == 0, "palette scene must not hardcode graph cards")
	palette.free()


func _test_palette_reuses_project_ui_and_blocks_graph_navigation() -> void:
	var palette = load("res://scenes/node_palette.tscn").instantiate()
	var panel: PanelContainer = palette.get_node("Root/Panel")
	var search: LineEdit = palette.get_node("Root/Panel/Content/Header/Controls/Search")
	var global_state = get_root().get_node_or_null("glob")
	_expect(palette.has_method("reuse_project_styles"), "palette must reuse existing Neuralese UI resources")
	_expect(panel.get_theme_stylebox("panel") is StyleBoxEmpty, "palette scene must not define a card-like panel border")
	_expect(not search.has_theme_stylebox_override("normal"), "palette search styling must come from the graph add menu")
	_expect(global_state != null, "global input state must be available to palette tests")

	if global_state != null:
		palette._occupy_palette_input(panel)
		_expect(global_state.scroll_imp.has(panel), "palette hover must block graph zoom and trackpad navigation")
		palette._release_palette_input(panel)
		_expect(not global_state.scroll_imp.has(panel), "palette input release must remove the graph navigation blocker")
	palette.free()


func _test_palette_search_style_is_a_local_copy() -> void:
	var palette_script = load("res://scripts/node_palette.gd")
	var source := StyleBoxFlat.new()
	source.corner_radius_top_left = 16
	source.corner_radius_top_right = 16
	source.corner_radius_bottom_right = 16
	source.corner_radius_bottom_left = 16

	var palette_style = palette_script.palette_search_style(source, 6)
	_expect(palette_style is StyleBoxFlat, "palette search must preserve the source style type")
	_expect(palette_style != source, "palette search must duplicate the Add Graph style")
	_expect(
		palette_style.corner_radius_top_left == 6
		and palette_style.corner_radius_top_right == 6
		and palette_style.corner_radius_bottom_right == 6
		and palette_style.corner_radius_bottom_left == 6,
		"palette search copy must use the local six-pixel radius"
	)
	_expect(source.corner_radius_top_left == 16, "palette styling must not mutate Add Graph")


func _test_palette_uses_the_live_top_bar_bottom() -> void:
	var palette_script = load("res://scripts/node_palette.gd")
	var top_bar := ColorRect.new()
	top_bar.position = Vector2(0.0, -3.0)
	top_bar.size = Vector2(1280.0, 54.0)
	_expect(
		is_equal_approx(palette_script.top_bar_bottom(top_bar, 52.0), 51.0),
		"palette must start at the live bottom edge of the top bar"
	)
	_expect(
		is_equal_approx(palette_script.top_bar_bottom(null, 52.0), 52.0),
		"palette geometry must retain a safe fallback before the top bar is available"
	)
	top_bar.free()


func _test_palette_reserves_visible_tutorial_header() -> void:
	var palette_script = load("res://scripts/node_palette.gd")
	_expect(
		is_equal_approx(palette_script.effective_top_inset(51.0, true, 81.0), 81.0),
		"visible tutorial progress panel pushes the palette below its bottom edge"
	)
	_expect(
		is_equal_approx(palette_script.effective_top_inset(51.0, false, 81.0), 51.0),
		"hidden tutorial progress panel restores the palette to the top bar"
	)


func _test_tutorial_card_uses_rendered_palette_edge() -> void:
	var palette = load("res://scenes/node_palette.tscn").instantiate()
	var quest_script = load("res://scripts/quest.gd")
	_expect(
		palette.has_method("tutorial_card_anchor_x"),
		"palette exposes its live rendered right edge for the tutorial card"
	)
	_expect(
		is_equal_approx(quest_script.tutorial_card_x(248.0, 12.0), 260.0),
		"tutorial card preserves its configured gap from the expanded palette"
	)
	_expect(
		is_equal_approx(quest_script.tutorial_card_x(-12.0, 12.0), 0.0),
		"tutorial card follows the collapsed palette instead of sticking to the viewport edge"
	)
	palette.free()
	var source := FileAccess.get_file_as_string("res://scripts/node_palette.gd")
	_expect(
		source.contains("progress_panel_layout_changed.connect"),
		"palette layout follows tutorial progress-panel signals"
	)


func _test_tutorial_bubble_stays_outside_the_palette() -> void:
	var quest_script = load("res://scripts/quest.gd")
	_expect(
		is_equal_approx(quest_script.workspace_safe_x(37.0, 248.0, true, 16.0), 264.0),
		"an open palette pushes the tutorial bubble into the usable workspace"
	)


func _test_tutorial_bubble_tracks_the_tutorial_header() -> void:
	var quest_script = load("res://scripts/quest.gd")
	_expect(
		is_equal_approx(quest_script.workspace_safe_y(51.0, true, 81.0, 32.0), 113.0),
		"a visible progress panel anchors the tutorial bubble below its bottom edge"
	)


func _test_tutorial_bubble_layout_is_idempotent() -> void:
	var quest_script = load("res://scripts/quest.gd")
	var first_layout_x: float = quest_script.bubble_unit_x(2.0, true)
	var repeated_layout_x: float = quest_script.bubble_unit_x(2.0, true)
	_expect(
		is_equal_approx(first_layout_x, 5.0) and is_equal_approx(repeated_layout_x, first_layout_x),
		"repeated palette layout updates cannot accumulate horizontal text offsets"
	)
	_expect(
		is_equal_approx(quest_script.workspace_safe_y(51.0, false, 81.0, 32.0), 83.0),
		"a hidden progress panel moves the tutorial bubble closer to the top bar"
	)
	var source := FileAccess.get_file_as_string("res://scripts/quest.gd")
	_expect(
		source.contains("progress_panel_layout_changed.connect"),
		"tutorial bubble follows progress-panel layout signals"
	)
	_expect(
		is_equal_approx(quest_script.workspace_safe_x(37.0, 248.0, false, 16.0), 37.0),
		"a hidden palette leaves the tutorial bubble at its authored position"
	)


func _test_item_scene_renders_an_unframed_preview() -> void:
	var scene_path := "res://scenes/node_palette_item.tscn"
	_expect(ResourceLoader.exists(scene_path), "node palette item scene must exist")
	if not ResourceLoader.exists(scene_path):
		return
	var item = load(scene_path).instantiate()
	_expect(item.has_method("setup"), "node palette item must expose setup metadata API")
	_expect(item.mouse_filter == Control.MOUSE_FILTER_STOP, "palette item must own pointer drag input")
	_expect(item.get_theme_stylebox("panel") is StyleBoxEmpty, "palette item must not draw a card frame")
	_expect(item.get_node_or_null("Margin/Content/Title") == null, "palette item must not duplicate the node name under its image")
	_expect(item.has_method("set_hovered"), "palette item must expose smooth hover state")
	for path in ["Margin", "Margin/Preview", "Margin/Fallback"]:
		var decoration = item.get_node_or_null(path)
		_expect(
			decoration != null and decoration.mouse_filter == Control.MOUSE_FILTER_IGNORE,
			"decorative child %s must not intercept card drag input" % path
		)
	if item.has_method("setup"):
		item.setup({
			"type_id": &"layer",
			"title": "Dense Layer",
			"icon_path": "res://node_icons/IconLayer.png",
			"outline_color": Color("65d8aa"),
		})
		_expect(item.type_id == &"layer", "item must retain the stable graph type id")
		_expect(item.tooltip_text == "Dense Layer", "item must retain the localized node title as a tooltip")
		var preview: TextureRect = item.get_node_or_null("Margin/Preview")
		_expect(preview != null and preview.texture != null, "item must load existing node preview")
		var drag_preview = item._build_drag_preview()
		_expect(drag_preview is TextureRect, "existing icons must use an unframed image drag preview")
		drag_preview.free()
		if item.has_method("set_hovered"):
			item.set_hovered(true)
			item._process(0.1)
			_expect(item.scale.x > 1.0 and item.scale.y > 1.0, "hover must smoothly enlarge the node preview")
	item.free()


func _test_drop_surface_has_no_drag_outline() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/node_palette_drop_surface.gd")
	_expect(not source.contains("draw_rect("), "node dragging must not draw a blue workspace outline")


func _test_palette_occupant_is_safe_for_connections() -> void:
	var connection_script = load("res://scripts/connection.gd")
	_expect(
		connection_script.has_method("menu_occupant_allows_reverse"),
		"connection input must safely classify generic menu_inside occupants"
	)
	if not connection_script.has_method("menu_occupant_allows_reverse"):
		return

	_expect(
		connection_script.menu_occupant_allows_reverse(null),
		"an empty menu_inside layer must preserve reverse connection behavior"
	)
	var palette_panel := PanelContainer.new()
	_expect(
		not connection_script.menu_occupant_allows_reverse(palette_panel),
		"a palette PanelContainer must block reverse connection input without reading a missing hint"
	)
	palette_panel.free()

	var detach_menu = load("res://scripts/detatch_menu.gd").new()
	detach_menu.hint = &"detatch"
	_expect(
		connection_script.menu_occupant_allows_reverse(detach_menu),
		"the existing detatch menu must keep allowing reverse connection input"
	)
	detach_menu.free()


func _test_palette_toggle_animation_contract() -> void:
	var palette = load("res://scenes/node_palette.tscn").instantiate()
	var source := FileAccess.get_file_as_string("res://scripts/node_palette.gd")
	_expect(
		palette.has_method("toggle_offset"),
		"palette must expose deterministic open and closed animation endpoints"
	)
	_expect(
		source.contains("@export var toggle_duration := 0.22"),
		"palette toggle must use the approved 220ms duration"
	)
	if palette.has_method("toggle_offset"):
		_expect(
			is_equal_approx(palette.toggle_offset(false, 248.0), 0.0),
			"expanded palette must end at the viewport edge"
		)
		_expect(
			is_equal_approx(palette.toggle_offset(true, 248.0), -248.0),
			"collapsed palette must end just outside the left edge"
		)
	_expect(source.contains("set_collapsed(false, false)"), "palette initialization must not animate")
	_expect(source.contains("_toggle_tween.kill()"), "a new toggle must interrupt the previous tween")
	_expect(source.contains("Tween.TRANS_CUBIC"), "palette motion must use cubic easing")
	_expect(
		source.contains("Tween.EASE_OUT if not value else Tween.EASE_IN"),
		"opening and closing must use the approved easing directions"
	)
	palette.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
