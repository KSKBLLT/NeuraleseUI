extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var schema_path := "res://scripts/simulations/simulation_io_schema.gd"
	_expect(ResourceLoader.exists(schema_path), "simulation I/O schema must exist")
	if not ResourceLoader.exists(schema_path):
		_finish()
		return

	var schema = load(schema_path)
	_expect(schema != null and schema.can_instantiate(), "simulation I/O schema must parse")
	if schema == null or not schema.can_instantiate():
		_finish()
		return

	var inputs: Array = schema.active_inputs()
	var outputs: Array = schema.outputs()
	var options: Array = schema.input_options()
	_expect(schema.input_width() == 9, "default mapping must expose nine model inputs")
	_expect(inputs.size() == 2, "default mapping must group rays and speed into two sources")
	if inputs.size() == 2:
		_expect(inputs[0].get("id") == &"ray_distance", "ray distance must be the first input source")
		_expect(inputs[0].get("channels") == 8, "ray distance must occupy eight channels")
		_expect(inputs[1].get("id") == &"speed", "speed must be the final input source")
		_expect(inputs[1].get("channels") == 1, "speed must occupy one channel")
	_expect(outputs.size() == 3, "car mapping must expose steering, throttle, and brake")
	if outputs.size() == 3:
		_expect(outputs[0].get("id") == &"steering", "steering must be output zero")
		_expect(outputs[1].get("id") == &"throttle", "throttle must be output one")
		_expect(outputs[2].get("id") == &"brake", "brake must be output two")
	_expect(options.size() >= inputs.size(), "schema must expose optional sensor sources for the mapping UI")

	var mutated: Array = schema.outputs()
	mutated[0]["label"] = "Broken"
	_expect(schema.outputs()[0].get("label") == "Steering", "schema callers must receive deep copies")

	var default_binding: Dictionary = schema.default_binding()
	_expect(default_binding.get("agent_id") == "side_view_car", "legacy schema must use the registry car binding")
	_expect(default_binding.get("input_width") == 9, "default binding input width must match the schema")
	_expect(default_binding.get("output_width") == 3, "default binding output width must match the schema")
	_expect(
		schema.input_columns_for(default_binding) == schema.input_columns(),
		"dataset input columns must be derived from the active binding"
	)
	_expect(
		schema.output_columns_for(default_binding) == schema.output_columns(),
		"dataset output columns must be derived from the active binding"
	)
	var dataset_schema: Dictionary = schema.dataset_schema_for(default_binding)
	_expect(dataset_schema.get("valid") == true, "valid binding must produce a dataset schema")
	_expect(dataset_schema.get("outputs_from") == 9, "dataset schema must split inputs from outputs at the binding width")
	_expect(dataset_schema.get("col_names", []).size() == 12, "dataset schema must contain all mapped input and output columns")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_io_schema")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_io_schema: %d failure(s)" % failures.size())
	quit(1)
