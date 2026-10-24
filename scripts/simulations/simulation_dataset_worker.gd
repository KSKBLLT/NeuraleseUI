class_name SimulationDatasetWorker
extends RefCounted

const Kernel = preload("res://scripts/simulations/simulation_kernel.gd")
const ExpertPolicy = preload("res://scripts/simulations/simulation_expert_policy.gd")
const Navigator = preload("res://scripts/simulations/navigation/simulation_navigator.gd")

const PHYSICS_DELTA := 1.0 / 60.0
const MAX_EPISODE_STEPS := 1200
const MAX_ROWS_PER_EPISODE := 64
const PREVIEW_EVERY_ROWS := 32
const PROGRESS_EVERY_ROWS := 32
const MAX_CONSECUTIVE_EMPTY_EPISODES := 50

var _thread := Thread.new()
var _tick := Semaphore.new()
var _mutex := Mutex.new()
var _messages: Array[Dictionary] = []
var _cancel_requested := false
var _finished := false
var _config: Dictionary = {}
var _kernel: Kernel = null
var _navigator: Navigator = null


func prepare(config: Dictionary) -> bool:
	if _thread.is_started():
		return false
	_config = config

	var blueprint: Dictionary = _config.get("blueprint", {})
	_kernel = Kernel.new()
	if not _kernel.create(blueprint, true):
		return false

	var agent_index := _kernel.first_agent_index()
	if agent_index < 0:
		return false

	_navigator = Navigator.new()
	return true


func start_thread() -> bool:
	if _thread.is_started():
		return false

	PhysicsServer2D.space_get_direct_state(_kernel._physics._space)

	var blueprint: Dictionary = _config.get("blueprint", {})
	var agent_size = Vector2(32, 32)
	var physics_kind: StringName = &"side_view_car"
	var hazard_bounds: Array[Rect2] = []

	for i in range(blueprint.get("definitions", []).size()):
		var def = blueprint.definitions[i]
		var t_str = str(blueprint.get("types", [])[i])
		var role = str(def.get("dataset_role", ""))

		if t_str in ["spikes", "lava"] or role == "hazard":
			var p: Vector2 = blueprint.get("positions")[i]
			var s: Vector2 = blueprint.get("sizes")[i]
			var sc: Vector2 = blueprint.get("scales")[i]
			var half = s * sc.abs() * 0.5
			hazard_bounds.append(Rect2(p - half, half * 2.0))

		if t_str in ["car", "rover", "flying_agent"]:
			agent_size = blueprint.get("sizes")[i]
			if t_str == "car":
				physics_kind = &"side_view_car"
			elif t_str == "rover" or t_str == "top_down_rover":
				physics_kind = &"top_down_rigid"
			elif t_str == "flying_agent":
				physics_kind = &"flying_rigid"

	var final_islands: Array[Rect2] = []
	var raw_islands = _config.get("islands", [])
	if raw_islands is Array:
		for r in raw_islands:
			if r is Rect2:
				final_islands.append(r)

	_navigator.rebuild_navigation(_kernel._physics._space, final_islands, physics_kind, {"jump_velocity": 450.0, "max_speed": 350.0, "size": agent_size}, hazard_bounds)

	return _thread.start(_run, Thread.PRIORITY_LOW) == OK


func force_space_flush() -> void:
	if _kernel and _kernel._physics and _kernel._physics._space.is_valid():
		PhysicsServer2D.space_get_direct_state(_kernel._physics._space)


func pulse() -> void:
	_tick.post()


func request_cancel() -> void:
	_mutex.lock()
	_cancel_requested = true
	_mutex.unlock()
	_tick.post()


func drain_messages() -> Array[Dictionary]:
	_mutex.lock()
	var result := _messages
	_messages = []
	_mutex.unlock()
	return result


func is_finished() -> bool:
	_mutex.lock()
	var result := _finished
	_mutex.unlock()
	return result


func join_finished() -> void:
	if is_finished() and _thread.is_started():
		_thread.wait_to_finish()


func shutdown() -> void:
	request_cancel()
	if _thread.is_started():
		_thread.wait_to_finish()


