extends Control
const S = preload("res://scripts/language_models/language_style.gd")
const TokenText = preload("res://scripts/language_models/token_text.gd")
var tokens: Array = []
var _groups: Array = []
var show_ids = true:
	set(value):
		show_ids = value
		_layout()
var selected_position = -1
var pills: Array[Control] = []
var _pill_pool: Array[Control] = []
var _scroll_offset=Vector2.ZERO
var _reveal_window=Rect2()
var _content_extent=Vector2.ZERO
var _pill_config: Resource
var _width_cache: Dictionary = {}
var _size_cache: Dictionary = {}
var _group_meta_cache: Dictionary = {}
var _label_font: Font
var _label_font_size: int = 32
var _last_layout_width = -1.0
var _last_selected_position = -1
const POOL_TARGET = 320
signal token_selected(position: int)

func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	resized.connect(_on_resized)
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_process(true)

func _process(_delta: float) -> void:
	var total = pills.size() + _pill_pool.size()
	if total >= POOL_TARGET:
		process_mode = Node.PROCESS_MODE_INHERIT
		set_process(false)
		return
	var batch = mini(16, POOL_TARGET - total)
	for _i in range(batch):
		var p = _alloc_pill()
		var rev: Control = p.get_parent()
		rev.visible = false
		_pill_pool.append(p)

func _on_resized() -> void:
	if absf(size.x - _last_layout_width) > 0.5:
		_layout()

func _ensure_group_meta(grp: Dictionary) -> String:
	var flag = 1 if show_ids else 0
	if grp.get("_key_flag", -1) != flag:
		var ids_str: String = grp.get("ids_str", "")
		if ids_str.is_empty():
			ids_str = TokenText.ids_text(grp.ids)
			grp["ids_str"] = ids_str
		var k = "%s|%s|%d" % [str(grp.piece), ids_str, flag]
		grp["key"] = k
		grp["_key_flag"] = flag
		if not _group_meta_cache.has(k):
			var piece = TokenText.visible(str(grp.piece))
			var w = maxf(30.0, _cached_font_width(S.FONT, piece, 11) + 18.0)
			if show_ids:
				w = maxf(w, _cached_font_width(S.FONT, ids_str, 11) + 18.0)
			if _label_font == null:
				_label_font = S.THEME.default_font
			var full_sz = _cached_font_size(_label_font if _label_font != null else S.FONT, piece, _label_font_size)
			_group_meta_cache[k] = {
				"piece": piece,
				"ids": ids_str,
				"raw_w": w,
				"tooltip": "%s · ID %s" % [piece, ids_str],
				"full_sz": full_sz
			}
		grp["_meta"] = _group_meta_cache[k]
	return str(grp["key"])

func _alloc_pill() -> Control:
	var reveal=Control.new()
	reveal.mouse_filter=Control.MOUSE_FILTER_IGNORE
	reveal.modulate.a=0.0
	add_child(reveal)
	var pill: Control = S.ACTION.instantiate()
	pill.auto_ready = false
	pill.auto_wrap = false
	pill.mouse_filter = Control.MOUSE_FILTER_PASS
	reveal.add_child(pill)
	pill.set_process(false)
	pill.process_mode = Node.PROCESS_MODE_DISABLED
	if _label_font == null:
		var lbl: Label = pill.get_node("Label")
		_label_font = lbl.get_theme_font("font")
		_label_font_size = lbl.get_theme_font_size("font_size")
	if _pill_config == null and pill.config != null:
		_pill_config = pill.config.duplicate()
		_pill_config._hover_scale = 1.0
		_pill_config._press_scale = 1.0
		_pill_config.animation_scale = 0.0
	if _pill_config != null:
		pill.config = _pill_config
	pill.custom_minimum_size=Vector2.ZERO
	var def_col = Color(S.ACCENT, 0.35)
	pill.set_meta("cached_outline", def_col)
	pill.set_instance_shader_parameter("outline_color", def_col)
	pill.pressed.connect(func():
		var idx: int = int(pill.get_meta("group_index", -1))
		if idx >= 0 and idx < _groups.size() and not _groups[idx].positions.is_empty():
			select_position(int(_groups[idx].positions[0]))
	)
	var number=S.label("",S.MUTED,8)
	number.name="TokenID"
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	number.position = Vector2(0, 18)
	number.process_mode = Node.PROCESS_MODE_DISABLED
	pill.add_child(number)
	pill.set_meta("token_id_label", number)
	return pill

