extends SceneTree

const Examples = preload("res://scripts/simulations/simulation_example_worlds.gd")
const Generator = preload("res://scripts/simulations/simulation_dataset_generator.gd")

var failures: Array[String] = []


func _initialize() -> void:
	var graph_manager := get_root().get_node_or_null("graphs")
	if graph_manager != null:
		graph_manager.process_mode = Node.PROCESS_MODE_DISABLED
	call_deferred("_run")


func _run() -> void:
	var state: Dictionary = Examples.world(&"side_view_car")
	var objects: Array = state.get("objects", [])
	for index in objects.size():
		var object: Dictionary = objects[index]
		if object.get("type_id") != &"car":
			continue
		var properties: Dictionary = object.get("properties", {}).duplicate(true)
		properties["model_binding"] = {
			"version": 1,
			"agent_id": "side_view_car",
			"input_width": 8,
			"output_width": 3,
			"inputs": [
				{"sensor_id": "ray_distance", "start": 0, "length": 7},
				{"sensor_id": "speed", "start": 7, "length": 1},
			],
			"outputs": [
				{"actuator_id": "steering", "start": 0, "length": 1},
				{"actuator_id": "throttle", "start": 1, "length": 1},
				{"actuator_id": "jump", "start": 2, "length": 1},
			],
		}
		object["properties"] = properties
		objects[index] = object
		break
	state["objects"] = objects

	var generator := Generator.new()
	get_root().add_child(generator)
	var dataset: Dictionary = await generator.generate(12, 912, state)
	_expect(int(dataset.get("row_count", 0)) == 12, "jump-enabled generation must produce every requested sample")
	_expect(int(dataset.get("column_count", 0)) == 11, "jump-enabled rows must contain eight inputs and three outputs")
	_expect(dataset.get("col_names", []).slice(8) == [
		"Steering:float",
		"Throttle:float",
		"Jump:float",
	], "jump-enabled datasets must expose the mapped actuator columns")
	_expect(str(generator.last_error()).is_empty(), "jump-enabled generation must not report a codec or policy error")
	generator.queue_free()
	await process_frame
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_jump_dataset")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_jump_dataset: %d failure(s)" % failures.size())
	quit(1)
