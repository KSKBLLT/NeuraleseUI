extends RefCounted
## Dataset Bento: everything drawn rather than built from nodes — the likeness
## map, the situations' segment bar, the grid of row cards (only the visible
## cards are drawn, so a dataset of any size scrolls smoothly) and a row's
## picture: the car's ray fan, an image, or bars for a table's inputs.

const UI := preload("res://scripts/ui/dataset_bento_ui.gd")


## A row's picture inside rect. `row` holds what the view read from the
## dataset: "rays" (0..1), "steer", "gas", or "texture", or "bars" (0..1).
static func draw_row(ci: CanvasItem, rect: Rect2, row: Dictionary, big := false) -> void:
	if row.has("texture"):
		var texture: Texture2D = row["texture"]
		var fit := texture.get_size() * minf(rect.size.x / texture.get_size().x, rect.size.y / texture.get_size().y)
		ci.draw_texture_rect(texture, Rect2(rect.get_center() - fit * 0.5, fit), false)
	elif row.has("rays"):
		_draw_fan(ci, rect, row["rays"], row.get("steer", 0.0), row.get("gas", 1.0), big)
	elif row.has("bars"):
		_draw_bars(ci, rect, row["bars"], big)
	else:
		_hatch(ci, rect)


static func _draw_fan(ci: CanvasItem, rect: Rect2, rays: PackedFloat32Array, steer: float, gas: float, big: bool) -> void:
	var origin := Vector2(rect.get_center().x, rect.end.y - rect.size.y * 0.2)
	var reach := rect.size.y * (0.76 if big else 0.74)
	if big:
		for ring in [0.5, 1.0, 1.5]:
			ci.draw_arc(origin, reach * ring * 0.67, PI, TAU, 48, Color(UI.INK, 0.08), 1.0, true)
	var count := rays.size()
	for r in count:
		var angle := deg_to_rad(-72.0 + 144.0 * r / maxf(1.0, count - 1.0)) - PI * 0.5
		var length := clampf(rays[r], 0.04, 1.0) * reach
		var tip := origin + Vector2.from_angle(angle) * length
		var hit := rays[r] < 0.97
		ci.draw_line(origin, tip, Color(UI.MINT, 1.0 if hit else 0.45), 2.0 if big else 1.5, true)
		if hit:
			ci.draw_circle(tip, 4.0 if big else 2.5, UI.MINT)
	# Where the car goes: the arrow turns with steering and grows with throttle.
	var heading := deg_to_rad(clampf(steer, -1.0, 1.0) * 60.0) - PI * 0.5
	var arrow := reach * (0.35 + 0.45 * clampf(gas, 0.0, 1.0))
	var head := origin + Vector2.from_angle(heading) * arrow
	ci.draw_line(origin, head, UI.YELLOW, 4.0 if big else 2.5, true)
	var size := 10.0 if big else 6.0
	var side := Vector2.from_angle(heading + PI * 0.5) * size * 0.6
	var front := Vector2.from_angle(heading) * size
	ci.draw_colored_polygon(PackedVector2Array([head + front, head + side, head - side]), UI.YELLOW)
	var body := Vector2(rect.size.x * 0.05 if big else rect.size.x * 0.07, rect.size.y * 0.16)
	var car := Rect2(Vector2(origin.x - body.x * 0.5, rect.end.y - rect.size.y * 0.04 - body.y), body)
	ci.draw_style_box(UI.box(UI.TEXT_1, 3 if big else 2), car)


static func _draw_bars(ci: CanvasItem, rect: Rect2, bars: PackedFloat32Array, big: bool) -> void:
	if bars.is_empty():
		return
	var inner := rect.grow(-rect.size.y * 0.14)
	var gap := 3.0 if big else 2.0
	var width := (inner.size.x - gap * (bars.size() - 1)) / bars.size()
	for b in bars.size():
		var height := maxf(2.0, clampf(bars[b], 0.0, 1.0) * inner.size.y)
		var bar := Rect2(inner.position.x + b * (width + gap), inner.end.y - height, width, height)
		ci.draw_rect(bar, Color(UI.MINT, 0.85))


static func _hatch(ci: CanvasItem, rect: Rect2) -> void:
	var outline := PackedVector2Array([rect.position, Vector2(rect.end.x, rect.position.y), rect.end, Vector2(rect.position.x, rect.end.y)])
	var x := -rect.size.y
	while x < rect.size.x:
		var line := PackedVector2Array([rect.position + Vector2(x, rect.size.y), rect.position + Vector2(x + rect.size.y, 0.0)])
		for piece in Geometry2D.intersect_polyline_with_polygon(line, outline):
			ci.draw_polyline(piece, UI.LINE, 3.0)
		x += 12.0


