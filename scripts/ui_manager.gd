extends Control

const PlatformInput = preload("res://scripts/platform_input.gd")
const TutorialRadialHighlightCore := preload("res://scripts/tutorial_radial_highlight.gd")
const UICaptureCore := preload("res://scripts/ui_capture.gd")
const INFERENCE_ANIMATION_SETTINGS_SCENE := preload("res://scenes/inference_animation_settings.tscn")

signal control_capture_finished(request_id: int, result: Dictionary)

var _capture_request_id := 0
var _capture_results: Dictionary[int, Dictionary] = {}
var last_capture_background_hidden := false
var inference_animation_settings: Node
var _inference_animation_generation := 0
var _inference_animation_splines: Dictionary = {}
var _inference_animation_nodes: Dictionary = {}
var _inference_animation_requests: Dictionary = {}
var _inference_animation_traversals: Dictionary = {}

func is_focus(control: Control):
	if control is HSlider: return (control.get_global_rect().has_point(get_global_mouse_position()))
	return control and get_viewport().gui_get_focus_owner() == control

func graph_shot(rect: Rect2, path: String) -> void:
	#("ff")
	for i in graphs._graphs.values():
		i.set_screenshotting()
	var background_state := _hide_background_for_capture()
	#bg.set_screenshotting()
	await get_tree().process_frame

	var viewport := get_viewport()
	var viewport_image := viewport.get_texture().get_image()
	var pixel_rect := PlatformInput.texture_pixel_rect(
		rect,
		viewport.get_visible_rect().size,
		viewport_image.get_size()
	)
	var img := viewport_image.get_region(pixel_rect)
	img.save_png(path)
	last_capture_background_hidden = _background_is_hidden_for_capture(background_state)

	_restore_background_after_capture(background_state)
	#DisplayServer.clipboard_set(img)
	for i in graphs._graphs.values():
		i.set_not_screenshotting()
	#bg.set_not_screenshotting()


func capture_control(
	target: Control,
	path: String,
	options: Dictionary = {}
) -> Dictionary:
	var background_state := _hide_background_for_capture()
	var result: Dictionary = await UICaptureCore.capture_control(target, path, options)
	last_capture_background_hidden = _background_is_hidden_for_capture(background_state)
	result["background_hidden_during_capture"] = last_capture_background_hidden
	_restore_background_after_capture(background_state)
	return result


func queue_control_capture(
	target: Control,
	path: String,
	options: Dictionary = {}
) -> int:
	_capture_request_id += 1
	var request_id := _capture_request_id
	_capture_results.erase(request_id)
	_run_queued_control_capture.call_deferred(request_id, target, path, options.duplicate(true))
	return request_id


func control_capture_result(request_id: int) -> Dictionary:
	return _capture_results.get(request_id, {})


func _run_queued_control_capture(
	request_id: int,
	target: Control,
	path: String,
	options: Dictionary
) -> void:
	var result := await capture_control(target, path, options)
	_capture_results[request_id] = result
	control_capture_finished.emit(request_id, result)


func _hide_background_for_capture() -> Dictionary:
	var background: CanvasLayer = _active_background()
	if not is_instance_valid(background):
		return {}
	if background.has_method("hide_for_capture"):
		return {
			"background": background,
			"state": background.hide_for_capture(),
		}
	var state := {"visible": background.visible}
	background.visible = false
	return {"background": background, "state": state}


func _active_background() -> CanvasLayer:
	var active_window = glob.tree_windows.get(glob.curr_window)
	if is_instance_valid(active_window) and active_window.has_method("get_background"):
		var active_background = active_window.get_background() as CanvasLayer
		if is_instance_valid(active_background):
			return active_background
	return glob.bg_trect


func _restore_background_after_capture(capture_state: Dictionary) -> void:
	var background: CanvasLayer = capture_state.get("background")
	if not is_instance_valid(background):
		return
	var state: Dictionary = capture_state.get("state", {})
	if background.has_method("restore_after_capture"):
		background.restore_after_capture(state)
		return
	background.visible = bool(state.get("visible", true))


func _background_is_hidden_for_capture(capture_state: Dictionary) -> bool:
	var background: CanvasLayer = capture_state.get("background")
	if not is_instance_valid(background):
		return true
	if background.has_method("is_hidden_for_capture"):
		return bool(background.is_hidden_for_capture())
	return not background.visible

var mist: ColorRect
var is_ai_building: bool = false
func set_ai_building():
	#return
	# TODO: make it look good
	
	is_ai_building = true
	axon_donut.target_visible()
	mist.target_visible()

func set_uni(who, what, val):
	who.material.set_shader_parameter(what, val)
func get_uni(who, what):
	return who.material.get_shader_parameter(what)

func stop_ai_building():
	#return
	
	
	is_ai_building = false
	axon_donut.target_invisible()
	mist.target_invisible()



func get_focus():
	return get_viewport().gui_get_focus_owner()

var topr: Control = null

func set_topr_text(text: String):
	topr.show_text(text)

func hide_topr():
	topr.hide()

var _active_splashed: bool = false

func active_splashed() -> bool:
	return _active_splashed

var mouse_buttons: Dictionary = {1: true, 2: true, 3: true}
var wheel_buttons: Dictionary = {
	MOUSE_BUTTON_WHEEL_UP: true,
	MOUSE_BUTTON_WHEEL_DOWN: true,
	MOUSE_BUTTON_WHEEL_LEFT: true,
	MOUSE_BUTTON_WHEEL_RIGHT: true,
}

func line_block(line: LineEdit):
	line.editable = false
	line.selecting_enabled = false
	line.release_focus()
	line.mouse_filter = MOUSE_FILTER_IGNORE

func line_unblock(line: LineEdit):
	line.editable = true
	line.selecting_enabled = true
	line.mouse_filter = MOUSE_FILTER_STOP

func window_changed(who):
	if is_ai_building:
		if who == "graph":
			axon_donut.resume()
			mist.show()
		else:
			axon_donut.stop()
			mist.hide()

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		if event.button_index in wheel_buttons:
			var hovered = get_viewport().gui_get_hovered_control()
			if hovered and hovered is Slider:
				accept_event()
				return
	#	elif event.button_index == MOUSE_BUTTON_LEFT:
	#		print(get_focus())

	if event is InputEventMouse:
		var focused = get_viewport().gui_get_focus_owner()
		#var occ = glob.is_occupied(focused, "menu_inside")
		#(occ)
		if event is InputEventMouseButton and event.pressed:
			#(glob.is_occupied(focused, "menu_inside"))
			if event.button_index in mouse_buttons:
				if focused and (focused is LineEdit or focused is Slider or focused is TextEdit or focused is RichTextLabel):
					var rect = focused.get_global_rect()
					if not rect.has_point(get_global_mouse_position()) and not event.has_meta("_emulated"):
						focused.release_focus()
						#if focused is ValidInput:
						focused.focus_exited.emit()
		elif not glob.mouse_pressed:
			if focused is Slider and not event.has_meta("_emulated"):
				#("fj")
				focused.release_focus()
				focused.focus_exited.emit()

