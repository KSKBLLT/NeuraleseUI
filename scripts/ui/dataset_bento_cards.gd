extends VBoxContainer
## Dataset Bento, middle column: the selected dataset's summary (size,
## mistakes, what the network sees and does), the likeness map beside the
## situations, and the card of rows under the current filter.

const UI := preload("res://scripts/ui/dataset_bento_ui.gd")
const Draw := preload("res://scripts/ui/dataset_bento_draw.gd")
const Analysis := preload("res://scripts/ui/dataset_bento_analysis.gd")
const Situations := preload("res://scripts/ui/dataset_bento_situations.gd")
const Words := preload("res://scripts/ui/dataset_bento_words.gd")

var view: Node
var grid: Draw.RowsGrid
var rows_body: Control

var _kind: Label
var _name: Label
var _count: Label
var _count_word: Label
var _deleted: Label
var _mistake_count: Label
var _mistake_text: Label
var _mistake_glow: TextureRect
var _mistake_view: Button
var _mistake_delete: Button
var _sees: VBoxContainer
var _does: VBoxContainer
var _map: Draw.MapView
var _segments: Draw.SegmentBar
var _situations: VBoxContainer
var _dot_colour := UI.TEXT_3
var _dot: Control
var _title: Label
var _meta: Label
var _pictures: Button
var _numbers: Button
var _delete_group: Button
var _all_rows: Button
var _undo: Button
var _reset: Button


func _init(owner_view: Node) -> void:
	view = owner_view


func _ready() -> void:
	add_theme_constant_override(&"separation", 10)
	var summary := HBoxContainer.new()
	summary.add_theme_constant_override(&"separation", 10)
	summary.custom_minimum_size.y = 150
	add_child(summary)
	_build_hero(summary)
	_build_mistakes(summary)
	_build_inside(summary)
	var middle := HBoxContainer.new()
	middle.add_theme_constant_override(&"separation", 10)
	middle.custom_minimum_size.y = 232
	add_child(middle)
	_build_map(middle)
	_build_situations(middle)
	_build_rows()


func _column(card: PanelContainer, separation := 10) -> VBoxContainer:
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", separation)
	card.add_child(column)
	return column


func _build_hero(row: HBoxContainer) -> void:
	var card := UI.card(UI.VIOLET)
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_stretch_ratio = 1.3
	row.add_child(card)
	var column := _column(card, 6)
	var soft := Color(UI.ON_VIOLET, 0.72)
	_kind = UI.label("", 12, soft)
	_name = UI.label("", 15, UI.ON_VIOLET)
	_name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_name.clip_text = true
	column.add_child(_kind)
	column.add_child(_name)
	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(push)
	var count_row := HBoxContainer.new()
	count_row.add_theme_constant_override(&"separation", 8)
	_count = UI.label("", 52, UI.ON_VIOLET)
	_count.add_theme_font_override(&"font", UI.font(400, -2))
	_count_word = UI.label("", 12, soft)
	_deleted = UI.label("", 12, soft)
	for part in [_count_word, _deleted]:
		part.size_flags_vertical = Control.SIZE_SHRINK_END
	count_row.add_child(_count)
	count_row.add_child(_count_word)
	count_row.add_child(_deleted)
	column.add_child(count_row)


