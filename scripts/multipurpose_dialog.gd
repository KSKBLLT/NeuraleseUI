extends SplashMenu
class_name MultipurposeDialog

const BUTTON_SCENE := preload("res://scenes/BaseBComponent.tscn")
const DialogSpecCore := preload("res://scripts/dialog_spec.gd")
const MarkdownCore := preload("res://scripts/markdown_to_bbcode.gd")
const PRIMARY_COLOR := Color(0.43137255, 0.5882353, 0.9019608, 1.0)
const SECONDARY_COLOR := Color(0.43137255, 0.5882353, 0.9019608, 0.0)
const SPLASH_MATERIAL := preload("res://scenes/splash.tres")

signal action_selected(result: Dictionary)

@onready var _title: Label = $ColorRect/Margin/VBox/Header/Title
@onready var _icon: TextureRect = $ColorRect/Margin/VBox/Header/Icon
@onready var _body: RichTextLabel = $ColorRect/Margin/VBox/Body
@onready var _progress_section: VBoxContainer = $ColorRect/Margin/VBox/ProgressSection
@onready var _progress_status: Label = $ColorRect/Margin/VBox/ProgressSection/Status
@onready var _progress_bar: ProgressBar = $ColorRect/Margin/VBox/ProgressSection/Bar
@onready var _progress_detail: Label = $ColorRect/Margin/VBox/ProgressSection/Detail
@onready var _actions: VBoxContainer = $ColorRect/Margin/VBox/Actions
@onready var _fields_section: VBoxContainer = $ColorRect/Margin/VBox/FieldsSection
@onready var _input_template: LineEdit = $ColorRect/Margin/VBox/FieldsSection/InputTemplate
@onready var _dropdown_template: OptionButton = $ColorRect/Margin/VBox/FieldsSection/DropdownTemplate
@onready var _color_rect: ColorRect = $ColorRect

var _normalized_spec: Dictionary = {}
var _source_spec: Dictionary = {}
var _viewport_size := Vector2(1280, 720)
var _action_buttons: Array[BlockComponent] = []
var _active_inputs: Dictionary = {}
var _choice_values: Dictionary = {}
var _field_labels: Dictionary = {}
var _action_layout_container: Container = null
var _result_emitted := false
var _last_result: Dictionary = {}
var _language := "en"
var _hidden_node_palette: CanvasLayer = null
var _node_palette_was_visible := false
var _choice_menu_layer: CanvasLayer = null
var _default_choice_menu_host: Node = null
var _choice_menu_host_captured := false
var _active_choice_dropdown: BlockComponent = null


func configure(spec: Dictionary, language: String, viewport_size: Vector2) -> MultipurposeDialog:
	_language = language
	_source_spec = spec.duplicate(true)
	_viewport_size = viewport_size
	_normalized_spec = DialogSpecCore.normalize(_source_spec, language, viewport_size)
	self.inner = _normalized_spec.get("inner", false)
	dismiss_on_escape = _normalized_spec["dismiss_on_escape"]
	dismiss_on_outside_click = _normalized_spec["dismiss_on_outside_click"]
	if is_node_ready():
		_apply_spec()
	return self


func _ready() -> void:
	_apply_spec()
	super()
	_promote_choice_menu_layer()


func _exit_tree() -> void:
	_restore_choice_menu_host()
	_dispose_choice_menu_layer()
	_restore_node_palette()


