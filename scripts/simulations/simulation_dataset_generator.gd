class_name SimulationDatasetGenerator
extends Node

const Compiler = preload("res://scripts/simulations/simulation_compiler.gd")
const Worker = preload("res://scripts/simulations/simulation_dataset_worker.gd")
const IOSchema = preload("res://scripts/simulations/simulation_io_schema.gd")
const WorldState = preload("res://scripts/simulations/simulation_world_state.gd")
const RandomizationProfile = preload("res://scripts/simulations/simulation_randomization_profile.gd")
const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

## PhysicsServer2D owns one global physics scheduler. More dataset spaces increase
## its per-tick work but do not create more physics threads, so reserve cores for
## the editor/render loop and use workers for encoding and row packing.
const MAX_WORKERS := 2
const ACTIVE_PHYSICS_BODY_BUDGET := 1024

@export_range(1, 16, 1) var max_worker_threads := MAX_WORKERS

signal progress(current: int, total: int)
signal sample_preview(environment_index: int, preview: Dictionary)
signal metrics_updated(metrics: Dictionary)
signal generation_completed(dataset: Dictionary)
signal episode_completed(summary: Dictionary)
signal expert_path_generated(path: Array)

var _workers: Array[SimulationDatasetWorker] = []
var _worker_progress: Dictionary = {}
var _worker_results: Dictionary = {}
var _episodes: Array[Dictionary] = []
var _total_rows := 0
var _seed := 0
var _binding: Dictionary = {}
var _world_state: Dictionary = {}
var _training_world: Dictionary = {}
var _running := false
var _cancel_requested := false
var _last_error := ""
var _progress_dirty := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_physics_process(false)


func _exit_tree() -> void:
	for worker in _workers:
		worker.request_cancel()
	for worker in _workers:
		worker.shutdown()
	_workers.clear()


func generate(sample_count: int, seed: int, world_state: Dictionary) -> Dictionary:
	var perf_token: int = PerformanceProbe.begin_scope(&"dataset.generate_total")
	var dataset: Dictionary = await _profiled_generate(sample_count, seed, world_state)
	PerformanceProbe.end_scope(&"dataset.generate_total", perf_token)
	return dataset


func _profiled_generate(sample_count: int, seed: int, world_state: Dictionary) -> Dictionary:
	if _running:
		_last_error = "Dataset generation is already running."
		return _empty_dataset("simulation_dataset", {})
	_last_error = ""
	_progress_dirty = false
	_cancel_requested = false
	_total_rows = maxi(0, sample_count)
	_seed = seed
	_world_state = world_state.duplicate(true)
	if _total_rows <= 0:
		return _empty_dataset(_dataset_name(), {})
	var validation := WorldState.validate_dictionary(_world_state)
	if not validation.get("valid", false):
		var errors: Array = validation.get("errors", [])
		_last_error = str(errors[0].get("message", "The simulation world is invalid.")) if not errors.is_empty() else "The simulation world is invalid."
		return _empty_dataset(_dataset_name(), {})
	var compile_token: int = PerformanceProbe.begin_scope(&"dataset.compile")
	var blueprint: Dictionary = Compiler.compile(_world_state)
	PerformanceProbe.end_scope(&"dataset.compile", compile_token)
	_training_world = Compiler.training_world(blueprint)
	var agent_indices: PackedInt32Array = blueprint.get("agent_indices", PackedInt32Array())
	if agent_indices.is_empty():
		_last_error = "Add an agent before generating a dataset."
		return _empty_dataset(_dataset_name(), {})
	_binding = blueprint["properties"][agent_indices[0]].get("model_binding", {}).duplicate(true)
	if _binding.is_empty():
		_last_error = "The selected agent has no valid model binding."
		return _empty_dataset(_dataset_name(), {})
	var physical_indices: PackedInt32Array = blueprint.get("physical_indices", PackedInt32Array())
	var physical_count: int = physical_indices.size()
	var worker_count := _worker_count_for(physical_count, OS.get_processor_count())
	_workers.clear()
	_worker_progress.clear()
	_worker_results.clear()
	_episodes.clear()
	_workers_started = false
	var temp_world := WorldState.new()
	temp_world.load_dictionary(_world_state)
	var islands_raw = temp_world.world_bounds_islands(256.0)
	var safe_bounds = Rect2(-4000, -4000, 8000, 8000)
	var final_islands: Array[Rect2] = []
	for island in islands_raw:
		var clamped = island.intersection(safe_bounds)
		if clamped.has_area():
			final_islands.append(clamped)

	for worker_id in worker_count:
		var worker: SimulationDatasetWorker = Worker.new()
		var config := {
			"worker_id": worker_id,
			"worker_count": worker_count,
			"total_rows": _total_rows,
			"seed": _seed,
			"blueprint": Compiler.clone_for_thread(blueprint),
			"islands": final_islands
		}
		if not worker.prepare(config):
			_last_error = "A dataset worker thread could not be started."
			for started_worker in _workers:
				started_worker.shutdown()
			_workers.clear()
			return _empty_dataset(_dataset_name(), _binding)
		_workers.append(worker)
		_worker_progress[worker_id] = 0

	_running = true
	set_physics_process(true)
	progress.emit(0, _total_rows)
	var dataset: Dictionary = await generation_completed

	return dataset


func cancel() -> void:
	_cancel_requested = true
	for worker in _workers:
		worker.request_cancel()


func last_error() -> String:
	return _last_error


func is_running() -> bool:
	return _running


func _physics_process(_delta: float) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"dataset.physics_poll_total")
	_profiled_physics_process()
	PerformanceProbe.end_scope(&"dataset.physics_poll_total", perf_token)


var _workers_started := false

func _profiled_physics_process() -> void:
	if not _running:
		return
	if not _workers_started:
		_workers_started = true
		for worker in _workers:
			worker.start_thread()
	for worker in _workers:
		worker.force_space_flush()
		worker.pulse()
	for worker in _workers:
		for message in worker.drain_messages():
			_handle_message(message)
	if _progress_dirty:
		_progress_dirty = false
		var completed := 0
		for value in _worker_progress.values():
			completed += int(value)
		progress.emit(completed, _total_rows)
		metrics_updated.emit(_combined_live_metrics(completed))
	var all_finished := _worker_results.size() == _workers.size()
	if all_finished:
		for worker in _workers:
			if not worker.is_finished():
				all_finished = false
				break
	if all_finished:
		_complete_generation()


func _handle_message(message: Dictionary) -> void:
	var worker_id := int(message.get("worker_id", 0))
	match str(message.get("kind", "")):
		"progress":
			_worker_progress[worker_id] = int(message.get("completed", 0))
			_progress_dirty = true
		"preview":
			if worker_id == 0:
				sample_preview.emit(0, message.get("data", {}))
		"expert_path":
			if worker_id == 0:
				expert_path_generated.emit(message.get("path", []))
		"episode":
			var summary: Dictionary = message.get("summary", {}).duplicate(true)
			_episodes.append(summary)
			episode_completed.emit(summary)
		"error":
			_last_error = str(message.get("message", "Dataset worker failed."))
			cancel()
		"finished":
			_worker_results[worker_id] = message


func _complete_generation() -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"dataset.complete_and_merge")
	set_physics_process(false)
	for worker in _workers:
		worker.join_finished()
	var dataset := _merge_results()
	_running = false
	_workers.clear()
	_worker_progress.clear()
	_worker_results.clear()
	progress.emit(PackedNumericDataset.row_count(dataset), _total_rows)
	metrics_updated.emit(dataset.get("metadata", {}).duplicate(true))
	generation_completed.emit(dataset)
	PerformanceProbe.end_scope(&"dataset.complete_and_merge", perf_token)


func _merge_results() -> Dictionary:
	var perf_token: int = PerformanceProbe.begin_scope(&"dataset.merge_results")
	var dataset: Dictionary = _profiled_merge_results()
	PerformanceProbe.end_scope(&"dataset.merge_results", perf_token)
	return dataset


func _profiled_merge_results() -> Dictionary:
	var stride: int = int(_binding.get("input_width", 0)) + int(_binding.get("output_width", 0))
	var aggregate: Dictionary = {"completed_episodes": 0, "successes": 0, "collisions": 0, "stuck": 0, "timeouts": 0, "discarded_rows": 0}
	var worker_count: int = maxi(1, _worker_results.size())
	var packed: PackedFloat32Array = PackedFloat32Array()
	var completed: int = 0
	var worker_ids: Array = _worker_results.keys()
	worker_ids.sort()
	for worker_id_value in worker_ids:
		var result: Dictionary = _worker_results[worker_id_value]
		var values: PackedFloat32Array = result.get("values", PackedFloat32Array())
		var available_rows: int = floori(float(values.size()) / float(maxi(1, stride)))
		var rows: int = mini(int(result.get("row_count", 0)), available_rows)
		if rows > 0:
			if values.size() != rows * stride:
				values = values.slice(0, rows * stride)
			packed.append_array(values)
			completed += rows
		var metrics: Dictionary = result.get("metrics", {})
		for key in aggregate:
			aggregate[key] = int(aggregate[key]) + int(metrics.get(key, 0))
	var safe_episodes: int = maxi(1, int(aggregate["completed_episodes"]))
	_episodes.sort_custom(_sort_episode)
	var output_statistics: Array[Dictionary] = _output_statistics(packed, completed, stride)
	var collapsed_outputs: Array[String] = _collapsed_output_labels(output_statistics)
	var metadata: Dictionary = {
		"generator": "threaded_physics_spaces_v3",
		"seed": _seed,
		"partial": completed < _total_rows,
		"thread_count": worker_count,
		"completed_samples": completed,
		"total_samples": _total_rows,
		"completed_episodes": aggregate["completed_episodes"],
		"success_rate": float(aggregate["successes"]) / float(safe_episodes),
		"collisions": aggregate["collisions"],
		"stuck": aggregate["stuck"],
		"timeouts": aggregate["timeouts"],
		"discarded_rows": aggregate["discarded_rows"],
		"episodes": _episodes.duplicate(true),
		"binding": _binding.duplicate(true),
		# Where the agent started and where the goal was: a robot driving this
		# model stands in the same world, shrunk to its size.
		"world": _training_world.duplicate(true),
		"randomization": RandomizationProfile.active_config(
			_world_state.get("metadata", {}).get("randomization", {})
		),
		"output_statistics": output_statistics,
		"collapsed_outputs": collapsed_outputs,
		"quality_status": "warning" if not collapsed_outputs.is_empty() else "good",
		"quality_warning": _quality_warning(collapsed_outputs),
		"error": _last_error,
	}
	var dataset := _empty_dataset(_dataset_name(), _binding)
	dataset["storage"] = "packed_float32"
	dataset["values"] = packed
	dataset["row_count"] = completed
	dataset["column_count"] = stride
	dataset["metadata"] = metadata
	return dataset


func _combined_live_metrics(completed: int) -> Dictionary:
	return {"completed_samples": completed, "total_samples": _total_rows, "completed_episodes": _episodes.size(), "success_rate": 0.0, "collisions": 0, "stuck": 0, "timeouts": 0, "discarded_rows": 0, "thread_count": _workers.size()}


func _worker_count_for(physical_count: int, processor_count: int) -> int:
	var available_workers := mini(max_worker_threads, maxi(1, processor_count - 2))
	var body_limited_workers := maxi(
		1,
		int(ACTIVE_PHYSICS_BODY_BUDGET / float(maxi(1, physical_count)))
	)
	return mini(MAX_WORKERS, mini(available_workers, body_limited_workers))


func _output_statistics(values: PackedFloat32Array, rows: int, stride: int) -> Array[Dictionary]:
	var output_width: int = int(_binding.get("output_width", 0))
	var input_width: int = int(_binding.get("input_width", 0))
	var labels: Array[String] = IOSchema.output_columns_for(_binding)
	var result: Array[Dictionary] = []
	if rows <= 0 or stride <= 0 or output_width <= 0:
		return result
	for output_index in output_width:
		var minimum: float = INF
		var maximum: float = -INF
		var total: float = 0.0
		var total_squared: float = 0.0
		for row_index in rows:
			var value_index: int = row_index * stride + input_width + output_index
			if value_index < 0 or value_index >= values.size():
				continue
			var value: float = values[value_index]
			minimum = minf(minimum, value)
			maximum = maxf(maximum, value)
			total += value
			total_squared += value * value
		var mean: float = total / float(rows)
		var variance: float = maxf(0.0, total_squared / float(rows) - mean * mean)
		var raw_label: String = labels[output_index] if output_index < labels.size() else "Output %d" % (output_index + 1)
		var label_parts: PackedStringArray = raw_label.rsplit(":", true, 1)
		result.append({
			"label": label_parts[0],
			"minimum": minimum,
			"maximum": maximum,
			"mean": mean,
			"standard_deviation": sqrt(variance),
			"span": maximum - minimum,
		})
	return result


func _collapsed_output_labels(statistics: Array[Dictionary]) -> Array[String]:
	var result: Array[String] = []
	for statistic in statistics:
		var span: float = float(statistic.get("span", 0.0))
		var deviation: float = float(statistic.get("standard_deviation", 0.0))
		if span < 0.03 or deviation < 0.01:
			result.append(str(statistic.get("label", "Output")))
	return result


func _quality_warning(collapsed_outputs: Array[String]) -> String:
	if collapsed_outputs.is_empty():
		return ""
	return "Nearly constant targets: %s. Check whether the mapped inputs expose the state used by the expert policy." % ", ".join(collapsed_outputs)


func _empty_dataset(dataset_name: String, binding: Dictionary) -> Dictionary:
	var schema := IOSchema.dataset_schema_for(binding) if not binding.is_empty() else {}
	return {
		"name": dataset_name,
		"arr": [],
		"storage": "packed_float32",
		"values": PackedFloat32Array(),
		"row_count": 0,
		"column_count": int(binding.get("input_width", 0)) + int(binding.get("output_width", 0)),
		"col_names": schema.get("col_names", []),
		"outputs_from": int(schema.get("outputs_from", 0)),
		"col_args": schema.get("col_args", []),
		"inputs": {"x": int(binding.get("input_width", 0)), "datatype": "1d"},
		"outputs": [{"label": "actions", "x": int(binding.get("output_width", 0)), "datatype": "1d"}],
		"input_hints": [],
		"cache": {},
		"metadata": {},
	}


func _dataset_name() -> String:
	return str(_world_state.get("metadata", {}).get("dataset_name", "simulation_dataset"))


func _sort_episode(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("episode_index", 0)) < int(right.get("episode_index", 0))