func _run() -> void:
	var worker_id := int(_config.get("worker_id", 0))
	var worker_count := int(_config.get("worker_count", 1))
	var total_rows := int(_config.get("total_rows", 0))
	var seed := int(_config.get("seed", 0))

	var agent: SimulationKernelAgent = _kernel.first_agent()
	var agent_index := _kernel.first_agent_index()
	if agent == null or agent_index < 0:
		_push({"kind": "error", "worker_id": worker_id, "message": "Add an agent before generating a dataset."})
		_push(_empty_finished(worker_id, worker_count))
		_finish()
		return
	var binding: Dictionary = agent.get_model_binding()
	var follows_route := agent.get_agent_id() != &"top_down_rover"
	var input_width := int(binding.get("input_width", 0))
	var output_width := int(binding.get("output_width", 0))
	var stride := input_width + output_width
	var target_rows := _assigned_row_count(total_rows, worker_id, worker_count)
	var values := PackedFloat32Array()
	values.resize(target_rows * stride)
	var completed := 0
	var completed_episodes := 0
	var discarded := 0
	var terminal_counts := {"success": 0, "hazard": 0, "collision": 0, "stuck": 0, "timeout": 0, "cancelled": 0, "sample_limit": 0}
	var episode_cursor := 0
	var consecutive_failures := 0
	var blueprint: Dictionary = _config.get("blueprint", {})
	var expert_waypoints := PackedVector2Array()
	var waypoint_radius := float(blueprint.get("metadata", {}).get("expert_waypoint_radius", 56.0))

	while completed < target_rows and not _cancelled():
		var episode_index := worker_id + episode_cursor * worker_count
		episode_cursor += 1
		var episode_seed := _episode_seed(seed, episode_index)
		var rng := RandomNumberGenerator.new()
		rng.seed = episode_seed
		var randomization := _kernel.randomize_episode(episode_seed)
		var original_start_position := _kernel.position_for(agent_index)
		var goal_position: Vector2 = _kernel.goal_position()

		var full_path := PackedVector2Array()
		if follows_route:
			full_path = _navigator.get_path(original_start_position, goal_position)
			expert_waypoints = _expert_waypoints(blueprint)
			if expert_waypoints.is_empty():
				expert_waypoints = full_path
		else:
			# Rover datasets teach a reusable local obstacle-avoidance policy. A*
			# remains available to other agents, but never supplies rover labels.
			expert_waypoints = PackedVector2Array()

		if completed_episodes == 0 and follows_route:
			_push({
				"kind": "expert_path",
				"worker_id": worker_id,
				"path": Array(expert_waypoints)
			})

		if follows_route and full_path.is_empty():
			# Try one more tick and recalculate just in case
			_tick.wait()
			_kernel.tick(PHYSICS_DELTA)
			full_path = _navigator.get_path(_kernel.position_for(agent_index), goal_position)

		if follows_route:
			expert_waypoints = full_path

		var terminal_reason: StringName = &""
		var episode_steps := 0
		var episode_limit := mini(
			MAX_ROWS_PER_EPISODE,
			mini(MAX_EPISODE_STEPS, target_rows - completed)
		)
		var episode_values := PackedFloat32Array()
		var expert_path_positions := PackedVector2Array()
		var preview_payload: Dictionary = {}
		var last_ray_values := PackedFloat32Array()
		var last_targets := PackedFloat32Array()

		# Teleport agent to a random point along the path
		var waypoint_index := 0

		if not follows_route:
			consecutive_failures = 0
		elif not full_path.is_empty():
			consecutive_failures = 0
			var path_pt_idx = rng.randi_range(0, expert_waypoints.size() - 1)
			var base_pt = expert_waypoints[path_pt_idx]
			var noise_x = rng.randf_range(-8.0, 8.0)
			var noise_y = rng.randf_range(-24.0, -16.0)

			# We must teleport the agent to this position in physics space!
			var teleport_pos = base_pt + Vector2(noise_x, noise_y)
			_kernel._set_position(agent_index, teleport_pos)
			waypoint_index = path_pt_idx
		else:
			# No path could be found. This will quickly fail as stuck.
			consecutive_failures += 1
			if consecutive_failures >= MAX_CONSECUTIVE_EMPTY_EPISODES:
				_push({"kind": "error", "worker_id": worker_id, "message": "Generation aborted: The expert policy failed %d times consecutively. The environment may be impossible." % MAX_CONSECUTIVE_EMPTY_EPISODES})
				_push(_empty_finished(worker_id, worker_count))
				_finish()
				return

		var start_position = _kernel.position_for(agent_index)
		expert_path_positions.append(start_position)

		while episode_steps < episode_limit and terminal_reason.is_empty() and not _cancelled():
			var context := _kernel.context_for_agent(agent_index)
			if follows_route:
				while waypoint_index < expert_waypoints.size() and _kernel.position_for(agent_index).distance_to(expert_waypoints[waypoint_index]) <= waypoint_radius:
					waypoint_index += 1
				if waypoint_index < expert_waypoints.size():
					context["navigation_target"] = expert_waypoints[waypoint_index]
				else:
					context["navigation_target"] = goal_position


			var encoded: Dictionary = agent.observation_for_binding(context)
			var observation_values: PackedFloat32Array = encoded.get("values", PackedFloat32Array())
			if not encoded.get("valid", false) or observation_values.size() != input_width:
				terminal_reason = &"collision"
				break
			var ray_values := _ray_values(observation_values, binding)
			context["ray_values"] = ray_values

			var targets := ExpertPolicy.actions_for(agent.get_agent_id(), binding, context)
			last_ray_values = ray_values
			last_targets = targets

			var noisy_targets := targets.duplicate()
			var noise_probability := 0.05 if not follows_route else 0.15
			var noise_range := 0.08 if not follows_route else 0.15
			for i in noisy_targets.size():
				if rng.randf() < noise_probability:
					noisy_targets[i] = clampf(noisy_targets[i] + rng.randf_range(-noise_range, noise_range), -1.0, 1.0)

			if targets.size() != output_width or not agent.apply_model_outputs(noisy_targets, context).get("valid", false):
				terminal_reason = &"stuck"
				break

			# Wait for global physics tick
			_tick.wait()
			if _cancelled():
				terminal_reason = &"cancelled"
				break
			_kernel.tick(PHYSICS_DELTA)

			episode_values.append_array(observation_values)
			episode_values.append_array(targets)
			expert_path_positions.append(_kernel.position_for(agent_index))
			episode_steps += 1

			# Evaluate terminal reason from micro-episode perspective.
			terminal_reason = _kernel.terminal_reason(agent_index, start_position, episode_steps, episode_limit)
			if terminal_reason == &"timeout":
				# In micro-episodes, timeout just means it hit the micro-episode limit, which is success!
				terminal_reason = &"success"

			if (completed + episode_steps) % PREVIEW_EVERY_ROWS == 0:
				preview_payload = _preview(_kernel, agent_index, ray_values, targets, binding, completed + episode_steps, terminal_reason)


		if terminal_reason.is_empty():
			terminal_reason = &"sample_limit" if episode_steps >= episode_limit else &"timeout"
		if _cancelled():
			terminal_reason = &"cancelled"
		if preview_payload.is_empty() and episode_steps > 0:
			preview_payload = _preview(
				_kernel,
				agent_index,
				last_ray_values,
				last_targets,
				binding,
				completed + episode_steps,
				terminal_reason
			)

		_push({
			"kind": "episode",
			"worker_id": worker_id,
			"summary": {"episode_index": episode_index, "seed": episode_seed, "steps": episode_steps, "terminal_reason": str(terminal_reason), "randomization": randomization, "expert_path_positions": Array(expert_path_positions)},
		})

		if terminal_reason == &"success" or terminal_reason == &"sample_limit":
			consecutive_failures = 0
			var row_offset := completed * stride
			var episode_stride := episode_steps * stride
			if row_offset + episode_stride <= values.size():
				for i in range(episode_stride):
					values[row_offset + i] = episode_values[i]
				completed += episode_steps
				completed_episodes += 1
				terminal_counts[str(terminal_reason)] = int(terminal_counts.get(str(terminal_reason), 0)) + 1
				_push({"kind": "progress", "worker_id": worker_id, "completed": completed, "target": target_rows})
				if not preview_payload.is_empty():
					_push(preview_payload)
			else:
				discarded += episode_steps

			_push({
				"kind": "preview_path",
				"worker_id": worker_id,
				"summary": {
					"id": episode_index,
					"seed": episode_seed,
					"steps": episode_steps,
					"positions": expert_path_positions
				}
			})
		else:
			discarded += episode_steps
			terminal_counts[str(terminal_reason)] = int(terminal_counts.get(str(terminal_reason), 0)) + 1
			_push({"kind": "progress", "worker_id": worker_id, "completed": completed, "target": target_rows})

	_push({
		"kind": "finished",
		"worker_id": worker_id,
		"values": values,
		"row_count": completed,
		"metrics": {
			"completed_episodes": completed_episodes,
			"successes": int(terminal_counts.get("success", 0)),
			"collisions": int(terminal_counts.get("collision", 0)),
			"hazards": int(terminal_counts.get("hazard", 0)),
			"stuck": int(terminal_counts.get("stuck", 0)),
			"timeouts": int(terminal_counts.get("timeout", 0)),
			"discarded_rows": discarded,
		}
	})
	_kernel.destroy()
	_finish()


