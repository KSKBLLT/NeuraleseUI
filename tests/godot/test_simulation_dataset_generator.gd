extends SceneTree

const Examples = preload("res://scripts/simulations/simulation_example_worlds.gd")
const DatasetWorker = preload("res://scripts/simulations/simulation_dataset_worker.gd")

var failures: Array[String] = []
var progress_events: Array[Vector2i] = []
var preview_events: Array[Dictionary] = []
var metrics_events: Array[Dictionary] = []
var cancel_at := -1
var active_generator: Node = null


func _initialize() -> void:
	var graph_manager := get_root().get_node_or_null("graphs")
	if graph_manager != null:
		graph_manager.process_mode = Node.PROCESS_MODE_DISABLED
	call_deferred("_run")


func _run() -> void:
	var generator_path := "res://scripts/simulations/simulation_dataset_generator.gd"
	_expect(ResourceLoader.exists(generator_path), "dataset generator script must exist")
	if not ResourceLoader.exists(generator_path):
		_finish()
		return

	var generator_script = load(generator_path)
	_expect(generator_script != null and generator_script.can_instantiate(), "dataset generator must parse")
	if generator_script == null or not generator_script.can_instantiate():
		_finish()
		return

	var generator = generator_script.new()
	active_generator = generator
	get_root().add_child(generator)
	generator.progress.connect(_on_progress)
	generator.sample_preview.connect(_on_sample_preview)
	generator.metrics_updated.connect(_on_metrics_updated)
	var state := _world_fixture()

	var first: Dictionary = await generator.generate(12, 731, state)
	var second: Dictionary = await generator.generate(12, 731, state)
	var different: Dictionary = await generator.generate(12, 732, state)

	_expect(PackedNumericDataset.row_count(first) == 12, "generator must return the exact requested sample count")
	_expect(first.get("col_names", []) == [
		"Ray 1:float",
		"Ray 2:float",
		"Ray 3:float",
		"Ray 4:float",
		"Ray 5:float",
		"Ray 6:float",
		"Ray 7:float",
		"Ray 8:float",
		"Speed:float",
		"Steering:float",
		"Throttle:float",
		"Brake:float",
	], "dataset columns must have a stable input/output order")
	_expect(first.get("outputs_from", -1) == 9, "the last three columns must be model outputs")
	_expect(
		first.get("inputs", {}).get("x", 0) == 9,
		"generated datasets must expose their input width to the existing TrainBegin flow"
	)
	_expect(
		first.get("outputs", []) == [{
			"label": "actions",
			"x": 3,
			"datatype": "1d",
		}],
		"generated datasets must expose output metadata to the RunModel training flow"
	)
	_expect(
		_episode_randomizations(first) == _episode_randomizations(second)
		and first.get("col_names") == second.get("col_names"),
		"the same seed and world must reproduce episode randomization and schema"
	)
	_expect(first.get("values") != different.get("values"), "a different seed must change generated samples")
	_expect(
		PackedNumericDataset.column_count(first) == 12,
		"every episode sample must exactly match the active model binding"
	)
	_expect(
		not progress_events.is_empty() and progress_events.back() == Vector2i(12, 12),
		"progress must report completion"
	)
	_expect(not generator.has_method("train"), "dataset generation must not expose or call a training API")
	_expect(not preview_events.is_empty(), "short generations must still publish a live preview")
	var seen_environments: Dictionary = {}
	for preview in preview_events:
		seen_environments[int(preview.get("environment_index", -1))] = true
	_expect(seen_environments.size() == 1, "UI must show only the environment that is actually simulated")
	_expect(
		not metrics_events.is_empty()
		and metrics_events.back().get("completed_samples") == 12
		and metrics_events.back().has("completed_episodes"),
		"generator must publish metrics derived from real episode records"
	)
	_expect(
		not metrics_events.back().has("average_reward"),
		"generator must not expose an undefined reward metric"
	)
	var metadata: Dictionary = first.get("metadata", {})
	_expect(metadata.get("generator") == "threaded_physics_spaces_v3", "dataset must identify the threaded physics generator")
	_expect(metadata.get("seed") == 731, "dataset must retain its reproducibility seed")
	_expect(
		metadata.get("randomization", {}).keys() == [
			"start_position",
			"goal_position",
			"obstacle_position",
			"surface_material",
		],
		"dataset metadata must record only the environment variations that were actually enabled"
	)
	var episode_randomization: Dictionary = metadata.get("episodes", [])[0].get("randomization", {})
	_expect(
		episode_randomization.get("object_positions", {}).has("obstacle"),
		"episode metadata must record the position chosen for each explicitly enabled obstacle"
	)
	_expect(
		episode_randomization.get("surface_materials", {}).get("object-1") in ["block", "ice", "sand"],
		"episode metadata must record the allowed material selected for each randomized surface"
	)
	_expect(int(metadata.get("completed_episodes", 0)) >= 1, "dataset must record completed episodes")
	_expect(
		metadata.get("episodes", []).all(
			func(episode: Dictionary) -> bool: return episode.get("terminal_reason") != "cancelled"
		),
		"normal completion must never be marked as user cancellation"
	)
	preview_events.clear()
	var side_view_dataset: Dictionary = await generator.generate(
		100,
		734,
		Examples.world(&"side_view_car")
	)
	_expect(PackedNumericDataset.row_count(side_view_dataset) == 100, "side-view example must generate every requested row")
	_expect(
		int(side_view_dataset.get("metadata", {}).get("completed_episodes", 0)) >= 2,
		"side-view generation must randomize more than one episode for a 100-row dataset"
	)
	_expect(
		float(side_view_dataset.get("metadata", {}).get("success_rate", 0.0)) > 0.0,
		"side-view expert generation must include a successful course trajectory"
	)
	_expect(
		_dataset_has_moving_episode(side_view_dataset),
		"successive rows must come from a moving physics episode, not isolated random snapshots"
	)
	var intended_bounds := Rect2(-520.0, -180.0, 1320.0, 440.0).grow(56.0)
	for preview in preview_events:
		var position_value: Vector2 = preview.get("world_position", Vector2.INF)
		_expect(
			intended_bounds.has_point(position_value),
			"side-view generation must stop and reset before the car leaves the course"
		)
		_expect(
			absf(wrapf(float(preview.get("rotation", 0.0)), -PI, PI)) < 1.1,
			"side-view generation must not spin the car onto its side"
		)
	for example_id in [&"top_down_rover", &"flying_agent"]:
		var example_dataset: Dictionary = await generator.generate(220, 734, Examples.world(example_id))
		_expect(
			PackedNumericDataset.row_count(example_dataset) == 220,
			"%s example must generate every requested row" % example_id
		)
		_expect(
			float(example_dataset.get("metadata", {}).get("success_rate", 0.0)) > 0.0,
			"%s expert route must include a successful trajectory" % example_id
		)
		if example_id == &"top_down_rover":
			var rover_binding: Dictionary = example_dataset.get("metadata", {}).get("binding", {})
			_expect(
				rover_binding.get("inputs", []).any(
					func(mapping: Dictionary) -> bool: return mapping.get("sensor_id") == &"local_goal_direction"
				),
				"rover datasets must encode the goal relative to the rover heading"
			)
			var steering_values := _packed_column(example_dataset, 11)
			_expect(
				_has_value_below(steering_values, -0.2)
				and _has_value_above(steering_values, 0.2),
				"rover datasets must contain meaningful obstacle-avoidance turns in both directions"
			)
	_expect(
		int(DatasetWorker.new().get_script().get_script_constant_map().get("MAX_CONSECUTIVE_EMPTY_EPISODES", 0)) > 0,
		"generator must have a bounded escape from repeated empty episodes"
	)
	_expect(
		int(DatasetWorker.new().get_script().get_script_constant_map().get("MAX_ROWS_PER_EPISODE", 0)) in range(1, 100),
		"dataset randomization cadence must not depend on the host CPU count"
	)
	var generator_source := FileAccess.get_file_as_string(generator_path)
	_expect(
		not generator_source.contains("_randomize_agent"),
		"generator must not create rows by randomly teleporting the agent"
	)

	_expect(generator.has_method("cancel"), "generator must expose cancellation to the dataset UI")
	var invalid_state := state.duplicate(true)
	invalid_state["objects"] = invalid_state["objects"].filter(
		func(object: Dictionary) -> bool: return object.get("type_id") != "car"
	)
	var rejected: Dictionary = await generator.generate(4, 1, invalid_state)
	_expect(PackedNumericDataset.row_count(rejected) == 0, "worlds without an agent must not create a fake dataset")
	_expect(
		generator.has_method("last_error") and not str(generator.last_error()).is_empty(),
		"rejected generation must expose a precise user-facing error"
	)
	var invalid_randomization := state.duplicate(true)
	invalid_randomization["metadata"]["randomization"]["start_position"]["jitter"] = Vector2(-5.0, 2.0)
	var invalid_randomization_result: Dictionary = await generator.generate(4, 1, invalid_randomization)
	_expect(
		PackedNumericDataset.row_count(invalid_randomization_result) == 0,
		"malformed world randomization must be rejected before a physics episode starts"
	)
	_expect(
		str(generator.last_error()).contains("negative jitter"),
		"world validation failures must remain precise enough to fix the configuration"
	)

	for agent_case in [
		{"type_id": "rover", "agent_id": "top_down_rover", "inputs": 11, "outputs": 3},
		{"type_id": "flying_agent", "agent_id": "flying_agent", "inputs": 13, "outputs": 2},
	]:
		var agent_dataset: Dictionary = await generator.generate(
			6,
			440,
			_agent_world_fixture(str(agent_case["type_id"]))
		)
		_expect(
			PackedNumericDataset.row_count(agent_dataset) == 6,
			"%s must generate a complete physics episode dataset" % agent_case["agent_id"]
		)
		_expect(
			PackedNumericDataset.column_count(agent_dataset)
			== int(agent_case["inputs"]) + int(agent_case["outputs"]),
			"%s rows must match its dynamic model contract" % agent_case["agent_id"]
		)
		_expect(
			agent_dataset.get("metadata", {}).get("binding", {}).get("agent_id") == agent_case["agent_id"],
			"%s dataset metadata must retain the active agent binding" % agent_case["agent_id"]
		)

	generator.queue_free()
	active_generator = null
	await process_frame
	_finish()


