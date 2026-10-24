extends Graph

const Adapter = preload("res://scripts/language_models/language_graph_adapter.gd")
const Style = preload("res://scripts/language_models/language_style.gd")
@export var language_kind: StringName = &"autoregression"
@onready var btn_step: BlockComponent = $ColorRect/Step
var editor: TextEdit
var trace: Dictionary = {}
var _controller: Node

func _after_ready() -> void:
	editor = Style.text_editor()
	editor.editable = false
	editor.position = Vector2(8, 5)
	editor.size = Vector2(129, 51)
	$ColorRect/TextPanel.add_child(editor)
	_config_field(&"creativity", cfg.get("creativity", 0.7))
	_config_field(&"candidates", cfg.get("candidates", 5))
	hold_for_frame()

func request_step() -> void:
	var controller := _source_controller()
	if controller == null or controller._pending >= 0: return
	if _controller != controller:
		if is_instance_valid(_controller) and _controller.state_changed.is_connected(_state_changed):
			_controller.state_changed.disconnect(_state_changed)
		_controller = controller
		_controller.state_changed.connect(_state_changed)
	controller.step(float(cfg.get("creativity", 0.7)), int(cfg.get("candidates", 5)))
	_state_changed(controller.state)

func _source_controller() -> Node:
	for member in Adapter.component(self):
		if member.get_meta("created_with", "") == "text_input": return member.controller
	return null

func _state_changed(value: StringName) -> void:
	if value in [&"running", &"training"]: btn_step.block_input()
	else: btn_step.unblock_input()
	hold_for_frame()

func _config_field(field: StringName, value: Variant) -> void:
	match field:
		&"creativity":
			$ColorRect/Creativity/HSlider.set_value_no_signal(clampf(float(value), 0, 2))
			$ColorRect/Creativity/n.text = "%.2f" % float(value)
		&"candidates":
			$ColorRect/Candidates/HSlider.set_value_no_signal(clampi(int(value), 1, 20))
			$ColorRect/Candidates/n.text = str(int(value))

func _creativity_changed(value: float) -> void:
	open_undo_redo()
	update_config({"creativity": snappedf(value, 0.05)})
	close_undo_redo()

func _candidates_changed(value: float) -> void:
	open_undo_redo()
	update_config({"candidates": int(value)})
	close_undo_redo()

func apply_language_trace(value: Dictionary) -> void:
	trace = value
	editor.text = str(value.get("preview", {}).get("decoded_text", ""))
	hold_for_frame()

func clear_language_trace() -> void:
	trace = {}
	editor.text = ""
	btn_step.unblock_input()
	hold_for_frame()

func get_language_op() -> StringName:
	return language_kind

func get_language_config() -> Dictionary:
	return cfg.duplicate(true)

func _can_drag() -> bool:
	return _can_drag_at(get_global_mouse_position())

func _can_drag_at(point: Vector2) -> bool:
	for control in [editor, btn_step, $ColorRect/Creativity/HSlider, $ColorRect/Candidates/HSlider]:
		if control.get_global_rect().has_point(point): return false
	return true
