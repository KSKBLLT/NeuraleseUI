extends Node
## Opens the Export window in robot mode with nothing to click through.
##
## Run the scene tests/godot/robot_window_harness.tscn (it is the real app plus
## this node). It waits for the startup, closes the startup dialog, makes sure a
## project with a trained-looking model is open, and opens the robot window with
## the prototype's model (car_brain.onnx) and the virtual robot, so every screen
## of the window can be looked at straight away.
##
## Options, as user arguments after "--" or in %TEMP%/robot_harness_options.txt:
## ``--robot-connect=dummy`` connects the virtual robot; ``--robot-fill`` also puts
## the parts of the prototype robot "KIRISIMA" on its drawing; ``--robot-dataset=<name>``
## describes a test dataset (local_runtime/tests/fixtures/robot_ui/<name>_meta.json)
## with a training world instead of the project's Car Track, and runs <name>.onnx
## from the same folder when there is one.

const MODEL := "res://local_runtime/tests/fixtures/robot_drive/car_brain.onnx"
const BUILTIN := "res://built_in_projects/Car Track.scn"

var window: SplashMenu = null


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 60:
		await get_tree().process_frame
	await _close_startup_dialogs()
	await _ensure_project()
	RobotPanel.debug_model_path = ProjectSettings.globalize_path(MODEL)
	RobotPanel.connect_extra = {"world": {"preset": "default"}, "seed": 1}
	var options := _options()
	if options.has("robot-dataset"):
		# A dataset from local_runtime/tests/fixtures/robot_ui, with a training world.
		var path := "res://local_runtime/tests/fixtures/robot_ui/%s_meta.json" % str(options["robot-dataset"])
		var dataset: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
		# Its model, when the fixtures have one (sim_top_down_full.onnx: 11 inputs,
		# 3 outputs, made by local_runtime/tests/robot_maps.py), so model and dataset fit.
		var model := "res://local_runtime/tests/fixtures/robot_ui/%s.onnx" % str(options["robot-dataset"])
		if FileAccess.file_exists(model):
			RobotPanel.debug_model_path = ProjectSettings.globalize_path(model)
		if dataset is Dictionary:
			dataset["metadata"]["world"] = {
				"bounds": [-480.0, -260.0, 960.0, 520.0],
				"agent_start": [-380.0, 120.0, 0.0],
				"agent_size": [72.0, 48.0],
				"agent_type": "rover",
				"goal": [360.0, -150.0],
			}
			RobotPanel.debug_dataset = dataset
	window = ui.splash("model_export", null, null, false, {"mode": "robot"})
	print("robot harness: window open")
	if options.has("robot-connect"):
		await _connect_dummy(options)


func _close_startup_dialogs() -> void:
	var waited := 0.0
	while waited < 12.0:
		for dialog in ui.active_dialogs.values():
			if is_instance_valid(dialog) and dialog.has_method("dismiss_with_splash_animation"):
				dialog.dismiss_with_splash_animation()
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		if ui.active_dialogs.is_empty() and waited > 3.0:
			break


## Always the built-in Car Track project, so every run starts from the same model.
func _ensure_project() -> void:
	await get_tree().create_timer(1.0).timeout
	# The app opened the user's last project: the harness's graph lives in
	# memory only and is never autosaved over it.
	glob.loaded_project_once = false
	await graphs.delete_all()
	var raw: Variant = glob._read_var_abs(BUILTIN)
	var data: Variant = bytes_to_var(raw) if raw is PackedByteArray else {}
	if data is Dictionary:
		var registry: Dictionary = data.get("registry", {})
		await graphs.load_graph(data.get("graphs", {}), registry.get("subgraph_registry", {}))
	# A project opened normally has its training dataset selected; loading the
	# bare graph does not, so select the built-in dataset the way the project does.
	for graph in graphs._graphs.values():
		if is_instance_valid(graph) and str(graph.server_typename) == "TrainBegin":
			graph.set_dataset_meta(glob.FULLY_LOCAL_BUILTIN_DATASETS["car_track"].duplicate(true))
	await get_tree().process_frame


func _options() -> Dictionary:
	var result := {}
	var arguments: Array = Array(OS.get_cmdline_user_args())
	# The editor tools cannot pass arguments: the same words may be in this file.
	var file_path := OS.get_environment("TEMP").path_join("robot_harness_options.txt")
	if FileAccess.file_exists(file_path):
		arguments.append_array(FileAccess.get_file_as_string(file_path).strip_edges().split(" ", false))
	for argument in arguments:
		var text := str(argument).trim_prefix("--")
		var parts := text.split("=", true, 1)
		result[parts[0]] = parts[1] if parts.size() > 1 else "1"
	return result


## The prototype robot "KIRISIMA": three sonars in front (as the EV3 had them),
## the left wheel on D and the right on B.
const KIRISIMA := {
	"sensors": {
		"in4": {"angle_deg": 45.0, "x_cm": 6.4, "y_cm": 2.5, "spot": "front_left"},
		"in3": {"angle_deg": 0.0, "x_cm": 7.0, "y_cm": 0.0, "spot": "front"},
		"in2": {"angle_deg": -45.0, "x_cm": 6.4, "y_cm": -2.5, "spot": "front_right"},
	},
	"drive": {"left_port": "outD", "right_port": "outB", "invert_left": false, "invert_right": false},
	"drive_sides": {"left": [{"port": "outD", "invert": false}], "right": [{"port": "outB", "invert": false}]},
	"wheel_diameter_cm": null,
	"track_cm": null,
	"length_cm": null,
	"heading": "",
	"chassis_preset": "two_wheel",
}


func _panel() -> RobotPanel:
	return get_tree().root.find_child("RobotPanel", true, false) as RobotPanel


func _connect_dummy(options: Dictionary) -> void:
	var panel := _panel()
	var waited := 0.0
	var dummy_id := ""
	while waited < 40.0 and dummy_id.is_empty():
		await get_tree().create_timer(0.5).timeout
		waited += 0.5
		for item in panel.robots:
			if str(item.get("platform", "")) == "dummy":
				dummy_id = str(item.get("robot_id", ""))
	if dummy_id.is_empty():
		print("robot harness: no virtual robot found")
		return
	while panel.scanning or panel.model.is_empty():
		await get_tree().create_timer(0.5).timeout
	await panel._connect(dummy_id)
	if options.has("robot-fill"):
		panel.geometry = KIRISIMA.duplicate(true)
		await panel._save_now()
		panel._open_build()
	print("robot harness: connected, screen ", panel.screen)