var expanded_menu: SubMenu = null
var _buttons = []

func move_mouse(pos: Vector2) -> void:
	var vp = get_viewport()
	var motion = InputEventMouseMotion.new()
	motion.global_position = pos
	motion.position = pos
	motion.relative = Vector2.ZERO
	motion.set_meta("_emulated", true)

	vp.push_input(motion)


var topr_inside: bool = false

var topr_state = {}
func upd_topr_inside(who: Object, val: bool):
	if val:
		topr_state[who] = true
	else:
		topr_state.erase(who)
	topr_inside = len(topr_state) > 0




func ask(packet: Dictionary):
	pass



#var _parent_graphs = {}
func reg_button(b: BlockComponent):
	pass
	#_parent_graphs[b] = [b.graph, b.graph.z_index if b.graph else 0]

func unreg_button(b: BlockComponent):
	pass

var axon_donut: Control

func conf_screen():
	for i in 10:
		await glob.wait(randf_range(0.1,0.4))
		confetti((Vector2(randi_range(0, glob.window_size.x), randi_range(0, glob.window_size.y))), true)
	#confetti((Vector2(glob.window_size.x - 50, 100)), true)
	#confetti((Vector2(glob.window_size.x/2, glob.window_size.y/2)), true)
	#confetti((Vector2(50, glob.window_size.y -50)), true)

func a():
	await confetti(get_global_mouse_position())

var fork = load("res://resources/fork.tscn")

func get_fork():
	return fork.instantiate()

func _process(delta: float):
	#if glob.space_just_pressed:
	#	set_ai_building()
	#	set_dense_units(1, 16)
	#print(splashed)
	var ct: int = 0
	for i in splashed.keys():
		if not is_instance_valid(i): splashed.erase(i); continue
		if not i.visible: splashed.erase(i); continue
		# Hidden persistent menus and docked panels do not block the canvas.
		if (i.persistent and not i.visible) or i.docked:
			ct += 1
	for i in splashed_in.keys():
		if not is_instance_valid(i): splashed_in.erase(i); continue
		if not i.visible: splashed_in.erase(i); continue
	_active_splashed = len(splashed) != ct
	#(_active_splashed)
#	print(get_viewport().gui_get_focus_owner())


## Starts a visual-only BFS from the input that dispatched a real request.
## With no arguments it remains available as the Space debug preview.
func start_inference_anim(input_graph: Graph = null, request_id: int = -1) -> bool:
	if not is_instance_valid(input_graph):
		input_graph = _find_inference_animation_input()
	if not is_instance_valid(input_graph):
		return false
	if request_id >= 0:
		var active_requests: Dictionary = _inference_animation_requests.get(input_graph, {})
		active_requests[request_id] = true
		_inference_animation_requests[input_graph] = active_requests
	var generation := _inference_animation_generation
	if request_id >= 0:
		var traversals: Dictionary = _inference_animation_traversals.get(input_graph, {})
		traversals[request_id] = int(traversals.get(request_id, 0)) + 1
		_inference_animation_traversals[input_graph] = traversals
		_run_inference_animation_traversal(input_graph, request_id, generation)
	else:
		_run_inference_animation_preview(input_graph, generation)
	return true


func stop_inference_anim() -> void:
	_inference_animation_generation += 1
	for tracked_splines in _inference_animation_splines.values():
		for spline in tracked_splines:
			if is_instance_valid(spline):
				spline.stop_inference_flow()
	for tracked_nodes in _inference_animation_nodes.values():
		for graph in tracked_nodes:
			if is_instance_valid(graph):
				graph.stop_inference_highlight()
	_inference_animation_splines.clear()
	_inference_animation_nodes.clear()
	_inference_animation_requests.clear()
	_inference_animation_traversals.clear()


func finish_inference_anim(input_graph: Graph, request_id: int) -> void:
	if not _inference_animation_requests.has(input_graph):
		return
	var active_requests: Dictionary = _inference_animation_requests[input_graph]
	active_requests.erase(request_id)
	if not active_requests.is_empty():
		_inference_animation_requests[input_graph] = active_requests
	else:
		_inference_animation_requests.erase(input_graph)
	_release_inference_animation_if_idle(input_graph)


func _run_inference_animation_traversal(input_graph: Graph, request_id: int, generation: int) -> void:
	await _play_inference_animation_bfs(input_graph, generation)
	if generation != _inference_animation_generation or not _inference_animation_traversals.has(input_graph):
		return
	var traversals: Dictionary = _inference_animation_traversals[input_graph]
	var remaining := int(traversals.get(request_id, 0)) - 1
	if remaining > 0:
		traversals[request_id] = remaining
	else:
		traversals.erase(request_id)
	if traversals.is_empty():
		_inference_animation_traversals.erase(input_graph)
	else:
		_inference_animation_traversals[input_graph] = traversals
	_release_inference_animation_if_idle(input_graph)


func _run_inference_animation_preview(input_graph: Graph, generation: int) -> void:
	await _play_inference_animation_bfs(input_graph, generation)
	if generation == _inference_animation_generation:
		_release_inference_animation_if_idle(input_graph)


func _release_inference_animation_if_idle(input_graph: Graph) -> void:
	if _inference_animation_requests.has(input_graph):
		return
	if _inference_animation_traversals.has(input_graph):
		return
	var release_delay := float(inference_animation_settings.get("spline_release_delay"))
	var tail_duration := float(inference_animation_settings.get("spline_tail_duration"))
	var tracked_splines: Dictionary = _inference_animation_splines.get(input_graph, {})
	var tracked_nodes: Dictionary = _inference_animation_nodes.get(input_graph, {})
	# Spline and Graph own their graceful tails from this point. Forgetting the
	# coordinator entries prevents freed project graphs accumulating as keys.
	_inference_animation_splines.erase(input_graph)
	_inference_animation_nodes.erase(input_graph)
	for spline in tracked_splines:
		if is_instance_valid(spline):
			spline.release_inference_flow(release_delay, tail_duration)
	for graph in tracked_nodes:
		if is_instance_valid(graph):
			graph.release_inference_highlight(
			release_delay,
			float(inference_animation_settings.get("node_highlight_fade_out")),
		)