func _apply_spec() -> void:
	if _normalized_spec.is_empty():
		_normalized_spec = DialogSpecCore.normalize({}, "en", Vector2(1280, 720))

	set_base_size(_normalized_spec["size"])
	typename = "dialog:%s" % _normalized_spec["id"]
	var appearance: Dictionary = _normalized_spec["appearance"]
	_title.text = _normalized_spec["title"]
	_title.add_theme_font_size_override("font_size", appearance["title_font_size"])
	_icon.texture = load(_normalized_spec["icon_path"])
	_icon.visible = appearance["show_icon"]
	_body.text = (
		MarkdownCore.convert(_normalized_spec["body"])
		if _normalized_spec["format"] == "markdown"
		else str(_normalized_spec["body"]).replace("[", "[lb]")
	)
	_body.visible = not str(_normalized_spec["body"]).strip_edges().is_empty()
	for font_size_key in ["normal_font_size", "bold_font_size", "italics_font_size"]:
		_body.add_theme_font_size_override(font_size_key, appearance["body_font_size"])
	_body.add_theme_font_size_override("mono_font_size", maxi(12, appearance["body_font_size"] - 1))

	# The light pixel veil does not hide what is behind, so dialogs keep their card.
	if _normalized_spec.get("surface", "default") == "transparent" and not design.pixel:
		_color_rect.material = null
		_color_rect.color = Color.TRANSPARENT
	else:
		_color_rect.material = SPLASH_MATERIAL
		_color_rect.color = Color.WHITE
	var s = float(_normalized_spec.get("scale", 1.0))
	scale = Vector2(s, s)

	_apply_progress()
	_ensure_choice_menu_layer()
	_rebuild_fields()
	_rebuild_actions()
	_apply_workspace_visibility()


func set_progress(value: float, status: String, detail: String) -> void:
	_normalized_spec["progress"] = {
		"visible": true,
		"value": clampf(value, 0.0, 100.0),
		"status": status,
		"detail": detail,
	}
	if is_node_ready():
		_apply_progress()


func get_progress_value() -> float:
	if is_node_ready():
		return _progress_bar.value
	return float(_normalized_spec.get("progress", {}).get("value", 0.0))


func set_actions(actions: Array[Dictionary]) -> void:
	_normalized_spec["buttons"] = DialogSpecCore.normalize_buttons(actions, _language)
	if is_node_ready():
		_rebuild_actions()


func _apply_progress() -> void:
	var progress: Dictionary = _normalized_spec.get("progress", {})
	_progress_section.visible = progress.get("visible", false) == true
	_progress_bar.value = clampf(float(progress.get("value", 0.0)), 0.0, 100.0)
	_progress_status.text = str(progress.get("status", ""))
	_progress_detail.text = str(progress.get("detail", ""))


func _rebuild_actions() -> void:
	for button in _action_buttons:
		if is_instance_valid(button):
			button.queue_free()
	_action_buttons.clear()
	if is_instance_valid(_action_layout_container):
		_action_layout_container.queue_free()
	_action_layout_container = (
		VBoxContainer.new()
		if _normalized_spec.get("action_layout", "horizontal") == "vertical"
		else HBoxContainer.new()
	)
	_action_layout_container.name = "ActionLayout"
	var appearance: Dictionary = _normalized_spec["appearance"]
	_action_layout_container.add_theme_constant_override("separation", appearance["action_separation"])
	_action_layout_container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if _action_layout_container is HBoxContainer:
		_action_layout_container.alignment = BoxContainer.ALIGNMENT_END
	_actions.add_child(_action_layout_container)

	for action: Dictionary in _normalized_spec["buttons"]:
		var button: BlockComponent = BUTTON_SCENE.instantiate()
		var automatic_width := maxf(84.0, 30.0 + float(action["text"].length()) * 9.0)
		var width := maxf(automatic_width, appearance["button_width"])
		button.name = "Action_%s" % action["id"].validate_node_name()
		button.auto_wrap = false
		button.button_type = BlockComponent.ButtonType.BLOCK_BUTTON
		button.top = true
		button.in_splash = true
		button.mouse_open = false
		button.base_scale_x = appearance["button_font_scale"]
		button.base_size = Vector2(width, appearance["button_height"])
		button.custom_minimum_size = button.base_size
		button.text_alignment = _button_text_alignment(appearance["button_text_alignment"])
		button.text_offset = Vector2(appearance["button_text_padding"], 0.0)
		button.color = PRIMARY_COLOR if action["style"] == "primary" else SECONDARY_COLOR
		if action["style"] == "primary":
			design.set_role(button, design.Role.PRIMARY)
		button.text = action["text"]
		button.mouse_filter = Control.MOUSE_FILTER_STOP
		var button_label := button.get_node_or_null("Label") as Control
		if button_label != null:
			button_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		button.released.connect(choose_action.bind(action["id"]))
		button.gui_input.connect(_on_action_gui_input.bind(action["id"]))
		_action_layout_container.add_child(button)
		_action_buttons.append(button)


