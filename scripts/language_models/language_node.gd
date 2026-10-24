extends Graph
const Layout = preload("res://scripts/language_models/language_layout.gd")
const S = preload("res://scripts/language_models/language_style.gd")
const Adapter = preload("res://scripts/language_models/language_graph_adapter.gd")
const TokenStrip = preload("res://scripts/language_models/views/token_strip.gd")
const TokenBoxView = preload("res://scripts/language_models/views/token_box_view.gd")
const Plot = preload("res://scripts/language_models/views/embedding_plot.gd")
const Heatmap = preload("res://scripts/language_models/views/attention_heatmap.gd")
const Candidates = preload("res://scripts/language_models/views/token_candidates.gd")
const Vocabulary = preload("res://scripts/language_models/views/vocabulary_dialog.gd")
@export var language_kind: StringName = &"tokenizer"
var view: Control
var body: Control
var visual_clip: Control
var status_label: Label
var controller: Node
var trace: Dictionary = {}
var _error_message:=""
var _interactive: Array[Control] = []
var _inspect_request := -1

var main_scroll: ScrollContainer
var attention_scroll: ScrollContainer
var _footer: Array[Control] = []
var _token_fit_pending := false
var target_size_vec:=Vector2.ZERO
var _content_extent:=Vector2.ZERO
var _visual_extent:=Vector2.ZERO

func _after_ready() -> void:
	if language_kind == &"attention_head" and not cfg.has("_head_order"):
		var order := 0
		for node in graphs._graphs.values():
			if node != self and node.get_meta("created_with","") == "attention_head":
				order = maxi(order,int(node.cfg.get("_head_order",-1))+1)
		# Stored with the ordinary graph configuration, so random graph IDs,
		# loading and undo do not shuffle existing parallel head selections.
		cfg["_head_order"] = order
	# Conv2D paints its ports first, then the frame over their inner halves.
	for port in _inputs+outputs:
		port.z_index=0
		move_child(port,0)
	body=Control.new()
	body.name="Body"
	body.mouse_filter=Control.MOUSE_FILTER_PASS
	body.position = Layout.input_origin() if language_kind == &"tokenizer" else Layout.content_origin()
	body.size = (rect.size - Layout.input_origin() - Layout.input_padding()) if language_kind == &"tokenizer" else (rect.size - Layout.content_origin() - Layout.trailing_padding())
	body.z_index=1
	rect.set_instance_shader_parameter("corner_radius_width_add",Layout.radius_adjustment())
	add_child(body)
	visual_clip=Control.new()
	visual_clip.name="VisualClip"
	visual_clip.mouse_filter=Control.MOUSE_FILTER_PASS
	visual_clip.clip_contents = (language_kind == &"tokenizer")
	body.add_child(visual_clip)
	status_label=S.label("",S.MUTED,9)
	add_child(status_label)
	var visual_height := body.size.y-26
	match language_kind:
		&"tokenizer":
			view = TokenBoxView.new()
			view.mouse_filter = Control.MOUSE_FILTER_PASS
			visual_clip.add_child(view)
			view.minimum_size_changed.connect(_queue_token_fit)
			view.token_selected.connect(_select)
		&"embedding", &"attention_head":
			if language_kind == &"attention_head":
				attention_scroll = ScrollContainer.new()
				attention_scroll.theme = preload("res://resources/theme.tres")
				attention_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
				attention_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
				attention_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
				attention_scroll.set_meta("allow_camera_drag", true)
				visual_clip.add_child(attention_scroll)
				view = Heatmap.new()
				view.mouse_filter = Control.MOUSE_FILTER_PASS
				view.set_meta("allow_camera_drag", true)
				attention_scroll.add_child(view)
				attention_scroll.mouse_entered.connect(func():
					if _is_attention_scrollbar_active():
						glob.set_scroll_impossible(attention_scroll)
				)
				attention_scroll.mouse_exited.connect(func():
					glob.set_scroll_possible(attention_scroll)
				)
				view.window_requested.connect(_inspect)
			else:
				view = Plot.new()
				view.position = Vector2.ZERO
				view.mouse_filter = Control.MOUSE_FILTER_PASS
				visual_clip.add_child(view)
			view.minimum_size_changed.connect(_queue_token_fit)
			if view.has_signal("token_selected") and language_kind != &"attention_head":
				view.token_selected.connect(_select)
		&"token_labels":
			main_scroll=_scroll(Vector2(body.size.x,visual_height))
			view=Candidates.new(); view.custom_minimum_size.x=0
			main_scroll.add_child(view)

			var dictionary=S.button(S.localized("Vocabulary…","Словарь…","Сөздік…"),_open_vocabulary)
			_place_footer(dictionary,body.size.x-86,86)
	var title=get_node("ColorRect/root/Label")
	title.theme=preload("res://resources/theme.tres")
	title.minimum_size_changed.connect(_queue_token_fit)
	_align_title()
	_update_content_layout()
	if target_size_vec != Vector2.ZERO:
		rect.size = target_size_vec
		size = rect.size
		if language_kind == &"tokenizer":
			body.position = Layout.input_origin()
			body.size = (rect.size - Layout.input_origin() - Layout.input_padding()).max(Vector2.ZERO)
			if is_instance_valid(view):
				visual_clip.position = -view._editor_expansion
				visual_clip.size = body.size.min(_visual_extent) + view._editor_expansion * 2
				view.size = body.size.min(_visual_extent)
				if is_instance_valid(view.editor):
					view.editor.size = view.size
		else:
			body.position = Layout.content_origin()
			body.size = (rect.size - Layout.content_origin() - Layout.trailing_padding()).max(Vector2.ZERO)
			visual_clip.position = Vector2.ZERO
			visual_clip.size = (body.size if _visual_extent == Vector2.ZERO else body.size.min(_visual_extent)).max(Vector2.ZERO)
			if is_instance_valid(view):
				if language_kind == &"token_labels":
					view.size.x = body.size.x
				elif _visual_extent == Vector2.ZERO:
					view.size = body.size.max(Vector2.ONE)
			if language_kind == &"attention_head" and is_instance_valid(attention_scroll):
				attention_scroll.size = body.size.min(_visual_extent)
		_align_title()
		_layout_status()
		_sync_ports()
		reposition_splines()
		size_changed()
	language_models.response_ready.connect(_inspection_received)
	glob.language_changed.connect(_language_changed)

