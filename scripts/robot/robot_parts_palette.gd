class_name RobotPartsPalette
extends PanelContainer
## The robot window's checklist: the steps of getting a robot ready, the open
## one with what to do and what it is about (the network's inputs and outputs,
## the robot's parts). A copy of the simulation's object palette
## (SimulationPalette): the same blurred panel, group headers with an accent
## bar, entries and dividers; rounded like the windows
## (resources/robot_parts_panel.tres) and in the window's own font.
##
## It only shows what the robot panel decides (show_rows); a press on a step's
## title or on a line is reported back with its id.

const NodePaletteStyle = preload("res://scripts/node_palette.gd")
const GraphicsQualityConfig = preload("res://scripts/graphics_quality.gd")
const PanelMaterial = preload("res://resources/robot_parts_panel.tres")

signal row_pressed(id: String)
signal part_requested(part: Dictionary)

var _background: ColorRect
var _groups: VBoxContainer
var _scroll: ScrollContainer
var _open_step := ""                # the step shown open last time


func _ready() -> void:
	add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	_background = ColorRect.new()
	_background.name = "Background"
	_background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_background)
	_reuse_blur_background()
	_reuse_blur_background.call_deferred()
	_build()


## The project's panel blur (tint and outline of the top bar), with rounded corners.
func _reuse_blur_background() -> void:
	NodePaletteStyle.apply_project_blur_background(_background)
	GraphicsQualityConfig.set_authored_screen_material(_background, PanelMaterial)

	_background.material = _background.material.duplicate()
	_background.material.set_shader_parameter("use_bg", true)
	print("egrgeregrerga")

## The mouse wheel is the palette's while the mouse is over it. Its own `visible`
## stays on when the Export window around it closes, so what counts is whether
## it is shown in the tree; otherwise its empty place kept the wheel and the
## camera could not be moved there.
func _process(_delta: float) -> void:
	if is_visible_in_tree() and get_global_rect().has_point(get_global_mouse_position()):
		glob.occupy(self, &"scroll")
	else:
		glob.un_occupy(self, &"scroll")


func _notification(what: int) -> void:
	# Hidden or taken away while the mouse was over it: its window may stop
	# processing it, so let go of the wheel now.
	if (what == NOTIFICATION_VISIBILITY_CHANGED and not is_visible_in_tree()) or what == NOTIFICATION_EXIT_TREE:
		glob.un_occupy(self, &"scroll")


func _build() -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 12)
	margin.add_theme_constant_override("margin_top", 12)
	margin.add_theme_constant_override("margin_right", 9)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 8)
	margin.add_child(layout)
	_scroll = ScrollContainer.new()
	_scroll.name = "PartScroll"
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
	layout.add_child(_scroll)
	_groups = VBoxContainer.new()
	_groups.name = "Groups"
	_groups.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_groups.add_theme_constant_override("separation", 6)
	_scroll.add_child(_groups)


## Rebuilds the palette. ``sections`` is a list of steps:
## {"id", "title" (already in the current language), "accent": Color, "state": "ok"|"",
## "current": bool, "note": what to do (its lines are broken to the width), "rows": [row]}
## where a row is a RobotPaletteRow spec: {"id", "text", "accent" | "picture",
## "count", "state": "ok"|"missing"|"off"|"", "port", "part", "pressable"}.
func show_rows(sections: Array) -> void:
	var scroll_value := _scroll.scroll_vertical
	var current_group: Control = null
	var current_id := ""
	for child in _groups.get_children():
		_groups.remove_child(child)
		child.queue_free()
	for index in sections.size():
		var section: Dictionary = sections[index]
		var group := VBoxContainer.new()
		group.add_theme_constant_override("separation", 2)
		_groups.add_child(group)
		if section.get("current", false):
			current_group = group
			current_id = str(section.get("id", ""))
		var header := RobotPaletteRow.new()
		var header_id := str(section.get("id", ""))
		header.configure({
			"id": header_id,
			"text": str(section.get("title", "")),
			"accent": section.get("accent", Color.WHITE),
			"state": section.get("state", ""),
			"pressable": true,
			"header": true,
			"current": section.get("current", false),
		})
		header.pressed.connect(func(): row_pressed.emit(header_id))
		group.add_child(header)
		var note := str(section.get("note", ""))
		if not note.is_empty():
			group.add_child(_note(note))
		for row_spec in section.get("rows", []):
			if row_spec.has("parts"):
				group.add_child(_part_tiles(row_spec["parts"]))
				continue
			var row := RobotPaletteRow.new()
			row.configure(row_spec)
			var id := str(row_spec.get("id", ""))
			if not row_spec.get("part", {}).is_empty():
				row.pressed.connect(func(): part_requested.emit(row_spec["part"]))
			elif row_spec.get("pressable", false):
				row.pressed.connect(func(): row_pressed.emit(id))
			group.add_child(row)
		if index < sections.size() - 1:
			var divider := HSeparator.new()
			divider.modulate = Color(1.0, 1.0, 1.0, 0.2)
			group.add_child(divider)
	# A step that has just opened is scrolled to its title (a small window has
	# room for a couple of lines only); otherwise the scroll stays where it was.
	var opened := current_id != _open_step
	_open_step = current_id
	var keep := func():
		if opened and is_instance_valid(current_group):
			_scroll.scroll_vertical = int(current_group.position.y)
		else:
			_scroll.scroll_vertical = scroll_value
	keep.call_deferred()


## What to do in the open step, in the dim colour of the window's other words.
func _note(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", 13)
	label.add_theme_color_override("font_color", Color(0.72, 0.74, 0.79, 1))
	label.add_theme_constant_override("line_spacing", 1)
	var margin := StyleBoxEmpty.new()
	margin.content_margin_left = 14.0
	margin.content_margin_bottom = 4.0
	label.add_theme_stylebox_override("normal", margin)
	label.clip_text = true
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# The lines follow the palette's width, breaking between words.
	label.resized.connect(func() -> void:
		label.text = RobotText.fit(text, label, label.size.x - margin.content_margin_left - 4.0))
	return label


## The robot's parts of one kind, side by side: a picture and a port each.
func _part_tiles(parts: Array) -> HFlowContainer:
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 4)
	flow.add_theme_constant_override("v_separation", 4)
	for part_spec in parts:
		var tile := RobotPaletteRow.new()
		tile.configure(part_spec)
		tile.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		tile.custom_minimum_size = Vector2(68.0, 46.0)
		tile.pressed.connect(func(): part_requested.emit(part_spec["part"]))
		flow.add_child(tile)
	return flow
