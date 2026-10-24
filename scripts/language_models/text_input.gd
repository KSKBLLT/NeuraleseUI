extends "res://scripts/input_base.gd"
const Layout=preload("res://scripts/language_models/language_layout.gd")
const Style=preload("res://scripts/language_models/language_style.gd")
const Adapter=preload("res://scripts/language_models/language_graph_adapter.gd")
const Controller=preload("res://scripts/language_models/language_graph_controller.gd")
@export var language_kind: StringName=&"text_input"
var editor: TextEdit
var body: Control
var visual_clip: Control
var status_label: Label
var controller: Node
var view: Control
var trace: Dictionary={}
var _footer: Array[Control]=[]
var _visual_extent:=Vector2.ZERO
var target_size_vec:=Vector2.ZERO
var _error_message:=""
var _editor_expansion:=Vector2.ZERO
var _applying_generation := false

func _after_ready() -> void:
	for port in outputs:
		port.z_index=0
		move_child(port,0)
	body=Control.new(); body.name="Body"; body.position=Layout.input_origin()
	add_child(body)
	visual_clip=Control.new(); visual_clip.clip_contents=true; body.add_child(visual_clip)
	editor=Style.input_editor(); visual_clip.add_child(editor)
	var v_bar := editor.get_v_scroll_bar()
	if v_bar != null:
		v_bar.modulate.a = 0.0
		v_bar.custom_minimum_size = Vector2.ZERO
		v_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h_bar := editor.get_h_scroll_bar()
	if h_bar != null:
		h_bar.modulate.a = 0.0
		h_bar.custom_minimum_size = Vector2.ZERO
		h_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var style: StyleBoxFlat=editor.get_theme_stylebox("normal")
	_editor_expansion=Vector2(style.expand_margin_left,style.expand_margin_top)
	visual_clip.position=-_editor_expansion
	editor.position=_editor_expansion
	editor.text=str(cfg.get("text",""))
	editor.text_changed.connect(_text_changed)
	editor.mouse_entered.connect(func(): glob.occupy(editor,&"menu_inside"); glob.set_scroll_impossible(editor))
	editor.mouse_exited.connect(_release_editor)
	editor.tree_exiting.connect(_release_editor)
	status_label=Style.label("!",Color(1,0.55,0.5),9); status_label.visible=false; rect.add_child(status_label)
	controller=Controller.new(); controller.name="LanguageController"; add_child(controller)
	controller.setup(language_models); controller.source=self
	controller.failed.connect(_show_error)
	glob.language_changed.connect(_language_changed)
	_language_changed()
	_update_content_layout()
	if target_size_vec != Vector2.ZERO:
		rect.size = target_size_vec
		size = rect.size
		body.size = (rect.size - Layout.input_origin() - Layout.input_padding()).max(Vector2.ZERO)
		editor.size = body.size.min(_visual_extent)
		visual_clip.size = body.size.min(_visual_extent) + _editor_expansion * 2
		status_label.position = Vector2(rect.size.x - 24, Layout.input_property("ColorRect/root/Label", &"offset_top"))
		for port in outputs:
			port.position = rect.position + Vector2(rect.size.x + Layout.input_property("o", &"offset_left") - Layout.input_property("ColorRect", &"offset_right"), rect.size.y / 2 - port.size.y / 2)
		reposition_splines()
		size_changed()
	hold_for_frame()

func _release_editor() -> void:
	glob.un_occupy(editor,&"menu_inside"); glob.set_scroll_possible(editor)

func _can_drag() -> bool:
	return not editor.get_global_rect().has_point(get_global_mouse_position())

func _text_changed() -> void:
	if _applying_generation: return
	_update_content_layout(); hold_for_frame()
	if editor.text==str(cfg.get("text","")): return
	open_undo_redo(); update_config({"text":editor.text}); close_undo_redo()

func apply_generated_text(text: String) -> void:
	_applying_generation = true
	update_config({"text":text})
	_applying_generation = false

func _config_field(field: StringName,value: Variant) -> void:
	if field==&"text" and is_instance_valid(editor):
		if editor.text!=str(value): editor.text=str(value)
		_update_content_layout(); hold_for_frame()
		if not _applying_generation and is_instance_valid(controller):
			controller.on_text_edited()