func _is_attention_scrollbar_active() -> bool:
	if not is_instance_valid(attention_scroll): return false
	var v_bar := attention_scroll.get_v_scroll_bar()
	var h_bar := attention_scroll.get_h_scroll_bar()
	if is_instance_valid(v_bar) and v_bar.is_visible_in_tree() and v_bar.max_value > v_bar.page:
		return true
	if is_instance_valid(h_bar) and h_bar.is_visible_in_tree() and h_bar.max_value > h_bar.page:
		return true
	return false

func _scroll(dimensions: Vector2) -> ScrollContainer:
	var scroll:=ScrollContainer.new()
	scroll.theme=preload("res://resources/theme.tres")
	scroll.size=dimensions
	scroll.horizontal_scroll_mode=ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter=Control.MOUSE_FILTER_PASS
	scroll.get_v_scroll_bar().value_changed.connect(func(_value): hold_for_frame())
	visual_clip.add_child(scroll)
	return scroll

func _place_footer(control: Control, x: float, width: float) -> void:
	control.set_meta("language_min_width",width)
	control.base_size=Vector2(width,18)
	control.custom_minimum_size=Vector2(width,18)
	control.position=Vector2(x,body.size.y-18)
	control.size=Vector2(width,18)
	var reveal:=Control.new()
	reveal.mouse_filter=Control.MOUSE_FILTER_IGNORE
	reveal.modulate.a=0
	body.add_child(reveal)
	reveal.add_child(control); _footer.append(control)
	S.fit_button(control)

func _align_title() -> void:
	var title=get_node("ColorRect/root/Label")
	var font: Font=title.get_theme_font("font")
	var text_size: Vector2=font.get_string_size(title.text,HORIZONTAL_ALIGNMENT_LEFT,-1,title.get_theme_font_size("font_size"))
	title.size=text_size
	if language_kind == &"tokenizer":
		title.scale = Layout.input_property("ColorRect/root/Label", &"scale")
		title.position = Vector2(Layout.input_property("ColorRect/root/Label", &"offset_left"), Layout.input_property("ColorRect/root/Label", &"offset_top"))
		return
	title.horizontal_alignment=HORIZONTAL_ALIGNMENT_LEFT
	title.scale=Layout.header_scale()
	title.position=Vector2((rect.size.x-title.size.x*title.scale.x)/2,Layout.header_y())

