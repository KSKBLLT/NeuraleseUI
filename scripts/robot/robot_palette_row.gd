class_name RobotPaletteRow
extends Button
## One line of the robot's palette: a step's title, a network input or output,
## a part of the robot to drag, or an action. A copy of the simulation palette's entry
## (SimulationPaletteEntry and the button styles SimulationPalette gives it),
## with what each line needs drawn around its text: an accent bar in the
## registry's colour or the part's picture on the left, the number of neurons
## and a state mark on the right.

const OK_COLOR := Color("77dfa2")
const BAD_COLOR := Color("ef795f")
const DIM_COLOR := Color("8b8e95")
const HANDLE_COLOR := Color("65d8dc")
const HANDLE_FILL := Color("111419")

var spec: Dictionary = {}           # see RobotPartsPalette.show_rows
var part: Dictionary = {}           # for a draggable part


func configure(new_spec: Dictionary) -> void:
	spec = new_spec
	part = spec.get("part", {})
	alignment = HORIZONTAL_ALIGNMENT_LEFT
	focus_mode = Control.FOCUS_NONE
	clip_text = true
	text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(0.0, 44.0 if spec.has("picture") else 32.0)
	var header := bool(spec.get("header", false))
	add_theme_font_size_override("font_size", 16 if header else 15)
	var normal := StyleBoxFlat.new()
	normal.bg_color = Color(0.08, 0.083, 0.091, 0.0)
	normal.set_corner_radius_all(3)
	normal.content_margin_left = (58.0 if not str(spec.get("text", "")).is_empty() else 0.0) if spec.has("picture") else 14.0
	normal.content_margin_right = _right_width()
	var hover := normal.duplicate()
	hover.bg_color = Color(0.16, 0.17, 0.19, 0.76)
	add_theme_stylebox_override("normal", normal)
	add_theme_stylebox_override("hover", hover if spec.get("pressable", false) else normal)
	add_theme_stylebox_override("pressed", hover if spec.get("pressable", false) else normal)
	add_theme_stylebox_override("disabled", normal)
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if spec.get("pressable", false) else Control.CURSOR_ARROW
	var state := str(spec.get("state", ""))
	var color := DIM_COLOR if state == "off" else Color(0.92, 0.93, 0.95)
	if header and not bool(spec.get("current", false)):
		color = Color(0.78, 0.8, 0.84, 0.96)      # the simulation palette's group titles
	add_theme_color_override("font_color", color)
	add_theme_color_override("font_hover_color", DIM_COLOR if state == "off" else Color.WHITE)
	text = str(spec.get("text", ""))
	queue_redraw()


## The whole name, only when the row had to cut it short.
func _get_tooltip(_at_position: Vector2) -> String:
	if text.is_empty():
		return ""
	var normal := get_theme_stylebox("normal")
	var room := size.x - normal.get_margin(SIDE_LEFT) - normal.get_margin(SIDE_RIGHT)
	var width := get_theme_font("font").get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, get_theme_font_size("font_size")).x
	return text if width > room else ""


func _right_width() -> float:
	var width := 10.0
	if spec.has("count"):
		width += 46.0
	if not str(spec.get("state", "")).is_empty():
		width += 20.0
	if spec.has("port"):
		width += 26.0
	return width


func _get_drag_data(_at_position: Vector2) -> Variant:
	if part.is_empty() or str(spec.get("state", "")) == "off":
		return null
	var preview := TextureRect.new()
	preview.texture = spec.get("picture")
	preview.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	preview.custom_minimum_size = Vector2(54, 40)
	preview.size = Vector2(54, 40)
	preview.self_modulate = RobotArtData.tint()
	set_drag_preview(preview)
	return {"robot_part": part}


func _draw() -> void:
	var middle := size.y * 0.5
	var state := str(spec.get("state", ""))
	if spec.has("picture") and str(spec.get("text", "")).is_empty():
		_draw_tile(middle, state)
		return
	if spec.has("picture"):
		var texture: Texture2D = spec["picture"]
		var box := Rect2(Vector2(8.0, 6.0), Vector2(44.0, size.y - 12.0))
		var ratio := texture.get_size().x / maxf(texture.get_size().y, 1.0)
		var fit := Vector2(box.size.y * ratio, box.size.y)
		if fit.x > box.size.x:
			fit = Vector2(box.size.x, box.size.x / ratio)
		var tint := RobotArtData.tint()
		if state == "off":
			tint = Color(tint, 0.35)
		draw_texture_rect(texture, Rect2(box.get_center() - fit * 0.5, fit), false, tint)
	elif spec.has("accent"):
		var accent: Color = spec["accent"]
		draw_rect(Rect2(Vector2(3.0, middle - 7.0), Vector2(3.0, 14.0)), accent.lightened(0.12) if state != "off" else DIM_COLOR)
	var font := get_theme_default_font()
	var x := size.x - 10.0
	if not state.is_empty():
		var mark: String = {"ok": "✓", "missing": "!", "off": "–"}.get(state, "")
		var colour: Color = {"ok": OK_COLOR, "missing": BAD_COLOR, "off": DIM_COLOR}.get(state, DIM_COLOR)
		var width := font.get_string_size(mark, HORIZONTAL_ALIGNMENT_LEFT, -1, 16).x
		draw_string(font, Vector2(x - width, middle + 6.0), mark, HORIZONTAL_ALIGNMENT_LEFT, -1, 16, colour)
		x -= 22.0
	if spec.has("port"):
		var center := Vector2(x - 11.0, middle)
		draw_circle(center, 10.0, HANDLE_FILL)
		draw_circle(center, 10.0, HANDLE_COLOR, false, 1.5, true)
		var label := str(spec["port"])
		var label_width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		draw_string(font, center + Vector2(-label_width * 0.5, 4.7), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		x -= 26.0
	if spec.has("count"):
		var count := "[ %d ]" % int(spec["count"])
		var count_width := font.get_string_size(count, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var accent: Color = spec.get("accent", DIM_COLOR)
		draw_string(font, Vector2(x - count_width, middle + 5.0), count, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, accent if state != "off" else Color("55585e"))


## A part without words: its picture and its port; a part already on the robot
## has its port ringed in the "ok" colour.
func _draw_tile(middle: float, state: String) -> void:
	var texture: Texture2D = spec["picture"]
	var box := Rect2(Vector2(4.0, 6.0), Vector2(38.0, size.y - 12.0))
	var ratio := texture.get_size().x / maxf(texture.get_size().y, 1.0)
	var fit := Vector2(box.size.y * ratio, box.size.y)
	if fit.x > box.size.x:
		fit = Vector2(box.size.x, box.size.x / ratio)
	draw_texture_rect(texture, Rect2(box.get_center() - fit * 0.5, fit), false, RobotArtData.tint())
	var center := Vector2(size.x - 16.0, middle)
	var placed := state == "ok"
	draw_circle(center, 11.0, HANDLE_FILL)
	draw_circle(center, 11.0, OK_COLOR if placed else HANDLE_COLOR, false, 2.5 if placed else 1.5, true)
	var font := get_theme_default_font()
	var label := str(spec.get("port", ""))
	var width := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	draw_string(font, center + Vector2(-width * 0.5, 4.7), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
