extends Control
const S = preload("res://scripts/language_models/language_style.gd")
const Layout = preload("res://scripts/language_models/language_layout.gd")
const DEPTH_PALETTE = preload("res://resources/language_models/ylgn.tres")
var preview: Dictionary = {}
var word_mode = true
var selected_position = -1
var _alpha: Dictionary = {}
signal token_selected(position: int)
signal window_requested(delta: int)

var _words_regex: RegEx
var _cached_groups: Array = []
var _cached_display_matrix: Array = []
var _cached_labels: Array = []
var _cached_geometry: Dictionary = {}
var _cache_valid = false
var _matrix_texture: ImageTexture
var _global_reveal_alpha: float = 0.0

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	_words_regex = RegEx.new()
	_words_regex.compile("[a-zA-Zа-яА-ЯёЁӘәҒғҚқҢңӨөҰұҮүҺһІі]+")

var _prev_content_size := Vector2.ZERO

func set_preview(value: Dictionary) -> void:
	preview = value
	_recompute_cache()
	var count = _cached_display_matrix.size()
	if count <= 8:
		for r in count:
			for c in count:
				var key = Vector2i(c, r)
				if not _alpha.has(key):
					_alpha[key] = 0.0
		for key in _alpha.keys():
			if key.x >= count or key.y >= count: _alpha.erase(key)
	else:
		_alpha.clear()
		_global_reveal_alpha = 1.0
	var cur_size := content_size()
	if cur_size != _prev_content_size:
		_prev_content_size = cur_size
		minimum_size_changed.emit()
	queue_redraw()

func clear_preview() -> void:
	preview = {}
	_alpha.clear()
	_global_reveal_alpha = 0.0
	_matrix_texture = null
	_recompute_cache()
	var cur_size := content_size()
	if cur_size != _prev_content_size:
		_prev_content_size = cur_size
		minimum_size_changed.emit()
	queue_redraw()

func set_word_mode(value: bool) -> void:
	if word_mode == value: return
	word_mode = value
	_recompute_cache()
	queue_redraw()

func set_window(start: int, _count: int) -> void:
	preview.start = start
	_recompute_cache()
	queue_redraw()

func select_position(value: int) -> void:
	selected_position = value
	queue_redraw()

var _width_cache: Dictionary = {}
var _color_lut: PackedInt32Array = PackedInt32Array()
var _prev_groups_keys: PackedStringArray = PackedStringArray()
var _prev_disp_prefix: Array = []
var _prev_u32_rows: Array = []
var _prev_sig: int = -1
var _zero_disp_row: Array = []

func _ensure_color_lut() -> void:
	if not _color_lut.is_empty():
		return
	_color_lut.resize(256)
	var bg_color := Color(0.08, 0.1, 0.15)
	for idx in 256:
		var t := float(idx) / 255.0
		var col: Color
		if idx == 0:
			col = bg_color
		else:
			var pal_col: Color = DEPTH_PALETTE.sample(clampf(1.0 - t, 0.0, 1.0))
			col = bg_color.lerp(pal_col, minf(1.0, 0.35 + t * 0.65))
		var r_b := clampi(int(roundf(col.r * 255.0)), 0, 255)
		var g_b := clampi(int(roundf(col.g * 255.0)), 0, 255)
		var b_b := clampi(int(roundf(col.b * 255.0)), 0, 255)
		_color_lut[idx] = r_b | (g_b << 8) | (b_b << 16) | (255 << 24)