func _on_action_gui_input(event: InputEvent, action_id: String) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		get_viewport().set_input_as_handled()
		choose_action(action_id)


func _button_text_alignment(value: String) -> Vector2:
	match value:
		"left":
			return Vector2(-1.0, 0.0)
		"right":
			return Vector2(1.0, 0.0)
		_:
			return Vector2.ZERO


func get_action_buttons() -> Array[BlockComponent]:
	return _action_buttons.filter(func(button: BlockComponent): return is_instance_valid(button))


func get_field_control(field_id: String) -> Control:
	return _active_inputs.get(field_id)


func get_field_label(field_id: String) -> Label:
	return _field_labels.get(field_id)


func wait_for_result() -> Dictionary:
	if _result_emitted:
		return _last_result.duplicate(true)
	var result: Dictionary = await action_selected
	return result


func choose_action(action_id: String) -> void:
	if _result_emitted or not _has_action(action_id):
		return

	# Validate fields before proceeding (skip validation if dismissing)
	if action_id != "dismiss":
		for field_id in _active_inputs:
			var node = _active_inputs[field_id]
			if node is LineEdit and node.has_method("update_valid"):
				node.update_valid()
				if not node.is_valid:
					return

	var is_can_go = true
	var close_mode := str(_normalized_spec.get("close_mode", "animated"))
	for btn in _normalized_spec["buttons"]:
		if btn["id"] == action_id:
			is_can_go = btn.get("can_go", true)
			close_mode = str(btn.get("close_mode", close_mode))
			break
	self.can_go = is_can_go
	_emit_result(action_id)
	
	if close_mode == "handoff":
		_close_for_handoff()
	elif _splash_ready:
		
		go_away()
	else:
		queue_free()


func _close_for_handoff() -> void:
	# A startup step is immediately replaced by another dialog. Remove this card
	# in the current action frame while keeping the shared blur fully opaque; the
	# next dialog is created as soon as tree_exited resumes at frame end.
	can_tween_zero = false
	go_away(false)
	quit()


func quit(_data: Dictionary = {}) -> void:
	quitting.emit()
	print(can_go)
	if not can_go:
		hide()
		queue_free()
		return
	if not _result_emitted:
		_emit_result("dismiss")
	hide()
	if can_tween_zero:
		ui.blur.self_modulate.a = 0.0
	var palette := glob.base_node.get_node_or_null("WIN_GRAPH/NodePalette") as CanvasLayer

	#palette.visible = true
	queue_free()


## Legacy SplashMenu toggles close through go_away(), which keeps the card
## alive for its normal fade-and-scale exit.  Dialog callers also need a result
## immediately so their awaiting flow can continue, hence the dismiss emit
## happens before starting that same legacy animation.
func dismiss_with_splash_animation() -> void:
	if not can_go:
		return
	if not _result_emitted:
		_emit_result("dismiss")
	print("quitting1")
	if _splash_ready:
		go_away()
	else:
		queue_free()


func _emit_result(action_id: String) -> void:
	_result_emitted = true
	var fields_data := {}
	for field_id in _active_inputs:
		var node = _active_inputs[field_id]
		if _choice_values.has(field_id):
			fields_data[field_id] = _choice_values[field_id]
		elif node is LineEdit:
			fields_data[field_id] = node.text.strip_edges()

	_last_result = {
		"dialog_id": _normalized_spec["id"],
		"action": action_id,
		"values": fields_data,
		"fields": fields_data.duplicate(true),
	}
	action_selected.emit(_last_result.duplicate(true))


