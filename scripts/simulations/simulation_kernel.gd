class_name SimulationKernel
extends RefCounted

const Backend = preload("res://scripts/simulations/simulation_physics_backend.gd")
const RayQuery = preload("res://scripts/simulations/simulation_compiled_ray_query.gd")
const AgentProvider = preload("res://scripts/simulations/simulation_kernel_agent.gd")
const RandomizationProfile = preload("res://scripts/simulations/simulation_randomization_profile.gd")
const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")

var _blueprint: Dictionary = {}
var _physics = null
var _ray_query = null
var _agents: Dictionary = {}
var _position_overrides: Dictionary = {}
var _rotation_overrides: Dictionary = {}
var _hidden_ids: Dictionary = {}
var _active_pairs: Dictionary = {}
var _events: Array[Dictionary] = []
var _elapsed := 0.0
var _dynamic_ids := PackedStringArray()
var _agent_ray_counts: Dictionary = {}
var _cached_ray_distances: Dictionary = {}

func create(blueprint: Dictionary, active: bool = true) -> bool:
	destroy()
	_blueprint = blueprint
	_physics = Backend.new()
	if not _physics.create(_blueprint, active):
		_physics = null
		return false
	_ray_query = RayQuery.new()
	_ray_query.configure(_blueprint)
	for index in _blueprint.get("agent_indices", PackedInt32Array()):
		var provider: SimulationKernelAgent = AgentProvider.new()
		provider.configure(self, index, _blueprint["definitions"][index], _blueprint["properties"][index])
		_agents[str(_blueprint["ids"][index])] = provider
		var ray_count := 0
		var binding_inputs: Array = _blueprint["properties"][index].get("model_binding", {}).get("inputs", [])
		if binding_inputs.is_empty():
			var agent_id = _blueprint["definitions"][index].get("agent_id", &"")
			binding_inputs = Registry.agent(agent_id).get("default_binding", {}).get("inputs", [])
		for entry in binding_inputs:
			if entry is Dictionary and str(entry.get("sensor_id", "")) == "ray_distance":
				ray_count = int(entry.get("length", 0))
		if ray_count > 0:
			_agent_ray_counts[str(_blueprint["ids"][index])] = ray_count
	for index in _blueprint.get("dynamic_indices", PackedInt32Array()):
		_dynamic_ids.append(_blueprint["ids"][index])
	return true


func destroy() -> void:
	if _physics != null:
		_physics.destroy()
	if _ray_query != null:
		_ray_query.clear()
	_physics = null
	_ray_query = null
	_agents.clear()
	_position_overrides.clear()
	_rotation_overrides.clear()
	_hidden_ids.clear()
	_active_pairs.clear()
	_events.clear()
	_dynamic_ids.clear()
	_agent_ray_counts.clear()
	_cached_ray_distances.clear()
	_elapsed = 0.0


func set_active(value: bool) -> void:
	if _physics != null:
		_physics.set_active(value)


func tick(delta: float) -> void:
	if _physics == null:
		return
	_sync_dynamic_ray_transforms()
	_cache_ray_distances()
	_elapsed += delta
	_update_triggers()


func reset() -> void:
	if _physics != null:
		_physics.reset_to_blueprint()
	if _ray_query != null:
		_ray_query.reset_to_blueprint()
	_position_overrides.clear()
	_rotation_overrides.clear()
	_hidden_ids.clear()
	_active_pairs.clear()
	_events.clear()
	_elapsed = 0.0


