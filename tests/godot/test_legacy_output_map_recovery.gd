extends Node


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 20:
		await get_tree().process_frame

	var intentionally_detached := _legacy_graph_state()
	intentionally_detached[40488483].subgraph_occupied = true
	var not_migrated: Dictionary = graphs._migrate_output_map_nodes(intentionally_detached)
	assert(not_migrated[25003910].outputs[0] == [9505352], "a deliberately detached TrainStep must not be reconnected")

	await graphs.delete_all()
	var loaded: bool = await graphs.load_graph(_legacy_graph_state(), _legacy_registry())
	assert(loaded, "legacy project graph must load")
	for _frame in 5:
		await get_tree().process_frame

	var train_begin := graphs.get_by_id(52203513)
	var run_model := graphs.get_by_id(25003910)
	var train_step := graphs.get_by_id(40488483)
	assert(is_instance_valid(train_begin), "legacy TrainBegin must load")
	assert(is_instance_valid(run_model), "legacy RunModel must load")
	assert(is_instance_valid(train_step), "legacy TrainStep must load")
	if is_instance_valid(run_model) and is_instance_valid(train_step):
		assert(
			run_model.output_keys[0].outputs.values().any(func(spline): return spline.tied_to.parent_graph == train_step),
			"legacy RunModel must be reconnected directly to TrainStep"
		)
	if is_instance_valid(train_begin) and is_instance_valid(train_step):
		assert(graphs._reach_input(train_step, "TrainBegin") == train_begin, "TrainStep must regain its TrainBegin root")
		assert(graphs.simple_reach(train_begin).has(train_step), "repaired training chain must be reachable")
		assert(Graph._subgraph_registry.get(train_step.subgraph_id, []).has(train_step), "repaired TrainStep must be restored to its subgraph registry")

	print("PASS test_legacy_output_map_recovery")
	get_tree().quit(0)


func _legacy_graph_state() -> Dictionary:
	# Exact topology stored by a project after OutputMap was deleted before its
	# two adjacent edges were bridged.  Connection ids deliberately differ:
	# RunModel's output is 9505352 while TrainStep's input is 8858043.
	return {
		13792766: {"cfg": {"neuron_count": 10}, "context_id": 169508, "created_with": "layer", "inputs": {212072: 0, 3219360: 1}, "llm_tag": "dense_layer_0", "neuron_count": 10, "outputs": {0: [9385953, 7694602]}, "position": Vector2(-6088.962, 73.84), "root_context_id": 0, "subgraph_id": 248822, "subgraph_occupied": true},
		25003910: {"cfg": {"branches": {"68196698": "cross_entropy"}, "mapped": {"ответ": "digit"}}, "context_id": 282860, "created_with": "run_model", "inputs": {9028137: 0, 9244198: 1}, "llm_tag": "run_model_0", "outputs": {0: [9505352]}, "position": Vector2(464.867, 55.716), "root_context_id": 0, "subgraph_id": 319635, "subgraph_occupied": true},
		29256087: {"cfg": {"meta": {}, "name": "mnist"}, "context_id": 282860, "created_with": "dataset", "inputs": {}, "llm_tag": "load_dataset_0", "outputs": {0: [2967522, 4669312]}, "position": Vector2(32.003, 13.716), "root_context_id": 0, "subgraph_id": 319635, "subgraph_occupied": true},
		40488483: {"cfg": {"lr": 1, "momentum": 0.0, "optimizer": "adam", "weight_decay": false}, "context_id": 78481514, "created_with": "train_input", "inputs": {8858043: 0}, "llm_tag": "train_step_0", "outputs": {}, "position": Vector2(44.576, 264.585), "root_context_id": 0, "subgraph_id": 78481514, "subgraph_occupied": false},
		52203513: {"cfg": {}, "context_id": 282860, "created_with": "train_begin", "inputs": {2967522: 0}, "llm_tag": "train_begin_0", "outputs": {0: [9028137, 511529]}, "position": Vector2(277.15, 99.436), "root_context_id": 282860, "subgraph_id": 319635, "subgraph_occupied": true},
		67773462: {"cfg": {}, "context_id": 169508, "created_with": "flatten", "inputs": {1078535: 0}, "llm_tag": "flatten_0", "outputs": {0: [3219360, 7322418]}, "position": Vector2(-6212.189, 70.309), "root_context_id": 0, "subgraph_id": 248822, "subgraph_occupied": true},
		68196698: {"cfg": {"label_names": ["0", "1", "2", "3"], "title": "ответ"}, "context_id": 169508, "created_with": "classifier", "inputs": {9385953: 1}, "llm_tag": "out_labels_0", "outputs": {}, "position": Vector2(-5891.623, 26.667), "root_context_id": 0, "subgraph_id": 248822, "subgraph_occupied": true},
		89764478: {"cfg": {}, "context_id": 169508, "created_with": "input", "inputs": {4438104: 1}, "llm_tag": "input_image_small_0", "outputs": {0: [1078535, 6622193]}, "position": Vector2(-6353.416, 46.769), "root_context_id": 169508, "subgraph_id": 248822, "subgraph_occupied": true},
	}


func _legacy_registry() -> Dictionary:
	return {
		248822: [89764478, 67773462, 13792766, 68196698],
		319635: [29256087, 52203513, 25003910],
	}
