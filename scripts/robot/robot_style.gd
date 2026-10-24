class_name RobotStyle
extends RefCounted
## Colours and small style factories of the robot window.
##
## Nothing here is new: every value is copied from an existing element. The
## sources are named next to each constant so the next person can find them.

## Brain Mapping status line (simulation_brain_mapping_panel.gd): ok / problem.
const OK := Color("77dfa2")
const BAD := Color("ef795f")
## Accent of the "Умная машинка" ready-made project (built_in_projects/catalog/car_track.tres).
const ACCENT := Color(0.39, 0.86, 0.86, 1.0)
## Transform gizmo (simulation_transform_gizmo.gd).
const HANDLE := Color("65d8dc")
const HANDLE_FILL := Color("111419")
## Text colours of BuiltinProjectCard.
const TITLE := Color(0.94, 0.94, 0.96, 1.0)
const BODY := Color(0.79, 0.8, 0.84, 1.0)
const TAG_TEXT := Color(0.86, 0.87, 0.91, 0.92)
## Brain Mapping row title: inactive / counters.
const DIM := Color("8b8e95")
const DIMMER := Color("55585e")
## The simulation's car drawing (simulation_canvas_draw.gd, _draw_car).
const BODY_STROKE := Color("d7dce2")
const BODY_FILL := Color(0.12, 0.13, 0.15, 0.96)
const GLASS_FILL := Color(0.16, 0.25, 0.29, 0.78)
const GLASS_STROKE := Color("8edce2")
const WHEEL_FILL := Color("111318")
const WHEEL_HUB := Color("59616c")
const WHEEL_HUB_STROKE := Color("c2c9d2")


## A small rounded label, as the tags of BuiltinProjectCard._build_tags.
static func tag(text: String, accent: Color = ACCENT, font_size: int = 11) -> Label:
	var label := Label.new()
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", TAG_TEXT)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(accent.r, accent.g, accent.b, 0.10)
	style.border_color = Color(accent.r, accent.g, accent.b, 0.34)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 9
	style.content_margin_right = 9
	style.content_margin_top = 4
	style.content_margin_bottom = 4
	label.add_theme_stylebox_override("normal", style)
	return label


## A rounded outlined panel, as BuiltinProjectCard._apply_accent_style.
static func panel_style(
	accent: Color,
	background: Color,
	border_width: int = 1,
	content_padding: Vector2 = Vector2.ZERO,
	radius: int = 12
) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = Color(accent.r, accent.g, accent.b, 0.72)
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(radius)
	style.content_margin_left = content_padding.x
	style.content_margin_right = content_padding.x
	style.content_margin_top = content_padding.y
	style.content_margin_bottom = content_padding.y
	return style


## A plain label in the card's title / body colours.
static func label(text: String, size: int = 14, color: Color = BODY) -> Label:
	var node := Label.new()
	node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	node.text = text
	node.add_theme_font_size_override("font_size", size)
	node.add_theme_color_override("font_color", color)
	return node
