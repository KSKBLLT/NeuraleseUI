extends SceneTree

class FakeClassifier extends Node:
	var res_meta := {"datatype": "1d", "x": 3}

	func get_first_ancestors() -> Array:
		# The preflight must not infer output width from graph topology. run_m.gd
		# already consumes res_meta, which is propagated through adaptive nodes.
		return [self]

	func get_x() -> int:
		return 99


var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager = load("res://scripts/run_manager.gd")
	var run_model = load("res://scripts/run_m.gd")
	var global_script = load("res://scripts/glob.gd")
	var datasets: Dictionary = global_script.FULLY_LOCAL_BUILTIN_DATASETS
	for name in ["mnist", "iris", "titanic", "eco_ai"]:
		_expect(run_model.dataset_training_loss(datasets[name], "mse") == "cross_entropy",
			"Classification dataset must replace an incompatible MSE branch loss: " + name)
	_expect(run_model.dataset_training_loss(datasets["car_track"], "cross_entropy") == "mse",
		"Regression dataset must retain its MSE training contract")
	var mnist: Dictionary = datasets["mnist"]
	_expect(manager.training_dataset_shape_error(mnist, 784, 10).is_empty(),
		"Digits must accept its 28x28 image as 784 input values")
	var wrong_width: String = manager.training_dataset_shape_error(mnist, 28, 10)
	_expect(not wrong_width.is_empty() and "784" in wrong_width,
		"MNIST must reject 28 values and report the full 784-value input size")
	_expect(not manager.training_dataset_shape_error(mnist, 784, 9).is_empty(),
		"MNIST must still reject a classifier with the wrong label count")
	var rectangular := {"inputs": {"x": 20, "y": 10, "datatype": "2d"}}
	_expect(manager.training_dataset_shape_error(rectangular, 200, -1).is_empty(),
		"Image validation must also handle non-square datasets")
	for name in ["iris", "titanic", "car_track", "eco_ai"]:
		var meta: Dictionary = datasets[name]
		var inputs: int = meta["inputs"]["x"]
		var outputs: int = meta["outputs"][0]["x"]
		_expect(manager.training_dataset_shape_error(meta, inputs, outputs).is_empty(),
			"Valid 1D dataset must still be accepted: " + name)
		_expect(not manager.training_dataset_shape_error(meta, inputs + 1, outputs).is_empty(),
			"Wrong 1D input count must still be rejected: " + name)
		_expect(not manager.training_dataset_shape_error(meta, inputs, outputs + 1).is_empty(),
			"Wrong 1D output count must still be rejected: " + name)
	_expect(manager.training_dataset_shape_error({}, 784, 10).is_empty(),
		"Missing metadata must not introduce a spurious mismatch")
	_expect(manager.training_dataset_shape_error(mnist, -1, -1).is_empty(),
		"Unknown graph dimensions must keep their existing behavior")
	var globals = root.get_node("glob")
	var runtime = root.get_node("nn")
	var original_data: Dictionary = globals.dataset_datas.duplicate()
	var local_data := {
		"name": "custom", "outputs_from": 2,
		"arr": [[{"val": 0.1}, {"val": 0.2}, {"num": 1}]],
		"col_names": ["x:float", "y:float", "answer:num"],
	}
	globals.dataset_datas["eco_ai"] = local_data
	globals.dataset_datas["custom"] = local_data
	var eco: Dictionary = runtime._training_dataset_meta("eco_ai", datasets["iris"])
	_expect(eco == datasets["eco_ai"], "Builtin training must ignore a stale preview or same-name local dataset")
	var eco_error: String = manager.training_dataset_shape_error(eco, 4, 3, 4, "ru")
	_expect("eco_ai" in eco_error and "4" in eco_error and "3" in eco_error,
		"Eco AI on Flower Classifier must report four required outputs instead of crashing")
	_expect("3 выходных нейрона" in eco_error,
		"Russian feedback must identify the real three-neuron model output")
	var eco_error_en: String = manager.training_dataset_shape_error(eco, 4, 3, 4, "en")
	_expect("3 output neurons" in eco_error_en and "4 classes" in eco_error_en,
		"English feedback must explain the model/dataset output mismatch")
	var eco_error_kz: String = manager.training_dataset_shape_error(eco, 4, 3, 4, "kz")
	_expect("3 шығыс нейроны" in eco_error_kz and "4 класс" in eco_error_kz,
		"Kazakh feedback must explain the model/dataset output mismatch")
	var label_error: String = manager.training_dataset_shape_error(eco, 4, 4, 3, "en")
	_expect("3 labels" in label_error and "4 output neurons" in label_error,
		"Feedback must also catch a label panel that disagrees with the model output")
	var classifier := FakeClassifier.new()
	_expect(manager.classifier_model_output_width(classifier) == 3,
		"Training preflight must reuse the adaptive output width already consumed by run_m.gd")
	classifier.free()
	var custom: Dictionary = runtime._training_dataset_meta("custom", {})
	_expect(custom.get("inputs", {}).get("x") == 2,
		"Local raw dataset must be converted to input schema metadata")
	_expect(manager.training_dataset_shape_error(custom, 2, 3).is_empty(),
		"One custom target column may hold sparse class indices; do not confuse it with one output class")
	_expect(not manager.training_dataset_shape_error(custom, 4, 3).is_empty(),
		"Local dataset shape validation must not silently skip raw data")
	globals.dataset_datas = original_data
	var layer = load("res://scenes/layer.tscn").instantiate()
	_expect(layer.group_size == 4, "Dense layer scene must group 4 neurons per visible unit")
	layer.free()
	if failures.is_empty():
		print("PASS test_training_dataset_shape")
		quit(0)
	else:
		for failure in failures:
			push_error(failure)
		quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
