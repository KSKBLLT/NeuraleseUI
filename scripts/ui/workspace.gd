extends CanvasLayer
## Pixel design, graph window: three columns on the pale workspace, as in the
## Dataset Bento layout: the node palette on the left, the canvas as a white
## card in the middle and room for the Axon panel on the right. This layer
## paints the workspace around the card; the palette and the Axon panel take
## their rects from here.
## It also holds the zoom buttons in the card's lower left corner.
##
## It sits between the graph world (layer 0) and every menu and panel
## (layers 125+), so nodes slide under the card's edges like a clipped view.

const MARGIN := 16.0
const GAP := 12.0
const PALETTE_WIDTH := 236.0
const AXON_WIDTH := 344.0
const CARD_RADIUS := 24.0
## Node titles read at about 14 px from this zoom on.
const READABLE_ZOOM := 1.0
const ZOOM_STEP := 1.25

const _SHADER := preload("res://shaders/graph_frame.gdshader")

## Set by the Axon panel while it is open beside the canvas.
static var axon_open := false
## Cleared by the palette while it is folded away; the card takes its room.
static var palette_open := true

var _paint := ColorRect.new()
var _zoom_bar := HBoxContainer.new()


## Top of the workspace: under the top bar and the lesson progress panel.
static func top() -> float:
	return glob.space_begin.y + GAP * 0.5


static func card_rect() -> Rect2:
	var view: Vector2 = glob.window_size
	var left := MARGIN + (PALETTE_WIDTH + GAP if palette_open else 0.0)
	var right := view.x - MARGIN - (AXON_WIDTH + GAP if axon_open else 0.0)
	return Rect2(left, top(), right - left, view.y - MARGIN - top())


## The node palette column left of the card.
static func dock_rect() -> Rect2:
	return Rect2(MARGIN, top(), PALETTE_WIDTH, glob.window_size.y - MARGIN - top())


static func axon_rect() -> Rect2:
	var view: Vector2 = glob.window_size
	return Rect2(view.x - MARGIN - AXON_WIDTH, top(), AXON_WIDTH, view.y - MARGIN - top())


## Frames the whole graph in the card. A graph too large to read at that
## size shows its beginning at a readable zoom instead.
static func fit_graph() -> void:
	var cam = glob.cam
	if not is_instance_valid(cam) or not cam.has_method("go_camera"):
		return
	var nodes: Array = []
	for graph in graphs._graphs.values():
		if is_instance_valid(graph):
			nodes.append(graph)
	if nodes.is_empty():
		return
	var bounds: Rect2 = cam._bbox_of(nodes).grow(40.0)
	var card := card_rect()
	var zoom := minf(card.size.x / bounds.size.x, card.size.y / bounds.size.y)
	zoom = clampf(zoom, READABLE_ZOOM, 1.6)
	var focus := bounds.get_center()
	if bounds.size.x * zoom > card.size.x:
		focus.x = bounds.position.x + card.size.x * 0.5 / zoom
	if bounds.size.y * zoom > card.size.y:
		focus.y = bounds.position.y + card.size.y * 0.5 / zoom
	# The camera centres the window; the card sits off-centre between the bar,
	# the palette and the Axon panel.
	var offset: Vector2 = card.get_center() - glob.window_size * 0.5
	cam.go_camera(zoom, focus - offset / zoom)


func _ready() -> void:
	layer = 100
	_paint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var paint := ShaderMaterial.new()
	paint.shader = _SHADER
	paint.set_shader_parameter(&"frame_color", design.FRAME_BG)
	paint.set_shader_parameter(&"radius", CARD_RADIUS)
	_paint.material = paint
	add_child(_paint)
	_zoom_bar.add_theme_constant_override(&"separation", 8)
	_zoom_bar.add_child(_zoom_button("", fit_graph, true))
	_zoom_bar.add_child(_zoom_button("−", _zoom_by.bind(1.0 / ZOOM_STEP)))
	_zoom_bar.add_child(_zoom_button("+", _zoom_by.bind(ZOOM_STEP)))
	add_child(_zoom_bar)
	glob.project_opened.connect(_on_project_opened)
	# The graph window stops processing its nodes while hidden, so follow the
	# palette that hosts this layer instead of polling the current window.
	var host := get_parent() as CanvasLayer
	if host:
		host.visibility_changed.connect(func(): visible = host.visible)
		visible = host.visible


func _process(_delta: float) -> void:
	if not visible:
		return
	var card := card_rect()
	_paint.size = glob.window_size
	_paint.material.set_shader_parameter(
		&"card_rect", Vector4(card.position.x, card.position.y, card.size.x, card.size.y)
	)
	var bar_size := _zoom_bar.get_combined_minimum_size()
	_zoom_bar.position = Vector2(card.position.x + 16, card.end.y - bar_size.y - 16)


## A project opens framed in the card at a readable size: a saved view was
## centred on the whole window, which now also holds the palette and Axon.
func _on_project_opened(..._args) -> void:
	await get_tree().process_frame
	await get_tree().process_frame
	fit_graph()


func _zoom_by(factor: float) -> void:
	var cam = glob.cam
	if is_instance_valid(cam) and cam.has_method("go_camera"):
		cam.go_camera(cam.target_zoom * factor, cam.target_position, 0.2)


func _zoom_button(glyph: String, action: Callable, fit_icon := false) -> Button:
	var button := Button.new()
	button.text = glyph
	button.custom_minimum_size = Vector2(44, 44)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override(&"font_size", 22)
	button.add_theme_color_override(&"font_color", design.ON_SURFACE)
	button.add_theme_color_override(&"font_hover_color", design.ON_SURFACE)
	for state in [&"normal", &"hover", &"pressed"]:
		var fill := StyleBoxFlat.new()
		fill.bg_color = design.SC_LOWEST if state == &"normal" else design.SC_HIGH
		fill.border_color = design.OUTLINE_VAR
		fill.set_border_width_all(1)
		fill.set_corner_radius_all(999)
		button.add_theme_stylebox_override(state, fill)
	button.pressed.connect(action)
	button.mouse_entered.connect(glob.set_scroll_impossible.bind(button))
	button.mouse_exited.connect(glob.set_scroll_possible.bind(button))
	if fit_icon:
		var corners := _FitIcon.new()
		corners.set_anchors_preset(Control.PRESET_FULL_RECT)
		corners.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.add_child(corners)
	return button


## "Fit" icon: four corner brackets.
class _FitIcon extends Control:
	func _draw() -> void:
		var c := size * 0.5
		var r := 9.0
		var arm := 5.0
		var colour: Color = Color("#1D1B20")
		for sx in [-1.0, 1.0]:
			for sy in [-1.0, 1.0]:
				var corner := c + Vector2(sx, sy) * r
				draw_line(corner, corner - Vector2(sx * arm, 0), colour, 2.0, true)
				draw_line(corner, corner - Vector2(0, sy * arm), colour, 2.0, true)