func _world_fixture() -> Dictionary:
	return {
		"version": 1,
		"world_name": "Dataset fixture",
		"metadata": {
			"generation_bounds": [-260.0, -120.0, 260.0, 120.0],
			"dataset_name": "simulation_dataset",
			"randomization": {
				"start_position": {"enabled": true, "jitter": Vector2(10.0, 3.0)},
				"goal_position": {"enabled": true, "jitter": Vector2(16.0, 8.0)},
				"obstacle_position": true,
				"surface_material": true,
			},
		},
		"objects": [
			{
				"id": "object-1",
				"type_id": "block",
				"position": Vector2(0.0, 100.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(520.0, 32.0),
				"properties": {
					"randomization": {
						"material_variants": ["block", "ice", "sand"],
					},
				},
			},
			{
				"id": "obstacle",
				"type_id": "block",
				"position": Vector2(0.0, -70.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(32.0, 32.0),
				"properties": {
					"randomization": {"position_jitter": Vector2(20.0, 8.0)},
				},
			},
			{
				"id": "object-2",
				"type_id": "finish",
				"position": Vector2(220.0, 32.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(48.0, 96.0),
				"properties": {},
			},
			{
				"id": "object-3",
				"type_id": "car",
				"position": Vector2(-180.0, 54.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(92.0, 42.0),
				"properties": {},
			},
		],
	}


func _agent_world_fixture(agent_type_id: String) -> Dictionary:
	return {
		"version": 1,
		"world_name": "%s fixture" % agent_type_id,
		"metadata": {
			"generation_bounds": [-260.0, -180.0, 260.0, 180.0],
			"dataset_name": "%s_dataset" % agent_type_id,
		},
		"objects": [
			{
				"id": "goal",
				"type_id": "finish",
				"position": Vector2(200.0, 0.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(48.0, 96.0),
				"properties": {},
			},
			{
				"id": "agent",
				"type_id": agent_type_id,
				"position": Vector2(-180.0, 0.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(72.0, 48.0),
				"properties": {},
			},
		],
	}


func _on_progress(current: int, total: int) -> void:
	progress_events.append(Vector2i(current, total))
	if cancel_at > 0 and current == cancel_at and is_instance_valid(active_generator):
		active_generator.cancel()


func _on_sample_preview(environment_index: int, preview: Dictionary) -> void:
	var value := preview.duplicate(true)
	value["environment_index"] = environment_index
	preview_events.append(value)


func _on_metrics_updated(metrics: Dictionary) -> void:
	metrics_events.append(metrics.duplicate(true))


func _packed_row(dataset: Dictionary, row_index: int) -> PackedFloat32Array:
	var width := PackedNumericDataset.column_count(dataset)
	var values: PackedFloat32Array = dataset.get("values", PackedFloat32Array())
	var start := row_index * width
	return values.slice(start, start + width) if width > 0 and start + width <= values.size() else PackedFloat32Array()


func _packed_column(dataset: Dictionary, column_index: int) -> PackedFloat32Array:
	var width := PackedNumericDataset.column_count(dataset)
	var row_count := PackedNumericDataset.row_count(dataset)
	var values: PackedFloat32Array = dataset.get("values", PackedFloat32Array())
	var result := PackedFloat32Array()
	if column_index < 0 or column_index >= width:
		return result
	result.resize(row_count)
	for row_index in row_count:
		result[row_index] = values[row_index * width + column_index]
	return result


func _dataset_has_moving_episode(dataset: Dictionary) -> bool:
	for episode in dataset.get("metadata", {}).get("episodes", []):
		var positions: Array = episode.get("expert_path_positions", [])
		if positions.size() < 2 or positions[0] is not Vector2:
			continue
		var start: Vector2 = positions[0]
		for position in positions.slice(1):
			if position is Vector2 and start.distance_squared_to(position) > 0.01:
				return true
	return false


func _has_value_below(values: PackedFloat32Array, threshold: float) -> bool:
	for value in values:
		if value < threshold:
			return true
	return false


func _has_value_above(values: PackedFloat32Array, threshold: float) -> bool:
	for value in values:
		if value > threshold:
			return true
	return false


func _episode_randomizations(dataset: Dictionary) -> Array:
	return dataset.get("metadata", {}).get("episodes", []).map(
		func(episode: Dictionary) -> Dictionary: return episode.get("randomization", {})
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_dataset_generator")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_dataset_generator: %d failure(s)" % failures.size())
	quit(1)