func _recompute_cache() -> void:
	_ensure_color_lut()
	var tokens: Array = preview.get("tokens", [])
	var matrix: Array = preview.get("matrix", [])
	var start = int(preview.get("start", 0))
	var groups: Array = []
	var source = str(preview.get("source_text", ""))
	if _words_regex == null:
		_words_regex = RegEx.new()
		_words_regex.compile("[a-zA-Zа-яА-ЯёЁӘәҒғҚқҢңӨөҰұҮүҺһІі]+")
	var spans = _words_regex.search_all(source) if not source.is_empty() else []
	var span_idx := 0
	var span_count := spans.size()
	var mat_size := matrix.size()
	var tok_size := tokens.size()
	for i in mat_size:
		var index = start + i
		if index >= tok_size: break
		var token: Dictionary = tokens[index]
		var label := ""
		var key := ""
		if span_count > 0:
			var end = int(token.get("end", index + 1))
			while span_idx < span_count and spans[span_idx].get_end() < end:
				span_idx += 1
			if span_idx < span_count:
				var span = spans[span_idx]
				if end > span.get_start() and end <= span.get_end():
					key = str(span_idx)
					label = span.get_string()
			if key.is_empty():
				continue
		else:
			label = str(token.get("piece", "")).strip_edges()
			var matched = _words_regex.search(label)
			if matched == null or matched.get_string().is_empty():
				continue
			key = str(token.get("start", index)) + ":" + str(token.get("end", index + 1))
			label = matched.get_string()

		if word_mode and not groups.is_empty() and groups[-1].key == key:
			groups[-1].indices.append(i)
		else:
			groups.append({"key": key, "label": label, "indices": [i]})
	_cached_groups = groups

	var count := groups.size()
	var lbls: Array = []
	lbls.resize(count)
	var k_start := PackedInt32Array()
	var k_end := PackedInt32Array()
	k_start.resize(count)
	k_end.resize(count)
	var cur_keys := PackedStringArray()
	cur_keys.resize(count)
	for g_i in count:
		var g: Dictionary = groups[g_i]
		lbls[g_i] = g.label
		var idxs: Array = g.indices
		var i0 := int(idxs[0])
		var i1 := int(idxs[-1])
		k_start[g_i] = i0
		k_end[g_i] = i1
		cur_keys[g_i] = "%s:%d:%d" % [str(g.key), i0, i1]
	_cached_labels = lbls

	if count == 0:
		_cached_display_matrix = []
		_cache_valid = true
		_cached_geometry = _calc_geometry(0)
		_matrix_texture = null
		_prev_groups_keys.clear()
		_prev_disp_prefix.clear()
		_prev_u32_rows.clear()
		return

	if _zero_disp_row.size() < count:
		_zero_disp_row.resize(maxi(256, count))
		_zero_disp_row.fill(0.0)

	var raw: Array = matrix
	var sig: int = hash(matrix)

	var reuse_len := 0
	if sig == _prev_sig:
		var max_reuse := mini(count, _prev_groups_keys.size())
		while reuse_len < max_reuse and cur_keys[reuse_len] == _prev_groups_keys[reuse_len]:
			reuse_len += 1

	var disp: Array = []
	disp.resize(count)
	var new_disp_prefix: Array = []
	new_disp_prefix.resize(count)
	var new_u32_rows: Array = []
	new_u32_rows.resize(count)

	var img := Image.create(count, count, false, Image.FORMAT_RGBA8)
	img.fill(Color.TRANSPARENT)
	var bytes := img.get_data()

	for r in range(reuse_len):
		var pref: Array = _prev_disp_prefix[r]
		new_disp_prefix[r] = pref
		var pad := count - (r + 1)
		disp[r] = pref + _zero_disp_row.slice(0, pad) if pad > 0 else pref.duplicate()
		var u32_row: PackedInt32Array = _prev_u32_rows[r]
		new_u32_rows[r] = u32_row
		var row_offset := r * count * 4
		for c in range(r + 1):
			bytes.encode_u32(row_offset + c * 4, u32_row[c])

	var summed := PackedFloat32Array()
	summed.resize(mat_size)

	for r in range(reuse_len, count):
		var q0 := k_start[r]
		var q1 := k_end[r]
		var q_len := q1 - q0 + 1
		var inv_q := 1.0 / float(q_len)
		var pref: Array = []
		pref.resize(r + 1)
		var u32_row := PackedInt32Array()
		u32_row.resize(r + 1)
		var row_offset := r * count * 4
		if q_len == 1:
			var rq0: Array = raw[q0]
			for c in range(r + 1):
				var kc0 := k_start[c]
				var kc1 := k_end[c]
				var v := float(rq0[kc0])
				if kc1 > kc0:
					v += float(rq0[kc0 + 1])
					if kc1 > kc0 + 1:
						for k_extra in range(kc0 + 2, kc1 + 1):
							v += float(rq0[k_extra])
				pref[c] = v
				var lut_idx := clampi(int(sqrt(maxf(0.0, v)) * 255.0), 0, 255)
				var col_u32 := _color_lut[lut_idx]
				u32_row[c] = col_u32
				bytes.encode_u32(row_offset + c * 4, col_u32)
		elif q_len == 2:
			var rq0: Array = raw[q0]
			var rq1: Array = raw[q1]
			for c in range(r + 1):
				var kc0 := k_start[c]
				var kc1 := k_end[c]
				var sum_v := float(rq0[kc0]) + float(rq1[kc0])
				if kc1 > kc0:
					sum_v += float(rq0[kc0 + 1]) + float(rq1[kc0 + 1])
					if kc1 > kc0 + 1:
						for k_extra in range(kc0 + 2, kc1 + 1):
							sum_v += float(rq0[k_extra]) + float(rq1[k_extra])
				var v := sum_v * 0.5
				pref[c] = v
				var lut_idx := clampi(int(sqrt(maxf(0.0, v)) * 255.0), 0, 255)
				var col_u32 := _color_lut[lut_idx]
				u32_row[c] = col_u32
				bytes.encode_u32(row_offset + c * 4, col_u32)
		else:
			var rq0: Array = raw[q0]
			for k_i in range(q1 + 1):
				summed[k_i] = float(rq0[k_i])
			for qi in range(q0 + 1, q1 + 1):
				var rqi: Array = raw[qi]
				for k_i in range(q1 + 1):
					summed[k_i] += float(rqi[k_i])
			for c in range(r + 1):
				var kc0 := k_start[c]
				var kc1 := k_end[c]
				var sum_v := 0.0
				for k_i in range(kc0, mini(kc1 + 1, q1 + 1)):
					sum_v += summed[k_i]
				var v := sum_v * inv_q
				pref[c] = v
				var lut_idx := clampi(int(sqrt(maxf(0.0, v)) * 255.0), 0, 255)
				var col_u32 := _color_lut[lut_idx]
				u32_row[c] = col_u32
				bytes.encode_u32(row_offset + c * 4, col_u32)
		new_disp_prefix[r] = pref
		new_u32_rows[r] = u32_row
		var pad := count - (r + 1)
		disp[r] = pref + _zero_disp_row.slice(0, pad) if pad > 0 else pref.duplicate()

	_prev_sig = sig
	_prev_groups_keys = cur_keys
	_prev_disp_prefix = new_disp_prefix
	_prev_u32_rows = new_u32_rows
	_cached_display_matrix = disp
	_cache_valid = true
	_cached_geometry = _calc_geometry(count)

	var final_img := Image.create_from_data(count, count, false, Image.FORMAT_RGBA8, bytes)
	_matrix_texture = ImageTexture.create_from_image(final_img)