func _has_action(action_id: String) -> bool:
	for action: Dictionary in _normalized_spec["buttons"]:
		if action["id"] == action_id:
			return true
	return false


func _rebuild_fields() -> void:
	for child in _fields_section.get_children():
		if child != _input_template and child != _dropdown_template:
			child.queue_free()
	_active_inputs.clear()
	_choice_values.clear()
	_field_labels.clear()

	var fields: Array = _normalized_spec.get("fields", [])
	if fields.is_empty():
		return

	var field_columns := int(_normalized_spec.get("appearance", {}).get("field_columns", 1))
	var appearance: Dictionary = _normalized_spec.get("appearance", {})
	var current_row: HBoxContainer = null
	for field_index in range(fields.size()):
		var field: Dictionary = fields[field_index]
		var field_id: String = field["id"]
		var type: String = field["type"]
		var field_parent: Container = _fields_section
		if field_columns > 1:
			if field_index % field_columns == 0:
				current_row = HBoxContainer.new()
				current_row.name = "FieldRow_%d" % (field_index / field_columns)
				current_row.add_theme_constant_override("separation", 12)
				_fields_section.add_child(current_row)
			field_parent = current_row
		var row := VBoxContainer.new()
		row.name = "Field_%s" % field_id.validate_node_name()
		row.add_theme_constant_override("separation", 5)
		row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		field_parent.add_child(row)
		var label := Label.new()
		label.name = "Label"
		label.text = field.get("label", "")
		label.theme = _title.theme
		label.add_theme_font_size_override("font_size", appearance["field_label_font_size"])
		label.visible = not label.text.is_empty()
		row.add_child(label)
		_field_labels[field_id] = label

		if type == "choice":
			var dropdown := _create_choice_field(field, appearance, field_columns)
			var choice_host := Control.new()
			choice_host.name = "ChoiceHost_%s" % field_id.validate_node_name()
			choice_host.custom_minimum_size = dropdown.base_size
			choice_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			choice_host.mouse_filter = Control.MOUSE_FILTER_IGNORE
			row.add_child(choice_host)
			choice_host.add_child(dropdown)
			dropdown.position = Vector2.ZERO
			dropdown.custom_minimum_size = Vector2.ZERO
			choice_host.resized.connect(
				_sync_choice_field_size.bind(dropdown, choice_host)
			)
			_sync_choice_field_size.call_deferred(dropdown, choice_host)
			_active_inputs[field_id] = dropdown
		else:
			var input: LineEdit = _input_template.duplicate()
			input.visible = true
			input.custom_minimum_size.y = appearance["field_height"]
			input.add_theme_font_size_override("font_size", appearance["field_font_size"])
			input.placeholder_text = field.get("placeholder", "")
			input.text = field.get("value", "")
			if field.get("required", false):
				input.set_is_valid_call(func(text: String): return text.strip_edges().length() > 0)
			row.add_child(input)
			_active_inputs[field_id] = input


func _sync_choice_field_size(dropdown: BlockComponent, choice_host: Control) -> void:
	if not is_instance_valid(dropdown) or not is_instance_valid(choice_host):
		return
	if dropdown.get_parent() != choice_host:
		return
	var target_width := choice_host.size.x
	if target_width <= 0.0 or is_equal_approx(dropdown.base_size.x, target_width):
		return
	dropdown.base_size.x = target_width
	dropdown.size.x = target_width
	if is_instance_valid(dropdown.scroll):
		dropdown.scroll.size.x = maxf(1.0, target_width - dropdown.scrollbar_padding)
		dropdown.arrange()


