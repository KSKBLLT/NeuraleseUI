extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var script_path := "res://scripts/simulations/simulation_world_state.gd"
	_expect(ResourceLoader.exists(script_path), "simulation world state script must exist")
	if not ResourceLoader.exists(script_path):
		_finish()
		return

	var world_state_script = load(script_path)
	_expect(world_state_script != null, "simulation world state script must load")
	_expect(
		world_state_script != null and world_state_script.can_instantiate(),
		"simulation world state script must parse"
	)
	if world_state_script == null or not world_state_script.can_instantiate():
		_finish()
		return

	_test_mutations(world_state_script)
	_test_round_trip(world_state_script)
	_test_validation(world_state_script)
	_finish()


func _test_mutations(world_state_script: Script) -> void:
	var state = world_state_script.new()
	state.world_name = "Maze Pilot"

	var invalid_id: String = state.add_object(&"missing", Transform2D.IDENTITY)
	_expect(invalid_id.is_empty(), "unknown catalog types must be rejected")
	_expect(state.object_count() == 0, "rejected objects must not mutate world state")

	var block_transform := Transform2D(0.25, Vector2(1.5, 0.75), 0.0, Vector2(120.0, 64.0))
	var block_id: String = state.add_object(&"block", block_transform, {"size": Vector2(160.0, 32.0)})
	var ball_id: String = state.add_object(&"ball", Transform2D(0.0, Vector2(320.0, 96.0)))

	_expect(block_id == "object-1", "first generated object id must be stable")
	_expect(ball_id == "object-2", "second generated object id must be stable")
	_expect(state.object_count() == 2, "valid objects must be added")
	_expect(state.ordered_ids() == ["object-1", "object-2"], "object ordering must be deterministic")

	_expect(
		state.update_object(block_id, {"position": Vector2(140.0, 70.0), "rotation": 0.5}),
		"existing objects must accept patches"
	)
	var updated: Dictionary = state.object_data(block_id)
	_expect(updated.get("position") == Vector2(140.0, 70.0), "patch must update position")
	_expect(updated.get("rotation") == 0.5, "patch must update rotation")
	_expect(not state.update_object("missing", {"rotation": 1.0}), "unknown object patches must be rejected")

	_expect(state.remove_object(ball_id), "existing object must be removable")
	_expect(not state.remove_object(ball_id), "removing the same object twice must be rejected")
	_expect(state.ordered_ids() == ["object-1"], "removal must update deterministic ordering")


func _test_round_trip(world_state_script: Script) -> void:
	var source = world_state_script.new()
	source.world_name = "Physics Lab"
	source.metadata = {"gravity": 980.0, "seed": 42}
	source.add_object(&"slope", Transform2D(0.2, Vector2(240.0, 180.0)), {
		"size": Vector2(180.0, 72.0),
		"label": "entry",
	})
	source.add_object(&"car", Transform2D(0.0, Vector2(80.0, 120.0)), {
		"brain": "project-model",
	})

	var serialized: Dictionary = source.to_dictionary()
	_expect(serialized.get("version") == 2, "world payload must use the data-oriented format version")
	_expect(serialized.get("world_name") == "Physics Lab", "world payload must include its name")

	var mutable_copy: Dictionary = source.to_dictionary()
	mutable_copy["objects"]["properties"]["object-1"]["label"] = "mutated"
	_expect(
		source.object_data("object-1").get("properties", {}).get("label") == "entry",
		"serialized dictionaries must not expose internal mutable state"
	)

	var restored = world_state_script.new()
	restored.load_dictionary(serialized)
	_expect(restored.to_dictionary() == serialized, "world state must survive an exact round trip")

	var next_id: String = restored.add_object(&"finish", Transform2D.IDENTITY)
	_expect(next_id == "object-3", "restored state must continue the stable id sequence")

	var malformed := serialized.duplicate(true)
	var malformed_objects: Array[Dictionary] = world_state_script.objects_from_dictionary(malformed)
	malformed_objects.append({
		"id": "object-99",
		"type_id": "missing",
		"position": Vector2.ZERO,
		"rotation": 0.0,
		"scale": Vector2.ONE,
		"size": Vector2.ONE,
		"properties": {},
	})
	malformed["objects"] = malformed_objects
	restored.load_dictionary(malformed)
	_expect(restored.object_count() == 2, "load must ignore unknown catalog object types")


