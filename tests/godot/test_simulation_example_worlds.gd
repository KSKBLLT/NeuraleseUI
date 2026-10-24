extends SceneTree

const Examples = preload("res://scripts/simulations/simulation_example_worlds.gd")
const WorldState = preload("res://scripts/simulations/simulation_world_state.gd")
const ObjectCatalog = preload("res://scripts/simulations/simulation_object_catalog.gd")

var failures: Array[String] = []


func _initialize() -> void:
	var expected_agents := {
		&"side_view_car": &"side_view_car",
		&"top_down_rover": &"top_down_rover",
		&"flying_agent": &"flying_agent",
	}
	_expect(Examples.ids().size() == expected_agents.size(), "MVP must expose exactly three focused examples")
	for example_id in expected_agents:
		var world: Dictionary = Examples.world(example_id)
		_expect(WorldState.validate_dictionary(world).get("valid", false), "%s world must validate" % example_id)
		var seen_ids: Dictionary = {}
		var agent_count := 0
		var goal_count := 0
		for object in world.get("objects", []):
			var object_id := str(object.get("id", ""))
			_expect(not seen_ids.has(object_id), "%s object ids must be unique" % example_id)
			seen_ids[object_id] = true
			var definition := ObjectCatalog.definition(StringName(object.get("type_id", "")))
			if str(definition.get("dataset_role", "")) == "agent":
				agent_count += 1
				_expect(
					StringName(definition.get("agent_id", "")) == expected_agents[example_id],
					"%s must use its registered agent" % example_id
				)
			if str(definition.get("dataset_role", "")) == "goal":
				goal_count += 1
		_expect(agent_count == 1, "%s must contain one controllable agent" % example_id)
		_expect(goal_count >= 1, "%s must contain a reachable goal" % example_id)
		if example_id != &"side_view_car":
			var waypoints: Array = world.get("metadata", {}).get("expert_waypoints", [])
			_expect(not waypoints.is_empty(), "%s must define a collision-free expert route" % example_id)
	var side_view_bounds: Array = Examples.world(&"side_view_car").get("metadata", {}).get(
		"generation_bounds",
		[]
	)
	_expect(
		side_view_bounds == [-520.0, -180.0, 800.0, 260.0],
		"example generation bounds must store left, top, right, bottom coordinates"
	)
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("simulation example worlds tests: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