func _on_inference_dispatched(input_graph: Graph, request_id: int) -> void:
	start_inference_anim(input_graph, request_id)


func _on_inference_visual_repeated(input_graph: Graph, request_id: int) -> void:
	# The pending local payload has no request id yet. Reuse the in-flight id
	# only to add visual energy; its actual dispatch receives a fresh id later.
	start_inference_anim(input_graph, request_id)


func _on_inference_finished(input_graph: Graph, request_id: int) -> void:
	finish_inference_anim(input_graph, request_id)


func _on_inference_failed(input_graph: Graph, request_id: int, _error_data: Variant) -> void:
	finish_inference_anim(input_graph, request_id)


func _find_inference_animation_input() -> Graph:
	for graph: Graph in graphs._graphs.values():
		if is_instance_valid(graph) and graphs.GraphRoles.is_numeric_input(graph):
			return graph
	return null


func _play_inference_animation_bfs(input_graph: Graph, generation: int) -> void:
	if generation != _inference_animation_generation or not is_instance_valid(input_graph):
		return
	var visited: Dictionary[Graph, bool] = {input_graph: true}
	var level: Array[Graph] = [input_graph]
	while not level.is_empty():
		if generation != _inference_animation_generation:
			return
		var next_level: Array[Graph] = []
		for graph in level:
			if not is_instance_valid(graph):
				continue
			var tracked_nodes: Dictionary = _inference_animation_nodes.get(input_graph, {})
			tracked_nodes[graph] = true
			_inference_animation_nodes[input_graph] = tracked_nodes
			_highlight_inference_node(graph)

			for spline in _outgoing_inference_splines(graph):
				if generation != _inference_animation_generation:
					return
				var tracked_splines: Dictionary = _inference_animation_splines.get(input_graph, {})
				tracked_splines[spline] = true
				_inference_animation_splines[input_graph] = tracked_splines
				var flow_color: Color = inference_animation_settings.get("spline_flow_color")
				spline.energize_inference_flow(
					float(inference_animation_settings.get("spline_flow_duration")),
					flow_color,
					float(inference_animation_settings.get("spline_initial_energy")),
					float(inference_animation_settings.get("spline_repeat_energy")),
					float(inference_animation_settings.get("spline_max_energy")),
					float(inference_animation_settings.get("spline_release_delay")),
					float(inference_animation_settings.get("spline_tail_duration")),
				)
				var target_graph := spline.tied_to.parent_graph if is_instance_valid(spline.tied_to) else null
				if is_instance_valid(target_graph) and not visited.has(target_graph):
					visited[target_graph] = true
					next_level.append(target_graph)
		if next_level.is_empty():
			return
		var hop_delay := maxf(0.0, float(inference_animation_settings.get("hop_delay")))
		if hop_delay > 0.0:
			await get_tree().create_timer(hop_delay).timeout
		level = next_level


func _highlight_inference_node(graph: Graph) -> void:
	var highlight_color: Color = inference_animation_settings.get("node_highlight_color")
	graph.energize_inference_highlight(
		highlight_color,
		float(inference_animation_settings.get("node_highlight_fade_in")),
		float(inference_animation_settings.get("node_highlight_hold")),
		float(inference_animation_settings.get("node_highlight_fade_out")),
		float(inference_animation_settings.get("node_highlight_shadow_opacity")),
		float(inference_animation_settings.get("node_repeat_energy")),
		float(inference_animation_settings.get("node_max_energy")),
	)


func _outgoing_inference_splines(graph: Graph) -> Array[Spline]:
	var result: Array[Spline] = []
	for output: Connection in graph.outputs:
		for spline: Spline in output.outputs.values():
			if is_instance_valid(spline) and is_instance_valid(spline.tied_to):
				result.append(spline)
	result.sort_custom(func(left: Spline, right: Spline) -> bool:
		return left.get_instance_id() < right.get_instance_id()
	)
	return result
			

var splashed_in = {}
var blur = preload("res://scenes/blur.tscn").instantiate()
const MULTIPURPOSE_DIALOG_SCENE := preload("res://scenes/multipurpose_dialog.tscn")
const DialogSpecCore := preload("res://scripts/dialog_spec.gd")
var splash_menus = {
	"login": preload("res://scenes/splash.tscn"),
	"signup": preload("res://scenes/signup.tscn"),
	"scene_create": preload("res://scenes/scene_create.tscn"),
	"dataset_create": preload("res://scenes/dataset_create.tscn"),
	"works": preload("res://scenes/works.tscn"),
	"workslist": preload("res://scenes/workslist.tscn"),
	"builtin_projects": preload("res://scenes/builtin_projects_window.tscn"),
	"lessonslist": preload("res://scenes/lessonlist.tscn"),
	"settings": preload("res://scenes/settings.tscn"),
	"project_create": preload("res://scenes/project_create.tscn"),
	"ai_help": preload("res://scenes/ai_help.tscn"),
	"select_dataset": preload("res://scenes/select_dataset.tscn"),
	"select_vocabulary": preload("res://scenes/select_vocabulary.tscn"),
	"model_export": preload("res://scenes/model_export.tscn"),
	"path_open": preload("res://scenes/path_open.tscn"),
	"classroom_create": preload("res://scenes/classroom_create.tscn"),
	"home": preload("res://scenes/home.tscn"),
}

var quest: Quest = null

func confetti(at: Vector2, screen: bool = false):
	var conf = ConfettiSplash.new()
	if screen:
		conf.position = at / 2
		glob.scale_fg.add_child(conf)
	else:
		conf.position = at
		add_child(conf)
	await conf.die

var conf_config = preload("res://resources/confetti.tres")
var quest_scene = preload("res://scenes/quest.tscn")
func recreate_quest():
	var old_pos = quest.position
	var p = quest.get_parent()
	quest.queue_free()
	var q = (quest_scene.instantiate())
	p.add_child(q)
	q.position = old_pos

var cl = CanvasLayer.new()
var tutorial_arrow_layer = CanvasLayer.new()
var tutorial_attention_layer = CanvasLayer.new()
var hg = preload("res://scenes/hourglass.tscn")
var hourglass: TextureRect

const ERROR_TOAST_LIMIT := 4
const ERROR_TOAST_WIDTH := 420.0
const ERROR_TOAST_HEIGHT := 96.0
const ERROR_TOAST_MARGIN := 20.0
const ERROR_TOAST_GAP := 10.0
var _error_toasts: Array[PanelContainer] = []

func hourglass_on():
	hourglass.on()

func hourglass_off():
	hourglass.off()

func show_lock():
	await quest.hide_request()
	quest.say(["✋ Подожди, пока другие ученики закончат. Скажи учителю что ты ожидаешь следующего шага."], false, false, Color.YELLOW)

