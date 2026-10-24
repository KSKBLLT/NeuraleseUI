class_name SimulationDefinitionRegistry
extends RefCounted

const SENSOR_DEFINITIONS := {
	&"ray_distance": {
		"label": "Ray Sensor",
		"detail": "Distance",
		"dimension_kind": &"range",
		"min_channels": 1,
		"max_channels": 32,
		"range": Vector2(0.0, 1.0),
		"normalization": &"already_normalized",
		"encoder": &"encode_ray_distance",
		"column_template": "Ray %d:float",
		"accent": Color("62d8d2"),
	},
	&"speed": {
		"label": "Speed",
		"detail": "Scalar",
		"dimension_kind": &"fixed",
		"channels": 1,
		"range": Vector2(0.0, 1.0),
		"normalization": &"max_speed",
		"encoder": &"encode_speed",
		"columns": ["Speed:float"],
		"accent": Color("6b9df4"),
	},
	&"velocity_x": {
		"label": "Horizontal speed",
		"detail": "Velocity X",
		"dimension_kind": &"fixed",
		"channels": 1,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"max_speed_signed",
		"encoder": &"encode_velocity_x",
		"columns": ["Velocity X:float"],
		"accent": Color("6b9df4"),
	},
	&"velocity_y": {
		"label": "Vertical speed",
		"detail": "Velocity Y",
		"dimension_kind": &"fixed",
		"channels": 1,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"max_speed_signed",
		"encoder": &"encode_velocity_y",
		"columns": ["Velocity Y:float"],
		"accent": Color("6b9df4"),
	},
	&"rotation": {
		"label": "Rotation",
		"detail": "Scalar",
		"dimension_kind": &"fixed",
		"channels": 1,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"angle_pi",
		"encoder": &"encode_rotation",
		"columns": ["Rotation:float"],
		"accent": Color("8e929a"),
	},
	&"gps": {
		"label": "GPS",
		"detail": "Position (x, y)",
		"dimension_kind": &"fixed",
		"channels": 2,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"world_bounds",
		"encoder": &"encode_normalized_position",
		"columns": ["GPS X:float", "GPS Y:float"],
		"accent": Color("8e929a"),
	},
	&"goal_vector": {
		"label": "Goal Vector",
		"detail": "Direction (x, y)",
		"dimension_kind": &"fixed",
		"channels": 2,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"unit_vector",
		"encoder": &"encode_goal_direction",
		"columns": ["Goal X:float", "Goal Y:float"],
		"accent": Color("76d49b"),
	},
	&"goal_direction": {
		"label": "Goal direction",
		"detail": "Direction (x, y)",
		"dimension_kind": &"fixed",
		"channels": 2,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"unit_vector",
		"encoder": &"encode_goal_direction",
		"columns": ["Goal direction X:float", "Goal direction Y:float"],
		"accent": Color("76d49b"),
	},
	&"local_goal_direction": {
		"label": "Local goal direction",
		"detail": "Relative to agent heading (x, y)",
		"dimension_kind": &"fixed",
		"channels": 2,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"unit_vector",
		"encoder": &"encode_local_goal_direction",
		"columns": ["Local goal X:float", "Local goal Y:float"],
		"accent": Color("76d49b"),
	},
	&"goal_distance": {
		"label": "Goal distance",
		"detail": "Scalar",
		"dimension_kind": &"fixed",
		"channels": 1,
		"range": Vector2(0.0, 1.0),
		"normalization": &"world_diagonal",
		"encoder": &"encode_goal_distance",
		"columns": ["Goal distance:float"],
		"accent": Color("76d49b"),
	},
	&"normalized_position": {
		"label": "Position",
		"detail": "Normalized (x, y)",
		"dimension_kind": &"fixed",
		"channels": 2,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"world_bounds",
		"encoder": &"encode_normalized_position",
		"columns": ["Position X:float", "Position Y:float"],
		"accent": Color("72b9d8"),
	},
	&"heading_sincos": {
		"label": "Heading",
		"detail": "Sin / cos",
		"dimension_kind": &"fixed",
		"channels": 2,
		"range": Vector2(-1.0, 1.0),
		"normalization": &"sincos",
		"encoder": &"encode_heading_sincos",
		"columns": ["Heading sin:float", "Heading cos:float"],
		"accent": Color("a58bd8"),
	},
	&"height": {
		"label": "Height",
		"detail": "Normalized height",
		"dimension_kind": &"fixed",
		"channels": 1,
		"range": Vector2(0.0, 1.0),
		"normalization": &"world_height",
		"encoder": &"encode_height",
		"columns": ["Height:float"],
		"accent": Color("a58bd8"),
	},
	&"grounded": {
		"label": "On ground",
		"detail": "Boolean",
		"dimension_kind": &"fixed",
		"channels": 1,
		"range": Vector2(0.0, 1.0),
		"normalization": &"boolean",
		"encoder": &"encode_grounded",
		"columns": ["Grounded:float"],
		"accent": Color("a58bd8"),
	},
}

