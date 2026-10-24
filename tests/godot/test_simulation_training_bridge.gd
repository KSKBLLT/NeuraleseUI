extends SceneTree

const Bridge = preload("res://scripts/simulations/simulation_training_bridge.gd")

var failures: Array[String] = []


func _initialize() -> void:
	if Bridge == null:
		failures.append("simulation training bridge must compile")
		_finish()
		return
	_test_pipeline_selection()
	_test_pipeline_shape_selection()
	_test_dataset_shape()
	_test_dataset_contract()
	_finish()


func _test_pipeline_selection() -> void:
	var default_dataset := RefCounted.new()
	var default_train := RefCounted.new()
	var other_dataset := RefCounted.new()
	var candidates := [
		{
			"dataset_node": other_dataset,
			"train_begin": RefCounted.new(),
			"model_name": "other_model",
		},
		{
			"dataset_node": default_dataset,
			"train_begin": default_train,
			"model_name": "__default_model__",
		},
	]
	var selected: Dictionary = Bridge.select_pipeline(candidates, "__default_model__")
	_expect(selected.get("dataset_node") == default_dataset, "bridge must select the default-model dataset pipeline")
	_expect(selected.get("train_begin") == default_train, "bridge must return the matching TrainBegin")
	_expect(
		Bridge.select_pipeline(candidates, "missing").is_empty(),
		"bridge must not silently train a different model"
	)


func _test_pipeline_shape_selection() -> void:
	var matching_dataset := RefCounted.new()
	var candidates := [
		{
			"dataset_node": RefCounted.new(),
			"train_begin": RefCounted.new(),
			"model_name": "__default_model__",
			"input_width": 784,
			"output_width": 10,
		},
		{
			"dataset_node": matching_dataset,
			"train_begin": RefCounted.new(),
			"model_name": "__default_model__",
			"input_width": 8,
			"output_width": 2,
		},
	]
	var selected: Dictionary = Bridge.select_pipeline(
		candidates,
		"__default_model__",
		8,
		2
	)
	_expect(
		selected.get("dataset_node") == matching_dataset,
		"bridge must select only a training pipeline with the dataset shape"
	)
	_expect(
		Bridge.select_pipeline(candidates, "__default_model__", 9, 3).is_empty(),
		"bridge must reject a default-model pipeline with an incompatible shape"
	)


func _test_dataset_shape() -> void:
	var shape: Dictionary = Bridge.dataset_shape({
		"outputs_from": 8,
		"arr": [[0.0, 0.1, 0.2, 0.3, 0.4, 0.5, 0.6, 0.7, -0.2, 0.8]],
	})
	_expect(
		shape == {"input_width": 8, "output_width": 2},
		"bridge must derive the Neuralese dataset I/O shape from its standard schema"
	)
	_expect(
		Bridge.dataset_shape({"outputs_from": 8, "arr": []}).is_empty(),
		"bridge must reject an empty dataset shape"
	)


func _test_dataset_contract() -> void:
	_expect(
		not Bridge.validate_request("", true, true).get("valid", true),
		"training must reject an empty dataset name"
	)
	_expect(
		not Bridge.validate_request("generated", false, true).get("valid", true),
		"training must reject a dataset that was not saved"
	)
	_expect(
		not Bridge.validate_request("generated", true, false).get("valid", true),
		"training must reject a project without a compatible training pipeline"
	)
	_expect(
		Bridge.validate_request("generated", true, true).get("valid", false),
		"a saved dataset and matching pipeline must be trainable"
	)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("simulation training bridge tests: PASS")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
