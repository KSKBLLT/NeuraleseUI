extends Node

const DEMO_PROJECT_PATH := "res://built_in_projects/Car Track.scn"
const ExampleWorlds = preload("res://scripts/simulations/simulation_example_worlds.gd")

var _editor: Node2D


func run(editor: Node2D) -> void:
	_editor = editor
	await _dismiss_startup_menu()
	await _hold(60)
	await _load_training_project()
	glob.go_window("env")
	await _hold(60)

	_editor.load_state_dictionary(_flat_car_demo_world())
	await _hold(120)
	_editor.select_first_agent()
	await _hold(75)
	_editor.select_object(null)
	await _hold(45)
	await _generate_dataset(600)
	_editor._set_generation_mode(false)
	await _hold(120)

	await _start_and_wait_for_training()
	await _hold(120)

	glob.go_window("env")
	_editor.load_state_dictionary(_flat_car_demo_world())
	_editor._set_generation_mode(false)
	await _hold(75)
	_editor.runtime.play()
	var model_started: bool = await _editor.model_runner.start()
	if model_started:
		await _wait_for_car_goal(1800)
		await _hold(120)
		_editor.model_runner.stop()
	_editor.runtime.stop()
	await _hold(90)

	await _show_dataset_world(&"top_down_rover", 180)
	await _show_dataset_world(&"flying_agent", 180)
	get_tree().quit()


func _dismiss_startup_menu() -> void:
	var ui_service := get_node_or_null("/root/ui")
	if not is_instance_valid(ui_service):
		return
	for _frame in 240:
		var active_dialogs: Dictionary = ui_service.get("active_dialogs")
		var dialog: Node = active_dialogs.get("startup_main_menu")
		if is_instance_valid(dialog):
			dialog.call("quit", {})
			return
		await get_tree().process_frame


func _show_dataset_world(example_id: StringName, sample_total: int) -> void:
	glob.go_window("env")
	_editor.load_state_dictionary(ExampleWorlds.world(example_id))
	_editor._set_generation_mode(false)
	await _hold(120)
	_editor.select_first_agent()
	await _hold(90)
	_editor.select_object(null)
	await _hold(45)
	await _generate_dataset(sample_total)
	await _hold(120)
	_editor._set_generation_mode(false)
	await _hold(75)


func _load_training_project() -> bool:
	var file := FileAccess.open(DEMO_PROJECT_PATH, FileAccess.READ)
	if file == null:
		push_error("Could not open simulation demo project: %s" % DEMO_PROJECT_PATH)
		return false
	var blob: Variant = file.get_var()
	file.close()
	if not blob is PackedByteArray:
		push_error("Simulation demo project is not a PackedByteArray payload.")
		return false
	var project_data: Variant = bytes_to_var(blob)
	if not project_data is Dictionary:
		push_error("Simulation demo project did not decode to a project dictionary.")
		return false
	return await glob._apply_project_payload("simulation-demo", "Car Track", project_data, {
		"stop_lesson": false,
		"set_project_id": false,
		"project_id": -1,
		"emit_project_opened": false,
	})


func _flat_car_demo_world() -> Dictionary:
	var world: Dictionary = ExampleWorlds.world(&"side_view_car")
	world["world_name"] = "Autonomous car course"
	world["metadata"]["dataset_name"] = "autonomous_car_samples"
	world["metadata"]["generation_bounds"] = [-620.0, -180.0, 700.0, 260.0]
	var retained: Dictionary = {}
	for object_data in world.get("objects", []):
		if object_data is Dictionary:
			retained[str(object_data.get("id", ""))] = object_data.duplicate(true)
	var ground: Dictionary = retained.get("ground-left", {}).duplicate(true)
	ground["id"] = "ground"
	ground["position"] = Vector2(40.0, 238.0)
	ground["size"] = Vector2(1320.0, 36.0)
	var goal: Dictionary = retained.get("goal", {}).duplicate(true)
	goal["position"] = Vector2(640.0, 166.0)
	var car: Dictionary = retained.get("car", {}).duplicate(true)
	car["position"] = Vector2(-520.0, 196.0)
	world["objects"] = [
		ground,
		_demo_object("coin-1", "coin", Vector2(-180.0, 158.0), Vector2(28.0, 28.0)),
		_demo_object("coin-2", "coin", Vector2(80.0, 158.0), Vector2(28.0, 28.0)),
		_demo_object("coin-3", "coin", Vector2(340.0, 158.0), Vector2(28.0, 28.0)),
		goal,
		car,
	]
	return world


func _demo_object(
	object_id: String,
	type_id: String,
	position: Vector2,
	size: Vector2
) -> Dictionary:
	return {
		"id": object_id,
		"type_id": type_id,
		"position": position,
		"rotation": 0.0,
		"scale": Vector2.ONE,
		"size": size,
		"properties": {},
	}