const ACTUATOR_DEFINITIONS := {
	&"steering": {
		"label": "Steering",
		"detail": "Turn left or right",
		"channels": 1,
		"range": Vector2(-1.0, 1.0),
		"decoder": &"apply_steering",
		"columns": ["Steering:float"],
		"accent": Color("e4c44f"),
	},
	&"throttle": {
		"label": "Throttle",
		"detail": "Forward power",
		"channels": 1,
		"range": Vector2(0.0, 1.0),
		"decoder": &"apply_throttle",
		"columns": ["Throttle:float"],
		"accent": Color("e4c44f"),
	},
	&"brake": {
		"label": "Brake",
		"detail": "Braking power",
		"channels": 1,
		"range": Vector2(0.0, 1.0),
		"decoder": &"apply_brake",
		"columns": ["Brake:float"],
		"accent": Color("e4c44f"),
	},
	&"horizontal_thrust": {
		"label": "Horizontal thrust",
		"detail": "Left or right power",
		"channels": 1,
		"range": Vector2(-1.0, 1.0),
		"decoder": &"apply_horizontal_thrust",
		"columns": ["Horizontal thrust:float"],
		"accent": Color("e4c44f"),
	},
	&"vertical_thrust": {
		"label": "Vertical thrust",
		"detail": "Up or down power",
		"channels": 1,
		"range": Vector2(-1.0, 1.0),
		"decoder": &"apply_vertical_thrust",
		"columns": ["Vertical thrust:float"],
		"accent": Color("e4c44f"),
	},
	&"jump": {
		"label": "Jump",
		"detail": "Upward impulse",
		"channels": 1,
		"range": Vector2(0.0, 1.0),
		"decoder": &"apply_jump",
		"columns": ["Jump:float"],
		"accent": Color("e4c44f"),
	},
}

