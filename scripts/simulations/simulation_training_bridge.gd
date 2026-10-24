class_name SimulationTrainingBridge
extends Node

signal status_changed(message: String)

var _dataset_name := ""
var _last_error := ""


func configure_dataset(dataset_name: String) -> void:
	_dataset_name = dataset_name.strip_edges()


func configured_dataset() -> String:
	return _dataset_name


func last_error() -> String:
	return _last_error


func start_training() -> bool:
	_last_error = ""
	var global_state = get_node_or_null("/root/glob")
	var graph_manager = get_node_or_null("/root/graphs")
	if not is_instance_valid(global_state) or not is_instance_valid(graph_manager):
		return _fail("Neuralese project services are not ready.")
	if not global_state.dataset_datas.has(_dataset_name):
		return _fail("The generated simulation dataset is no longer available.")
	var dataset: Dictionary = global_state.dataset_datas[_dataset_name]
	var shape := dataset_shape(dataset)
	if shape.is_empty():
		return _fail("The generated simulation dataset has no valid input/output rows.")
	var candidates := _collect_pipeline_candidates()
	var default_model_name := str(global_state.DEFAULT_MODEL_NAME)
	var pipeline := select_pipeline(
		candidates,
		default_model_name,
		int(shape["input_width"]),
		int(shape["output_width"])
	)
	var request_validation := validate_request(
		_dataset_name,
		true,
		not pipeline.is_empty()
	)
	if not request_validation.get("valid", false):
		if _has_named_pipeline(candidates, default_model_name):
			return _fail(
				"The current default model is not compatible with this simulation dataset "
				+ "(%d inputs, %d outputs). Open or create a matching graph before training."
				% [int(shape["input_width"]), int(shape["output_width"])]
			)
		return _fail(str(request_validation.get("message", "Training is not ready.")))

	var dataset_node: Node = pipeline.get("dataset_node")
	var train_begin: Node = pipeline.get("train_begin")
	if not is_instance_valid(dataset_node) or not is_instance_valid(train_begin):
		return _fail("The project training pipeline is no longer available.")

	dataset_node.update_config({"name": _dataset_name})
	if train_begin.has_method("set_dataset_meta"):
		train_begin.set_dataset_meta(dataset)
	await get_tree().process_frame
	await get_tree().process_frame
	if not train_begin.has_method("train_start"):
		return _fail("The project TrainBegin node cannot start training.")

	global_state.go_window("graph")
	await get_tree().process_frame
	status_changed.emit("Training %s" % _dataset_name)
	await train_begin.train_start()
	return true


func _collect_pipeline_candidates() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var global_state = get_node_or_null("/root/glob")
	var graph_manager = get_node_or_null("/root/graphs")
	if not is_instance_valid(global_state) or not is_instance_valid(graph_manager):
		return result
	for graph in graph_manager._graphs.values():
		if not is_instance_valid(graph) or str(graph.server_typename) != "DatasetName":
			continue
		var reached: Dictionary = graph_manager.simple_reach(graph, true)
		var train_begins: Array[Node] = []
		var model_names: Dictionary = {}
		for node in reached:
			if not is_instance_valid(node):
				continue
			match str(node.server_typename):
				"TrainBegin":
					train_begins.append(node)
				"RunModel":
					var model_name := str(node.name_graph).strip_edges()
					if model_name.is_empty():
						model_name = str(global_state.DEFAULT_MODEL_NAME)
					model_names[model_name] = true
		for train_begin in train_begins:
			for model_name in model_names:
				var shape := _model_shape(str(model_name))
				result.append({
					"dataset_node": graph,
					"train_begin": train_begin,
					"model_name": model_name,
					"input_width": int(shape.get("input_width", 0)),
					"output_width": int(shape.get("output_width", 0)),
				})
	return result


func _model_shape(model_name: String) -> Dictionary:
	var graph_manager = get_node_or_null("/root/graphs")
	if not is_instance_valid(graph_manager):
		return {}
	var input_graph = graph_manager.get_input_graph_by_name(model_name)
	if not is_instance_valid(input_graph):
		return {}
	var properties: Dictionary = input_graph.useful_properties()
	var output_width := 0
	for graph in graph_manager.simple_reach(input_graph, true):
		if not is_instance_valid(graph) or str(graph.server_typename) != "ClassifierNode":
			continue
		var units: Variant = graph.get("units")
		if units is Array and not units.is_empty():
			output_width = units.size()
			break
	return {
		"input_width": int(properties.get("shape", 0)),
		"output_width": output_width,
	}


static func select_pipeline(
	candidates: Array,
	default_model_name: String,
	input_width: int = -1,
	output_width: int = -1
) -> Dictionary:
	for candidate in candidates:
		if not (candidate is Dictionary):
			continue
		if str(candidate.get("model_name", "")) != default_model_name:
			continue
		if input_width >= 0 and int(candidate.get("input_width", 0)) != input_width:
			continue
		if output_width >= 0 and int(candidate.get("output_width", 0)) != output_width:
			continue
		return candidate
	return {}


static func dataset_shape(dataset: Dictionary) -> Dictionary:
	if PackedNumericDataset.is_packed(dataset):
		var packed_input_width := int(dataset.get("outputs_from", 0))
		var packed_output_width := PackedNumericDataset.column_count(dataset) - packed_input_width
		if PackedNumericDataset.row_count(dataset) <= 0 or packed_input_width <= 0 or packed_output_width <= 0:
			return {}
		return {"input_width": packed_input_width, "output_width": packed_output_width}
	var rows: Variant = dataset.get("arr", [])
	if not (rows is Array) or rows.is_empty():
		return {}
	var first_row: Variant = rows[0]
	if not (first_row is Array) and not (first_row is PackedFloat32Array):
		return {}
	var input_width := int(dataset.get("outputs_from", 0))
	var output_width: int = first_row.size() - input_width
	if input_width <= 0 or output_width <= 0:
		return {}
	return {"input_width": input_width, "output_width": output_width}


static func _has_named_pipeline(candidates: Array, model_name: String) -> bool:
	for candidate in candidates:
		if candidate is Dictionary and str(candidate.get("model_name", "")) == model_name:
			return true
	return false


static func validate_request(dataset_name: String, dataset_exists: bool, has_pipeline: bool) -> Dictionary:
	if dataset_name.strip_edges().is_empty():
		return {
			"valid": false,
			"message": "Generate a simulation dataset before training the model.",
		}
	if not dataset_exists:
		return {
			"valid": false,
			"message": "The generated simulation dataset is no longer available.",
		}
	if not has_pipeline:
		return {
			"valid": false,
			"message": "Connect a Dataset node to the default model training flow in Graphs.",
		}
	return {"valid": true, "message": ""}


func _fail(message: String) -> bool:
	_last_error = message
	status_changed.emit(message)
	return false