func _build_mistakes(row: HBoxContainer) -> void:
	# A plain panel, so the glow spans the whole card and is clipped to its corners.
	var card := Panel.new()
	card.add_theme_stylebox_override(&"panel", UI.box(UI.CARD, 14))
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	row.add_child(card)
	# A coral glow from the top right corner while something looks wrong.
	var gradient := Gradient.new()
	gradient.set_color(0, Color(UI.CORAL, 0.24))
	gradient.set_color(1, Color(UI.CORAL, 0.0))
	gradient.set_offset(1, 0.62)
	var glow := GradientTexture2D.new()
	glow.gradient = gradient
	glow.fill = GradientTexture2D.FILL_RADIAL
	glow.fill_from = Vector2(1.0, 0.0)
	glow.fill_to = Vector2(-0.2, 0.0)
	_mistake_glow = TextureRect.new()
	_mistake_glow.texture = glow
	_mistake_glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_mistake_glow.stretch_mode = TextureRect.STRETCH_SCALE
	_mistake_glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_mistake_glow.set_anchors_preset(Control.PRESET_FULL_RECT)
	card.add_child(_mistake_glow)
	var inset := MarginContainer.new()
	inset.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in [&"margin_left", &"margin_right", &"margin_top", &"margin_bottom"]:
		inset.add_theme_constant_override(side, 16)
	card.add_child(inset)
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 10)
	inset.add_child(column)
	column.add_child((UI.tagged(UI.label("", 12, UI.TEXT_2), "mistakes") as Label))
	var line := HBoxContainer.new()
	line.add_theme_constant_override(&"separation", 10)
	line.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_mistake_count = UI.label("", 52, UI.CORAL)
	_mistake_count.add_theme_font_override(&"font", UI.font(400, -2))
	_mistake_text = UI.label("", 11, Color("#4A4456"))
	_mistake_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_mistake_text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_mistake_text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(_mistake_count)
	line.add_child(_mistake_text)
	column.add_child(line)
	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override(&"separation", 6)
	_mistake_view = UI.button("", 11, UI.TEXT_1, UI.BUTTON, 6)
	_mistake_view.pressed.connect(func(): view.toggle_mistakes())
	_mistake_delete = (UI.tagged(UI.button("", 11, UI.TEXT_1, UI.BUTTON, 6), "delete") as Button)
	_mistake_delete.pressed.connect(func(): view.delete_rows(view.mistakes()))
	buttons.add_child(_mistake_view)
	buttons.add_child(_mistake_delete)
	column.add_child(buttons)


func _build_inside(row: HBoxContainer) -> void:
	var card := UI.card()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.size_flags_stretch_ratio = 1.3
	row.add_child(card)
	var column := _column(card, 12)
	column.add_child((UI.tagged(UI.label("", 12, UI.TEXT_2), "inside") as Label))
	var push := Control.new()
	push.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(push)
	var sides := HBoxContainer.new()
	sides.add_theme_constant_override(&"separation", 10)
	_sees = VBoxContainer.new()
	_does = VBoxContainer.new()
	for side in [_sees, _does]:
		side.add_theme_constant_override(&"separation", 6)
		side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var arrow := UI.label("→", 13, UI.TEXT_3)
	arrow.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	arrow.custom_minimum_size.y = 50
	arrow.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	sides.add_child(_sees)
	sides.add_child(arrow)
	sides.add_child(_does)
	column.add_child(sides)


func _build_map(row: HBoxContainer) -> void:
	var card := UI.card(UI.CARD, 14.0)
	card.custom_minimum_size.x = 280
	row.add_child(card)
	var column := _column(card, 10)
	var head := HBoxContainer.new()
	head.add_child((UI.tagged(UI.label("", 12, UI.TEXT_2), "map") as Label))
	head.add_child(UI.spacer())
	head.add_child((UI.tagged(UI.label("", 10, UI.TEXT_3), "map_hint") as Label))
	column.add_child(head)
	_map = Draw.MapView.new()
	_map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_map.picked.connect(func(index: int): view.pick_cluster(index))
	column.add_child(_map)