func _update_content_layout() -> void:
	if not is_instance_valid(body): return
	if language_kind == &"tokenizer":
		_visual_extent = view.content_size()
		for node in Adapter.component(self):
			if (node.get("language_kind") == &"text_input" or node.get_meta("created_with", "") == "text_input") and is_instance_valid(node):
				if node._visual_extent.y > 0.0:
					_visual_extent.y = node._visual_extent.y
				break
		_content_extent = _visual_extent
		target_size_vec = Layout.input_origin() + _visual_extent + Layout.input_padding()
		view.size = _visual_extent
	elif is_instance_valid(view) and view.has_method("content_size"):
		if language_kind == &"attention_head" and is_instance_valid(attention_scroll):
			var count: int = view.display_matrix().size()
			_visual_extent = view.extent_for_count(8)
			if count <= 8:
				attention_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
				attention_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
				attention_scroll.size = _visual_extent
				view.size = _visual_extent
				view.custom_minimum_size = _visual_extent
			else:
				attention_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
				attention_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_AUTO
				attention_scroll.size = _visual_extent
				view.custom_minimum_size = view.content_size()
				view.size = view.content_size()
		else:
			_visual_extent = view.content_size()
	elif language_kind == &"token_labels":
		_visual_extent = Vector2(180, view.custom_minimum_size.y)
	if language_kind != &"tokenizer":
		var footer_width := 0.0
		for control in _footer:
			var width := maxf(control.get_meta("language_min_width", 28), S.FONT.get_string_size(control.text, HORIZONTAL_ALIGNMENT_LEFT, -1, 32).x * 0.328125 + 12)
			control.size.x = width; control.base_size.x = width
			S.fit_button(control)
			footer_width += width + Layout.row_gap()
		footer_width = maxf(0, footer_width - Layout.row_gap())
		if language_kind == &"token_labels": footer_width += 100 + Layout.row_gap()
		var title = get_node("ColorRect/root/Label")
		var header_width: float = title.get_theme_font("font").get_string_size(title.text, HORIZONTAL_ALIGNMENT_LEFT, -1, title.get_theme_font_size("font_size")).x * title.scale.x
		_content_extent = Vector2(maxf(_visual_extent.x, footer_width), _visual_extent.y + (Layout.row_gap() + 18 if not _footer.is_empty() else 0))
		_content_extent.x = maxf(_content_extent.x, header_width)
		target_size_vec = Layout.fit(_content_extent)
		if language_kind == &"token_labels": _visual_extent.x = _content_extent.x
		if is_instance_valid(view):
			var fallback_body := (target_size_vec - Layout.content_origin() - Layout.trailing_padding()).max(Vector2.ONE)
			if language_kind != &"attention_head":
				view.size = (_visual_extent if _visual_extent != Vector2.ZERO else fallback_body).max(Vector2.ONE)
		if is_instance_valid(main_scroll):
			main_scroll.size = _visual_extent.max(Vector2.ONE)
		var x := 0.0
		if language_kind == &"token_labels": x = _content_extent.x - footer_width + 100 + Layout.row_gap()
		for control in _footer:
			control.position = Vector2(x, _visual_extent.y + Layout.row_gap())
			x += control.size.x + Layout.row_gap()
	_align_title()
	_layout_status()

func _after_process(delta: float) -> void:
	if target_size_vec == Vector2.ZERO:
		_update_content_layout()
	var previous:=rect.size
	rect.size=rect.size.lerp(target_size_vec,minf(1,delta*15.0))
	if rect.size.distance_to(target_size_vec)<0.05: rect.size=target_size_vec
	size=rect.size
	if language_kind == &"tokenizer":
		body.position = Layout.input_origin()
		body.size = (rect.size - Layout.input_origin() - Layout.input_padding()).max(Vector2.ZERO)
		if is_instance_valid(view):
			visual_clip.position = -view._editor_expansion
			visual_clip.size = body.size.min(_visual_extent) + view._editor_expansion * 2
			view.size = body.size.min(_visual_extent)
			if is_instance_valid(view.editor):
				view.editor.size = view.size
	else:
		body.position = Layout.content_origin()
		body.size = (rect.size - Layout.content_origin() - Layout.trailing_padding()).max(Vector2.ZERO)
		visual_clip.position = Vector2.ZERO
		visual_clip.size = (body.size if _visual_extent == Vector2.ZERO else body.size.min(_visual_extent)).max(Vector2.ZERO)
		if is_instance_valid(view):
			if language_kind == &"token_labels":
				view.size.x = body.size.x
			elif _visual_extent == Vector2.ZERO:
				view.size = body.size.max(Vector2.ONE)
		if language_kind == &"attention_head" and is_instance_valid(attention_scroll):
			attention_scroll.size = body.size.min(_visual_extent)
	if is_instance_valid(view) and view.has_method("advance_reveal"): view.advance_reveal(delta,visual_clip.size)
	for control in _footer:
		control.visible=control.position.y+control.size.y<=body.size.y+0.05 and control.position.x+control.size.x<=body.size.x+0.05
		if control.visible: control.get_parent().modulate.a=lerpf(control.get_parent().modulate.a,1.0,minf(1,delta*15))
	if previous!=rect.size:
		_align_title()
		_layout_status()
		_sync_ports()
		size_changed()
		hold_for_frame()