func _create_pill() -> Control:
	if not _pill_pool.is_empty():
		var pooled: Control = _pill_pool.pop_back()
		var rev: Control = pooled.get_parent()
		rev.visible = true
		rev.modulate.a = 0.0
		return pooled
	return _alloc_pill()

func set_preview(value: Dictionary) -> void:
	var next: Array=value.get("tokens",[])
	var groups=TokenText.groups(next,str(value.get("source_text","")))
	tokens = next
	_groups = groups
	var group_count = _groups.size()
	for g_idx in range(group_count):
		_ensure_group_meta(_groups[g_idx])
	var old_count = pills.size()
	var prefix_len = 0
	while prefix_len < mini(old_count, group_count):
		if pills[prefix_len].get_meta("cached_key", "") != str(_groups[prefix_len]["key"]):
			break
		prefix_len += 1

	if prefix_len < old_count or prefix_len < group_count:
		var buckets: Dictionary = {}
		var spare: Array[Control] = []
		for i in range(prefix_len, old_count):
			var p: Control = pills[i]
			var k: String = str(p.get_meta("cached_key", ""))
			if not k.is_empty():
				if not buckets.has(k):
					buckets[k] = []
				buckets[k].append(p)
			else:
				spare.append(p)

		var remaining_pool: Array[Control] = []
		for p in _pill_pool:
			var k: String = str(p.get_meta("cached_key", ""))
			if not k.is_empty():
				if not buckets.has(k):
					buckets[k] = []
				buckets[k].append(p)
			else:
				remaining_pool.append(p)
		_pill_pool = remaining_pool

		var new_tail: Array[Control] = []
		var unmatched_indices: Array[int] = []
		new_tail.resize(maxi(0, group_count - prefix_len))
		for offset in range(group_count - prefix_len):
			var g_idx = prefix_len + offset
			var k = str(_groups[g_idx]["key"])
			if buckets.has(k) and not buckets[k].is_empty():
				var matched_pill: Control = buckets[k].pop_front()
				var rev: Control = matched_pill.get_parent()
				if not rev.visible:
					rev.visible = true
					rev.modulate.a = 0.0
				new_tail[offset] = matched_pill
			else:
				unmatched_indices.append(offset)

		for k in buckets:
			for p in buckets[k]:
				if p.get_parent().visible:
					spare.append(p)
				else:
					_pill_pool.append(p)

		for offset in unmatched_indices:
			if not spare.is_empty():
				new_tail[offset] = spare.pop_back()
			else:
				new_tail[offset] = _create_pill()

		for p in spare:
			var reveal: Control = p.get_parent()
			reveal.visible = false
			reveal.modulate.a = 0.0
			_pill_pool.append(p)

		pills.resize(group_count)
		for offset in range(new_tail.size()):
			pills[prefix_len + offset] = new_tail[offset]

	_layout()
	minimum_size_changed.emit()

func clear_preview() -> void:
	_clear_pills()
	tokens = []
	_groups = []
	selected_position = -1
	_last_selected_position = -1
	_content_extent = Vector2.ZERO
	custom_minimum_size.y = 0
	minimum_size_changed.emit()

func _clear_pills() -> void:
	for pill in pills:
		var reveal: Control = pill.get_parent()
		reveal.visible = false
		reveal.modulate.a = 0.0
		_pill_pool.append(pill)
	pills.clear()