## Bars of a situation's profile, in its colour.
static func draw_profile(ci: CanvasItem, rect: Rect2, values: PackedFloat32Array, colour: Color) -> void:
	if values.is_empty():
		return
	var gap := 2.0
	var width := (rect.size.x - gap * (values.size() - 1)) / values.size()
	for v in values.size():
		var height := maxf(1.0, clampf(values[v], 0.04, 1.0) * rect.size.y)
		ci.draw_rect(Rect2(rect.position.x + v * (width + gap), rect.end.y - height, width, height), colour)


## The likeness map: every analysed row as a dot, situations as numbered badges.
class MapView extends Control:
	signal picked(cluster: int)

	var points := PackedVector2Array()
	var point_cluster := PackedInt32Array()
	var clusters: Array = []
	var selected := -1
	var showing_mistakes := false

	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP
		clip_contents = true

	func _draw() -> void:
		draw_style_box(UI.box(UI.WELL, 10), Rect2(Vector2.ZERO, size))
		draw_line(Vector2(size.x * 0.5, 0), Vector2(size.x * 0.5, size.y), UI.LINE, 1.0)
		draw_line(Vector2(0, size.y * 0.5), Vector2(size.x, size.y * 0.5), UI.LINE, 1.0)
		for i in points.size():
			var cluster := point_cluster[i]
			var colour: Color = UI.CORAL if cluster < 0 else clusters[cluster]["color"]
			var faded := (selected >= 0 and cluster != selected) or (showing_mistakes and cluster >= 0)
			var at := points[i] * size
			draw_circle(at, 3.0, Color(colour, 0.25 if faded else 0.9))
			draw_circle(at, 3.0, Color(colour.darkened(0.25), 0.3 if faded else 1.0), false, 1.5, true)
		for c in clusters.size():
			var at: Vector2 = clusters[c]["centre"] * size
			var colour: Color = clusters[c]["color"]
			for glow in 3:
				draw_circle(at, 11.0 + 3.0 * (glow + 1), Color(colour, 0.10 - glow * 0.03))
			draw_circle(at, 13.0, UI.WELL)
			draw_circle(at, 11.0, colour)
			if c == selected:
				draw_circle(at, 13.0, UI.VIOLET, false, 2.0, true)
			var text := str(c + 1)
			var font := UI.font(600)
			var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11).x
			draw_string(font, at + Vector2(-width * 0.5, 4.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, UI.ON_VIOLET)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			for c in clusters.size():
				if (clusters[c]["centre"] * size).distance_to(event.position) <= 14.0:
					picked.emit(c)
					accept_event()
					return


## The situations' shares as one segmented line.
class SegmentBar extends Control:
	signal picked(cluster: int)

	var shares: Array = []
	var selected := -1

	func _init() -> void:
		custom_minimum_size.y = 6.0
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _segments() -> Array:
		var total := 0.0
		for share in shares:
			total += share[0]
		var rects: Array = []
		var x := 0.0
		var free := size.x - 3.0 * maxf(0.0, shares.size() - 1.0)
		for share in shares:
			var width := maxf(4.0, free * share[0] / maxf(total, 1.0))
			rects.append(Rect2(x, 0.0, width, size.y))
			x += width + 3.0
		return rects

	func _draw() -> void:
		var rects := _segments()
		for s in rects.size():
			var colour: Color = shares[s][1]
			draw_style_box(UI.box(Color(colour, 0.35 if selected >= 0 and s != selected else 1.0), 3), rects[s])

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var rects := _segments()
			for s in rects.size():
				if rects[s].grow(3.0).has_point(event.position):
					picked.emit(s)
					return


## The rows as cards, drawn only where the view can see them.
class RowsGrid extends Control:
	signal picked(index: int)
	signal delete_requested(row: int)

	const PAD := 14.0
	const GAP := 8.0
	const MIN_CARD := 118.0
	const FOOTER := 24.0

	## Dataset rows shown, in order; `current` indexes into it.
	var rows := PackedInt32Array()
	var current := 0
	var mistakes := {}
	var image := false
	## Callable(row) -> Dictionary, the picture's data (see draw_row).
	var describe: Callable
	## Callable(canvas, rect, data): draws a row's picture.
	var paint_row: Callable
	var scroll := 0.0
	var _hover := -1

	func _init() -> void:
		clip_contents = true
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _layout() -> Vector3:
		var columns := maxi(1, int((size.x - PAD * 2.0 + GAP) / (MIN_CARD + GAP)))
		var width := (size.x - PAD * 2.0 - GAP * (columns - 1)) / columns
		var picture := width * (0.75 if image else 11.0 / 20.0)
		return Vector3(columns, width, picture + FOOTER + 10.0)

	func card_rect(position_in_list: int) -> Rect2:
		var layout := _layout()
		var column := position_in_list % int(layout.x)
		var line := position_in_list / int(layout.x)
		return Rect2(PAD + column * (layout.y + GAP), 2.0 + line * (layout.z + GAP) - scroll, layout.y, layout.z)

	func content_height() -> float:
		var layout := _layout()
		var lines := ceili(float(rows.size()) / layout.x)
		return 2.0 + lines * (layout.z + GAP) + PAD

	func show_current() -> void:
		var rect := card_rect(current)
		if rect.position.y < 0.0:
			scroll += rect.position.y - 4.0
		elif rect.end.y > size.y:
			scroll += rect.end.y - size.y + 4.0
		_clamp_scroll()
		queue_redraw()

	func _clamp_scroll() -> void:
		scroll = clampf(scroll, 0.0, maxf(0.0, content_height() - size.y))

	func _draw() -> void:
		if rows.is_empty():
			var font := UI.font()
			var text := UI.t("empty")
			var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x
			draw_string(font, Vector2((size.x - width) * 0.5, 50.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, UI.TEXT_3)
			return
		var layout := _layout()
		var first := maxi(0, int(scroll / (layout.z + GAP)) * int(layout.x))
		var font := UI.font()
		for p in range(first, rows.size()):
			var rect := card_rect(p)
			if rect.position.y > size.y:
				break
			var row := rows[p]
			draw_style_box(UI.box(UI.TILE_HOVER if p == _hover else UI.TILE, 10), rect)
			var picture := Rect2(rect.position + Vector2(5, 5), Vector2(rect.size.x - 10, rect.size.y - FOOTER - 10))
			draw_style_box(UI.box(UI.WELL, 7), picture)
			paint_row.call(self, picture, describe.call(row))
			if mistakes.has(row):
				draw_circle(picture.position + Vector2(picture.size.x - 10, 10), 4.0, UI.CORAL)
			if p == current:
				var ring := UI.box(Color.TRANSPARENT, 10)
				ring.set_border_width_all(2)
				ring.border_color = UI.VIOLET
				draw_style_box(ring, rect)
			var foot := rect.end.y - 8.0
			draw_string(font, Vector2(rect.position.x + 9, foot), "#%04d" % row, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, UI.TEXT_3)
			draw_string(font, Vector2(rect.end.x - 18, foot + 1), "×", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, UI.TEXT_3)
		var height := content_height()
		if height > size.y:
			var track := size.y - 8.0
			var knob := maxf(24.0, track * size.y / height)
			var top := 4.0 + (track - knob) * scroll / (height - size.y)
			draw_style_box(UI.box(Color(UI.INK, 0.18), 3), Rect2(size.x - 7, top, 4, knob))

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed:
			if event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
				scroll += 60.0 * (1.0 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1.0)
				_clamp_scroll()
				queue_redraw()
				accept_event()
			elif event.button_index == MOUSE_BUTTON_LEFT:
				var p := _card_at(event.position)
				if p >= 0:
					var rect := card_rect(p)
					if Rect2(rect.end - Vector2(26, FOOTER + 2), Vector2(24, FOOTER)).has_point(event.position):
						delete_requested.emit(rows[p])
					else:
						picked.emit(p)
					accept_event()
		elif event is InputEventMouseMotion:
			var p := _card_at(event.position)
			if p != _hover:
				_hover = p
				queue_redraw()

	func _card_at(at: Vector2) -> int:
		var layout := _layout()
		var line := int((at.y + scroll - 2.0) / (layout.z + GAP))
		var column := int((at.x - PAD) / (layout.y + GAP))
		if at.x < PAD or column >= int(layout.x):
			return -1
		var p := line * int(layout.x) + column
		if p < 0 or p >= rows.size() or not card_rect(p).has_point(at):
			return -1
		return p

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			_clamp_scroll()
		elif what == NOTIFICATION_MOUSE_EXIT and _hover != -1:
			_hover = -1
			queue_redraw()


## A control that draws a callable: the situations' profile bars, the preview.
class Painted extends Control:
	var paint: Callable

	func _init(painter: Callable = Callable()) -> void:
		paint = painter
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		if paint.is_valid():
			paint.call(self)