func _proceed_hold() -> bool:
	for control in _footer:
		if control.visible and control.get_parent().modulate.a<0.995: return true
	return rect.size.distance_to(target_size_vec)>0.05 or (is_instance_valid(view) and view.has_method("is_revealing") and view.is_revealing())

func _layout_size() -> Vector2:
	return target_size_vec if target_size_vec!=Vector2.ZERO else rect.size

func _show_error(error: Dictionary) -> void:
	_error_message=str(error.get("message",""))
	_layout_status()
	status_label.text="!"
	status_label.tooltip_text=str(error.get("message",""))
	status_label.mouse_filter=Control.MOUSE_FILTER_PASS
	status_label.add_theme_color_override("font_color",Color(1,0.55,0.5))
	tooltip_text=status_label.tooltip_text
	hold_for_frame()

func _layout_status() -> void:
	status_label.text=""
	status_label.visible=false
	status_label.size=Vector2(100,14)
	status_label.clip_text=true
	status_label.horizontal_alignment=HORIZONTAL_ALIGNMENT_LEFT
	status_label.mouse_filter=Control.MOUSE_FILTER_IGNORE
	status_label.add_theme_color_override("font_color",S.MUTED)
	tooltip_text=S.localized("Connect an input to see model data","Подключите вход, чтобы увидеть данные модели","Модель деректерін көру үшін кірісті қосыңыз") if trace.is_empty() else ""
	if language_kind in [&"tokenizer",&"token_labels"]:
		status_label.position=Layout.content_origin()+Vector2(0,_visual_extent.y+Layout.row_gap()+2)
		status_label.text=str(view.tokens.size())+S.localized(" tokens"," токенов"," токен") if language_kind==&"tokenizer" else S.localized("Other","Остальные","Қалғаны")+" %.1f%%" % (view.other_mass*100)
		status_label.visible=status_label.position.y+14<=rect.size.y-Layout.trailing_padding().y
	if not _error_message.is_empty():
		status_label.visible=true
		status_label.position=Vector2(rect.size.x-24,Layout.header_y())
		status_label.size=Vector2(12,14)
		status_label.text="!"
		status_label.tooltip_text=_error_message
		status_label.mouse_filter=Control.MOUSE_FILTER_PASS
		status_label.add_theme_color_override("font_color",Color(1,0.55,0.5))
		tooltip_text=_error_message

func _queue_token_fit() -> void:
	if _token_fit_pending: return
	_token_fit_pending=true
	_fit_tokenizer.call_deferred()

func _fit_tokenizer() -> void:
	_token_fit_pending=false
	_update_content_layout()
	hold_for_frame()

func _sync_ports() -> void:
	for port in _inputs+outputs:
		if port.config_conn: continue
		port.position=Vector2(-8 if port.connection_type==0 else rect.size.x-10,rect.size.y/2-9.5)
	reposition_splines()

func _language_changed() -> void:
	S.retranslate(self)
	if is_instance_valid(view): view.queue_redraw()
	_layout_status()
	_align_title.call_deferred()
	if language_kind==&"token_labels" and not trace.is_empty(): _tail()
	_queue_token_fit()

func _watch(control: Control) -> void:
	_interactive.append(control)
	control.mouse_entered.connect(func(): glob.occupy(control,&"menu_inside"))
	control.mouse_exited.connect(func(): glob.un_occupy(control,&"menu_inside"))
	control.tree_exiting.connect(func(): glob.un_occupy(control,&"menu_inside"))

func _io(_inputs: Dictionary) -> Variant:
	return null

func _get_x() -> Variant:
	return int(cfg.get("width",256))

func get_language_op() -> StringName:
	return language_kind

func get_language_config() -> Dictionary:
	return cfg.duplicate(true)

func _config_field(field: StringName, value: Variant) -> void:
	if field==&"top_n" and is_instance_valid(view) and language_kind==&"token_labels":
		view.set_visible_count(int(value))

		_tail()

func apply_language_trace(value: Dictionary) -> void:
	_error_message=""
	trace=value
	var preview: Dictionary = value.get("preview",{})
	if is_instance_valid(view):
		if language_kind==&"token_labels":
			view.set_visible_count(int(cfg.get("top_n",5)))
			if preview.has("candidates"): view.set_candidates(preview.candidates,int(preview.get("selected_id",-1)))
			else: view.set_distribution(preview.get("scores",[]),int(preview.get("selected_id",-1)),preview.get("labels",{}))
			_tail()
		else: view.set_preview(preview)
	_queue_token_fit()

	hold_for_frame()