func select_position(value: int) -> void:
	if value == -1 and _last_selected_position == -1:
		selected_position = -1
		return
	selected_position = value
	_last_selected_position = value
	var def_col = Color(S.ACCENT, 0.35)
	for i in mini(pills.size(), _groups.size()):
		var target_col: Color = S.ACCENT if (value >= 0 and _groups[i].positions.has(value)) else def_col
		if pills[i].get_meta("cached_outline", Color.TRANSPARENT) != target_col:
			pills[i].set_meta("cached_outline", target_col)
			pills[i].set_instance_shader_parameter("outline_color", target_col)

func content_size() -> Vector2:
	return _content_extent

func _cached_font_width(font: Font, text: String, font_size: int) -> float:
	var key = "%d:%s" % [font_size, text]
	if _width_cache.has(key):
		return float(_width_cache[key])
	var w = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	_width_cache[key] = w
	return w

func _cached_font_size(font: Font, text: String, font_size: int) -> Vector2:
	var key = "%d:%s" % [font_size, text]
	if _size_cache.has(key):
		return _size_cache[key]
	var sz = font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	_size_cache[key] = sz
	_width_cache[key] = sz.x
	return sz

func _layout() -> void:
	_last_layout_width = size.x
	var pen = Vector2.ZERO
	var height = 32.0 if show_ids else 22.0
	var max_extent = Vector2.ZERO
	var max_w = maxf(size.x, 30.0)
	var target_offset = Vector2(0, -5 if show_ids else 0)
	var count = mini(pills.size(), _groups.size())
	for i in count:
		var pill: Control = pills[i]
		pill.set_meta("group_index", i)
		var grp: Dictionary = _groups[i]
		var cache_key = _ensure_group_meta(grp)
		var meta: Dictionary = grp["_meta"]
		var raw_w: float = float(meta["raw_w"])
		var width = minf(max_w, raw_w)
		if pen.x + width > size.x and pen.x > 0:
			pen.x = 0
			pen.y += height + 5.0
		pill.position = pen
		var target_size: Vector2 = Vector2(width, height)
		var key_changed: bool = str(pill.get_meta("cached_key", "")) != cache_key
		if key_changed or pill.size != target_size or pill.text_offset != target_offset:
			var piece_txt: String = str(meta["piece"])
			var full_sz: Vector2 = meta["full_sz"]
			var sc_x = minf(0.328125, maxf(0.15, (width - 12.0) / maxf(full_sz.x, 1.0)))
			pill.set_pill_text_fast(piece_txt, sc_x, full_sz, target_size, target_offset)
			var number: Label = pill.get_meta("token_id_label")
			number.visible = show_ids
			number.size = Vector2(width, 11)
			if key_changed:
				pill.set_meta("cached_key", cache_key)
				pill.tooltip_text = str(meta["tooltip"])
				number.text = str(meta["ids"])
		max_extent = max_extent.max(pen + target_size)
		pen.x += width + 5.0
	_content_extent = max_extent
	custom_minimum_size.y = pen.y + height if not pills.is_empty() else 0
	select_position(selected_position)

func advance_reveal(delta: float, available: Vector2) -> void:
	_reveal_window=Rect2(_scroll_offset,available)
	for pill in pills:
		var reveal=pill.get_parent()
		if reveal.modulate.a >= 1.0: continue
		if _reveal_window.intersects(Rect2(pill.position,pill.size)):
			var next_a = lerpf(reveal.modulate.a,1.0,minf(1,delta*15))
			if next_a >= 0.995: next_a = 1.0
			reveal.modulate.a = next_a

func set_scroll_offset(value: Vector2) -> void:
	_scroll_offset=value

func is_revealing() -> bool:
	for pill in pills:
		if pill.get_parent().modulate.a<0.995 and _reveal_window.intersects(Rect2(pill.position,pill.size)): return true
	return false

func is_mouse_over_interactive() -> bool:
	return false