func randomize_episode(seed: int) -> Dictionary:
	reset()
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	var applied := {"object_positions": {}, "surface_materials": {}, "start_position": null, "goal_position": null}
	var active_randomization := RandomizationProfile.active_config(_blueprint.get("metadata", {}).get("randomization", {}))
	for index in _blueprint.get("ids", PackedStringArray()).size():
		var properties: Dictionary = _blueprint["properties"][index]
		var config: Variant = properties.get("randomization", {})
		if config is Dictionary and config.has("position_jitter") and active_randomization.has("obstacle_position"):
			var jitter := _as_vector2(config["position_jitter"], Vector2.ZERO)
			var next_position: Vector2 = _blueprint["positions"][index] + Vector2(rng.randf_range(-jitter.x, jitter.x), rng.randf_range(-jitter.y, jitter.y))
			_set_position(index, next_position)
			applied["object_positions"][_blueprint["ids"][index]] = next_position
		if config is Dictionary and config.has("material_variants") and active_randomization.has("surface_material"):
			var variants: Variant = config["material_variants"]
			if variants is Array and not variants.is_empty():
				var selected_type := StringName(variants[rng.randi_range(0, variants.size() - 1)])
				var selected_definition := SimulationObjectCatalog.definition(selected_type)
				if not selected_definition.is_empty() and _physics != null:
					_physics.set_material(index, selected_definition)
					applied["surface_materials"][_blueprint["ids"][index]] = str(selected_type)
	for index in _blueprint.get("agent_indices", PackedInt32Array()):
		if active_randomization.has("start_position"):
			var jitter := RandomizationProfile.vector_value(active_randomization, "start_position")
			var next_position: Vector2 = _blueprint["positions"][index] + Vector2(rng.randf_range(-jitter.x, jitter.x), rng.randf_range(-jitter.y, jitter.y))
			_set_position(index, next_position)
			applied["start_position"] = next_position
		if active_randomization.has("initial_speed"):
			var speed_range := RandomizationProfile.vector_value(active_randomization, "initial_speed")
			var speed := rng.randf_range(minf(speed_range.x, speed_range.y), maxf(speed_range.x, speed_range.y))
			_physics.set_body_state(index, position_for(index), rotation_for(index), Vector2.RIGHT.rotated(rotation_for(index)) * speed)
	for index in _blueprint.get("goal_indices", PackedInt32Array()):
		if active_randomization.has("goal_position"):
			var jitter := RandomizationProfile.vector_value(active_randomization, "goal_position")
			var next_position: Vector2 = _blueprint["positions"][index] + Vector2(rng.randf_range(-jitter.x, jitter.x), rng.randf_range(-jitter.y, jitter.y))
			_set_position(index, next_position)
			applied["goal_position"] = next_position
	return applied


func agent_object_ids() -> Array[String]:
	var result: Array[String] = []
	for object_id in _agents:
		result.append(object_id)
	return result


func agent(object_id: String) -> SimulationKernelAgent:
	return _agents.get(object_id) as SimulationKernelAgent


func first_agent() -> SimulationKernelAgent:
	if _agents.is_empty():
		return null
	return _agents.values()[0] as SimulationKernelAgent


func first_agent_index() -> int:
	var indices: PackedInt32Array = _blueprint.get("agent_indices", PackedInt32Array())
	return indices[0] if not indices.is_empty() else -1


func context_for_agent(index: int) -> Dictionary:
	var bounds: Rect2 = _blueprint.get("bounds", Rect2(-480.0, -260.0, 960.0, 520.0))
	var object_id = str(_blueprint["ids"][index])
	var ray_distances = _cached_ray_distances.get(object_id, PackedFloat32Array())
	return {
		"agent_position": position_for(index),
		"agent_rotation": rotation_for(index),
		"agent_velocity": velocity_for(index),
		"goal_position": goal_position(),
		"world_bounds": bounds,
		"max_goal_distance": maxf(bounds.size.length(), 1.0),
		"ray_values": ray_distances,
	}


func apply_agent_controls(index: int, physics_kind: StringName, controls: Dictionary) -> void:
	if _physics != null:
		_physics.apply_agent_controls(index, physics_kind, controls)


func position_for(index: int) -> Vector2:
	if _position_overrides.has(index):
		return _position_overrides[index]
	return _physics.position(index) if _physics != null else _blueprint.get("positions", PackedVector2Array())[index]


func rotation_for(index: int) -> float:
	if _rotation_overrides.has(index):
		return _rotation_overrides[index]
	return _physics.rotation(index) if _physics != null else float(_blueprint.get("rotations", PackedFloat32Array())[index])


func velocity_for(index: int) -> Vector2:
	return _physics.velocity(index) if _physics != null else Vector2.ZERO


func angular_velocity_for(index: int) -> float:
	return _physics.angular_velocity(index) if _physics != null else 0.0