func _test_validation(world_state_script: Script) -> void:
	var state = world_state_script.new()
	state.world_name = "Contract test"
	state.metadata = {
		"mode": "physical_2d",
		"randomization": {
			"start_position": true,
			"goal_position": true,
			"obstacle_position": true,
			"surface_material": true,
		},
	}
	state.add_object(&"block", Transform2D.IDENTITY, {
		"randomization": {
			"position_jitter": Vector2(12.0, 4.0),
			"material_variants": ["block", "ice", "sand"],
		},
	})
	state.add_object(&"car", Transform2D(0.0, Vector2(20.0, 30.0)))
	state.add_object(&"finish", Transform2D(0.0, Vector2(300.0, 30.0)))
	var valid_result: Dictionary = world_state_script.validate_dictionary(state.to_dictionary())
	_expect(valid_result.get("valid") == true, "well-formed simulation world must validate")

	var duplicate: Dictionary = state.to_dictionary()
	var duplicate_objects: Array[Dictionary] = world_state_script.objects_from_dictionary(duplicate)
	duplicate_objects[1]["id"] = duplicate_objects[0]["id"]
	duplicate["objects"] = duplicate_objects
	var duplicate_result: Dictionary = world_state_script.validate_dictionary(duplicate)
	_expect(not duplicate_result.get("valid", true), "duplicate world object ids must be rejected")
	_expect(_has_code(duplicate_result, "duplicate_object_id"), "world validation errors must be machine-readable")

	var unknown: Dictionary = state.to_dictionary()
	var unknown_objects: Array[Dictionary] = world_state_script.objects_from_dictionary(unknown)
	unknown_objects[0]["type_id"] = "unknown"
	unknown["objects"] = unknown_objects
	var unknown_result: Dictionary = world_state_script.validate_dictionary(unknown)
	_expect(not unknown_result.get("valid", true), "unknown world object types must be rejected")
	_expect(_has_code(unknown_result, "unknown_object_type"), "unknown object error must be explicit")

	var invalid_binding: Dictionary = state.to_dictionary()
	var binding_objects: Array[Dictionary] = world_state_script.objects_from_dictionary(invalid_binding)
	binding_objects[1]["properties"]["model_binding"] = {
		"version": 1,
		"agent_id": "side_view_car",
		"input_width": 2,
		"output_width": 1,
		"inputs": [],
		"outputs": [],
	}
	invalid_binding["objects"] = binding_objects
	var binding_result: Dictionary = world_state_script.validate_dictionary(invalid_binding)
	_expect(not binding_result.get("valid", true), "invalid persisted model bindings must reject the world")
	_expect(_has_code(binding_result, "invalid_model_binding"), "binding validation error must be explicit")

	var invalid_material: Dictionary = state.to_dictionary()
	var material_objects: Array[Dictionary] = world_state_script.objects_from_dictionary(invalid_material)
	material_objects[0]["properties"]["randomization"]["material_variants"] = [
		"block",
		"car",
	]
	invalid_material["objects"] = material_objects
	var material_result: Dictionary = world_state_script.validate_dictionary(invalid_material)
	_expect(
		not material_result.get("valid", true),
		"surface randomization must reject agents and other non-surface object types"
	)
	_expect(
		_has_code(material_result, "invalid_material_variant"),
		"invalid surface variants must expose a machine-readable error"
	)


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
		print("PASS test_simulation_world_state")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_world_state: %d failure(s)" % failures.size())
	quit(1)
