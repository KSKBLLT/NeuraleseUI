extends Node

var failures: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 20:
		await get_tree().process_frame
	await graphs.delete_all()
	var loaded: bool = await graphs.load_graph(_dense_input2d_graph(), {
		248822: [89764478, 67773462, 13792766, 68196698],
	})
	_expect(loaded, "Input2D dense graph fixture must load")
	if not loaded:
		_finish()
		return

	var input := graphs._graphs.get(89764478) as Graph
	_expect(is_instance_valid(input), "Input2D graph must be registered")
	if is_instance_valid(input):
		_expect(nn.check_valid(input), "trained Input2D -> Flatten -> Dense -> Classifier graph must be inference-valid: %s" % JSON.stringify(_validation_report(input)))
	_finish()


func _validation_report(input: Graph) -> Dictionary:
	var reached := graphs.simple_reach(input, true)
	var nodes: Array[Dictionary] = []
	for node: Graph in reached:
		nodes.append({
			"graph_id": node.graph_id,
			"type": str(node.server_typename),
			"valid": node.is_valid(),
			"invalid_fields": node.invalid_fields,
		})
	return {"nodes": nodes}


func _dense_input2d_graph() -> Dictionary:
	return {
		13792766: {
			"position": Vector2(-6088.962, 73.83971),
			"cfg": {"neuron_count": 10},
			"inputs": {212072: 0, 3219360: 1},
			"outputs": {0: [9385953, 7694602]},
			"created_with": "layer",
			"llm_tag": "dense_layer_0",
			"context_id": 169508,
			"subgraph_id": 248822,
			"subgraph_occupied": true,
			"root_context_id": 0,
		},
		67773462: {
			"position": Vector2(-6212.189, 70.30934),
			"cfg": {},
			"inputs": {1078535: 0},
			"outputs": {0: [3219360, 7322418]},
			"created_with": "flatten",
			"llm_tag": "flatten_0",
			"context_id": 169508,
			"subgraph_id": 248822,
			"subgraph_occupied": true,
			"root_context_id": 0,
		},
		68196698: {
			"position": Vector2(-5891.623, 26.66673),
			"cfg": {"label_names": ["0", "1", "2", "3"], "title": "answer"},
			"inputs": {9385953: 1},
			"outputs": {},
			"created_with": "classifier",
			"llm_tag": "out_labels_0",
			"context_id": 169508,
			"subgraph_id": 248822,
			"subgraph_occupied": true,
			"root_context_id": 0,
		},
		89764478: {
			"position": Vector2(-6353.416, 46.76935),
			"cfg": {},
			"inputs": {4438104: 1},
			"outputs": {0: [1078535, 6622193]},
			"created_with": "input",
			"llm_tag": "input_image_small_0",
			"context_id": 169508,
			"subgraph_id": 248822,
			"subgraph_occupied": true,
			"root_context_id": 169508,
		},
	}


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_input2d_dense_inference")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
