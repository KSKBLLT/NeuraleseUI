extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_agent(&"car", &"side_view_car", 9, 3)
	_test_agent(&"rover", &"top_down_rover", 11, 3)
	_test_agent(&"flying_agent", &"flying_agent", 13, 2)
	_finish()


func _test_agent(
	object_type: StringName,
	expected_agent_id: StringName,
	expected_inputs: int,
	expected_outputs: int
) -> void:
	var world := SimulationWorldState.new()
	var agent_rotation := PI * 0.5 if object_type == &"rover" else 0.0
	var agent_id := world.add_object(
		object_type,
		Transform2D(agent_rotation, Vector2.ZERO),
		{"id": "agent"}
	)
	world.add_object(
		&"block",
		Transform2D(0.0, Vector2(120.0, 0.0)),
		{"id": "obstacle", "size": Vector2(20.0, 80.0)}
	)
	world.add_object(
		&"finish",
		Transform2D(0.0, Vector2(240.0, 0.0)),
		{"id": "finish"}
	)
	var kernel := SimulationKernel.new()
	_expect(
		kernel.create(SimulationCompiler.compile(world.thread_snapshot()), true),
		"%s world must compile into a native physics kernel" % object_type
	)
	var agent := kernel.agent(agent_id)
	_expect(agent != null, "%s must create a kernel agent provider" % object_type)
	if agent == null:
		kernel.destroy()
		return
	_expect(agent.get_agent_id() == expected_agent_id, "%s must use its registry agent id" % object_type)
	var binding: Dictionary = agent.get_model_binding()
	_expect(binding.get("input_width") == expected_inputs, "%s must expose its complete default observation" % object_type)
	_expect(binding.get("output_width") == expected_outputs, "%s must expose its complete default action width" % object_type)
	var observation: Dictionary = agent.observation_for_binding()
	_expect(observation.get("valid") == true, "%s observation must encode through the registry binding" % object_type)
	var values: PackedFloat32Array = observation.get("values", PackedFloat32Array())
	_expect(values.size() == expected_inputs, "%s observation width must match its model binding" % object_type)
	for value in values:
		_expect(is_finite(value), "%s observations must contain only finite values" % object_type)
	if object_type == &"rover" and values.size() == 11:
		_expect(
			absf(values[9]) < 0.05 and values[10] < -0.95,
			"rover goal direction must be encoded in body-local coordinates without changing the 11-input contract"
		)

	var outputs := PackedFloat32Array()
	outputs.resize(expected_outputs)
	outputs.fill(0.25)
	_expect(
		agent.apply_model_outputs(outputs).get("valid") == true,
		"%s must decode a complete action vector" % object_type
	)
	_expect(
		not agent.apply_model_outputs(PackedFloat32Array([1.0])).get("valid", true),
		"%s must reject the wrong model output width" % object_type
	)

	if object_type == &"car":
		var compact := SimulationModelBinding.create_auto(&"side_view_car", 5, 2)
		_expect(agent.set_model_binding(compact), "car must accept a compatible variable model shape")
		var compact_observation: Dictionary = agent.observation_for_binding()
		_expect(
			compact_observation.get("valid") == true
			and compact_observation.get("values", PackedFloat32Array()).size() == 5,
			"variable car mappings must control the encoded observation width"
		)
		var invalid: Dictionary = compact.duplicate(true)
		invalid["inputs"][0]["length"] = 99
		_expect(not agent.set_model_binding(invalid), "kernel agents must reject invalid bindings")
		_expect(agent.get_model_binding() == compact, "rejected bindings must not replace the active mapping")

	kernel.destroy()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_agent")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_agent: %d failure(s)" % failures.size())
	quit(1)