func clear_language_trace() -> void:
	_error_message=""
	trace={}
	if is_instance_valid(view) and view.has_method("clear_preview"): view.clear_preview()
	if is_instance_valid(status_label): _layout_status()
	_queue_token_fit()
	hold_for_frame()

func _source_controller() -> Node:
	for node in Adapter.component(self):
		if node.get_meta("created_with","")=="text_input": return node.controller
	return null

func select_language_position(position: int) -> void:
	if is_instance_valid(view) and view.has_method("select_position"):
		if view.get("selected_position") != position: view.select_position(position)

func _select(position: int) -> void:
	for node in Adapter.component(self):
		if node.has_method("select_language_position"): node.select_language_position(position)

func _tail() -> void:
	if is_instance_valid(status_label) and is_instance_valid(view): status_label.text=S.localized("Other","Остальные","Қалғаны")+" %.1f%%" % (view.other_mass*100)

func _open_vocabulary() -> void:
	var existing = get_tree().root.get_node_or_null("VocabularyDialog")
	if is_instance_valid(existing):
		existing.popup_centered(Vector2i(420, 500))
		return
	var sid := ""
	var rev := 0
	var run := _source_controller()
	if run != null:
		sid = run.session_id
		rev = run.graph_revision
	var popup := Vocabulary.new()
	popup.name = "VocabularyDialog"
	get_tree().root.add_child(popup)
	popup.open(language_models, sid, rev)

func _inspect(delta: int) -> void:
	if trace.is_empty(): return
	var p: Dictionary = trace.get("preview", {})
	if p.is_empty(): return
	var run := _source_controller()
	var cur_s: int = int(p.get("start", 0))
	var target_start: int = cur_s
	if is_instance_valid(view) and view.preview.get("start", 0) != cur_s:
		target_start = int(view.preview.get("start", 0))
	else:
		target_start = maxi(0, cur_s + delta)
	var tot: int = maxi(int(p.get("total", 0)), (p.get("tokens", []) as Array).size())
	if tot > 0 and target_start >= tot: return
	p.start = target_start
	if run == null or run.session_id == "":
		if is_instance_valid(view):
			view.set_preview(p)
		return
	_inspect_request = language_models.request(&"inspect", {"node_id":str(graph_id),"layer_index":p.get("layer_index",0),"head_index": p.get("head_index", 0), "start": target_start, "count": 8}, run.session_id, run.graph_revision)

func _inspection_received(response: Dictionary) -> void:
	var run := _source_controller()
	if run==null or response.get("graph_revision")!=run.graph_revision or response.get("session_id")!=run.session_id: return
	if response.get("request_id") != _inspect_request or not response.ok or trace.is_empty(): return
	trace.preview.matrix=response.result.matrix; trace.preview.start=response.result.start; view.set_preview(trace.preview)

func unselect() -> void:
	super.unselect()
	if is_instance_valid(view) and view.has_method("select_position"):
		if view.get("selected_position") != -1:
			_select(-1)

func _exit_tree() -> void:
	super._exit_tree()
	if is_instance_valid(attention_scroll): glob.set_scroll_possible(attention_scroll)
	if language_models.response_ready.is_connected(_inspection_received): language_models.response_ready.disconnect(_inspection_received)

func _can_drag() -> bool:
	if language_kind == &"attention_head" and is_instance_valid(attention_scroll) and attention_scroll.is_visible_in_tree():
		var v_bar := attention_scroll.get_v_scroll_bar()
		var h_bar := attention_scroll.get_h_scroll_bar()
		if is_instance_valid(v_bar) and v_bar.is_visible_in_tree() and (v_bar.has_focus() or v_bar.get_global_rect().has_point(get_global_mouse_position())):
			return false
		if is_instance_valid(h_bar) and h_bar.is_visible_in_tree() and (h_bar.has_focus() or h_bar.get_global_rect().has_point(get_global_mouse_position())):
			return false

	for control in _interactive:
		if is_instance_valid(control) and control.is_visible_in_tree() and control.get_global_rect().has_point(get_global_mouse_position()): return false

	for btn in _footer:
		if is_instance_valid(btn) and btn.is_visible_in_tree() and btn.get_global_rect().has_point(get_global_mouse_position()):
			return false

	if not super._can_drag():
		return false
	if is_instance_valid(view) and view.has_method("is_mouse_over_interactive"):
		if view.is_mouse_over_interactive():
			return false
	return true
