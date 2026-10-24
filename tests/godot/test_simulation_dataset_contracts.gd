extends SceneTree

const Compiler = preload("res://scripts/simulations/simulation_compiler.gd")
const Examples = preload("res://scripts/simulations/simulation_example_worlds.gd")
const Generator = preload("res://scripts/simulations/simulation_dataset_generator.gd")
const Kernel = preload("res://scripts/simulations/simulation_kernel.gd")
const Worker = preload("res://scripts/simulations/simulation_dataset_worker.gd")

var failures: Array[String] = []
var previews: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_generator_forwards_worker_preview_data()
	_test_preview_actions_follow_model_binding()
	_test_worker_selection_honors_limits()
	_finish()


func _test_generator_forwards_worker_preview_data() -> void:
	var generator: Variant = Generator.new()
	get_root().add_child(generator)
	generator.sample_preview.connect(_on_sample_preview)
	var expected := {
		"world_position": Vector2(12.0, 24.0),
		"actions": {"steering": [0.5]},
	}
	generator._handle_message({
		"kind": "preview",
		"worker_id": 0,
		"data": expected,
	})
	_expect(previews == [expected], "generator must forward the worker's data payload to the live preview")
	generator.free()


func _test_preview_actions_follow_model_binding() -> void:
	var blueprint: Dictionary = Compiler.compile(Examples.world(&"side_view_car"))
	var kernel: Variant = Kernel.new()
	_expect(kernel.create(blueprint, true), "side-view example must create a simulation kernel")
	if kernel.first_agent() == null:
		kernel.destroy()
		return
	var binding: Dictionary = kernel.first_agent().get_model_binding()
	binding["output_width"] = 3
	binding["outputs"] = [
		{"actuator_id": &"steering", "start": 0, "length": 1},
		{"actuator_id": &"throttle", "start": 1, "length": 1},
		{"actuator_id": &"brake", "start": 2, "length": 1},
	]
	var worker: Variant = Worker.new()
	worker._config = {"worker_id": 0}
	worker._kernel = kernel
	var message: Dictionary = worker._preview(
		kernel,
		kernel.first_agent_index(),
		PackedFloat32Array([0.25, 0.75]),
		PackedFloat32Array([0.5, 0.75, 0.25]),
		binding,
		1,
		&""
	)
	_expect(message.get("data", {}).get("actions", {}) == {
		"steering": [0.5],
		"throttle": [0.75],
		"brake": [0.25],
	}, "preview actions must use actuator_id and length from the model binding")
	kernel.destroy()


func _test_worker_selection_honors_limits() -> void:
	var generator: Variant = Generator.new()
	generator.max_worker_threads = 1
	_expect(generator._worker_count_for(8, 8) == 1, "worker selection must honor max_worker_threads")
	generator.max_worker_threads = 8
	_expect(generator._worker_count_for(2048, 8) == 1, "worker selection must honor the active physics body budget")
	_expect(generator._worker_count_for(8, 8) == 2, "worker selection must retain the global worker safety cap")


func _on_sample_preview(_environment_index: int, preview: Dictionary) -> void:
	previews.append(preview)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_dataset_contracts")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_dataset_contracts: %d failure(s)" % failures.size())
	quit(1)
