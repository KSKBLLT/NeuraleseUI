extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var runner_path := "res://scripts/simulations/simulation_model_runner.gd"
	_expect(ResourceLoader.exists(runner_path), "simulation model runner script must exist")
	if not ResourceLoader.exists(runner_path):
		_finish()
		return

	var runner_script = load(runner_path)
	_expect(
		runner_script != null and runner_script.can_instantiate(),
		"simulation model runner script must parse"
	)
	if runner_script == null or not runner_script.can_instantiate():
		_finish()
		return

	var direct: PackedFloat32Array = runner_script.extract_actions({
		"agent_output": [[-0.35, 0.8]],
	})
	_expect(direct.size() == 2, "runner must extract two actuator values")
	if direct.size() == 2:
		_expect(is_equal_approx(direct[0], -0.35), "first model output must map to steering")
		_expect(is_equal_approx(direct[1], 0.8), "second model output must map to throttle")

	var nested: PackedFloat32Array = runner_script.extract_actions({
		"agent_output": [[[2.0], [-3.0], [0.5]]],
	})
	_expect(nested.size() == 2, "runner must flatten nested Neuralese output tensors")
	if nested.size() == 2:
		_expect(is_equal_approx(nested[0], 1.0), "steering output must be clamped")
		_expect(is_equal_approx(nested[1], -1.0), "throttle output must be clamped")

	_expect(
		runner_script.extract_actions({}).is_empty(),
		"missing model output must not create synthetic actuator values"
	)
	var three_outputs: PackedFloat32Array = runner_script.extract_actions({
		"agent_output": [[0.25, 0.75, 0.5]],
	}, 3)
	_expect(three_outputs.size() == 3, "runner must extract the output width requested by the binding")
	if three_outputs.size() == 3:
		_expect(is_equal_approx(three_outputs[2], 0.5), "runner must preserve the third bound actuator value")
	_expect(
		runner_script.extract_actions({"agent_output": [[0.0, 1.0]]}, 3).is_empty(),
		"runner must reject model output shorter than the active binding"
	)
	var binding_script = load("res://scripts/simulations/simulation_model_binding.gd")
	var default_binding: Dictionary = binding_script.create_default(&"side_view_car")
	_expect(
		runner_script.binding_shape_error(default_binding, 9).is_empty(),
		"runner must accept a binding matching the selected graph input"
	)
	_expect(
		runner_script.binding_shape_error(default_binding, 8).contains("expects 8 inputs"),
		"runner must reject a mismatched binding before opening inference"
	)
	_expect(
		runner_script.binding_contract_error(default_binding, 9, 3).is_empty(),
		"runner must accept a model matching both mapped input and output widths"
	)
	_expect(
		runner_script.binding_contract_error(default_binding, 9, 2).contains("provides 2 outputs"),
		"runner must reject a mismatched model output before opening inference"
	)

	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_model_runner")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_model_runner: %d failure(s)" % failures.size())
	quit(1)
