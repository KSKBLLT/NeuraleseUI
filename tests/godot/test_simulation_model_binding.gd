extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var binding_path := "res://scripts/simulations/simulation_model_binding.gd"
	_expect(ResourceLoader.exists(binding_path), "simulation model binding must exist")
	if not ResourceLoader.exists(binding_path):
		_finish()
		return

	var binding_script = load(binding_path)
	_expect(binding_script != null and binding_script.can_instantiate(), "model binding must parse")
	if binding_script == null or not binding_script.can_instantiate():
		_finish()
		return

	var valid_payload := {
		"version": 1,
		"agent_id": "side_view_car",
		"model": {"graph_name": "Maze Pilot", "checkpoint_id": "checkpoint-1"},
		"input_width": 9,
		"output_width": 3,
		"inputs": [
			{"sensor_id": "ray_distance", "start": 0, "length": 8},
			{"sensor_id": "speed", "start": 8, "length": 1},
		],
		"outputs": [
			{"actuator_id": "steering", "start": 0, "length": 1},
			{"actuator_id": "throttle", "start": 1, "length": 1},
			{"actuator_id": "brake", "start": 2, "length": 1},
		],
	}
	var valid_result: Dictionary = binding_script.validate(valid_payload)
	_expect(valid_result.get("valid") == true, "complete compatible binding must be valid")
	_expect(valid_result.get("errors", []).is_empty(), "valid binding must have no errors")

	var overlap := valid_payload.duplicate(true)
	overlap["inputs"][1]["start"] = 7
	var overlap_result: Dictionary = binding_script.validate(overlap)
	_expect(not overlap_result.get("valid", true), "overlapping input ranges must be rejected")
	_expect(_has_code(overlap_result, "input_overlap"), "overlap error must be machine-readable")

	var missing := valid_payload.duplicate(true)
	missing["inputs"].remove_at(1)
	var missing_result: Dictionary = binding_script.validate(missing)
	_expect(not missing_result.get("valid", true), "unmapped model inputs must be rejected")
	_expect(missing_result.get("unbound_inputs") == [8], "validation must report unbound input indices")

	var incompatible := valid_payload.duplicate(true)
	incompatible["outputs"][2]["actuator_id"] = "vertical_thrust"
	var incompatible_result: Dictionary = binding_script.validate(incompatible)
	_expect(not incompatible_result.get("valid", true), "agent-incompatible actuator must be rejected")
	_expect(_has_code(incompatible_result, "incompatible_actuator"), "compatibility errors must be explicit")

	var wrong_width := valid_payload.duplicate(true)
	wrong_width["inputs"][1]["length"] = 2
	var width_result: Dictionary = binding_script.validate(wrong_width)
	_expect(not width_result.get("valid", true), "fixed-width sensor mappings must be rejected")
	_expect(_has_code(width_result, "invalid_sensor_width"), "width errors must be explicit")

	var compact_car: Dictionary = binding_script.create_auto(&"side_view_car", 5, 2)
	_expect(
		binding_script.validate(compact_car).get("valid") == true,
		"auto-map must create a valid car binding for a different model shape"
	)
	_expect(compact_car.get("input_width") == 5, "auto-map must preserve the model input width")
	_expect(compact_car.get("output_width") == 2, "auto-map must preserve the model output width")
	_expect(
		compact_car.get("inputs", [])[0].get("sensor_id") == &"ray_distance"
		and compact_car.get("inputs", [])[0].get("length") == 4,
		"auto-map must resize the registry-defined flexible sensor instead of hardcoding a schema"
	)

	var compact_flyer: Dictionary = binding_script.create_auto(&"flying_agent", 8, 2)
	_expect(
		binding_script.validate(compact_flyer).get("valid") == true,
		"auto-map must work for a second agent using the same registry path"
	)
	_expect(
		binding_script.create_auto(&"flying_agent", 0, 2).is_empty(),
		"auto-map must fail closed for an impossible model shape"
	)
	_finish()


func _has_code(result: Dictionary, code: String) -> bool:
	for error in result.get("errors", []):
		if error is Dictionary and str(error.get("code", "")) == code:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_model_binding")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_model_binding: %d failure(s)" % failures.size())
	quit(1)