func _preview(kernel: SimulationKernel, agent_index: int, rays: PackedFloat32Array, targets: PackedFloat32Array, binding: Dictionary, completed: int, terminal: StringName) -> Dictionary:
	var context := _kernel.context_for_agent(agent_index)
	var result := {
		"sample_index": completed - 1,
		"world_position": context["agent_position"],
		"terminal_reason": str(terminal),
		"ray_distances": Array(rays),
		"ray_angles": [],
		"actions": {},
	}
	var count = int(binding.get("raycast_count", 0))
	var spread = float(binding.get("raycast_spread", 0.0))
	for i in count:
		result["ray_angles"].append(_kernel._ray_angle(i, count, spread))
	for spec in binding.get("outputs", []):
		if spec is not Dictionary:
			continue
		var actuator_id := str(spec.get("actuator_id", ""))
		var start := int(spec.get("start", -1))
		var length := int(spec.get("length", 0))
		if actuator_id.is_empty() or start < 0 or length <= 0:
			continue
		var vals = []
		for value_index in range(start, mini(start + length, targets.size())):
			vals.append(targets[value_index])
		result["actions"][actuator_id] = vals
	return {"kind": "preview", "worker_id": _config.get("worker_id", 0), "data": result}


func _ray_values(observation: PackedFloat32Array, binding: Dictionary) -> PackedFloat32Array:
	for mapping in binding.get("inputs", []):
		if mapping is Dictionary and StringName(mapping.get("sensor_id", "")) == &"ray_distance":
			var start := int(mapping.get("start", 0))
			return observation.slice(start, start + int(mapping.get("length", 0)))
	return PackedFloat32Array()


