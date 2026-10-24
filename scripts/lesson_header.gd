extends ColorRect

# Color(0.49, 0.627, 0.831)
# Color(0.49, 0.83, 0.614)

const SkipButtonScene := preload("res://scenes/BaseBComponent.tscn")
const SKIP_TEXT := {
	"en": "Skip tutorial",
	"ru": "Пропустить",
	"kz": "Өткізіп жіберу",
}

signal progress_panel_layout_changed(visible: bool, bottom: float)

var _skip_tour_button: BlockComponent = null
var _skip_requested := false
var _progress_panel_enabled := true
var _panel_base_color := Color.WHITE
var _base_works_color := Color.WHITE

func appear():
	target_lerps = null
	show()
	if get_parent() and "workslist_but" in get_parent() and is_instance_valid(get_parent().workslist_but):
		get_parent().workslist_but.color = Color(0.49, 0.83, 0.614)
	_apply_progress_panel_visibility()

func dissapear():
	target_lerps = null
	if get_parent() and "workslist_but" in get_parent() and is_instance_valid(get_parent().workslist_but):
		get_parent().workslist_but.color = _base_works_color
	hide()
	_update_workspace_inset()
	_emit_progress_panel_layout()

func _ready():
	_panel_base_color = color
	if get_parent() and "workslist_but" in get_parent() and is_instance_valid(get_parent().workslist_but):
		_base_works_color = get_parent().workslist_but.color
	glob.language_changed.connect(re_data)
	_ensure_skip_tour_button()
	_update_skip_tour_text()
	_apply_progress_panel_visibility()

func _enter_tree():
	ui.lesson_bar = self

func _process(delta: float) -> void:
	if not visible: return
	sizing_tick()
	#update_data({classroom_name = "Math 10A", step_index = (glob.ticks / 100) % 10 + 1, step_shorthand = "Create LoadDataset node",
	#lesson_index = 1, lesson_name = "Your First ML Model: MNIST digit classifier", total_steps = 10})
	re_data()
	if first_point and !is_equal_approx($actual.points[-1].x, target_lerps.x):
		var last_point = lerp($actual.points[-1], target_lerps, minf(1.0, delta * 10.0))
		$actual.points = PackedVector2Array([Vector2(first_point, 0), last_point])

func sizing_tick():
	$Label2.size.x = glob.get_label_text_size($Label2).x
	var skip_width := 0.0
	if is_instance_valid(_skip_tour_button) and _skip_tour_button.visible:
		skip_width = _skip_tour_button.base_size.x * _skip_tour_button.scale.x + 14.0
	$Label2.position.x = size.x - $Label2.size.x * $Label2.scale.x - 10.0 - skip_width
	_layout_skip_tour_button()

func re_data():
	_update_skip_tour_text()
	if last_data:
		update_data(last_data)


func set_interface_tour_controls(enabled: bool, show_progress: bool = true) -> void:
	_ensure_skip_tour_button()
	_skip_requested = false
	_skip_tour_button.visible = enabled
	_progress_panel_enabled = not enabled or show_progress
	_apply_progress_panel_visibility()
	_update_skip_tour_text()
	sizing_tick()


func is_progress_panel_visible() -> bool:
	return visible and _progress_panel_enabled


func get_progress_panel_bottom() -> float:
	return get_global_rect().end.y if is_progress_panel_visible() else 0.0


func _apply_progress_panel_visibility() -> void:
	var panel_visible := _progress_panel_enabled
	var next_color := _panel_base_color
	next_color.a = _panel_base_color.a if panel_visible else 0.0
	color = next_color
	$Label.visible = panel_visible
	$Label2.visible = panel_visible
	$backline.visible = panel_visible
	$actual.visible = panel_visible
	mouse_filter = Control.MOUSE_FILTER_STOP if panel_visible else Control.MOUSE_FILTER_IGNORE
	_update_workspace_inset()
	_emit_progress_panel_layout()


func _update_workspace_inset() -> void:
	var top_panel := get_parent() as Control
	if not is_instance_valid(top_panel):
		return
	var top_panel_bottom: float = top_panel.size.y + top_panel.position.y
	glob.space_begin.y = (
		top_panel_bottom + size.y - 1.0
		if is_progress_panel_visible()
		else top_panel_bottom
	)


func _emit_progress_panel_layout() -> void:
	progress_panel_layout_changed.emit(
		is_progress_panel_visible(),
		get_progress_panel_bottom()
	)