func raycast_fan(index: int, count: int, distance: float, arc: float) -> PackedFloat32Array:
	return _ray_query.raycast_fan(index, count, distance, arc) if _ray_query != null else PackedFloat32Array()


func grounded(index: int) -> bool:
	var half_height: float = _blueprint["sizes"][index].y * absf(_blueprint["scales"][index].y) * 0.5
	return _ray_query != null and _ray_query.raycast_direction(index, Vector2.DOWN, half_height + 8.0) < 0.999


func goal_position() -> Vector2:
	var goals: PackedInt32Array = _blueprint.get("goal_indices", PackedInt32Array())
	return position_for(goals[0]) if not goals.is_empty() else _blueprint.get("bounds", Rect2()).end


func snapshot() -> Dictionary:
	var transforms := PackedFloat32Array()
	for index in _blueprint.get("dynamic_indices", PackedInt32Array()):
		var value := position_for(index)
		transforms.append(value.x)
		transforms.append(value.y)
		transforms.append(rotation_for(index))
	return {"ids": _dynamic_ids, "transforms": transforms, "raycasts": _cached_ray_distances, "hidden_ids": _hidden_ids.duplicate(), "elapsed": _elapsed}


func drain_events() -> Array[Dictionary]:
	var result := _events
	_events = []
	return result


func terminal_reason(agent_index: int, start_position: Vector2, step_index: int, max_steps: int) -> StringName:
	var position_value := position_for(agent_index)
	if position_value.distance_to(goal_position()) <= 54.0:
		return &"success"
	for trigger_index in _blueprint.get("trigger_indices", PackedInt32Array()):
		if not _overlaps(agent_index, trigger_index):
			continue
		var role := str(_blueprint["definitions"][trigger_index].get("dataset_role", ""))
		if role == "hazard":
			return &"hazard"
	var bounds: Rect2 = _blueprint.get("bounds", Rect2(-480.0, -260.0, 960.0, 520.0))
	if not bounds.grow(48.0).has_point(position_value):
		return &"collision"
	if step_index >= 180 and position_value.distance_to(start_position) < 24.0:
		return &"stuck"
	if step_index >= max_steps:
		return &"timeout"
	return &""


func blueprint() -> Dictionary:
	return _blueprint


func export_dynamic_states() -> Dictionary:
	var states := {}
	if _physics == null:
		return states
	for index in _blueprint.get("dynamic_indices", PackedInt32Array()):
		var object_id = str(_blueprint["ids"][index])
		states[object_id] = {
			"position": position_for(index),
			"rotation": rotation_for(index),
			"velocity": velocity_for(index),
			"angular_velocity": angular_velocity_for(index)
		}
	return states


func object_at(world_position: Vector2, preferred_id: String = "") -> String:
	var best_id := ""
	for index in _blueprint.get("dynamic_indices", PackedInt32Array()):
		var position := position_for(index)
		var rotation := rotation_for(index)
		var scale: Vector2 = _blueprint["scales"][index]
		var size: Vector2 = _blueprint["sizes"][index]
		var local := (world_position - position).rotated(-rotation)
		local = Vector2(local.x / maxf(absf(scale.x), 0.0001), local.y / maxf(absf(scale.y), 0.0001))
		var definition: Dictionary = _blueprint["definitions"][index]
		var hit := false
		match str(definition.get("shape_kind", "rectangle")):
			"circle":
				var normalized := Vector2(local.x / maxf(size.x * 0.5, 0.001), local.y / maxf(size.y * 0.5, 0.001))
				hit = normalized.length_squared() <= 1.0
			"slope":
				hit = Geometry2D.is_point_in_polygon(local, PackedVector2Array([
					Vector2(-size.x * 0.5, size.y * 0.5),
					Vector2(size.x * 0.5, size.y * 0.5),
					Vector2(size.x * 0.5, -size.y * 0.5),
				]))
			_:
				hit = Rect2(-size * 0.5, size).has_point(local)
		if hit:
			var hit_id := str(_blueprint["ids"][index])
			if hit_id == preferred_id:
				return hit_id
			best_id = hit_id
	return best_id