func hide_lock():
	await quest.hide_request()

var chosen = {}

var arrows = {}
var tutorial_highlights: Dictionary = {}
const TUTORIAL_TARGET_GROUP := &"tutorial_ui_target"
const TUTORIAL_TARGET_META := &"tutorial_target_id"
const UI_ARROW_DISTANCE := 74.0
const UI_ARROW_TIP_GAP := 18.0
const DEFAULT_TUTORIAL_ARROW_STYLE := {
	"color": Color.CORAL,
	"thickness": 3.0,
	"head_size": 12.0,
	"wobble_amplitude": 50.0,
	"shadow": {
		"enabled": false,
		"color": Color(0.0, 0.0, 0.0, 0.65),
		"offset": Vector2(4.0, 5.0),
		"thickness_add": 4.0,
		"head_size_add": 5.0,
	},
}
const DEFAULT_TUTORIAL_HIGHLIGHT_STYLE := {
	"center_opacity": 0.5,
	"padding": 24.0,
	"fade_in": 0.16,
	"fade_out": 0.18,
}

var _tutorial_arrow_style: Dictionary = DEFAULT_TUTORIAL_ARROW_STYLE.duplicate(true)
var _tutorial_highlight_style: Dictionary = DEFAULT_TUTORIAL_HIGHLIGHT_STYLE.duplicate(true)


func configure_tutorial_ui(config: Dictionary) -> void:
	reset_tutorial_ui_config()
	_merge_tutorial_style(_tutorial_arrow_style, config.get("arrow_style", {}))
	_merge_tutorial_style(_tutorial_highlight_style, config.get("highlight_style", {}))


func reset_tutorial_ui_config() -> void:
	_tutorial_arrow_style = DEFAULT_TUTORIAL_ARROW_STYLE.duplicate(true)
	_tutorial_highlight_style = DEFAULT_TUTORIAL_HIGHLIGHT_STYLE.duplicate(true)


func _merge_tutorial_style(target: Dictionary, source: Variant) -> void:
	if typeof(source) != TYPE_DICTIONARY:
		return
	for key in source:
		var value: Variant = source[key]
		if typeof(value) == TYPE_DICTIONARY and typeof(target.get(key)) == TYPE_DICTIONARY:
			var nested_target: Dictionary = target[key]
			_merge_tutorial_style(nested_target, value)
		else:
			target[key] = value


func tutorial_target(target_id: String) -> Control:
	var normalized := target_id.strip_edges()
	if normalized.is_empty():
		return null
	for candidate in get_tree().get_nodes_in_group(TUTORIAL_TARGET_GROUP):
		if not candidate is Control:
			continue
		if str(candidate.get_meta(TUTORIAL_TARGET_META, "")) != normalized:
			continue
		var control := candidate as Control
		if control.is_visible_in_tree():
			return control
	return null


func show_arrow_ui(target_id: String, side: String = "bottom") -> bool:
	var target := tutorial_target(target_id)
	if not is_instance_valid(target):
		push_warning("Tutorial UI target is unavailable: %s" % target_id)
		return false
	var normalized_side := side if side in ["top", "bottom", "left", "right"] else "bottom"
	var tip := _tutorial_target_tip(target, normalized_side)
	var outward := _tutorial_arrow_outward(normalized_side)
	show_arrow(
		tip + outward * UI_ARROW_DISTANCE,
		tip + outward * UI_ARROW_TIP_GAP,
		Callable(self, "_tutorial_target_tip_for_id").bind(target_id, normalized_side),
		tutorial_arrow_layer
	)
	return true


func show_highlight_ui(target_id: String) -> bool:
	var target := tutorial_target(target_id)
	if not is_instance_valid(target):
		push_warning("Tutorial UI target is unavailable: %s" % target_id)
		return false
	if tutorial_highlights.has(target_id):
		var old: Variant = tutorial_highlights[target_id]
		if is_instance_valid(old):
			old.disappear()
	var highlight := TutorialRadialHighlightCore.new()
	highlight.configure(_tutorial_highlight_style)
	tutorial_attention_layer.add_child(highlight)
	tutorial_highlights[target_id] = highlight
	_update_tutorial_highlight(target_id, highlight)
	_follow_tutorial_highlight(target_id, highlight)
	highlight.appear()
	return true


func _follow_tutorial_highlight(target_id: String, highlight: Variant) -> void:
	glob.tween_call({}, func(_data, _delta):
		if not is_instance_valid(highlight):
			return true
		var target := tutorial_target(target_id)
		highlight.visible = is_instance_valid(target)
		if is_instance_valid(target):
			_update_tutorial_highlight(target_id, highlight)
	)


func _update_tutorial_highlight(target_id: String, highlight: Variant) -> void:
	var target := tutorial_target(target_id)
	if not is_instance_valid(target) or not is_instance_valid(highlight):
		return
	highlight.place_over(_tutorial_target_viewport_rect(target), tutorial_attention_layer.transform)


func _tutorial_target_viewport_rect(target: Control) -> Rect2:
	var xform := target.get_global_transform_with_canvas()
	var points := [
		xform * Vector2.ZERO,
		xform * Vector2(target.size.x, 0.0),
		xform * target.size,
		xform * Vector2(0.0, target.size.y),
	]
	var rect := Rect2(points[0], Vector2.ZERO)
	for point in points.slice(1):
		rect = rect.expand(point)
	return rect


func hide_ui_highlights() -> void:
	for highlight in tutorial_highlights.values():
		if is_instance_valid(highlight):
			highlight.disappear()
	tutorial_highlights.clear()


func wait_for_tutorial_ui(target_id: String, lesson: Variant = null) -> bool:
	var normalized := target_id.strip_edges()
	if normalized.is_empty():
		return false
	while true:
		if not _tutorial_wait_is_active(lesson):
			return false
		var target := tutorial_target(normalized)
		if not is_instance_valid(target):
			await get_tree().process_frame
			continue
		var state := {"activated": false}
		var released_callback := func(): state["activated"] = true
		var input_callback := func(event: InputEvent):
			if (
				event is InputEventMouseButton
				and event.button_index == MOUSE_BUTTON_LEFT
				and not event.pressed
			):
				state["activated"] = true
		var uses_released := target.has_signal("released")
		if uses_released:
			target.connect("released", released_callback)
		else:
			target.gui_input.connect(input_callback)
		while (
			is_instance_valid(target)
			and target.is_visible_in_tree()
			and not state["activated"]
			and _tutorial_wait_is_active(lesson)
		):
			await get_tree().process_frame
		if is_instance_valid(target):
			if uses_released and target.is_connected("released", released_callback):
				target.disconnect("released", released_callback)
			elif not uses_released and target.gui_input.is_connected(input_callback):
				target.gui_input.disconnect(input_callback)
		if state["activated"]:
			return true
		if not _tutorial_wait_is_active(lesson):
			return false
	return false


func wait_for_tutorial_dialog_closed(dialog_id: String, lesson: Variant = null) -> bool:
	var normalized := dialog_id.strip_edges()
	if normalized.is_empty():
		return false
	for _frame in 60:
		if not _tutorial_wait_is_active(lesson):
			return false
		var dialog: Variant = active_dialogs.get(normalized)
		if not is_instance_valid(dialog):
			dialog = get_splash(normalized)
		if is_instance_valid(dialog):
			while is_instance_valid(dialog):
				if not _tutorial_wait_is_active(lesson):
					return false
				await get_tree().process_frame
			return true
		await get_tree().process_frame
	return false


func _tutorial_wait_is_active(lesson: Variant) -> bool:
	if lesson == null:
		return true
	if not is_instance_valid(lesson):
		return false
	return int(lesson.get("current_step_index")) >= 0


func _tutorial_target_tip_for_id(target_id: String, side: String) -> Variant:
	var target := tutorial_target(target_id)
	if not is_instance_valid(target):
		return null
	return _tutorial_target_tip(target, side)


func _tutorial_target_tip(target: Control, side: String) -> Vector2:
	var local_tip: Vector2
	match side:
		"top":
			local_tip = Vector2(target.size.x * 0.5, 0.0)
		"left":
			local_tip = Vector2(0.0, target.size.y * 0.5)
		"right":
			local_tip = Vector2(target.size.x, target.size.y * 0.5)
		_:
			local_tip = Vector2(target.size.x * 0.5, target.size.y)
	var viewport_tip := target.get_global_transform_with_canvas() * local_tip
	if is_instance_valid(tutorial_arrow_layer) and tutorial_arrow_layer.is_inside_tree():
		return tutorial_arrow_layer.transform.affine_inverse() * viewport_tip
	return get_global_transform_with_canvas().affine_inverse() * viewport_tip


func _tutorial_arrow_outward(side: String) -> Vector2:
	match side:
		"top":
			return Vector2.UP
		"left":
			return Vector2.LEFT
		"right":
			return Vector2.RIGHT
		_:
			return Vector2.DOWN


func hide_arrows():
	await glob.tween_call({}, func(data, delta):
		for i in arrows.keys():
			arrows[i] = false
			i.modulate.a = lerpf(i.modulate.a, 0.0, minf(1.0, delta * 20.0))
			if i.modulate.a < 0.01:
				i.queue_free()
				arrows.erase(i)
		if not arrows:
			return true
		)

func show_arrow_conn(points_to: Connection):
	show_arrow(points_to.dir_vector * 50 + points_to.get_origin(), 
	points_to.dir_vector * 10 + points_to.get_origin(), func(): return points_to.get_origin() if is_instance_valid(points_to) else null)

func prect(points_to):
	var lx = Vector2(0.5,1)
	var g = points_to.rect.get_global_rect()
	return Vector2(lerp(g.position.x, g.end.x, lx.x), lerp(g.position.y, g.end.y, lx.y))

func show_arrow_graph(points_to: Graph):
	show_arrow(prect(points_to) + 100 * Vector2.DOWN, 
	prect(points_to) + 40 * Vector2.DOWN, func(): return prect(points_to) if is_instance_valid(points_to) else null)


func base(): return Vector2()

func show_arrow(start: Vector2, end: Vector2, rel: Callable = base, arrow_parent: Node = null):
	var arrow := Arrow2D.new()
	var resolved_parent := arrow_parent if is_instance_valid(arrow_parent) else self
	resolved_parent.add_child(arrow)

	arrow.position = start
	arrow.end = end - start
	arrow.color = _tutorial_arrow_style.get("color", Color.CORAL)
	arrow.thickness = float(_tutorial_arrow_style.get("thickness", 3.0))
	arrow.end_size = float(_tutorial_arrow_style.get("head_size", 12.0))
	var shadow: Dictionary = _tutorial_arrow_style.get("shadow", {})
	arrow.shadow_enabled = bool(shadow.get("enabled", false))
	arrow.shadow_color = shadow.get("color", Color(0.0, 0.0, 0.0, 0.65))
	arrow.shadow_offset = shadow.get("offset", Vector2(4.0, 5.0))
	arrow.shadow_thickness_add = float(shadow.get("thickness_add", 4.0))
	arrow.shadow_end_size_add = float(shadow.get("head_size_add", 5.0))
	arrow.modulate.a = 0.0

	var normal := start.direction_to(end)
	var anchor = arrow.position - rel.call()

	glob.tween_call({ t = 0.0 }, func(data, delta):
		if not is_instance_valid(arrow):
			return true
			

		data.t += delta

		# Fade-in
		if arrows.get(arrow, false):
			arrow.modulate.a = lerpf(
				arrow.modulate.a,
				1.0,
				delta * FADE_SPEED
			)

		# Damped oscillation
		var amplitude := float(_tutorial_arrow_style.get("wobble_amplitude", WOBBLE_AMPL)) * exp(-DAMPING * data.t)
		var offset := normal * sin(data.t * WOBBLE_FREQ) * amplitude
		
		var c = rel.call()
		if c is Vector2:
			arrow.position = c + anchor + offset

	)

	arrows[arrow] = true


const WOBBLE_FREQ := 8.0      # radians/sec
const WOBBLE_AMPL := 50.0    # pixels
const DAMPING := 1.5         # higher = faster settle
const FADE_SPEED := 3


func _ready():
	inference_animation_settings = INFERENCE_ANIMATION_SETTINGS_SCENE.instantiate()
	add_child(inference_animation_settings)
	if not nn.inference_dispatched.is_connected(_on_inference_dispatched):
		nn.inference_dispatched.connect(_on_inference_dispatched)
	if not nn.inference_visual_repeated.is_connected(_on_inference_visual_repeated):
		nn.inference_visual_repeated.connect(_on_inference_visual_repeated)
	if not nn.inference_finished.is_connected(_on_inference_finished):
		nn.inference_finished.connect(_on_inference_finished)
	if not nn.inference_failed.is_connected(_on_inference_failed):
		nn.inference_failed.connect(_on_inference_failed)
	tutorial_attention_layer.layer = 129
	add_child(tutorial_attention_layer)
	tutorial_arrow_layer.layer = 130
	add_child(tutorial_arrow_layer)
	cl.layer = 128
	add_child(cl)
	blur.self_modulate.a = 0
	cl.add_child(blur)
	var inst: Control = hg.instantiate()
	hourglass = inst
	hourglass.hide()
	cl.add_child(inst)
	inst.scale = Vector2.ONE * 2.0
	#inst.position = Vector2(30,30)
	#inst.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	inst.set_anchors_and_offsets_preset(Control.PRESET_BOTTOM_LEFT, Control.PRESET_MODE_KEEP_HEIGHT, 39)
	inst.z_index = 90
	
	configure_richtext_theme_auto(header_theme, header_font, base_font)

