extends Control
const S = preload("res://scripts/language_models/language_style.gd")
const Layout = preload("res://scripts/language_models/language_layout.gd")
const TokenText = preload("res://scripts/language_models/token_text.gd")
const DEPTH_PALETTE = preload("res://resources/language_models/ylgn.tres")

signal token_selected(position: int)

class LightweightPill extends RefCounted:
	signal pressed
	var text: String = ""
	var position: Vector2 = Vector2.ZERO
	var size: Vector2 = Vector2.ZERO
	var id: int = 0
	var config: Variant = null
	func _init(t: String, p: Vector2, s: Vector2, i: int) -> void:
		text = t
		position = p
		size = s
		id = i
	func get_instance_shader_parameter(_param: String) -> Variant:
		return null

var preview: Dictionary = {}
var tokens: Array = []
var pills: Array = []
var editor: TextEdit
var overlay: Control
var selected_position: int = -1
var _token_rects: Array[Rect2] = []
var _editor_expansion: Vector2 = Vector2.ZERO

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	editor = S.token_editor()
	var style: StyleBoxFlat = editor.get_theme_stylebox("normal")
	_editor_expansion = Vector2(style.expand_margin_left, style.expand_margin_top)
	editor.position = _editor_expansion
	add_child(editor)

	overlay = Control.new()
	overlay.name = "Overlay"
	overlay.mouse_filter = Control.MOUSE_FILTER_PASS
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	editor.add_child(overlay)
	overlay.draw.connect(_on_overlay_draw)
	overlay.gui_input.connect(_on_overlay_gui_input)

func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		if is_instance_valid(editor):
			editor.size = size
			overlay.queue_redraw()

func content_size() -> Vector2:
	if not is_instance_valid(editor): return Vector2.ZERO
	var base_width: float = Layout.input_property("ColorRect", &"offset_right") - Layout.input_property("ColorRect", &"offset_left") - Layout.input_origin().x - Layout.input_padding().x
	var minimum_width: float = base_width * 3.0
	var measured := Layout.measure_text(editor, minimum_width)
	var line_h: float = float(editor.get_line_height()) if editor.get_line_height() > 0 else 14.0
	var stylebox := editor.get_theme_stylebox("normal")
	var margins_y: float = stylebox.get_minimum_size().y if stylebox != null else 8.0
	var base_height: float = line_h + margins_y
	var minimum_height: float = base_height * 3.0
	measured.y = maxf(measured.y, minimum_height)
	editor.size = measured
	return measured

func set_preview(value: Dictionary) -> void:
	preview = value
	var next: Array = value.get("tokens", [])
	tokens = next
	var source_text := str(value.get("source_text", ""))
	if source_text.is_empty() and not next.is_empty():
		for t in next:
			source_text += str(t.get("piece", ""))
	editor.text = source_text.replace("\t", "    ")
	custom_minimum_size = content_size()
	editor.size = custom_minimum_size
	size = custom_minimum_size
	_recompute_pills(source_text)
	overlay.queue_redraw()
	minimum_size_changed.emit()

func clear_preview() -> void:
	preview = {}
	tokens.clear()
	pills.clear()
	_token_rects.clear()
	selected_position = -1
	editor.text = ""
	custom_minimum_size = Vector2.ZERO
	overlay.queue_redraw()
	minimum_size_changed.emit()

func select_position(value: int) -> void:
	selected_position = value
	overlay.queue_redraw()

func _recompute_pills(text: String) -> void:
	pills.clear()
	if tokens.is_empty() or text.is_empty():
		return
	var grps: Array = TokenText.groups(tokens, text)
	for grp in grps:
		var tok_id: int = int(grp.ids[0]) if not grp.ids.is_empty() else 0
		var piece_vis: String = TokenText.visible(str(grp.piece))
		pills.append(LightweightPill.new(piece_vis, Vector2.ZERO, Vector2(20.0, 20.0), tok_id))

