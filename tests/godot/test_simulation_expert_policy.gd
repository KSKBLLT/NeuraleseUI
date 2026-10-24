extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var policy_path := "res://scripts/simulations/simulation_expert_policy.gd"
	_expect(ResourceLoader.exists(policy_path), "dataset expert policy must exist")
	if not ResourceLoader.exists(policy_path):
		_finish()
		return
	var policy = load(policy_path)
	_expect(policy != null and policy.can_instantiate(), "dataset expert policy must parse")
	if policy == null or not policy.can_instantiate():
		_finish()
		return

	var car_binding := {
		"output_width": 3,
		"outputs": [
			{"actuator_id": "steering", "start": 0, "length": 1},
			{"actuator_id": "throttle", "start": 1, "length": 1},
			{"actuator_id": "brake", "start": 2, "length": 1},
		],
	}
	var car_actions: PackedFloat32Array = policy.actions_for(
		&"side_view_car",
		car_binding,
		{"agent_position": Vector2.ZERO, "agent_rotation": 0.0, "goal_position": Vector2(100.0, 0.0)}
	)
	_expect(car_actions.size() == 3, "car expert must follow the active output binding")
	if car_actions.size() == 3:
		_expect(car_actions[0] > 0.95, "car expert must drive right toward a goal ahead")
		_expect(car_actions[1] > 0.5, "car expert must apply throttle toward a reachable goal")
	var elevated_goal_actions: PackedFloat32Array = policy.actions_for(
		&"side_view_car",
		car_binding,
		{
			"agent_position": Vector2.ZERO,
			"agent_rotation": 0.7,
			"goal_position": Vector2(100.0, -100.0),
			"ray_values": PackedFloat32Array([0.1, 0.2, 0.9, 1.0]),
		}
	)
	_expect(
		elevated_goal_actions.size() == 3 and elevated_goal_actions[0] > 0.95,
		"side-view direction must follow horizontal goal position, not vertical angle or ray imbalance"
	)
	var left_goal_actions: PackedFloat32Array = policy.actions_for(
		&"side_view_car",
		car_binding,
		{"agent_position": Vector2.ZERO, "goal_position": Vector2(-100.0, 80.0)}
	)
	_expect(
		left_goal_actions.size() == 3 and left_goal_actions[0] < -0.95,
		"side-view direction must reverse for a goal to the left"
	)
	var rover_avoids_lower_obstacle: PackedFloat32Array = policy.actions_for(
		&"top_down_rover",
		car_binding,
		{
			"agent_position": Vector2.ZERO,
			"agent_rotation": 0.0,
			"goal_position": Vector2(100.0, 0.0),
			"ray_values": PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 0.6, 0.3, 0.15, 0.1]),
		}
	)
	_expect(
		rover_avoids_lower_obstacle.size() == 3 and rover_avoids_lower_obstacle[0] < -0.5,
		"top-down expert must turn away from an obstacle below its forward path"
	)
	_expect(
		rover_avoids_lower_obstacle.size() == 3 and rover_avoids_lower_obstacle[1] < 0.7,
		"top-down expert must reduce speed while an obstacle blocks its path"
	)
	var rover_avoids_upper_obstacle: PackedFloat32Array = policy.actions_for(
		&"top_down_rover",
		car_binding,
		{
			"agent_position": Vector2.ZERO,
			"agent_rotation": 0.0,
			"goal_position": Vector2(100.0, 0.0),
			"ray_values": PackedFloat32Array([0.1, 0.15, 0.3, 0.6, 1.0, 1.0, 1.0, 1.0]),
		}
	)
	_expect(
		rover_avoids_upper_obstacle.size() == 3 and rover_avoids_upper_obstacle[0] > 0.5,
		"top-down expert must turn away from an obstacle above its forward path"
	)
	var rover_escapes_symmetric_wall: PackedFloat32Array = policy.actions_for(
		&"top_down_rover",
		car_binding,
		{
			"agent_position": Vector2.ZERO,
			"agent_rotation": 0.0,
			"goal_position": Vector2(400.0, 0.0),
			"ray_values": PackedFloat32Array([1.0, 0.8, 0.25, 0.05, 0.05, 0.25, 0.8, 1.0]),
		}
	)
	_expect(
		rover_escapes_symmetric_wall.size() == 3 and rover_escapes_symmetric_wall[0] > 0.7,
		"top-down expert must choose a stable escape direction when a wall blocks the center rays"
	)
	var rover_ignores_astar_turn: PackedFloat32Array = policy.actions_for(
		&"top_down_rover",
		car_binding,
		{
			"agent_position": Vector2.ZERO,
			"agent_rotation": 0.0,
			"agent_velocity": Vector2.ZERO,
			"goal_position": Vector2.RIGHT * 400.0,
			"navigation_target": Vector2.LEFT * 400.0,
			"ray_values": PackedFloat32Array([1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0, 1.0]),
		}
	)
	_expect(
		rover_ignores_astar_turn.size() == 3
		and absf(rover_ignores_astar_turn[0]) < 0.1
		and rover_ignores_astar_turn[1] > 0.8,
		"top-down expert labels must follow the goal and local sensors instead of an A* waypoint"
	)

	var flying_binding := {
		"output_width": 2,
		"outputs": [
			{"actuator_id": "horizontal_thrust", "start": 0, "length": 1},
			{"actuator_id": "vertical_thrust", "start": 1, "length": 1},
		],
	}
	var flying_actions: PackedFloat32Array = policy.actions_for(
		&"flying_agent",
		flying_binding,
		{"agent_position": Vector2.ZERO, "goal_position": Vector2(100.0, -50.0)}
	)
	_expect(flying_actions.size() == 2, "flying expert must follow the active output binding")
	if flying_actions.size() == 2:
		_expect(flying_actions[0] > 0.0, "flying expert must thrust toward the goal horizontally")
		_expect(flying_actions[1] < 0.0, "flying expert must thrust toward a goal above it")
	var avoid_upper_obstacle: PackedFloat32Array = policy.actions_for(
		&"flying_agent",
		flying_binding,
		{
			"agent_position": Vector2.ZERO,
			"goal_position": Vector2(100.0, 0.0),
			"agent_velocity": Vector2(180.0, 0.0),
			"ray_values": PackedFloat32Array([0.05, 0.1, 1.0, 1.0, 1.0]),
		}
	)
	_expect(
		avoid_upper_obstacle.size() == 2 and avoid_upper_obstacle[1] > 0.0,
		"flying expert must use mapped rays to move below an obstacle in its upper path"
	)
	_expect(
		avoid_upper_obstacle.size() == 2 and avoid_upper_obstacle[0] < 0.0,
		"flying expert must brake horizontal momentum before reaching a blocked path"
	)
	var routed_flyer: PackedFloat32Array = policy.actions_for(
		&"flying_agent",
		flying_binding,
		{
			"agent_position": Vector2.ZERO,
			"goal_position": Vector2(-100.0, 0.0),
			"navigation_target": Vector2(100.0, 100.0),
		}
	)
	_expect(
		routed_flyer.size() == 2 and routed_flyer[0] > 0.0 and routed_flyer[1] > 0.0,
		"flying expert must follow configured route waypoints without hardcoded world coordinates"
	)

	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_expert_policy")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_expert_policy: %d failure(s)" % failures.size())
	quit(1)