func _groups() -> Array:
	if not _cache_valid: _recompute_cache()
	return _cached_groups

func labels() -> Array:
	if not _cache_valid: _recompute_cache()
	return _cached_labels

func display_matrix() -> Array:
	if not _cache_valid: _recompute_cache()
	return _cached_display_matrix

static func _format_label(name: Variant) -> String:
	var text := str(name)
	if text.length() > 14:
		text = text.left(13) + "…"
	return text

func _label_width(name: Variant) -> float:
	var text := _format_label(name)
	if _width_cache.has(text):
		return float(_width_cache[text])
	var w := minf(S.FONT.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x, 76.0)
	_width_cache[text] = w
	return w

func _calc_geometry(count: int) -> Dictionary:
	var maximum = 0.0
	for name in _cached_labels:
		var w := _label_width(name)
		maximum = maxf(maximum, w)
	maximum = minf(maximum, 76.0)
	var cell: float = Layout.step().x
	return {
		"cell": cell,
		"origin": Vector2(ceilf(maximum) + 6.0, 0.0),
		"grid_size": maxf(0.0, count * cell - Layout.grid_gap()),
		"label_extent": (ceilf(maximum / sqrt(2.0)) + 12.0) if maximum > 0.0 else 4.0
	}

func _geometry(count: int) -> Dictionary:
	if not _cache_valid: _recompute_cache()
	if count == _cached_display_matrix.size() and not _cached_geometry.is_empty():
		return _cached_geometry
	return _calc_geometry(count)

func content_size() -> Vector2:
	var count = display_matrix().size()
	var geometry = _calc_geometry(count)
	var right_pad = maxf(4.0, geometry.label_extent - Layout.step().x)
	return Vector2(geometry.origin.x + geometry.grid_size + right_pad, geometry.grid_size + geometry.label_extent)

func extent_for_count(target_count: int) -> Vector2:
	var geometry = _calc_geometry(target_count)
	var count = display_matrix().size()
	var grid_right: float = geometry.origin.x + geometry.grid_size
	var right_pad: float = 4.0

	if count > target_count:
		right_pad = 14.0
	elif count > 0:
		for c in range(count):
			if c < _cached_labels.size():
				var label_w: float = _label_width(_cached_labels[c])
				var label_right: float = geometry.origin.x + float(c) * geometry.cell + 3.0 + ceilf(label_w / sqrt(2.0))
				if label_right > grid_right:
					right_pad = maxf(right_pad, label_right - grid_right + 4.0)

	return Vector2(grid_right + right_pad, geometry.grid_size + geometry.label_extent)

func cell_alpha(key: Vector2i) -> float:
	if display_matrix().size() <= 8:
		return _alpha.get(key, 0.0)
	return _global_reveal_alpha

func advance_reveal(delta: float, available: Vector2) -> void:
	var count = display_matrix().size()
	if count == 0: return
	var geometry = _geometry(count)
	var any_changed = false
	if count <= 8:
		for key in _alpha:
			var end: Vector2 = geometry.origin + Vector2(key) * Layout.step() + Layout.unit_size()
			if end.x <= available.x and end.y <= available.y:
				var old_val: float = _alpha[key]
				if old_val < 0.999:
					var new_val = lerpf(old_val, 1.0, minf(1, delta * 15.0))
					if new_val >= 0.995: new_val = 1.0
					_alpha[key] = new_val
					any_changed = true
	else:
		if _global_reveal_alpha < 0.999:
			_global_reveal_alpha = lerpf(_global_reveal_alpha, 1.0, minf(1, delta * 15.0))
			if _global_reveal_alpha >= 0.995: _global_reveal_alpha = 1.0
			any_changed = true
	if any_changed:
		queue_redraw()

func is_revealing() -> bool:
	if display_matrix().size() <= 8:
		for value in _alpha.values():
			if value < 0.995: return true
		return false
	return _global_reveal_alpha < 0.995

func is_mouse_over_interactive() -> bool:
	return false

func _cell_at(at: Vector2) -> Vector2i:
	var count = display_matrix().size()
	if count == 0: return Vector2i(-1, -1)
	var geometry = _geometry(count)
	var cell: float = geometry.cell
	var local: Vector2 = at - geometry.origin
	if local.x < 0 or local.y < 0 or local.x >= geometry.grid_size or local.y >= geometry.grid_size: return Vector2i(-1, -1)
	return Vector2i(int(local.x / cell), int(local.y / cell))

func _get_tooltip(at: Vector2) -> String:
	var cell = _cell_at(at)
	if cell.x < 0: return ""
	var names = labels()
	return "%s → %s: %.1f%%" % [names[cell.y], names[cell.x], float(display_matrix()[cell.y][cell.x]) * 100]

func _draw() -> void:
	var matrix = display_matrix()
	var names = labels()
	var count = matrix.size()
	var grid_cols: int = maxi(8, count)
	var geometry = _calc_geometry(grid_cols)
	var cell: float = geometry.cell
	var origin: Vector2 = geometry.origin
	var unit := cell - Layout.grid_gap()
	var empty_bg := Color(0.08, 0.1, 0.15, 0.5)

	for r in grid_cols:
		for c in grid_cols:
			draw_rect(Rect2(origin.x + c * cell, origin.y + r * cell, unit, unit), empty_bg, true)

	if _matrix_texture != null and count > 0:
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		var actual_geom = _calc_geometry(count)
		var grid_rect = Rect2(origin, Vector2(actual_geom.grid_size, actual_geom.grid_size))
		var alpha = maxf(_global_reveal_alpha, cell_alpha(Vector2i(0, 0)))
		var draw_color := Color(1, 1, 1, maxf(alpha, 0.35)) if is_revealing() else Color.WHITE
		draw_texture_rect(_matrix_texture, grid_rect, false, draw_color)

	for r in count:
		var text := _format_label(names[r])
		var alpha_r = maxf(_global_reveal_alpha, cell_alpha(Vector2i(0, r)))
		draw_string(S.FONT, Vector2(0, origin.y + r * cell + 11), text, HORIZONTAL_ALIGNMENT_RIGHT, origin.x - 6, 9, Color(S.MUTED, maxf(alpha_r, 0.05)))
		draw_set_transform(Vector2(origin.x + r * cell + 3, origin.y + geometry.grid_size + 9), PI / 4)
		var alpha_c = maxf(_global_reveal_alpha, cell_alpha(Vector2i(r, 0)))
		draw_string(S.FONT, Vector2.ZERO, text, HORIZONTAL_ALIGNMENT_LEFT, 76, 9, Color(S.MUTED, maxf(alpha_c, 0.05)))
		draw_set_transform(Vector2.ZERO)

func _is_scrollbar_active() -> bool:
	var parent_scroll = get_parent()
	if parent_scroll is ScrollContainer:
		var v_bar = parent_scroll.get_v_scroll_bar()
		var h_bar = parent_scroll.get_h_scroll_bar()
		if is_instance_valid(v_bar) and v_bar.is_visible_in_tree() and v_bar.max_value > v_bar.page:
			return true
		if is_instance_valid(h_bar) and h_bar.is_visible_in_tree() and h_bar.max_value > h_bar.page:
			return true
	return false

func _scroll_window(delta: int) -> void:
	var total: int = int(preview.get("total", 0))
	var tokens: Array = preview.get("tokens", [])
	var max_total: int = maxi(total, tokens.size())
	var cur_start: int = int(preview.get("start", 0))
	var new_start: int = maxi(0, cur_start + delta)
	if max_total > 0 and new_start >= max_total:
		return
	if new_start != cur_start:
		preview.start = new_start
		_recompute_cache()
		queue_redraw()
		window_requested.emit(delta)

func _gui_input(_event: InputEvent) -> void:
	pass