func objects_in_rect(rect: Rect2) -> Array[String]:
	var result: Array[String] = []
	for index in _blueprint.get("dynamic_indices", PackedInt32Array()):
		var position := position_for(index)
		var size: Vector2 = _blueprint["sizes"][index]
		var max_radius = maxf(size.x, size.y) * 0.7071
		if rect.grow(max_radius).has_point(position):
			result.append(str(_blueprint["ids"][index]))
	return result


func import_dynamic_states(states: Dictionary) -> void:
	if _physics == null:
		return
	for index in _blueprint.get("dynamic_indices", PackedInt32Array()):
		var object_id = str(_blueprint["ids"][index])
		if states.has(object_id):
			var state = states[object_id]
			_physics.set_body_state(index, state["position"], state["rotation"], state["velocity"], state["angular_velocity"])
			if _ray_query != null:
				_ray_query.set_transform(index, state["position"], state["rotation"])


func live_update_object(object_data: Dictionary) -> void:
	var object_id = str(object_data.get("id", ""))
	var index := -1
	var ids: PackedStringArray = _blueprint.get("ids", PackedStringArray())
	for i in ids.size():
		if ids[i] == object_id:
			index = i
			break
	if index < 0:
		return

	_blueprint["positions"][index] = object_data.get("position", Vector2.ZERO)
	_blueprint["rotations"][index] = float(object_data.get("rotation", 0.0))
	_blueprint["scales"][index] = object_data.get("scale", Vector2.ONE)
	_blueprint["sizes"][index] = object_data.get("size", Vector2.ZERO)
	_blueprint["properties"][index] = object_data.get("properties", {}).duplicate(true)

	if _physics != null:
		_physics.live_update_object(index, object_data, _blueprint["definitions"][index])
	if _ray_query != null:
		_ray_query.live_update_object(index, object_data)


func _set_position(index: int, value: Vector2) -> void:
	var definition: Dictionary = _blueprint["definitions"][index]
	var body_kind: String = str(definition.get("body_kind", ""))
	if body_kind in ["static", "rigid", "agent"]:
		_position_overrides.erase(index)
	else:
		_position_overrides[index] = value
	if _physics != null:
		_physics.set_object_transform(index, value, rotation_for(index))
	if _ray_query != null:
		_ray_query.set_transform(index, value, rotation_for(index))


func _sync_dynamic_ray_transforms() -> void:
	if _ray_query == null or _physics == null:
		return
	for index in _blueprint.get("dynamic_indices", PackedInt32Array()):
		_ray_query.set_transform(index, _physics.position(index), _physics.rotation(index))


func _cache_ray_distances() -> void:
	for object_id in _agent_ray_counts:
		var agent_node: SimulationKernelAgent = _agents.get(object_id)
		if agent_node != null:
			_cached_ray_distances[object_id] = agent_node.encode_ray_distance(_agent_ray_counts[object_id], {})


func _update_triggers() -> void:
	var current := {}
	for agent_index in _blueprint.get("agent_indices", PackedInt32Array()):
		for trigger_index in _blueprint.get("trigger_indices", PackedInt32Array()):
			if not _overlaps(agent_index, trigger_index):
				continue
			var pair := "%d:%d" % [agent_index, trigger_index]
			current[pair] = true
			if _active_pairs.has(pair):
				continue
			var definition: Dictionary = _blueprint["definitions"][trigger_index]
			var object_id := str(_blueprint["ids"][trigger_index])
			var effect := StringName(definition.get("effect", ""))
			_events.append({"object_id": object_id, "agent_id": str(_blueprint["ids"][agent_index]), "effect": effect})
			if effect == &"coin":
				_hidden_ids[object_id] = true
	_active_pairs = current


func _overlaps(left_index: int, right_index: int) -> bool:
	if _hidden_ids.has(str(_blueprint["ids"][right_index])):
		return false
	return _bounds_for(left_index).intersects(_bounds_for(right_index), true)


func _bounds_for(index: int) -> Rect2:
	var half: Vector2 = _blueprint["sizes"][index] * _blueprint["scales"][index].abs() * 0.5
	return Rect2(position_for(index) - half, half * 2.0)


func _as_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback
