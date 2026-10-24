extends SplashMenu

func _ready() -> void:
	super()
	$ColorRect/Label.text = glob.DEFAULT_MODEL_NAME
	#$ColorRect/Label.set_is_valid_call(func(input):
	#	#(graphs.get_input_graph_by_name(input))
	#	return len(input)> 0 and graphs.get_input_graph_by_name(input))
	un_all()
	quant_un_all()
	_on_onnx_released()
	if nn.FULLY_LOCAL_TRAINING:
		_on_none_released()
	else:
		_on_int_8_released()
	# The window is shown (and _splash runs) inside super() above, before the
	# defaults just set; a request for robot mode is applied again here.
	if str(passed_data.get("mode", "")) == "robot":
		_on_robot_released()

const DEFAULT_SIZE := Vector2(421, 318)
const ROBOT_MAX_SIZE := Vector2(900, 640)
const ROBOT_MIN_SIZE := Vector2(620, 330)
const ROBOT_WINDOW_INSET := Vector2(48, 36)
const ROBOT_PANEL_TOP := 136.0

var _robot_panel: RobotPanel = null
var _robot_mode := false
## Found once: block buttons move into runtime wrappers, so their scene paths stop working.
@onready var _hidden_in_robot_mode: Array = [$ColorRect/quant, $ColorRect/train, $ColorRect/train2]


func _process(delta: float) -> void:
	# While a robot is being connected or is driving, Esc and a click beside the
	# window must not close it: Esc (and Space) are the emergency stop there.
	var busy := _robot_mode and _robot_panel != null and _robot_panel.is_busy()
	dismiss_on_escape = not busy
	dismiss_on_outside_click = not busy
	super(delta)
	if _robot_mode:
		target_size = _robot_size()


func _splash():
	if str(passed_data.get("mode", "")) == "robot":
		_on_robot_released()
	elif _robot_mode:
		_set_robot_mode(true)


func _just_go_away():
	if _robot_panel != null and not _hiding_for_child:
		_robot_panel.close()


## A dialog opened from the robot panel (the PIN): this window steps aside keeping
## the blur and the robot's connection, as workslist.gd does for its dialogs.
var _hiding_for_child := false


func hide_for_child() -> void:
	_hiding_for_child = true
	can_tween_zero = false
	can_go = false
	# A splash fades only to its 5% threshold; once it has, it is hidden so
	# nothing of it shows through the dialog.
	quitting.connect(hide, CONNECT_ONE_SHOT)
	go_away(false)


func restore_from_child() -> void:
	can_go = true
	can_tween_zero = true
	splash()
	_hiding_for_child = false


func _robot_size() -> Vector2:
	var available: Vector2 = glob.window_size - ROBOT_WINDOW_INSET
	return Vector2(
		clampf(available.x, minf(ROBOT_MIN_SIZE.x, available.x), ROBOT_MAX_SIZE.x),
		clampf(available.y, minf(ROBOT_MIN_SIZE.y, available.y), ROBOT_MAX_SIZE.y)
	)


## Robot mode: the window grows to hold the robot screens below the mode pills.
func _set_robot_mode(enabled: bool) -> void:
	_robot_mode = enabled
	for node in _hidden_in_robot_mode:
		node.visible = not enabled
	if enabled:
		if _robot_panel == null:
			_robot_panel = RobotPanel.new()
			_robot_panel.name = "RobotPanel"
			_robot_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
			_robot_panel.offset_left = 26.0
			_robot_panel.offset_top = ROBOT_PANEL_TOP
			_robot_panel.offset_right = -26.0
			_robot_panel.offset_bottom = -20.0
			$ColorRect.add_child(_robot_panel)
		_robot_panel.show()
		target_size = _robot_size()
		_robot_panel.open()
	else:
		target_size = DEFAULT_SIZE
		if _robot_panel != null:
			_robot_panel.close()
			_robot_panel.hide()

func quit(data: Dictionary = {}):
	quitting.emit()
	if can_go:
		hide()
		ui.blur.self_modulate.a = 0
		emitter.res.emit(data)

func _resultate(data: Dictionary):
	emitter.res.emit(data)
	#glob.env_dump[data["text"]] = "-- Scene '%s'\nprint('Hello, world!')" % data["text"]
	#glob.tree_windows["env"].reload_scenes()
	go_away()

@onready var dl_but = $ColorRect/train
func set_downloading():
	$ColorRect/ProgressBar.show()
	dl_but.hide()

func reset_downloading():
	$ColorRect/ProgressBar.hide()
	dl_but.show()

@onready var export_but: BlockComponent = $ColorRect/train
func _on_trainn_released() -> void:
	#$ColorRect/Label.update_valid()
	
	if 1:#$ColorRect/Label.is_valid:
		#await glob.wait(1)
		#reset_downloading()
		#return
		var export_txt = "  Model"
		var saved_txt = "  Saved!"
		match glob.get_lang():
			"ru":
				export_txt = "  Модель"
				saved_txt = "  Скачано"
			"kz":
				export_txt = "  Модель"
				saved_txt = "  Сақт.!"
		export_but.text = export_txt
		var got = graphs.get_input_graph_by_name($ColorRect/Label.text)
		var ext = ".bin"
		match type:
			"windows": ext = ".exe"
			"linux": ext = ""
			"onnx": ext = ".onnx"
			"tensorrt": ext = ".trt"
		var filename = 'MODEL_GRAPH_%s_%s%s' % [glob.fg.get_scene_name(), type_quant, ext]

		if nn.FULLY_LOCAL_TRAINING:
			set_downloading()
			var output_path := OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS).path_join(filename)
			var local_result = await nn.export_fully_local_model(got, type, type_quant, output_path)
			reset_downloading()
			if local_result is Dictionary and local_result.get("status", "") == "ok":
				var saved_path := str(local_result.get("output_path", output_path))
				if FileAccess.file_exists(saved_path):
					export_but.text = saved_txt
					await glob.wait(1.0)
					export_but.text = export_txt
				else:
					ui.error("Export reported success, but the file was not found: " + saved_path)
					export_but.text = export_txt
			else:
				var err := "FullyLocal export failed."
				if local_result is Dictionary:
					err = str(local_result.get("error", err))
				ui.error(err)
				export_but.text = export_txt
			return
		if not glob.require_remote_session():
			return
		set_downloading()

		var handle = web.POST("export", {"user": cookies.user(), "pass": cookies.pwd(), 
		"graph": graphs.get_syntax_tree(got),
		"context": str(got.context_id), "scene_id": glob.get_project_id(),
		"quant": type_quant,
		"platform": type}, false, true)
		#handle.on_chunk.connect(print)
		var a = await handle.completed
		if a and a['body']:
			
			#(OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS) + "/%s"%filename)
			#("a")
			var f = FileAccess.open(OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS) + "/%s"%filename, FileAccess.WRITE)
			f.store_buffer(a["body"])
			f.close()
			reset_downloading()
			export_but.text = saved_txt
			#(export_but.text)
			#await glob.wait(1.0)
			#export_but.text = "   Downloads"
			await glob.wait(1.0)
			export_but.text = export_txt
		#(a["body"].size() / 1024.0)
		reset_downloading()
	#	resultate({"text": $ColorRect/Label.text})


@onready var buts = [$ColorRect/windows, $ColorRect/linux, $ColorRect/onnx, $ColorRect/tensor, $ColorRect/robot]
@onready var quants = [$ColorRect/quant/float16, $ColorRect/quant/int8, $ColorRect/quant/none]

func un_all():
		#switch.base_modulate = Color(0.583, 0.578, 0.85) * 1.3
		#switch.text = "I"
	for switch in buts:
		switch.base_modulate = Color(0.583, 0.578, 0.85) * 0.7

func quant_un_all():
		#switch.base_modulate = Color(0.583, 0.578, 0.85) * 1.3
		#switch.text = "I"
	for switch in quants:
		switch.base_modulate = Color(0.583, 0.578, 0.85) * 0.7

var type: String = ""
func on(who: BlockComponent):
	who.base_modulate = Color(0.583, 0.578, 0.85) * 1.3
	type = who.hint
	var robot_selected: bool = who.hint == &"robot"
	if robot_selected != _robot_mode:
		_set_robot_mode(robot_selected)

var type_quant: String = ""
func qon(who: BlockComponent):
	who.base_modulate = Color(0.583, 0.578, 0.85) * 1.3
	type_quant = who.hint

func _on_tensor_released() -> void:
	un_all()
	on(buts[3])


func _on_robot_released() -> void:
	un_all()
	on(buts[4])


func _on_onnx_released() -> void:
	un_all()
	on(buts[2])


func _on_linux_released() -> void:
	un_all()
	on(buts[1])


func _on_windows_released() -> void:
	un_all()
	on(buts[0])


func _on_float_16_released() -> void:
	quant_un_all()
	qon(quants[0])

func _on_int_8_released() -> void:
	quant_un_all()
	qon(quants[1])

func _on_none_released() -> void:
	quant_un_all()
	qon(quants[2])


@onready var saveall = $ColorRect/train2
func _on_saveall_released() -> void:
	var export_txt = "  Project"
	var saved_txt = "  Saved!"
	match glob.get_lang():
		"ru":
			export_txt = "  Проект"
			saved_txt = "  Скачано"
		"kz":
			export_txt = "  Проект"
			saved_txt = "  Сақт.!"
	var bytes = await glob.export_project()
	
	var f = cookies.open_or_create("save_%s.nls"%glob.fg.get_scene_name(), \
	cookies.downloads_dir)
	#(f)
	f.store_buffer(bytes)
	f.close()
	saveall.text = saved_txt
	#(export_but.text)
	#await glob.wait(1.0)
	#export_but.text = "   Downloads"
	await glob.wait(1.0)
	saveall.text = export_txt