func _assigned_row_count(total_rows: int, worker_id: int, worker_count: int) -> int:
	var base := total_rows / worker_count
	var remainder := total_rows % worker_count
	return base + (1 if worker_id < remainder else 0)


func _episode_seed(global_seed: int, episode_index: int) -> int:
	return int((global_seed ^ (episode_index + 1) * 0x9E3779B1) & 0x7FFFFFFF)


func _expert_waypoints(blueprint: Dictionary) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var raw: Variant = blueprint.get("metadata", {}).get("expert_waypoints", [])
	if raw is PackedVector2Array:
		for point in raw:
			if point.is_finite():
				result.append(point)
		return result
	if raw is not Array:
		return result
	for point in raw:
		if point is Vector2 and point.is_finite():
			result.append(point)
		elif point is Array and point.size() >= 2:
			var value := Vector2(float(point[0]), float(point[1]))
			if value.is_finite():
				result.append(value)
	return result


func _empty_finished(worker_id: int, worker_count: int) -> Dictionary:
	return {
		"kind": "finished",
		"worker_id": worker_id,
		"values": PackedFloat32Array(),
		"episodes": 0,
		"successes": 0,
		"collisions": 0,
		"hazards": 0,
		"stucks": 0,
		"timeouts": 0,
		"discarded_rows": 0,
	}


func _cancelled() -> bool:
	_mutex.lock()
	var result := _cancel_requested
	_mutex.unlock()
	return result


func _push(message: Dictionary) -> void:
	_mutex.lock()
	_messages.append(message)
	_mutex.unlock()


func _finish() -> void:
	_mutex.lock()
	_finished = true
	_mutex.unlock()