func _build_situations(row: HBoxContainer) -> void:
	var card := UI.card(UI.CARD, 10.0)
	(card.get_theme_stylebox(&"panel") as StyleBoxFlat).content_margin_top = 12.0
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(card)
	var column := _column(card, 8)
	var head := MarginContainer.new()
	head.add_theme_constant_override(&"margin_left", 6)
	head.custom_minimum_size.y = 28
	var title := (UI.tagged(UI.label("", 12, UI.TEXT_2), "situations") as Label)
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	head.add_child(title)
	column.add_child(head)
	var bar_inset := MarginContainer.new()
	bar_inset.add_theme_constant_override(&"margin_left", 6)
	bar_inset.add_theme_constant_override(&"margin_right", 6)
	_segments = Draw.SegmentBar.new()
	_segments.picked.connect(func(index: int): view.pick_cluster(index))
	bar_inset.add_child(_segments)
	column.add_child(bar_inset)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_situations = VBoxContainer.new()
	_situations.add_theme_constant_override(&"separation", 3)
	_situations.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_situations)
	column.add_child(scroll)


func _build_rows() -> void:
	var card := UI.card(UI.CARD, 0.0)
	card.size_flags_vertical = Control.SIZE_EXPAND_FILL
	add_child(card)
	var column := _column(card, 0)
	var head_inset := MarginContainer.new()
	head_inset.add_theme_constant_override(&"margin_left", 14)
	head_inset.add_theme_constant_override(&"margin_right", 14)
	head_inset.add_theme_constant_override(&"margin_top", 12)
	head_inset.add_theme_constant_override(&"margin_bottom", 10)
	var head := HBoxContainer.new()
	head.add_theme_constant_override(&"separation", 10)
	head_inset.add_child(head)
	column.add_child(head_inset)
	_dot = Draw.Painted.new(func(ci: Control): ci.draw_circle(ci.size * 0.5, 5.0, _dot_colour))
	_dot.custom_minimum_size = Vector2(10, 10)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_title = UI.label("", 13, UI.INK)
	_meta = UI.label("", 11, UI.TEXT_2)
	_meta.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for part in [_dot, _title, _meta]:
		head.add_child(part)
	head.add_child(UI.spacer())
	var track := UI.card(UI.CHIP, 3.0, 9)
	var options := HBoxContainer.new()
	options.add_theme_constant_override(&"separation", 3)
	_pictures = UI.button("", 11, UI.TEXT_1, UI.CARD, 7)
	_numbers = UI.button("", 11, UI.TEXT_2, UI.CHIP, 7)
	_pictures.pressed.connect(func(): view.set_numbers(false))
	_numbers.pressed.connect(func(): view.set_numbers(true))
	options.add_child(_pictures)
	options.add_child(_numbers)
	track.add_child(options)
	head.add_child(track)
	_delete_group = UI.button("", 12)
	_delete_group.pressed.connect(func(): view.delete_rows(view.shown))
	_all_rows = UI.button("", 12)
	_all_rows.pressed.connect(func(): view.clear_filter())
	_undo = UI.button("", 12)
	_undo.pressed.connect(func(): view.undo())
	_reset = UI.button("", 12)
	_reset.pressed.connect(func(): view.reset())
	for button in [_delete_group, _all_rows, _undo, _reset]:
		head.add_child(button)
	rows_body = Control.new()
	rows_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(rows_body)
	grid = Draw.RowsGrid.new()
	grid.set_anchors_preset(Control.PRESET_FULL_RECT)
	grid.describe = func(row: int) -> Dictionary: return view.describe(row)
	grid.paint_row = func(ci: CanvasItem, rect: Rect2, info: Dictionary): Draw.draw_row(ci, rect, info)
	grid.picked.connect(func(index: int): view.pick_row(index))
	grid.delete_requested.connect(func(row: int): view.delete_rows(PackedInt32Array([row])))
	rows_body.add_child(grid)


