class_name SimulationExpertPolicy
extends RefCounted

const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")


static func actions_for(
	agent_id: StringName,
	binding: Dictionary,
	context: Dictionary
) -> PackedFloat32Array:
	var method := StringName(Registry.agent(agent_id).get("expert_policy", ""))
	var provider = new()
	if method.is_empty() or not provider.has_method(method):
		return PackedFloat32Array()
	var desired = provider.call(method, context)
	if desired is not Dictionary:
		return PackedFloat32Array()
	return _bind_outputs(binding, desired)


func side_view_car_actions(context: Dictionary) -> Dictionary:
	var position: Vector2 = context.get("agent_position", Vector2.ZERO)
	var nav_target: Vector2 = context.get("navigation_target", context.get("goal_position", position + Vector2.RIGHT))
	var final_goal: Vector2 = context.get("goal_position", position + Vector2.RIGHT)
	var nav_horizontal_distance: float = nav_target.x - position.x
	var final_horizontal_distance: float = final_goal.x - position.x
	var final_absolute_distance: float = absf(final_horizontal_distance)
	var close_to_goal: bool = final_absolute_distance <= 54.0
	var drive_direction: float = 0.0 if close_to_goal else signf(nav_horizontal_distance)
	var approach_strength: float = smoothstep(54.0, 96.0, final_absolute_distance)
	var ray_values: PackedFloat32Array = _float_array(context.get("ray_values", []))
	var clearance_strength: float = _side_view_clearance_strength(ray_values)
	var drive_strength: float = minf(approach_strength, clearance_strength)
	var jump: float = 0.0
	if clearance_strength < 0.6 and final_absolute_distance > 54.0:
		jump = 1.0
	if nav_target.y < position.y - 40.0 and final_absolute_distance > 54.0:
		jump = 1.0

	return {
		# A side-view car uses signed steering as its horizontal drive direction.
		# A* owns the route direction. Ray clearance can slow the car or trigger
		# a jump, but must not weaken the direction toward the active waypoint.
		&"steering": drive_direction * approach_strength,
		&"throttle": drive_strength,
		&"brake": 1.0 if close_to_goal else 0.0,
		&"jump": jump,
	}


func _side_view_clearance_strength(ray_values: PackedFloat32Array) -> float:
	if ray_values.is_empty():
		return 1.0
	var total: float = 0.0
	for ray_value in ray_values:
		total += clampf(ray_value, 0.0, 1.0)
	var average_clearance: float = total / float(ray_values.size())
	return lerpf(0.35, 1.0, smoothstep(0.15, 0.9, average_clearance))


func top_down_rover_actions(context: Dictionary) -> Dictionary:
	var position: Vector2 = context.get("agent_position", Vector2.ZERO)
	var goal: Vector2 = context.get("goal_position", position + Vector2.RIGHT)
	if position.distance_to(goal) <= 54.0:
		return {
			&"steering": 0.0,
			&"throttle": 0.0,
			&"brake": 1.0,
		}

	var rotation := float(context.get("agent_rotation", 0.0))
	var goal_angle := wrapf((goal - position).angle() - rotation, -PI, PI)
	var goal_steering := clampf(goal_angle / (PI * 0.5), -1.0, 1.0)
	var ray_values: PackedFloat32Array = _float_array(context.get("ray_values", []))
	if ray_values.is_empty():
		return {
			&"steering": goal_steering,
			&"throttle": clampf(1.0 - absf(goal_steering) * 0.35, 0.45, 1.0),
			&"brake": 0.0,
		}

	var nearest_ray := 1.0
	var avoidance := 0.0
	var left_clearance := 0.0
	var right_clearance := 0.0
	var left_count := 0
	var right_count := 0
	var center_start := maxi(0, ray_values.size() / 2 - 1)
	var center_end := mini(ray_values.size() - 1, ray_values.size() / 2)
	var front_clearance := 1.0
	for ray_index in ray_values.size():
		var clearance := clampf(ray_values[ray_index], 0.0, 1.0)
		nearest_ray = minf(nearest_ray, clearance)
		if ray_index >= center_start and ray_index <= center_end:
			front_clearance = minf(front_clearance, clearance)
		if ray_index < ray_values.size() / 2:
			left_clearance += clearance
			left_count += 1
		else:
			right_clearance += clearance
			right_count += 1
		var ratio := 0.5 if ray_values.size() == 1 else float(ray_index) / float(ray_values.size() - 1)
		var ray_angle := lerpf(deg_to_rad(-66.0), deg_to_rad(66.0), ratio)
		avoidance -= sin(ray_angle) * pow(1.0 - clearance, 2.0)

	left_clearance /= float(maxi(left_count, 1))
	right_clearance /= float(maxi(right_count, 1))
	var steering := clampf(goal_steering * 0.35 + avoidance * 3.0, -1.0, 1.0)
	if front_clearance < 0.45:
		var escape_direction := 1.0
		if absf(right_clearance - left_clearance) > 0.04:
			escape_direction = 1.0 if right_clearance > left_clearance else -1.0
		var urgency := 1.0 - smoothstep(0.08, 0.45, front_clearance)
		steering = lerpf(escape_direction * 0.8, escape_direction, urgency)

	var speed: float = (context.get("agent_velocity", Vector2.ZERO) as Vector2).length()
	var brake := 1.0 if front_clearance < 0.035 and speed > 120.0 else 0.0
	var clearance_throttle := lerpf(0.28, 1.0, smoothstep(0.15, 0.85, front_clearance))
	var turn_throttle := clampf(1.0 - absf(steering) * 0.45, 0.4, 1.0)
	return {
		&"steering": steering,
		&"throttle": 0.0 if brake > 0.0 else minf(clearance_throttle, turn_throttle),
		&"brake": brake,
	}


