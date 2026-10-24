extends Control
const S = preload("res://scripts/language_models/language_style.gd")
const TokenText = preload("res://scripts/language_models/token_text.gd")
# ColorBrewer YlGn; the same 256 samples shown in palette option 2.
# Attribution and licence: docs/licenses/ColorBrewer.txt.
const DEPTH_PALETTE = preload("res://resources/language_models/ylgn.tres")
const CANVAS_DIM := 154.0
signal token_selected(position: int)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS

var preview: Dictionary = {}
var selected_position := -1
var _alpha: Dictionary = {}
var _labels: Dictionary = {}
var _z_range := Vector2(-1, 1)
var _display_points: Array = []
var _render_items: Array = []
var _view_center := Vector2.ZERO
var _view_scale := 1.0
var _words_regex: RegEx
var _width_cache: Dictionary = {}

func _cached_text_size(text: String, font_size: int) -> Vector2:
	var key := "%d:%s" % [font_size, text]
	if _width_cache.has(key):
		return _width_cache[key]
	var sz := S.FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	_width_cache[key] = sz
	return sz

func _trim_to_width(txt: String, max_w: float, font_size: int = 10) -> String:
	if max_w <= 0.0:
		return ""
	var full_sz := _cached_text_size(txt, font_size)
	if full_sz.x <= max_w:
		return txt
	var ell := "…"
	var ell_sz := _cached_text_size(ell, font_size)
	if ell_sz.x > max_w:
		return ""
	var target_w := max_w - ell_sz.x
	var low := 1
	var high := txt.length()
	var best := 0
	while low <= high:
		var mid := (low + high) / 2
		var sub := txt.substr(0, mid)
		var w := _cached_text_size(sub, font_size).x
		if w <= target_w:
			best = mid
			low = mid + 1
		else:
			high = mid - 1
	if best <= 0:
		return ell
	return txt.substr(0, best) + ell

func set_preview(value: Dictionary) -> void:
	preview = value
	_z_range = Vector2(-1, 1)
	var depth_range: Array = preview.get("z_range", [-1.0, 1.0])
	if depth_range.size() == 2 and is_finite(float(depth_range[0])) and is_finite(float(depth_range[1])) and float(depth_range[1]) > float(depth_range[0]):
		_z_range = Vector2(float(depth_range[0]), float(depth_range[1]))

	var raw_points: Array = preview.get("points", [])
	var tokens: Array = preview.get("tokens", [])
	var source := str(preview.get("source_text", ""))

	if bool(preview.get("points_are_words",false)):
		_display_points=raw_points.duplicate(true)
	elif not tokens.is_empty() and not source.is_empty():
		if _words_regex == null:
			_words_regex = RegEx.new()
			_words_regex.compile("[a-zA-Zа-яА-ЯёЁӘәҒғҚқҢңӨөҰұҮүҺһІі0-9]+")
		var spans := _words_regex.search_all(source)
		var disp: Array = []
		var tok_idx := 0
		var tok_count := tokens.size()
		var pts_count := raw_points.size()
		for span in spans:
			var span_start := span.get_start()
			var span_end := span.get_end()
			var span_text := span.get_string()
			while tok_idx < tok_count:
				var e_val := int(tokens[tok_idx].get("end", tokens[tok_idx].get("start", 0) + 1))
				if e_val <= span_start:
					tok_idx += 1
				else:
					break
			var scan_idx := tok_idx
			var count_matched := 0
			var avg_x := 0.0
			var avg_y := 0.0
			var avg_z := 0.0
			var has_z := false
			var first_pt: Dictionary = {}
			var matched_positions: Array[int] = []
			while scan_idx < tok_count:
				var t_start := int(tokens[scan_idx].get("start", 0))
				var t_end := int(tokens[scan_idx].get("end", t_start + 1))
				if t_start >= span_end:
					break
				if t_end > span_start and scan_idx < pts_count:
					var pt: Dictionary = raw_points[scan_idx]
					if count_matched == 0:
						first_pt = pt
					count_matched += 1
					matched_positions.append(int(pt.get("position", scan_idx)))
					avg_x += float(pt.get("x", 0.0))
					avg_y += float(pt.get("y", 0.0))
					if pt.has("z") and is_finite(float(pt.z)):
						avg_z += float(pt.z)
						has_z = true
				scan_idx += 1
			if count_matched > 0:
				var inv_n := 1.0 / float(count_matched)
				var word_pt := {
					"position": first_pt.get("position", 0),
					"positions": matched_positions,
					"piece": span_text,
					"x": avg_x * inv_n,
					"y": avg_y * inv_n,
					"id": first_pt.get("id", 0),
					"vector": first_pt.get("vector", [])
				}
				if has_z:
					word_pt["z"] = avg_z * inv_n
				disp.append(word_pt)
		if disp.is_empty():
			var raw_disp: Array = []
			for idx in range(raw_points.size()):
				var pt_copy: Dictionary = raw_points[idx].duplicate(true)
				pt_copy["positions"] = [int(pt_copy.get("position", idx))]
				raw_disp.append(pt_copy)
			_display_points = raw_disp
		else:
			_display_points = disp
	else:
		var raw_disp: Array = []
		for idx in range(raw_points.size()):
			var pt_copy: Dictionary = raw_points[idx].duplicate(true)
			pt_copy["positions"] = [int(pt_copy.get("position", idx))]
			raw_disp.append(pt_copy)
		_display_points = raw_disp

	_fit_view()
	_rebuild_render_items()
	_measure()
	for item in _render_items:
		if not _alpha.has(item.position_id): _alpha[item.position_id] = 0.0
	queue_redraw()