## Refills every card from the view's dataset, analysis and filter.
func show_dataset() -> void:
	var data: Dictionary = view.data
	var image: bool = data["image"]
	var columns: Array = data["columns"]
	var split: int = data["split"]
	var rows: int = view._rows().size()
	_kind.text = "%s · %d → %d" % [UI.t("image" if image else "table"), split, columns.size() - split]
	_name.text = data["name"]
	_count.text = UI.group_digits(rows)
	_count_word.text = UI.rows_word(rows, image)
	_deleted.text = "· " + UI.t("deleted") % UI.group_digits(view.deleted) if view.deleted > 0 else ""
	var ready: bool = not view.analysis.is_empty()
	var mistakes: PackedInt32Array = view.mistakes()
	_mistake_count.text = str(mistakes.size()) if ready else "…"
	_mistake_count.add_theme_color_override(&"font_color", UI.CORAL if not mistakes.is_empty() else UI.TEXT_3)
	_mistake_text.text = "" if not ready else UI.t("mistakes_frames" if image else "mistakes_rows") if not mistakes.is_empty() else UI.t("no_mistakes")
	_mistake_glow.visible = not mistakes.is_empty()
	_mistake_view.get_parent().visible = not mistakes.is_empty()
	_mistake_view.text = UI.t("hide" if view.mistakes_only else "view")
	(_mistake_view.get_theme_stylebox(&"normal") as StyleBoxFlat).bg_color = UI.PICKED_SOFT if view.mistakes_only else UI.BUTTON
	_fill_inside(data)
	_fill_situations(ready)
	_fill_rows(image)


func _fill_inside(data: Dictionary) -> void:
	for side in [_sees, _does]:
		UI.clear(side)
	var sees := UI.label(UI.t("sees"), 10, UI.MINT)
	var does := UI.label(UI.t("does"), 10, UI.YELLOW)
	for head in [sees, does]:
		head.add_theme_font_override(&"font", UI.font(400, 1))
	_sees.add_child(sees)
	_does.add_child(does)
	var columns: Array = data["columns"]
	var split: int = data["split"]
	var car: Dictionary = data["car"]
	var seen: Array = columns.slice(0, split)
	var done: Array = columns.slice(split)
	if not car.is_empty():
		seen = [UI.count(car["rays"].size(), ["луч", "луча", "лучей"], "сәуле", ["ray", "rays"])]
		if car["speed"] >= 0:
			seen.append(UI.t("speed"))
		done = [UI.t("steering")]
		if car["throttle"] >= 0:
			done.append(UI.t("throttle"))
	elif data["image"]:
		seen = [UI.t("camera_frame")]
	for pair in [[_sees, seen], [_does, done]]:
		var words: Array = pair[1]
		for word in words.slice(0, 2):
			pair[0].add_child(UI.chip(str(word)))
		if words.size() > 2:
			pair[0].add_child(UI.chip("+%d" % (words.size() - 2), 11, UI.TEXT_2))


func _fill_situations(ready: bool) -> void:
	var clusters: Array = view.analysis.get("clusters", [])
	_map.points = view.analysis.get("points", PackedVector2Array())
	_map.point_cluster = view.analysis.get("point_cluster", PackedInt32Array())
	_map.clusters = clusters
	_map.selected = view.cluster
	_map.showing_mistakes = view.mistakes_only
	_map.queue_redraw()
	_segments.shares = clusters.map(func(c): return [c["members"].size(), c["color"]])
	_segments.selected = view.cluster
	_segments.queue_redraw()
	UI.clear(_situations)
	if not ready:
		_situations.add_child(UI.label("…", 13, UI.TEXT_3))
		return
	for j in clusters.size():
		_situations.add_child(_situation_row(j, clusters[j]))