func _create_choice_field(
	field: Dictionary,
	appearance: Dictionary,
	field_columns: int
) -> BlockComponent:
	var field_id := str(field["id"])
	var options: Array = field.get("options", [])
	var selected_value := str(field.get("value", ""))
	var selected_text := ""
	var available_width := maxf(appearance["button_width"], 360.0)
	var field_width := maxf(
		180.0,
		(available_width - 12.0 * float(field_columns - 1)) / float(field_columns)
	)

	var dropdown: BlockComponent = BUTTON_SCENE.instantiate()
	dropdown.name = "Choice_%s" % field_id.validate_node_name()
	dropdown.auto_wrap = false
	dropdown.button_type = BlockComponent.ButtonType.DROPOUT_MENU
	dropdown.top = true
	dropdown.in_splash = true
	dropdown.mouse_open = false
	dropdown.base_scale_x = appearance["field_font_scale"]
	dropdown.base_size = Vector2(field_width, appearance["field_height"])
	dropdown.custom_minimum_size = dropdown.base_size
	dropdown.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dropdown.text_alignment = Vector2(-1.0, 0.0)
	dropdown.text_offset = Vector2(16.0, 0.0)
	dropdown.color = PRIMARY_COLOR
	dropdown.max_size = int(minf(260.0, appearance["field_height"] * float(options.size() + 1) + 18.0))
	dropdown.arrangement_padding = Vector2(8.0, 5.0)
	dropdown.mouse_filter = Control.MOUSE_FILTER_STOP
	var dropdown_label := dropdown.get_node_or_null("Label") as Control
	if dropdown_label != null:
		dropdown_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dropdown.pressed.connect(_prepare_choice_dropdown.bind(dropdown))
	dropdown.ready.connect(
		_initialize_choice_dropdown.bind(dropdown),
		CONNECT_ONE_SHOT
	)

	for option: Dictionary in options:
		var option_value := str(option["value"])
		var option_text := str(option["text"])
		if option_value == selected_value:
			selected_text = option_text
		var option_button: BlockComponent = BUTTON_SCENE.instantiate()
		option_button.name = "Option_%s" % option_value.validate_node_name()
		option_button.auto_wrap = false
		option_button.hint = StringName(option_value)
		option_button.button_type = BlockComponent.ButtonType.BLOCK_BUTTON
		option_button.top = true
		option_button.in_splash = true
		option_button.mouse_open = false
		option_button.base_scale_x = appearance["field_font_scale"]
		option_button.base_size = Vector2(field_width - 16.0, appearance["field_height"] - 4.0)
		option_button.custom_minimum_size = option_button.base_size
		option_button.text_alignment = Vector2(-1.0, 0.0)
		option_button.text_offset = Vector2(14.0, 0.0)
		option_button.color = SECONDARY_COLOR
		option_button.text = option_text
		option_button.mouse_filter = Control.MOUSE_FILTER_STOP
		var option_label := option_button.get_node_or_null("Label") as Control
		if option_label != null:
			option_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
		option_button.gui_input.connect(
			_on_choice_option_gui_input.bind(option_button, field_id, dropdown)
		)
		dropdown.add_child(option_button)

	if selected_text.is_empty() and not options.is_empty():
		selected_value = str(options[0]["value"])
		selected_text = str(options[0]["text"])
	_choice_values[field_id] = selected_value
	dropdown.text = selected_text
	dropdown.child_button_release.connect(_on_choice_selected.bind(field_id, dropdown))
	return dropdown


func _ensure_choice_menu_layer() -> void:
	if is_instance_valid(_choice_menu_layer):
		return
	_choice_menu_layer = CanvasLayer.new()
	_choice_menu_layer.name = "ChoiceMenuLayer"
	_choice_menu_layer.layer = 129
	add_child(_choice_menu_layer)