func _rebuild_render_items() -> void:
	_render_items.clear()
	var area := Rect2(Vector2.ZERO, Vector2(CANVAS_DIM, CANVAS_DIM))
	var occupied: Array[Rect2] = []
	var seen_coords: Dictionary = {}
	var min_x := 3.0
	var max_x := CANVAS_DIM - 3.0
	var gap_x := 7.0
	var offset_y := 13.0

	for point in _display_points:
		var p := _point(point)
		if not area.has_point(p): continue
		var full_text := _label(point)
		var dedup_key := "%d:%d:%s" % [roundi(p.x * 2.0), roundi(p.y * 2.0), full_text]
		var pt_positions: Array = point.get("positions", [point.get("position", 0)])
		if seen_coords.has(dedup_key):
			var existing_item: Dictionary = seen_coords[dedup_key]
			for pos in pt_positions:
				if not existing_item.positions.has(pos):
					existing_item.positions.append(pos)
			continue
		var color := point_color(point)
		var full_size := _cached_text_size(full_text, 10)
		var space_right := maxf(0.0, max_x - (p.x + gap_x))
		var space_left := maxf(0.0, (p.x - gap_x) - min_x)

		# Smart placement:
		# If it doesn't fit on left -> put on right; if not on right -> put on left.
		# If it fits neither side -> trim with "…" in the direction it faces (more space).
		var prefer_right := (space_right >= space_left)
		var primary_side := "right" if prefer_right else "left"
		var alternate_side := "left" if prefer_right else "right"

		var chosen_text := full_text
		var chosen_bounds := Rect2()
		var chosen_overlaps := false
		var placed := false

		# Step 1: Try placing the full text cleanly on primary side, then alternate side
		for side in [primary_side, alternate_side]:
			var avail := space_right if side == "right" else space_left
			if full_size.x <= avail:
				var b := Rect2(p + Vector2(gap_x, -offset_y), full_size) if side == "right" else Rect2(p - Vector2(full_size.x + gap_x, offset_y), full_size)
				var coll := false
				for box in occupied:
					if b.intersects(box):
						coll = true
						break
				if not coll:
					chosen_text = full_text
					chosen_bounds = b
					chosen_overlaps = false
					placed = true
					break

		# A centered point leaves only half the canvas on either side. A long
		# name can use a centered row above/below it, including the whole width.
		if not placed:
			var tr := _trim_to_width(full_text, max_x-min_x, 10)
			var tr_sz := _cached_text_size(tr,10)
			for shift in [-offset_y, 8.0, -offset_y-14.0, 22.0]:
				var b := Rect2(Vector2(clampf(p.x-tr_sz.x*0.5,min_x,max_x-tr_sz.x),p.y+shift),tr_sz)
				if not area.encloses(b): continue
				var coll := false
				for box in occupied:
					if b.grow(1).intersects(box): coll=true; break
				if coll: continue
				chosen_text=tr
				chosen_bounds=b
				placed=true
				break

		# Step 2: If full text cannot fit cleanly on either side without collision/overflow,
		# trim with "…" in the direction it faces
		if not placed:
			for side in [primary_side, alternate_side]:
				var avail := space_right if side == "right" else space_left
				var tr := _trim_to_width(full_text, avail, 10)
				if tr.is_empty():
					continue
				var tr_sz := _cached_text_size(tr, 10)
				var b := Rect2(p + Vector2(gap_x, -offset_y), tr_sz) if side == "right" else Rect2(p - Vector2(tr_sz.x + gap_x, offset_y), tr_sz)
				var coll := false
				for box in occupied:
					if b.intersects(box):
						coll = true
						break
				if not coll:
					chosen_text = tr
					chosen_bounds = b
					chosen_overlaps = false
					placed = true
					break

		# Keep the true point fixed. Crowded labels can use nearby vertical slots,
		# without adding connecting lines between labels and points.
		if not placed:
			for distance in range(1, 12):
				if placed: break
				for direction in [-1, 1]:
					if placed: break
					for side in [primary_side, alternate_side]:
						var avail := space_right if side == "right" else space_left
						var tr := _trim_to_width(full_text, avail, 10)
						if tr.is_empty(): continue
						var tr_sz := _cached_text_size(tr, 10)
						var b := Rect2(p + Vector2(gap_x, -offset_y), tr_sz) if side == "right" else Rect2(p - Vector2(tr_sz.x + gap_x, offset_y), tr_sz)
						b.position.y += direction * distance * 14.0
						if not area.encloses(b): continue
						var coll := false
						for box in occupied:
							if b.grow(1).intersects(box): coll = true; break
						if coll: continue
						chosen_text = tr
						chosen_bounds = b
						placed = true
						break
		# If the plot is genuinely full, retain the point and its tooltip; selection
		# can reveal this one label without making every label overlap.
		if not placed:
			var avail := space_right if primary_side == "right" else space_left
			var tr := _trim_to_width(full_text, avail, 10)
			var tr_sz := _cached_text_size(tr, 10)
			var b := Rect2(p + Vector2(gap_x, -offset_y), tr_sz) if primary_side == "right" else Rect2(p - Vector2(tr_sz.x + gap_x, offset_y), tr_sz)
			chosen_text = tr
			chosen_bounds = b
			chosen_overlaps = true

		if not chosen_overlaps: occupied.append(chosen_bounds)
		var item: Dictionary = {
			"pos": p,
			"position_id": point.get("position", 0),
			"positions": pt_positions.duplicate(),
			"color": color,
			"text": chosen_text,
			"full_text": full_text,
			"label_pos": chosen_bounds.position + Vector2(0, 10),
			"label_bounds": chosen_bounds,
			"show_label": not chosen_overlaps
		}
		seen_coords[dedup_key] = item
		_render_items.append(item)