func _align_title() -> void:
	var title: Label=get_node("ColorRect/root/Label")
	title.scale=Layout.input_property("ColorRect/root/Label",&"scale")
	title.position=Vector2(Layout.input_property("ColorRect/root/Label",&"offset_left"),Layout.input_property("ColorRect/root/Label",&"offset_top"))
	title.size=title.get_theme_font("font").get_string_size(title.text,HORIZONTAL_ALIGNMENT_LEFT,-1,title.get_theme_font_size("font_size"))

func _update_content_layout() -> void:
	if not is_instance_valid(editor): return
	_align_title()
	var title: Label=get_node("ColorRect/root/Label")
	var base_width: float = Layout.input_property("ColorRect",&"offset_right")-Layout.input_property("ColorRect",&"offset_left")-Layout.input_origin().x-Layout.input_padding().x
	var minimum_width: float = base_width * 3.0
	var measured := Layout.measure_text(editor,maxf(minimum_width,title.size.x*title.scale.x))
	var line_h: float = float(editor.get_line_height()) if editor.get_line_height() > 0 else 14.0
	var stylebox := editor.get_theme_stylebox("normal")
	var margins_y: float = stylebox.get_minimum_size().y if stylebox != null else 8.0
	var base_height: float = line_h + margins_y
	var minimum_height: float = base_height * 3.0
	measured.y = maxf(measured.y, minimum_height)
	editor.size = measured
	var v_bar := editor.get_v_scroll_bar()
	if v_bar != null:
		v_bar.modulate.a = 0.0
		v_bar.custom_minimum_size = Vector2.ZERO
		v_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_visual_extent = measured
	target_size_vec=Layout.input_origin()+_visual_extent+Layout.input_padding()
	status_label.position=Vector2(rect.size.x-24,Layout.input_property("ColorRect/root/Label",&"offset_top"))
	status_label.size=Vector2(12,14)
	for node in Adapter.component(self):
		if node != self and node.has_method("_queue_token_fit"):
			node._queue_token_fit()

func _queue_token_fit() -> void:
	_update_content_layout(); hold_for_frame()

func _after_process(delta: float) -> void:
	if target_size_vec == Vector2.ZERO:
		_update_content_layout()
	var previous:=rect.size
	rect.size=rect.size.lerp(target_size_vec,minf(1,delta*15))
	if rect.size.distance_to(target_size_vec)<0.05: rect.size=target_size_vec
	size=rect.size
	body.size=(rect.size-Layout.input_origin()-Layout.input_padding()).max(Vector2.ZERO)
	editor.size=body.size.min(_visual_extent)
	# Native fields draw their rounded border outside their Control rect.
	visual_clip.size=body.size.min(_visual_extent)+_editor_expansion*2
	status_label.position=Vector2(rect.size.x-24,Layout.input_property("ColorRect/root/Label",&"offset_top"))
	status_label.size=Vector2(12,14)
	if previous!=rect.size:
		for port in outputs:
			port.position=rect.position+Vector2(rect.size.x+Layout.input_property("o",&"offset_left")-Layout.input_property("ColorRect",&"offset_right"),rect.size.y/2-port.size.y/2)
		reposition_splines(); size_changed(); hold_for_frame()

func _proceed_hold() -> bool:
	if editor.has_focus(): return true
	return rect.size.distance_to(target_size_vec)>0.05

func _layout_size() -> Vector2:
	return target_size_vec if target_size_vec!=Vector2.ZERO else rect.size

func _language_changed() -> void:
	editor.placeholder_text=Style.localized("Text…","Текст…","Мәтін…")
	_update_content_layout(); hold_for_frame()

func _show_error(error: Dictionary) -> void:
	_error_message=str(error.get("message",""))
	status_label.visible=true; status_label.tooltip_text=_error_message
	tooltip_text=_error_message; hold_for_frame()

func clear_language_trace() -> void:
	trace={}; _error_message=""; status_label.visible=false
	tooltip_text=""

func apply_language_trace(value: Dictionary) -> void:
	trace=value; _error_message=""; status_label.visible=false

func get_language_op() -> StringName:
	return language_kind

func get_language_config() -> Dictionary:
	return cfg.duplicate(true)

func _io(_inputs: Dictionary) -> Variant:
	return null