func _promote_choice_menu_layer() -> void:
	if not is_instance_valid(_choice_menu_layer) or get_tree() == null:
		return
	var root := get_tree().root
	if _choice_menu_layer.get_parent() != root:
		_choice_menu_layer.reparent(root)


func _initialize_choice_dropdown(dropdown: BlockComponent) -> void:
	if not is_instance_valid(dropdown):
		return
	dropdown._disarm_menu_hit_tests()
	dropdown.update_children_reveal()


func _prepare_choice_dropdown(dropdown: BlockComponent) -> void:
	_ensure_choice_menu_layer()
	if (
		is_instance_valid(_active_choice_dropdown)
		and _active_choice_dropdown != dropdown
		and _active_choice_dropdown.current_type == BlockComponent.ButtonType.CONTEXT_MENU
	):
		_active_choice_dropdown.menu_hide()
	if not _choice_menu_host_captured:
		_default_choice_menu_host = glob.follow_menus
		_choice_menu_host_captured = true
	glob.follow_menus = _choice_menu_layer
	_active_choice_dropdown = dropdown
	dropdown._arm_menu_hit_tests()


func _restore_choice_menu_host() -> void:
	if is_instance_valid(_active_choice_dropdown) and glob.opened_menu == _active_choice_dropdown:
		glob.opened_menu = null
	if _choice_menu_host_captured and glob.follow_menus == _choice_menu_layer:
		glob.follow_menus = _default_choice_menu_host
	_default_choice_menu_host = null
	_choice_menu_host_captured = false
	_active_choice_dropdown = null


func _dispose_choice_menu_layer() -> void:
	if is_instance_valid(_choice_menu_layer):
		_choice_menu_layer.queue_free()
	_choice_menu_layer = null


func _on_choice_option_gui_input(
	event: InputEvent,
	option_button: BlockComponent,
	field_id: String,
	dropdown: BlockComponent
) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		get_viewport().set_input_as_handled()
		_on_choice_selected(option_button, field_id, dropdown)


func _on_choice_selected(
	option_button: BlockComponent,
	field_id: String,
	dropdown: BlockComponent
) -> void:
	if not is_instance_valid(option_button) or not is_instance_valid(dropdown):
		return
	_choice_values[field_id] = str(option_button.hint)
	dropdown.text = option_button.text
	dropdown.menu_hide()
	if _is_live_language_field(field_id):
		_apply_live_language(str(option_button.hint))


func _is_live_language_field(field_id: String) -> bool:
	for field: Dictionary in _normalized_spec.get("fields", []):
		if field.get("id") == field_id:
			return field.get("live_language", false) == true
	return false


func _apply_live_language(language: String) -> void:
	var values := _current_field_values()
	values["language"] = language
	for field in _source_spec.get("fields", []):
		if field is Dictionary and values.has(field.get("id")):
			field["value"] = values[field.get("id")]
	_language = language
	_normalized_spec = DialogSpecCore.normalize(_source_spec, _language, _viewport_size)
	_apply_spec()


func _current_field_values() -> Dictionary:
	var values := _choice_values.duplicate(true)
	for field_id in _active_inputs:
		var node = _active_inputs[field_id]
		if node is LineEdit:
			values[field_id] = node.text
	return values


func _apply_workspace_visibility() -> void:
	#_restore_node_palette()
	if not bool(_normalized_spec.get("appearance", {}).get("hide_node_palette", false)):
		return
	if not is_instance_valid(glob.base_node):
		return
	var palette := glob.base_node.get_node_or_null("WIN_GRAPH/NodePalette") as CanvasLayer
	if not is_instance_valid(palette):
		return
	#palette.visible = false
	#_hidden_node_palette = palette
	#_node_palette_was_visible = palette.visible
	#palette.visible = false


func _restore_node_palette() -> void:
	if is_instance_valid(_hidden_node_palette):
		_hidden_node_palette.visible = _node_palette_was_visible
	_hidden_node_palette = null
	_node_palette_was_visible = false