func clear_preview() -> void:
	_view_center = Vector2.ZERO
	_view_scale = 1.0
	_z_range = Vector2(-1, 1)
	preview = {}
	selected_position = -1
	_alpha.clear()
	_labels.clear()
	_display_points.clear()
	_render_items.clear()
	_measure()
	queue_redraw()

func select_position(value: int) -> void:
	if selected_position == value: return
	selected_position = value
	token_selected.emit(value)
	queue_redraw()

func _fit_view() -> void:
	# A single camera translation and uniform zoom uses the canvas without
	# changing pairwise angles or relative distances between word vectors.
	_view_center = Vector2.ZERO
	_view_scale = 1.0
	if _display_points.is_empty(): return
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for point in _display_points:
		var p := Vector2(float(point.get("x", 0)), float(point.get("y", 0)))
		low = low.min(p)
		high = high.max(p)
	_view_center = (low + high) * 0.5
	var extent := maxf(high.x - low.x, high.y - low.y) * 0.5
	if extent > 0.000001: _view_scale = 1.0 / extent

func _point(value: Dictionary) -> Vector2:
	var center := Vector2(CANVAS_DIM * 0.5, CANVAS_DIM * 0.5)
	var p := (Vector2(float(value.get("x", 0)), float(value.get("y", 0))) - _view_center) * _view_scale
	return center + Vector2(p.x, -p.y) * (CANVAS_DIM * 0.5 - 20.0)

func _label(point: Dictionary) -> String:
	var piece := str(point.get("piece", ""))
	return piece.strip_edges()

func point_color(point: Dictionary) -> Color:
	if not point.has("z") or not is_finite(float(point.z)):
		return S.ACCENT
	return _depth_color(clampf(inverse_lerp(_z_range.x, _z_range.y, float(point.z)), 0.0, 1.0))

func _depth_color(t: float) -> Color:
	return DEPTH_PALETTE.sample(clampf(t, 0.0, 1.0))

func _measure() -> void:
	minimum_size_changed.emit()

func content_size() -> Vector2:
	return Vector2(CANVAS_DIM, CANVAS_DIM)

func advance_reveal(delta: float, available: Vector2) -> void:
	var any_changed := false
	for item in _render_items:
		var p: Vector2 = item.pos
		if p.x + 4 <= available.x and p.y + 4 <= available.y:
			var pos_id = item.position_id
			var cur_alpha: float = _alpha.get(pos_id, 0.0)
			if cur_alpha < 0.999:
				var new_alpha := lerpf(cur_alpha, 1.0, minf(1, delta * 15.0))
				if new_alpha >= 0.995: new_alpha = 1.0
				_alpha[pos_id] = new_alpha
				any_changed = true
	if any_changed:
		queue_redraw()