func _situation_row(j: int, group: Dictionary) -> Control:
	var picked: bool = view.cluster == j
	var item := PanelContainer.new()
	var style := UI.box(UI.PICKED if picked else Color.TRANSPARENT, 10)
	style.content_margin_left = 10.0
	style.content_margin_right = 10.0
	style.content_margin_top = 7.0
	style.content_margin_bottom = 7.0
	if picked:
		style.border_color = UI.VIOLET
		style.set_border_width_all(1)
	item.add_theme_stylebox_override(&"panel", style)
	item.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	item.gui_input.connect(func(event: InputEvent):
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			view.pick_cluster(j))
	var line := HBoxContainer.new()
	line.add_theme_constant_override(&"separation", 10)
	var colour: Color = group["color"]
	var badge := Draw.Painted.new(func(ci: Control):
		ci.draw_circle(ci.size * 0.5, 11.0, colour)
		var text := str(j + 1)
		var width := UI.font(600).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
		ci.draw_string(UI.font(600), ci.size * 0.5 + Vector2(-width * 0.5, 4), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UI.ON_VIOLET))
	badge.custom_minimum_size = Vector2(22, 22)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(badge)
	var names := VBoxContainer.new()
	names.add_theme_constant_override(&"separation", 2)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var title := UI.label(Words.cluster_text(view, j), 13, UI.TEXT_1)
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.clip_text = true
	names.add_child(title)
	names.add_child(UI.label(UI.examples(group["members"].size(), view.data["image"]), 10, UI.TEXT_2))
	line.add_child(names)
	var members: PackedInt32Array = group["members"]
	var profile := Draw.Painted.new(func(ci: Control):
		if view.data["image"]:
			for t in mini(3, members.size()):
				var cell := Rect2(t * 20.0, 0, 17, ci.size.y)
				ci.draw_style_box(UI.box(UI.WELL, 3), cell)
				Draw.draw_row(ci, cell, view.describe(members[t]))
		else:
			Draw.draw_profile(ci, Rect2(Vector2.ZERO, ci.size), group["profile"], colour))
	profile.custom_minimum_size = Vector2(60, 26)
	profile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	line.add_child(profile)
	line.add_child(UI.label("→", 12, UI.TEXT_3))
	var action := VBoxContainer.new()
	action.custom_minimum_size.x = 92
	action.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	action.add_child(UI.chip(Words.action_text(group["action"]), 11, Color("#2A2532"), UI.CHIP, 5))
	line.add_child(action)
	item.add_child(line)
	return item


func _fill_rows(image: bool) -> void:
	var filtered: bool = view.cluster >= 0 or view.mistakes_only
	_dot_colour = UI.CORAL if view.mistakes_only else (view.analysis["clusters"][view.cluster]["color"] if view.cluster >= 0 else UI.TEXT_3)
	_dot.queue_redraw()
	_title.text = selection_title()
	_meta.text = UI.examples(view.shown.size(), image)
	_pictures.text = UI.t("pictures")
	_numbers.text = UI.t("numbers")
	_paint_option(_pictures, not view.numbers)
	_paint_option(_numbers, view.numbers)
	_delete_group.visible = filtered and not view.shown.is_empty()
	_delete_group.text = UI.t("delete_all" if view.mistakes_only else "delete_group")
	_all_rows.visible = filtered
	_all_rows.text = UI.t("all_frames" if image else "all_rows")
	_undo.visible = view.can_undo()
	_undo.text = UI.t("undo")
	_reset.text = UI.t("reset")
	grid.visible = not view.numbers
	grid.rows = view.shown
	grid.current = view.current
	grid.mistakes = {}
	for row in view.mistakes():
		grid.mistakes[row] = true
	grid.image = image
	grid.queue_redraw()


func _paint_option(button: Button, active: bool) -> void:
	for state in [&"normal", &"hover", &"pressed"]:
		var style := button.get_theme_stylebox(state) as StyleBoxFlat
		style.bg_color = UI.CARD if active else (UI.BUTTON_HOVER if state != &"normal" else UI.CHIP)
	for state in [&"font_color", &"font_hover_color", &"font_pressed_color"]:
		button.add_theme_color_override(state, UI.INK if active else UI.TEXT_2)


func selection_title() -> String:
	if view.mistakes_only:
		return UI.t("mistakes")
	if view.cluster >= 0:
		return Words.cluster_text(view, view.cluster)
	return UI.t("all_frames" if view.data["image"] else "all_rows")