func _ensure_skip_tour_button() -> void:
	if is_instance_valid(_skip_tour_button):
		return
	_skip_tour_button = SkipButtonScene.instantiate() as BlockComponent
	_skip_tour_button.name = "SkipTour"
	_skip_tour_button.base_size = Vector2(150.0, 34.0)
	_skip_tour_button.custom_minimum_size = _skip_tour_button.base_size
	_skip_tour_button.scale = Vector2(0.72, 0.72)
	_skip_tour_button.pivot_offset = _skip_tour_button.base_size * 0.5
	_skip_tour_button.base_scale_x = 0.52
	_skip_tour_button.button_type = 1
	_skip_tour_button.top = true
	_skip_tour_button.color = Color(0.49, 0.83, 0.614)
	_skip_tour_button.text_alignment = Vector2.ZERO
	_skip_tour_button.mouse_filter = Control.MOUSE_FILTER_STOP
	var button_label := _skip_tour_button.get_node_or_null("Label") as Control
	if button_label != null:
		button_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_skip_tour_button.released.connect(_on_skip_tour_released)
	_skip_tour_button.gui_input.connect(_on_skip_tour_gui_input)
	add_child(_skip_tour_button)
	_skip_tour_button.hide()
	_layout_skip_tour_button()


func _layout_skip_tour_button() -> void:
	if not is_instance_valid(_skip_tour_button):
		return
	var rendered_control: Control = _skip_tour_button
	if is_instance_valid(_skip_tour_button._wrapped_in):
		rendered_control = _skip_tour_button._wrapped_in
	var rendered_size := rendered_control.size
	if rendered_size.is_zero_approx():
		rendered_size = _skip_tour_button.base_size * _skip_tour_button.scale
	rendered_control.position = Vector2(size.x - rendered_size.x - 8.0, 3.0)
	rendered_control.z_index = 10


func _update_skip_tour_text() -> void:
	if not is_instance_valid(_skip_tour_button):
		return
	_skip_tour_button.text = str(SKIP_TEXT.get(str(glob.get_lang()), SKIP_TEXT["en"]))


func _on_skip_tour_gui_input(event: InputEvent) -> void:
	if (
		event is InputEventMouseButton
		and event.button_index == MOUSE_BUTTON_LEFT
		and not event.pressed
	):
		accept_event()
		_on_skip_tour_released()


func _on_skip_tour_released() -> void:
	if _skip_requested:
		return
	_skip_requested = true
	if is_instance_valid(glob.startup_flow) and glob.startup_flow.has_method("dismiss_interface_tour"):
		var result: Dictionary = await glob.startup_flow.dismiss_interface_tour()
		if not result.get("ok", false):
			_skip_requested = false
	else:
		_skip_requested = false

var last_data = {}
func update_data(packet: Dictionary, force: bool = false, lerper: bool = false):
	last_data = packet
	$Label.text = str(packet["lesson_index"]) + ". " + packet["lesson_name"]
	var max_size: int = clamp(size.x / 30, 13, 99)
	#(size.x)
	if max_size < 40 and len($Label.text) > max_size:
		$Label.text = $Label.text.substr(0,max_size) + ".."
	
	var step_text = " - Step "
	if glob.curr_lang == "kz":
		step_text = " - Кезең "
	elif glob.curr_lang == "ru":
		step_text = " - Шаг "
	$Label2.text = packet["step_shorthand"] + step_text + str(packet["step_index"]) + " / " + str(int(packet["total_steps"]))

	first_point = $Label.size.x * $Label.scale.x + 50
	var last_point = $Label2.position.x - 40
	if lerper and target_lerps != null:
		print("call once")
		sizing_tick()
		var temp_target_lerps = Vector2(lerpf(first_point, last_point, (float(packet["step_index"])-1) / packet["total_steps"]), 0)
		$actual.points = PackedVector2Array([Vector2(first_point, 0), temp_target_lerps])
	$backline.points = PackedVector2Array([Vector2(first_point, 0), Vector2(last_point, 0)])
	target_lerps = Vector2(lerpf(first_point, last_point, float(packet["step_index"]) / packet["total_steps"]), 0)
	if force:
		await get_tree().process_frame
		$actual.points = PackedVector2Array([Vector2(first_point, 0), target_lerps])

var first_point = null
var target_lerps = null