func _on_overlay_draw() -> void:
	if tokens.is_empty() or editor.text.is_empty():
		return

	var font: Font = editor.get_theme_font("font")
	var font_size: int = editor.get_theme_font_size("font_size")
	var stylebox := editor.get_theme_stylebox("normal")
	var margin_left: float = stylebox.content_margin_left if stylebox != null else 8.0
	var margin_top: float = stylebox.content_margin_top if stylebox != null else 4.0
	var line_height: float = float(editor.get_line_height()) if editor.get_line_height() > 0 else 14.0

	var all_rows: Array[Dictionary] = []
	var total_char_idx := 0
	var line_count := editor.get_line_count()
	for l in range(line_count):
		var wrapped := editor.get_line_wrapped_text(l)
		if wrapped.is_empty():
			all_rows.append({"text": "", "start": total_char_idx, "length": 0})
			total_char_idx += 1
		else:
			for w_idx in range(wrapped.size()):
				var row_str: String = wrapped[w_idx]
				var row_len: int = row_str.length()
				all_rows.append({"text": row_str, "start": total_char_idx, "length": row_len})
				total_char_idx += row_len
			total_char_idx += 1

	var points: Array = preview.get("points", [])
	var z_range: Array = preview.get("z_range", [-1.0, 1.0])
	var z_min := float(z_range[0]) if z_range.size() == 2 else -1.0
	var z_max := float(z_range[1]) if z_range.size() == 2 else 1.0
	var has_selection := (selected_position != -1)
	var word_token_colors := _compute_token_colors(z_min, z_max)

	_token_rects.clear()
	for i in range(tokens.size()):
		var t: Dictionary = tokens[i]
		var s_idx: int = int(t.get("start", -1))
		var e_idx: int = int(t.get("end", -1))
		if s_idx < 0:
			s_idx = total_char_idx
			e_idx = s_idx + str(t.get("piece", "")).length()

		var r_idx := 0
		while r_idx + 1 < all_rows.size() and all_rows[r_idx + 1].start <= s_idx:
			r_idx += 1

		var row_info: Dictionary = all_rows[r_idx] if r_idx < all_rows.size() else {"text": "", "start": 0, "length": 0}
		var row_str: String = str(row_info.get("text", ""))
		var row_start: int = int(row_info.get("start", 0))
		var row_len: int = int(row_info.get("length", 0))

		var c0: int = clampi(s_idx - row_start, 0, row_len)
		var c1: int = clampi(e_idx - row_start, 0, row_len)

		var tok_text := row_str.substr(c0, c1 - c0)
		var is_word := _is_word_token(tok_text)
		if not is_word:
			_token_rects.append(Rect2())
			continue

		var x_start := margin_left + font.get_string_size(row_str.substr(0, c0), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var x_end := margin_left + font.get_string_size(row_str.substr(0, c1), HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
		var width := maxf(4.0, x_end - x_start)
		var y_pos := margin_top + float(r_idx) * line_height
		var r := Rect2(Vector2(x_start, y_pos), Vector2(width, line_height))
		_token_rects.append(r)
		if i < pills.size():
			pills[i].position = r.position
			pills[i].size = r.size
		var is_selected := (i == selected_position)
		var tok_color: Color
		if word_token_colors.has(i):
			tok_color = word_token_colors[i]
		elif i < points.size() and points[i] is Dictionary and points[i].has("z") and is_finite(float(points[i].z)) and z_max > z_min:
			var z := float(points[i].get("z", 0.0))
			var t_val := clampf(inverse_lerp(z_min, z_max, z), 0.0, 1.0)
			tok_color = DEPTH_PALETTE.sample(t_val)
		else:
			tok_color = S.ACCENT

		var border_color: Color
		var fill_color: Color
		if is_selected:
			border_color = tok_color.lightened(0.25)
			border_color.a = 1.0
			fill_color = Color(tok_color, 0.28)
		elif has_selection:
			border_color = tok_color
			border_color.a = 0.20
			fill_color = Color(tok_color, 0.03)
		else:
			border_color = tok_color
			border_color.a = 0.88
			fill_color = Color(tok_color, 0.10)

		# 1px inset on left and right guarantees that adjacent token rectangles never touch or overlap
		var draw_box := Rect2(r.position.x + 1.0, r.position.y + 1.0, maxf(2.0, r.size.x - 2.0), maxf(2.0, r.size.y - 2.0))
		overlay.draw_rect(draw_box, fill_color, true)
		overlay.draw_rect(draw_box, border_color, false, 2.0 if is_selected else 1.0)

func is_mouse_over_interactive() -> bool:
	if not is_instance_valid(overlay) or not overlay.is_visible_in_tree():
		return false
	var local_mouse := overlay.get_local_mouse_position()
	for r in _token_rects:
		if r != Rect2() and r.has_point(local_mouse):
			return true
	return false

static var _word_regex: RegEx = null

static func _is_word_token(text: String) -> bool:
	if _word_regex == null:
		_word_regex = RegEx.new()
		_word_regex.compile("[a-zA-Z0-9а-яА-ЯёЁӘәҒғҚқҢңӨөҰұҮүҺһІі]")
	return _word_regex.search(text) != null

static var _words_regex: RegEx = null

func _compute_token_colors(z_min: float, z_max: float) -> Dictionary:
	var token_colors: Dictionary = {}
	var raw_points: Array = preview.get("points", [])
	var source_text := str(preview.get("source_text", ""))
	if source_text.is_empty() and not tokens.is_empty():
		for t in tokens:
			source_text += str(t.get("piece", ""))

	if not tokens.is_empty() and not source_text.is_empty():
		if _words_regex == null:
			_words_regex = RegEx.new()
			_words_regex.compile("[a-zA-Zа-яА-ЯёЁӘәҒғҚқҢңӨөҰұҮүҺһІі0-9]+")
		var spans := _words_regex.search_all(source_text)
		var tok_idx := 0
		var tok_count := tokens.size()
		var pts_count := raw_points.size()
		for span in spans:
			var span_start := span.get_start()
			var span_end := span.get_end()
			while tok_idx < tok_count:
				var e_val := int(tokens[tok_idx].get("end", tokens[tok_idx].get("start", 0) + 1))
				if e_val <= span_start:
					tok_idx += 1
				else:
					break
			var scan_idx := tok_idx
			var count_matched := 0
			var avg_z := 0.0
			var has_z := false
			var matched_token_indices: Array[int] = []
			while scan_idx < tok_count:
				var t_start := int(tokens[scan_idx].get("start", 0))
				var t_end := int(tokens[scan_idx].get("end", t_start + 1))
				if t_start >= span_end:
					break
				if t_end > span_start:
					matched_token_indices.append(scan_idx)
					if scan_idx < pts_count:
						var pt: Dictionary = raw_points[scan_idx]
						count_matched += 1
						if pt.has("z") and is_finite(float(pt.z)):
							avg_z += float(pt.z)
							has_z = true
				scan_idx += 1
			if not matched_token_indices.is_empty():
				var word_color: Color
				if has_z and count_matched > 0 and z_max > z_min:
					var final_z := avg_z / float(count_matched)
					var t_val := clampf(inverse_lerp(z_min, z_max, final_z), 0.0, 1.0)
					word_color = DEPTH_PALETTE.sample(t_val)
				else:
					word_color = S.ACCENT
				for idx in matched_token_indices:
					token_colors[idx] = word_color

	return token_colors

func _on_overlay_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var pos: Vector2 = event.position
		for i in range(_token_rects.size()):
			if _token_rects[i] != Rect2() and _token_rects[i].has_point(pos):
				select_position(i)
				token_selected.emit(i)
				accept_event()
				return
		if selected_position != -1:
			select_position(-1)
			token_selected.emit(-1)
			accept_event()