const AGENT_DEFINITIONS := {
	&"side_view_car": {
		"label": "Side-view Car",
		"physics_kind": &"ground_rigid",
		"compatible_perspective": &"side_view",
		"expert_policy": &"side_view_car_actions",
		"sensors": [
			&"ray_distance", &"speed", &"velocity_x", &"velocity_y",
			&"rotation", &"gps", &"goal_vector", &"goal_direction", &"goal_distance", &"normalized_position",
			&"heading_sincos", &"grounded",
		],
		"actuators": [&"steering", &"throttle", &"brake", &"jump"],
		"default_binding": {
			"inputs": [
				{"sensor_id": &"ray_distance", "start": 0, "length": 8},
				{"sensor_id": &"speed", "start": 8, "length": 1},
			],
			"outputs": [
				{"actuator_id": &"steering", "start": 0, "length": 1},
				{"actuator_id": &"throttle", "start": 1, "length": 1},
				{"actuator_id": &"brake", "start": 2, "length": 1},
			],
		},
	},
	&"top_down_rover": {
		"label": "Top-down Rover",
		"physics_kind": &"top_down_rigid",
		"compatible_perspective": &"top_down",
		"expert_policy": &"top_down_rover_actions",
		"sensors": [
			&"ray_distance", &"speed", &"velocity_x", &"velocity_y",
			&"rotation", &"gps", &"goal_vector", &"goal_direction", &"local_goal_direction", &"goal_distance", &"normalized_position",
			&"heading_sincos",
		],
		"actuators": [&"steering", &"throttle", &"brake", &"horizontal_thrust", &"vertical_thrust"],
		"default_binding": {
			"inputs": [
				{"sensor_id": &"ray_distance", "start": 0, "length": 8},
				{"sensor_id": &"speed", "start": 8, "length": 1},
				{"sensor_id": &"local_goal_direction", "start": 9, "length": 2},
			],
			"outputs": [
				{"actuator_id": &"steering", "start": 0, "length": 1},
				{"actuator_id": &"throttle", "start": 1, "length": 1},
				{"actuator_id": &"brake", "start": 2, "length": 1},
			],
		},
	},
	&"flying_agent": {
		"label": "Flying Agent",
		"physics_kind": &"flying_rigid",
		"compatible_perspective": &"side_view",
		"expert_policy": &"flying_agent_actions",
		"sensors": [
			&"ray_distance", &"speed", &"velocity_x", &"velocity_y",
			&"rotation", &"gps", &"goal_vector", &"goal_direction", &"goal_distance", &"normalized_position",
			&"heading_sincos", &"height",
		],
		"actuators": [&"horizontal_thrust", &"vertical_thrust"],
		"default_binding": {
			"inputs": [
				{"sensor_id": &"ray_distance", "start": 0, "length": 8},
				{"sensor_id": &"velocity_x", "start": 8, "length": 1},
				{"sensor_id": &"velocity_y", "start": 9, "length": 1},
				{"sensor_id": &"goal_direction", "start": 10, "length": 2},
				{"sensor_id": &"height", "start": 12, "length": 1},
			],
			"outputs": [
				{"actuator_id": &"horizontal_thrust", "start": 0, "length": 1},
				{"actuator_id": &"vertical_thrust", "start": 1, "length": 1},
			],
		},
	},
}


static func sensors() -> Dictionary:
	return SENSOR_DEFINITIONS.duplicate(true)


static func actuators() -> Dictionary:
	return ACTUATOR_DEFINITIONS.duplicate(true)


static func agents() -> Dictionary:
	return AGENT_DEFINITIONS.duplicate(true)


static func sensor(sensor_id: StringName) -> Dictionary:
	return _definition(SENSOR_DEFINITIONS, sensor_id)


static func actuator(actuator_id: StringName) -> Dictionary:
	return _definition(ACTUATOR_DEFINITIONS, actuator_id)


static func agent(agent_id: StringName) -> Dictionary:
	return _definition(AGENT_DEFINITIONS, agent_id)


static func sensor_accepts_width(sensor_id: StringName, width: int) -> bool:
	var definition := sensor(sensor_id)
	if definition.is_empty() or width <= 0:
		return false
	if definition.get("dimension_kind") == &"range":
		return width >= int(definition.get("min_channels", 1)) \
			and width <= int(definition.get("max_channels", width))
	return width == int(definition.get("channels", 0))


static func actuator_accepts_width(actuator_id: StringName, width: int) -> bool:
	var definition := actuator(actuator_id)
	return not definition.is_empty() and width == int(definition.get("channels", 0))


static func agent_supports_sensor(agent_id: StringName, sensor_id: StringName) -> bool:
	return agent(agent_id).get("sensors", []).has(sensor_id)


static func agent_supports_actuator(agent_id: StringName, actuator_id: StringName) -> bool:
	return agent(agent_id).get("actuators", []).has(actuator_id)


static func sensor_columns(sensor_id: StringName, width: int) -> Array[String]:
	var definition := sensor(sensor_id)
	var result: Array[String] = []
	if definition.is_empty() or not sensor_accepts_width(sensor_id, width):
		return result
	if definition.has("column_template"):
		for channel_index in width:
			result.append(str(definition["column_template"]) % (channel_index + 1))
		return result
	for column in definition.get("columns", []):
		result.append(str(column))
	return result


static func actuator_columns(actuator_id: StringName) -> Array[String]:
	var result: Array[String] = []
	for column in actuator(actuator_id).get("columns", []):
		result.append(str(column))
	return result


static func default_binding(agent_id: StringName) -> Dictionary:
	var definition := agent(agent_id)
	return definition.get("default_binding", {}).duplicate(true)


static func _definition(catalog: Dictionary, definition_id: StringName) -> Dictionary:
	if not catalog.has(definition_id):
		return {}
	return catalog[definition_id].duplicate(true)