func _start_and_wait_for_training() -> bool:
	var bridge: Node = _editor.training_bridge
	var candidates: Array[Dictionary] = bridge._collect_pipeline_candidates()
	var pipeline: Dictionary = bridge.select_pipeline(
		candidates,
		str(glob.DEFAULT_MODEL_NAME),
		8,
		2
	)
	if pipeline.is_empty():
		push_error("No compatible 8-input, 2-output demo training pipeline was found.")
		return false
	var train_begin: Node = pipeline.get("train_begin")
	var epochs_input: Node = train_begin.get_node_or_null("YY")
	if is_instance_valid(epochs_input) and epochs_input.has_method("set_line"):
		epochs_input.set_line("20")

	var started: bool = await bridge.start_training()
	if not started:
		push_error(bridge.last_error())
		return false

	if nn.local_training_jobs.is_empty():
		return await _wait_for_train_begin(train_begin)

	# Movie Maker advances fixed-time frames much faster than the child Python
	# process. Poll the same progress stream here at presentation speed so the
	# training states remain visible in the recorded graph UI.
	var training_head: Node = nn.local_training_jobs.keys()[0]
	var job: Dictionary = nn.local_training_jobs[training_head]
	nn.set_process(false)
	var line_count := 0
	var terminal_phase := ""
	var terminal_packet: Dictionary = {}
	for frame_index in 1200:
		var progress_path := str(job.get("progress_path", ""))
		if FileAccess.file_exists(progress_path):
			var lines := FileAccess.get_file_as_string(progress_path).split("\n", false)
			for line_index in range(line_count, lines.size()):
				var packet: Variant = JSON.parse_string(lines[line_index].strip_edges())
				if packet is Dictionary:
					nn._handle_train_state_dict(
						packet,
						job.get("additional", glob.def),
						job.get("training_head", null)
					)
					if str(packet.get("phase", "")) in ["done", "stopped", "error"]:
						terminal_phase = str(packet.get("phase", ""))
						terminal_packet = packet.duplicate(true)
			line_count = lines.size()
		if not terminal_phase.is_empty():
			break
		await get_tree().process_frame
		if frame_index % 3 == 0:
			OS.delay_msec(10)

	if nn.local_training_jobs.has(training_head):
		nn._finalize_local_training_job(job)
		nn.local_training_jobs.erase(training_head)
	nn.set_process(true)
	if terminal_phase == "done":
		return true
	push_error(
		"Simulation demo training stopped with phase '%s': %s"
		% [terminal_phase, JSON.stringify(terminal_packet)]
	)
	return false


func _wait_for_train_begin(train_begin: Node) -> bool:
	var saw_training := false
	for frame_index in 1200:
		var training: bool = bool(train_begin.get("training"))
		saw_training = saw_training or training
		if saw_training and not training:
			return true
		await get_tree().process_frame
		if frame_index % 3 == 0:
			OS.delay_msec(10)
	push_error("Simulation demo training did not finish before the capture timeout.")
	return false


func _wait_for_generation() -> void:
	while bool(_editor.get("_generation_running")):
		await get_tree().process_frame


func _generate_dataset(sample_total: int) -> void:
	_editor.start_dataset_generation(sample_total)
	await _wait_for_generation()


func _wait_for_car_goal(max_frames: int) -> bool:
	var car_index: int = _editor.world_state.index_of("car")
	var goal_index: int = _editor.world_state.index_of("goal")
	var kernel = _editor.runtime.kernel()
	if car_index < 0 or goal_index < 0 or kernel == null:
		push_error("Simulation demo could not find the car or finish object.")
		await _hold(max_frames)
		return false
	for _frame in max_frames:
		var car_position: Vector2 = kernel.position_for(car_index)
		var goal_position: Vector2 = kernel.position_for(goal_index)
		var distance := car_position.distance_to(goal_position)
		if distance <= 60.0:
			print(
				"SIMULATION_DEMO_GOAL_REACHED car=", car_position,
				" goal=", goal_position,
				" distance=", distance
			)
			return true
		await get_tree().process_frame
	var final_car_position: Vector2 = kernel.position_for(car_index)
	var final_goal_position: Vector2 = kernel.position_for(goal_index)
	push_error(
		"SIMULATION_DEMO_GOAL_TIMEOUT car=%s goal=%s distance=%.2f"
		% [final_car_position, final_goal_position,
		final_car_position.distance_to(final_goal_position)]
	)
	return false


func _hold(frame_count: int) -> void:
	for _frame in frame_count:
		await get_tree().process_frame
