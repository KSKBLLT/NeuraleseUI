class_name SimulationExampleWorlds
extends RefCounted

const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")

const EXAMPLE_IDS: Array[StringName] = [
	&"side_view_car",
	&"top_down_rover",
	&"flying_agent",
]


static func ids() -> Array[StringName]:
	return EXAMPLE_IDS.duplicate()


static func label(example_id: StringName) -> String:
	match example_id:
		&"side_view_car":
			return "Side-view car"
		&"top_down_rover":
			return "Top-down rover"
		&"flying_agent":
			return "Flying agent"
	return str(example_id)


static func world(example_id: StringName) -> Dictionary:
	match example_id:
		&"top_down_rover":
			return _top_down_rover_world()
		&"flying_agent":
			return _flying_agent_world()
		_:
			return _side_view_car_world()


static func _side_view_car_world() -> Dictionary:
	return _world(
		"Side-view car course",
		"side_view_car_samples",
		Rect2(-520.0, -180.0, 1320.0, 440.0),
		[
			_object("ground-left", &"block", Vector2(-350.0, 238.0), Vector2(420.0, 36.0)),
			_object("ramp", &"slope", Vector2(-140.0, 185.0), Vector2(280.0, 70.0)),
			_object("ground-middle", &"block", Vector2(230.0, 168.0), Vector2(460.0, 36.0)),
			_object("ice", &"ice", Vector2(95.0, 137.0), Vector2(150.0, 26.0)),
			_object("sand", &"sand", Vector2(236.0, 137.0), Vector2(132.0, 26.0)),
			_object("trampoline", &"trampoline", Vector2(350.0, 141.0), Vector2(96.0, 18.0)),
			_object("spikes", &"spikes", Vector2(430.0, 138.0), Vector2(70.0, 24.0)),
			_object("ground-right", &"block", Vector2(680.0, 168.0), Vector2(260.0, 36.0)),
			_object("goal", &"finish", Vector2(760.0, 96.0), Vector2(64.0, 108.0)),
			_object(
				"car",
				&"car",
				Vector2(-450.0, 196.0),
				Vector2(92.0, 42.0),
				0.0,
				{"model_binding": ModelBinding.create_auto(&"side_view_car", 8, 2)}
			),
		]
	)


static func _top_down_rover_world() -> Dictionary:
	var result := _world(
		"Top-down rover arena",
		"top_down_rover_samples",
		Rect2(-560.0, -360.0, 1120.0, 720.0),
		[
			_object("wall-top", &"block", Vector2(0.0, -310.0), Vector2(1080.0, 34.0)),
			_object("wall-bottom", &"block", Vector2(0.0, 310.0), Vector2(1080.0, 34.0)),
			_object("wall-left", &"block", Vector2(-520.0, 0.0), Vector2(34.0, 620.0)),
			_object("wall-right", &"block", Vector2(520.0, 0.0), Vector2(34.0, 620.0)),
			_object("obstacle-a", &"block", Vector2(-120.0, -90.0), Vector2(220.0, 42.0), 0.35),
			_object("obstacle-b", &"block", Vector2(110.0, 105.0), Vector2(260.0, 42.0), -0.3),
			_object("hazard", &"lava", Vector2(40.0, -180.0), Vector2(150.0, 70.0)),
			_object("goal", &"finish", Vector2(430.0, -225.0), Vector2(80.0, 80.0)),
			_object("rover", &"rover", Vector2(-420.0, 220.0), Vector2(72.0, 48.0)),
		]
	)
	result["metadata"]["expert_waypoints"] = [
		Vector2(250.0, 240.0),
		Vector2(380.0, 160.0),
		Vector2(360.0, -40.0),
	]
	result["metadata"]["expert_waypoint_radius"] = 100.0
	return result


static func _flying_agent_world() -> Dictionary:
	var result := _world(
		"Flying agent tunnel",
		"flying_agent_samples",
		Rect2(-560.0, -340.0, 1120.0, 680.0),
		[
			_object("floor", &"block", Vector2(0.0, 310.0), Vector2(1080.0, 34.0)),
			_object("ceiling", &"block", Vector2(0.0, -310.0), Vector2(1080.0, 34.0)),
			_object("pillar-low", &"block", Vector2(-120.0, 170.0), Vector2(70.0, 250.0)),
			_object("pillar-high", &"block", Vector2(145.0, -155.0), Vector2(70.0, 280.0)),
			_object("spikes", &"spikes", Vector2(310.0, 285.0), Vector2(170.0, 26.0)),
			_object("goal", &"finish", Vector2(455.0, -215.0), Vector2(90.0, 90.0)),
			_object("flyer", &"flying_agent", Vector2(-455.0, 205.0), Vector2(58.0, 58.0)),
		]
	)
	result["metadata"]["expert_waypoints"] = [
		Vector2(-210.0, -50.0),
		Vector2(20.0, -50.0),
		Vector2(20.0, 80.0),
		Vector2(210.0, 80.0),
	]
	result["metadata"]["expert_waypoint_radius"] = 55.0
	return result


static func _world(
	world_name: String,
	dataset_name: String,
	bounds: Rect2,
	objects: Array
) -> Dictionary:
	return {
		"version": 1,
		"world_name": world_name,
		"metadata": {
			"generation_bounds": [bounds.position.x, bounds.position.y, bounds.end.x, bounds.end.y],
			"dataset_name": dataset_name,
			"randomization": {
				"start_position": {"enabled": true, "jitter": Vector2(12.0, 8.0)},
				"goal_position": {"enabled": true, "jitter": Vector2(16.0, 12.0)},
				"initial_speed": {"enabled": true, "range": Vector2(0.0, 0.08)},
			},
		},
		"objects": objects,
	}


static func _object(
	object_id: String,
	type_id: StringName,
	position: Vector2,
	size: Vector2,
	rotation: float = 0.0,
	properties: Dictionary = {}
) -> Dictionary:
	return {
		"id": object_id,
		"type_id": str(type_id),
		"position": position,
		"rotation": rotation,
		"scale": Vector2.ONE,
		"size": size,
		"properties": properties.duplicate(true),
	}