func is_revealing() -> bool:
	for item in _render_items:
		if _alpha.get(item.position_id, 0.0) < 0.995: return true
	return false

func is_mouse_over_interactive() -> bool:
	var local_m := get_local_mouse_position()
	for item in _render_items:
		if item.pos.distance_to(local_m) <= 12.0:
			return true
	return false

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var pos: Vector2 = event.position
		for item in _render_items:
			if item.pos.distance_to(pos) <= 12.0:
				select_position(item.position_id)
				token_selected.emit(item.position_id)
				accept_event()
				return
		if selected_position != -1:
			select_position(-1)
			token_selected.emit(-1)
			accept_event()

func _draw() -> void:
	var area := Rect2(Vector2.ZERO, Vector2(CANVAS_DIM, CANVAS_DIM))
	var center := Vector2(CANVAS_DIM * 0.5, CANVAS_DIM * 0.5)
	var plot_radius := CANVAS_DIM * 0.5 - 20.0

	# Coordinate grid subdivisions
	var grid_color := Color(S.MUTED, 0.12)
	var axis_color := Color(S.MUTED, 0.28)
	var divisions: Array[float] = [-1.0, -0.5, 0.5, 1.0]
	for frac in divisions:
		var gx: float = center.x + frac * plot_radius
		var gy: float = center.y + frac * plot_radius
		draw_line(Vector2(gx, area.position.y), Vector2(gx, area.end.y), grid_color, 1.0, true)
		draw_line(Vector2(area.position.x, gy), Vector2(area.end.x, gy), grid_color, 1.0, true)

	# Main center axes
	draw_line(Vector2(area.position.x, center.y), Vector2(area.end.x, center.y), axis_color, 1.0, true)
	draw_line(Vector2(center.x, area.position.y), Vector2(center.x, area.end.y), axis_color, 1.0, true)

	var pt_radius := 4.5
	var has_sel := (selected_position != -1)
	var tokens: Array = preview.get("tokens", [])
	var source := str(preview.get("source_text", ""))
	var sel_word := ""
	if has_sel and not tokens.is_empty() and selected_position >= 0 and selected_position < tokens.size():
		var sel_tok: Dictionary = tokens[selected_position]
		var sel_start := int(sel_tok.get("start", 0))
		var sel_end := int(sel_tok.get("end", sel_start + 1))
		if _words_regex != null and not source.is_empty():
			for span in _words_regex.search_all(source):
				if sel_end > span.get_start() and sel_start < span.get_end():
					sel_word = span.get_string()
					break
		if sel_word.is_empty():
			var piece := str(sel_tok.get("piece", "")).strip_edges()
			if _words_regex != null:
				var m := _words_regex.search(piece)
				if m != null: sel_word = m.get_string()
			if sel_word.is_empty(): sel_word = piece

	for item in _render_items:
		var p: Vector2 = item.pos
		var is_selected: bool = false
		if has_sel:
			if item.position_id == selected_position:
				is_selected = true
			elif item.has("positions") and item.positions.has(selected_position):
				is_selected = true
			elif not sel_word.is_empty() and (item.text == sel_word or item.get("full_text", "") == sel_word):
				is_selected = true

		var mult: float = 1.0 if not has_sel else (1.0 if is_selected else 0.2)
		var alpha: float = _alpha.get(item.position_id, 1.0) * mult
		var color: Color = item.color.lightened(0.2) if is_selected else item.color
		var pt_color := Color(color, alpha)

		# Outer stroke for visibility against dark canvas
		var cur_radius: float = pt_radius + 1.5 if is_selected else pt_radius
		draw_circle(p, cur_radius + 1.0, Color(0.08, 0.1, 0.15, alpha))
		draw_circle(p, cur_radius, pt_color)
		if is_selected:
			draw_arc(p, cur_radius + 2.5, 0, TAU, 16, Color(color, 0.9), 1.5, true)
		if item.show_label or is_selected:
			draw_string(S.FONT, item.label_pos, item.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 10, pt_color)

func _get_tooltip(at: Vector2) -> String:
	for point in _display_points:
		if _point(point).distance_to(at) < 12:
			var values: Array = point.get("vector", [])
			var axis := S.localized("Axis 3", "Ось 3", "3-ось") if preview.get("points_are_words", false) else "PC3"
			var depth: String = "\n%s: %.3f" % [axis, float(point.z)] if point.has("z") and is_finite(float(point.z)) else ""
			return "%s · #%d%s\n%s" % [_label(point), point.id, depth, str(values)]
	return ""
