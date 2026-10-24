extends Node

var failures: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 20:
		await get_tree().process_frame
	var flower := _read_builtin("res://built_in_projects/Flower Classifier.scn")
	_expect(not flower.is_empty(), "Flower Classifier must decode as project data")
	if flower.is_empty():
		_finish()
		return

	# Loading the same immutable template twice reproduces gallery duplicates:
	# both copies intentionally contain the same persisted graph ids.
	await _load_project(flower)
	var expected_size = graphs._graphs.size()
	await _load_project(flower)

	var expected_counts := _serialized_neuron_counts(flower)
	var actual_counts := _loaded_neuron_counts()
	_expect(expected_counts.size() >= 3, "Flower Classifier must contain its configured Dense layers")
	_expect(actual_counts == expected_counts, "reloaded built-in must preserve every neuron count by graph id")

	var actual_graphs_size = graphs._graphs.size()
	var actual_storage_size = graphs.storage.get_child_count()

	if actual_graphs_size != expected_size:
		failures.append("reloading a built-in must keep every new graph registered (expected %d, got %d)" % [expected_size, actual_graphs_size])
	if actual_storage_size != expected_size:
		failures.append("reloading a built-in must remove every graph from the previous copy (expected %d, got %d)" % [expected_size, actual_storage_size])

	_finish()


func _read_builtin(path: String) -> Dictionary:
	var raw: Variant = glob._read_var_abs(path)
	if not raw is PackedByteArray:
		return {}
	var decoded: Variant = bytes_to_var(raw)
	return decoded if decoded is Dictionary else {}


func _load_project(data: Dictionary) -> void:
	await graphs.delete_all()
	var registry: Dictionary = data.get("registry", {})
	var loaded := bool(await graphs.load_graph(
		data.get("graphs", {}),
		registry.get("subgraph_registry", {})
	))
	_expect(loaded, "built-in graph loader must accept Flower Classifier")


func _serialized_neuron_counts(data: Dictionary) -> Dictionary:
	var result: Dictionary = {}
	for graph_id in data.get("graphs", {}):
		var pack: Dictionary = data["graphs"][graph_id]
		var config: Dictionary = pack.get("cfg", {})
		if config.has("neuron_count"):
			result[int(graph_id)] = int(config["neuron_count"])
	return result


func _loaded_neuron_counts() -> Dictionary:
	var result: Dictionary = {}
	for graph in graphs._graphs.values():
		if is_instance_valid(graph) and graph.cfg.has("neuron_count"):
			result[int(graph.graph_id)] = int(graph.cfg["neuron_count"])
	return result


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_builtin_project_switch")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