func flying_agent_actions(context: Dictionary) -> Dictionary:
	var nav_target: Vector2 = context.get("navigation_target", context.get("goal_position", Vector2.ZERO))
	var final_goal: Vector2 = context.get("goal_position", context.get("agent_position", Vector2.ZERO))
	var position: Vector2 = context.get("agent_position", Vector2.ZERO)

	var delta: Vector2 = nav_target - position
	var direction := delta.normalized()

	var velocity: Vector2 = context.get("agent_velocity", Vector2.ZERO)
	var ray_values: PackedFloat32Array = _float_array(context.get("ray_values", []))
	var vertical_avoidance := 0.0
	var nearest_ray := 1.0
	for ray_index in ray_values.size():
		var clearance := clampf(ray_values[ray_index], 0.0, 1.0)
		nearest_ray = minf(nearest_ray, clearance)
		var ratio := 0.5 if ray_values.size() == 1 else float(ray_index) / float(ray_values.size() - 1)
		var angle := lerpf(deg_to_rad(-66.0), deg_to_rad(66.0), ratio)
		var weight := pow(1.0 - clearance, 2.0)
		vertical_avoidance -= sin(angle) * weight

	if nearest_ray < 0.6 and absf(vertical_avoidance) < 0.15:
		var bounds: Rect2 = context.get("world_bounds", Rect2(-1.0, -1.0, 2.0, 2.0))
		var room_above := position.y - bounds.position.y
		var room_below := bounds.end.y - position.y
		vertical_avoidance = 0.7 if room_below >= room_above else -0.7

	var speed_scale := maxf(0.12, smoothstep(0.25, 0.9, nearest_ray))

	if position.distance_to(final_goal) <= 54.0:
		return { &"horizontal_thrust": 0.0, &"vertical_thrust": 0.0 }

	var horizontal_thrust := direction.x * speed_scale
	var needs_hard_brake := nearest_ray < 0.35 and absf(velocity.x) > 20.0
	var needs_early_brake := nearest_ray < 0.7 and absf(velocity.x) > 60.0
	if needs_hard_brake or needs_early_brake:
		horizontal_thrust = -signf(velocity.x)
	elif nearest_ray < 0.35:
		horizontal_thrust = 0.0

	return {
		&"horizontal_thrust": horizontal_thrust,
		&"vertical_thrust": clampf(direction.y * 0.7 + vertical_avoidance * 3.4, -1.0, 1.0),
	}


static func _bind_outputs(binding: Dictionary, desired: Dictionary) -> PackedFloat32Array:
	var width := int(binding.get("output_width", 0))
	if width <= 0:
		return PackedFloat32Array()
	var result := PackedFloat32Array()
	result.resize(width)
	for mapping in binding.get("outputs", []):
		if mapping is not Dictionary:
			return PackedFloat32Array()
		var actuator_id := StringName(mapping.get("actuator_id", ""))
		var start := int(mapping.get("start", -1))
		var length := int(mapping.get("length", 0))
		if start < 0 or length <= 0 or start + length > width or not desired.has(actuator_id):
			return PackedFloat32Array()
		var values := _float_array(desired[actuator_id])
		if values.is_empty() and length == 1 and desired[actuator_id] is float:
			values.append(float(desired[actuator_id]))
		if values.is_empty() and length == 1 and desired[actuator_id] is int:
			values.append(float(desired[actuator_id]))
		if values.size() != length:
			return PackedFloat32Array()
		var definition := Registry.actuator(actuator_id)
		var value_range: Vector2 = definition.get("range", Vector2(-1.0, 1.0))
		for value_index in length:
			result[start + value_index] = clampf(values[value_index], value_range.x, value_range.y)
	return result


static func _float_array(value: Variant) -> PackedFloat32Array:
	if value is PackedFloat32Array:
		return value
	var result := PackedFloat32Array()
	if value is Array or value is PackedFloat64Array:
		for item in value:
			if item is not float and item is not int:
				return PackedFloat32Array()
			result.append(float(item))
	return result


static func _average(values: PackedFloat32Array) -> float:
	if values.is_empty():
		return 1.0
	var total := 0.0
	for value in values:
		total += value
	return total / float(values.size())