var splashed = {}

func add_splashed(who: SplashMenu):
	splashed[who] = true

func rem_splashed(who: SplashMenu):
	splashed.erase(who)

func is_splashed(who: String) -> bool:
	for i in splashed:
		if i.typename == who: return true
	return false

func get_splash(who: String) -> SplashMenu:
	for i in splashed:
		if i.typename == who: return i
	return null

func force_layout_update(node: Control):
	node.propagate_call("minimum_size_changed")
	node.propagate_call("queue_sort")
	node.propagate_call("size_flags_changed")
	node.propagate_call("update_minimum_size")
	node.propagate_call("update")
	node.propagate_call("notification", [NOTIFICATION_LAYOUT_DIRECTION_CHANGED])

func close_top_level_splashes(except_typename: String = "") -> void:
	for s in splashed.keys():
		if not is_instance_valid(s): continue
		if s.inner: continue
		if s.persistent: continue # optional: keep persistent ones
		if except_typename != "" and s.typename == except_typename: continue
		s.can_go = true
		s.go_away()

var nodes_choosing: bool = false

func nodes_choosing_on():
	nodes_choosing = true
	for graph: Graph in graphs._graphs.values():
		graph.enter_selection_mode()

func mark_chosen(who):
	chosen[who] = true

func unmark_chosen(who):
	chosen.erase(who)

func choose():
	print("CHOOSING STUFF...")
	nodes_choosing_on()
	await choosing_finished
	return lock_chosen()

signal choosing_finished






func emphasize_nodes(nodes):
	glob.cam.emp_node(nodes if nodes is Array else [nodes])
	for i in nodes:
		if i is Graph:
			i.blink()
		else:
			graphs._graphs[i].blink()


func lock_chosen():
	nodes_choosing = false
	for graph: Graph in graphs._graphs.values():
		graph.exit_selection_mode()
	for graph: Graph in graphs._graphs.values():
		graph.exit_selection_mode()
	var old_chosen = chosen
	chosen = {}
	return old_chosen

func highlight_node(move_viewport: bool = false):
	pass

func hide_splash():
	close_top_level_splashes()

func preload_splash_menu(menu: String) -> void:
	if not menu in splash_menus or menu in already_splashed:
		return
	var m: SplashMenu = splash_menus[menu].instantiate()
	m.show_on_ready = false
	m.hide()
	m.tree_exited.connect(func(): already_splashed.erase(menu))
	cl.add_child(m)
	already_splashed[menu] = m

func splash(menu: String, splashed_from = null, emitter_ = null, inner = false, passed_data = null) -> SplashMenu:
	hourglass.off(true)
	#(menu)
	#_stack()
#	close_top_level_splashes(menu)
	if splashed_from:
		if !is_splashed(menu):
			splashed_from.in_splash = true
		else:
			splashed_from.in_splash = false
			get_splash(menu).go_away()
			return null
	var m: SplashMenu 
	if menu in already_splashed:
		m = already_splashed[menu]
	else:
		m = splash_menus[menu].instantiate()
	m.inner = inner
	hide_topr()
	if passed_data: m.passed_data = passed_data
	if not menu in already_splashed:
		m.tree_exited.connect(func(): already_splashed.erase(menu))
		cl.add_child(m)
	else:
		m.readys()
		m.splash()
	already_splashed[menu] = m
	m.splashed_from = splashed_from
	var emitter = ResultEmitter.new() if !emitter_ else emitter_
	m.emitter = emitter
	if splashed_from:
		emitter.res.connect(func(...args): splashed_from.in_splash = false)
	return m

func error(text: String) -> void:
	print(text)
	var toast := PanelContainer.new()
	toast.name = "ErrorToast"
	toast.add_to_group("ui_error_toast")
	toast.custom_minimum_size = Vector2(ERROR_TOAST_WIDTH, ERROR_TOAST_HEIGHT)
	toast.clip_contents = true
	toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	toast.z_index = 200
	toast.modulate.a = 0.0

	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.73, 0.12, 0.16, 0.97)
	style.border_color = Color(1.0, 0.48, 0.5, 0.9)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 12
	style.content_margin_bottom = 12
	toast.add_theme_stylebox_override("panel", style)

	var label := Label.new()
	label.text = text
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.max_lines_visible = 3
	label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color.WHITE)
	toast.add_child(label)

	cl.add_child(toast)
	_error_toasts.append(toast)
	while _error_toasts.size() > ERROR_TOAST_LIMIT:
		_dismiss_error_toast(_error_toasts.front(), true)
	_reflow_error_toasts(true)
	_expire_error_toast(toast)
	_reflow_error_toasts.call_deferred(false)


func _toast_viewport_size() -> Vector2:
	var viewport_size := glob.window_size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = get_viewport().get_visible_rect().size
	return viewport_size


func _reflow_error_toasts(animate_newest: bool = false) -> void:
	var viewport_size := _toast_viewport_size()
	var toast_width := minf(ERROR_TOAST_WIDTH, maxf(220.0, viewport_size.x - ERROR_TOAST_MARGIN * 2.0))
	var next_bottom := viewport_size.y - ERROR_TOAST_MARGIN
	for index in range(_error_toasts.size() - 1, -1, -1):
		var toast := _error_toasts[index]
		if not is_instance_valid(toast):
			continue
		var toast_height := ERROR_TOAST_HEIGHT
		toast.custom_minimum_size = Vector2(toast_width, toast_height)
		toast.size = Vector2(toast_width, toast_height)
		next_bottom -= toast_height
		var target := Vector2(viewport_size.x - toast_width - ERROR_TOAST_MARGIN, next_bottom)
		toast.set_meta("target_y", target.y)
		var is_newest := index == _error_toasts.size() - 1
		if animate_newest and is_newest and toast.modulate.a <= 0.01:
			toast.position = target + Vector2(0.0, 18.0)
		var tween := toast.create_tween().set_parallel(true)
		tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.tween_property(toast, "position", target, 0.22)
		tween.tween_property(toast, "modulate:a", 1.0, 0.18)
		next_bottom -= ERROR_TOAST_GAP


func _expire_error_toast(toast: PanelContainer) -> void:
	await get_tree().create_timer(5.0).timeout
	_dismiss_error_toast(toast)


func _dismiss_error_toast(toast: PanelContainer, overflow := false) -> void:
	if not is_instance_valid(toast):
		return
	var index := _error_toasts.find(toast)
	if index >= 0:
		_error_toasts.remove_at(index)
	if toast.is_in_group("ui_error_toast"):
		toast.remove_from_group("ui_error_toast")
	_reflow_error_toasts()
	var tween := toast.create_tween().set_parallel(true)
	tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_property(toast, "modulate:a", 0.0, 0.16 if overflow else 0.25)
	tween.tween_property(toast, "position:y", toast.position.y - 12.0, 0.2)
	tween.chain().tween_callback(toast.queue_free)

class ResultEmitter:
	signal res(data: Dictionary, who: String)

var already_splashed: Dictionary = {}
var active_dialogs: Dictionary = {}
signal result_emit(data: Dictionary)


func show_dialog(spec: Dictionary) -> SplashMenu:
	var viewport_size := glob.window_size
	if viewport_size.x <= 1.0 or viewport_size.y <= 1.0:
		viewport_size = get_viewport().get_visible_rect().size
	var normalized := DialogSpecCore.normalize(spec, glob.get_lang(), viewport_size)
	var dialog_id: String = normalized["id"]
	var splashed_from: Variant = spec.get("splashed_from", null)
	var existing = active_dialogs.get(dialog_id)
	if is_instance_valid(existing):
		# Match legacy splash toggle behaviour: a source button pressed while its
		# dialog is already open closes it instead of returning/reopening it.
		if splashed_from is BlockComponent:
			if existing.has_method("dismiss_with_splash_animation"):
				existing.dismiss_with_splash_animation()
			else:
				existing.go_away()
			return null
		return existing

	var dialog = MULTIPURPOSE_DIALOG_SCENE.instantiate()
	dialog.configure(spec, glob.get_lang(), viewport_size)
	# Dialogs use the same source-button contract as legacy SplashMenu.  Keeping
	# it inside the dictionary means every caller can opt in with one field:
	# { ..., "splashed_from": some_block_button }.
	if splashed_from is BlockComponent and is_instance_valid(splashed_from):
		dialog.splashed_from = splashed_from
		splashed_from.in_splash = true
		dialog.tree_exited.connect(func():
			if is_instance_valid(splashed_from):
				splashed_from.in_splash = false
	)
	if is_instance_valid(topr):
		hide_topr()
	cl.add_child(dialog)
	active_dialogs[dialog_id] = dialog
	dialog.tree_exited.connect(_on_dialog_exited.bind(dialog_id, dialog))
	return dialog


func show_dialog_and_get_result(spec: Dictionary, wait_until_closed: bool = false) -> Dictionary:
	var dialog = show_dialog(spec)
	if not is_instance_valid(dialog):
		return {}
	var result: Dictionary = await dialog.wait_for_result()
	if wait_until_closed and is_instance_valid(dialog):
		await dialog.tree_exited
	return result


func _on_dialog_exited(dialog_id: String, dialog: Node) -> void:
	if active_dialogs.get(dialog_id) == dialog:
		active_dialogs.erase(dialog_id)


func splash_and_get_result(menu: String, splashed_from = null, emitter_ = null, inner = false, passed_data = null) -> Dictionary:
	#_stack()
	#if glob.DUMMY_LOGIN and menu == "login":
	#	return {"user": "n", "pass": "1"}
	#close_top_level_splashes(menu)
	
	hourglass.off(true)
	if splashed_from:
		if !is_splashed(menu):
			splashed_from.in_splash = true
		else:
			splashed_from.in_splash = false
			get_splash(menu).go_away()
			return {}
	var m: SplashMenu 
	if menu in already_splashed:
		m = already_splashed[menu]
	else:
		m = splash_menus[menu].instantiate()
	m.inner = inner
	hide_topr()
	if passed_data: m.passed_data = passed_data
	if not menu in already_splashed:
		cl.add_child(m)
	else:
		m.readys()
		m.splash()
	already_splashed[menu] = m
	m.splashed_from = splashed_from
	var emitter = ResultEmitter.new() if !emitter_ else emitter_
	m.emitter = emitter
	if splashed_from:
		emitter.res.connect(func(...args): splashed_from.in_splash = false)
	m.tree_exited.connect(func(): already_splashed.erase(menu))
	var a = await emitter.res
	return a

func set_dense_units(per_unit: int, max_units: int):
	for i in graphs._graphs:
		var g = graphs._graphs[i]
		if graphs.is_layer(g, "Dense"):
			g.group_size = per_unit
			g.max_units = max_units
			g.update_config({"neuron_count": g.cfg["neuron_count"]})

var lesson_bar: ColorRect = null

func configure_richtext_theme_auto(theme: Theme, base_font: FontFile, monospaced_font: FontFile) -> void:
	if theme == null or base_font == null:
		push_warning("configure_richtext_theme_auto: theme/base_font must be non-null")
		return
	if monospaced_font == null:
		monospaced_font = base_font
	var has_axes := func(f: Font, tag: String) -> bool:
		if f and f.has_method(&"get_supported_variation_list"):
			var axes: Dictionary = f.get_supported_variation_list()
			return axes.has(tag)
		return false

	var make_bold := func(f: Font) -> Font:
		var v := FontVariation.new()
		v.base_font = f
		if has_axes.call(f, "wght"):
			var coords := v.variation_opentype
			coords["wght"] = 700.0
			v.variation_opentype = coords
		else:
			v.variation_embolden = 0.8
		return v

	var make_italic := func(f: Font) -> Font:
		var v := FontVariation.new()
		v.base_font = f
		if has_axes.call(f, "ital"):
			var coords := v.variation_opentype
			coords["ital"] = 1.0
			v.variation_opentype = coords
		elif has_axes.call(f, "slnt"):
			var coords := v.variation_opentype
			coords["slnt"] = -12.0
			v.variation_opentype = coords
		else:
			v.variation_transform = Transform2D(Vector2(1, 0.2), Vector2(0, 1), Vector2.ZERO)
		return v

	var make_bold_italic := func(f: Font) -> Font:
		var v := FontVariation.new()
		v.base_font = f
		var used_axes := false
		if has_axes.call(f, "wght"):
			var coords := v.variation_opentype
			coords["wght"] = 700.0
			v.variation_opentype = coords
			used_axes = true
		if has_axes.call(f, "ital") or has_axes.call(f, "slnt"):
			var coords := v.variation_opentype
			if has_axes.call(f, "ital"):
				coords["ital"] = 1.0
			elif has_axes.call(f, "slnt"):
				coords["slnt"] = -12.0
			v.variation_opentype = coords
			used_axes = true
		if not used_axes:
			v.variation_embolden = 0.8
			v.variation_transform = Transform2D(Vector2(1, 0.2), Vector2(0, 1), Vector2.ZERO)
		return v

	var normal_font: Font = base_font
	var bold_font: Font = make_bold.call(base_font)
	var italics_font: Font = make_italic.call(base_font)
	var bold_italics_font: Font = make_bold_italic.call(base_font)
	var mono_font: Font = monospaced_font


	theme.set_font(&"normal_font", &"RichTextLabel", normal_font)
	theme.set_font(&"bold_font", &"RichTextLabel", bold_font)
	theme.set_font(&"italics_font", &"RichTextLabel", italics_font)
	theme.set_font(&"bold_italics_font", &"RichTextLabel", bold_italics_font)
	theme.set_font(&"mono_font", &"RichTextLabel", mono_font)




const _CODEBLOCK_TOKEN = "\uF000CODEBLOCK%03d\uF000"
const _CODESPAN_TOKEN  = "\uF001CODESPAN%03d\uF001"

func markdown_to_bbcode(md: String) -> String:
	var codeblocks: Array[String] = []
	var codespans: Array[String] = []
	var text = md

	# ---------- 1) Extract fenced code blocks: ```...```
	var re_block = RegEx.new()
	re_block.compile("(?s)```(?:[A-Za-z0-9_+-]+)?\\s*(.*?)\\s*```")
	while true:
		var m = re_block.search(text)
		if m == null: break
		var code = m.get_string(1)
		codeblocks.append(code)
		var token = _CODEBLOCK_TOKEN % (codeblocks.size() - 1)
		text = text.substr(0, m.get_start()) + token + text.substr(m.get_end())

	# ---------- 2) Extract inline code: `...`
	var re_span = RegEx.new()
	re_span.compile("`([^`\\n]+?)`")
	while true:
		var m2 = re_span.search(text)
		if m2 == null: break
		var span = m2.get_string(1)
		codespans.append(span)
		var token2 = _CODESPAN_TOKEN % (codespans.size() - 1)
		text = text.substr(0, m2.get_start()) + token2 + text.substr(m2.get_end())

	# ---------- 3) Links: [text](url)
	var re_link = RegEx.new()
	re_link.compile("\\[([^\\]]+)\\]\\(([^)\\s]+)\\)")
	while true:
		var ml = re_link.search(text)
		if ml == null: break
		var label = ml.get_string(1)
		var url = ml.get_string(2)
		var rep = "[url=%s]%s[/url]" % [url, label]
		text = text.substr(0, ml.get_start()) + rep + text.substr(ml.get_end())

	# ---------- 4) Headings: #..######  → just make them bold + newline
	# (Top to bottom to avoid double-processing)
	for level in range(6, 0, -1):
		var pfx = String("#").repeat(level)
		var re_h = RegEx.new()
		re_h.compile("(?m)^%s\\s+(.*)$" % pfx)
		while true:
			var mh = re_h.search(text)
			if mh == null: break
			var body = mh.get_string(1).strip_edges()
			var rep_h = "[b]%s[/b]" % body
			text = text.substr(0, mh.get_start()) + rep_h + text.substr(mh.get_end())

	# ---------- 5) Strikethrough: ~~text~~
	var re_s = RegEx.new()
	re_s.compile("~~(.+?)~~")
	while true:
		var ms = re_s.search(text)
		if ms == null: break
		text = text.substr(0, ms.get_start()) + "[s]" + ms.get_string(1) + "[/s]" + text.substr(ms.get_end())

	# ---------- 6) Bold: **text** and __text__
	for pat in ["\\*\\*(.+?)\\*\\*", "__(.+?)__"]:
		var re_b = RegEx.new()
		re_b.compile(pat)
		while true:
			var mb = re_b.search(text)
			if mb == null: break
			text = text.substr(0, mb.get_start()) + "[b]" + mb.get_string(1) + "[/b]" + text.substr(mb.get_end())

	# ---------- 7) Italic: *text* and _text_  (avoid touching ** already handled)
	for pat_i in ["(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)"]:
		var re_i = RegEx.new()
		re_i.compile(pat_i)
		while true:
			var mi = re_i.search(text)
			if mi == null: break
			text = text.substr(0, mi.get_start()) + "[i]" + mi.get_string(1) + "[/i]" + text.substr(mi.get_end())

	# ---------- 8) Simple bullets: lines starting with "- " or "* "
	for pat_bullet in ["(?m)^-\\s+", "(?m)^\\*\\s+"]:
		var re_bu = RegEx.new()
		re_bu.compile(pat_bullet)
		text = re_bu.sub(text, "• ", true)

	# ---------- 9) Restore code spans and blocks as [code]...[/code]
	# Escape BBCode brackets inside code so they render literally.
	var esc = func(s: String) -> String:
		return s.replace("[", "\\[").replace("]", "\\]")

	# Spans first (so blocks can contain tokens without conflict)
	for idx in range(codespans.size()):
		var token = _CODESPAN_TOKEN % idx
		var repl = "[code]" + esc.call(codespans[idx]) + "[/code]"
		text = text.replace(token, repl)

	for idxb in range(codeblocks.size()):
		var tokenb = _CODEBLOCK_TOKEN % idxb
		var body = esc.call(codeblocks[idxb])
		# Ensure code blocks are separated by blank lines for RTL auto-parsing
		var replb = "\n[code]\n%s\n[/code]\n" % body
		text = text.replace(tokenb, replb)

	return text





var base_theme = preload("res://resources/theme.tres")
var header_theme = preload("res://resources/theme_headers.tres")
var header_font = preload("res://game_assets/fonts/JetBrainsSans[wght]-VF.ttf") as FontFile
var base_font = preload("res://game_assets/fonts/JetBrainsMono-VariableFont_wght.ttf") as FontFile



var selecting_box: bool = false
func click_screen(pos: Vector2, button = MOUSE_BUTTON_LEFT, double_click = false) -> void:
	var vp = get_viewport()

	var down = InputEventMouseButton.new()
	down.button_index = button
	down.pressed = true
	down.double_click = double_click
	down.position = pos
	down.global_position = pos
	down.set_meta("_emulated", true)
	vp.push_input(down)

	var up = InputEventMouseButton.new()
	up.button_index = button
	up.pressed = false
	up.double_click = false
	up.position = pos
	up.global_position = pos
	up.set_meta("_emulated", true)
	vp.push_input(up)
