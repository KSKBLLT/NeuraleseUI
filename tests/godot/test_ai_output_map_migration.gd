extends Node


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 20:
		await get_tree().process_frame
	var actions := {
		"change_nodes": [[
			{"tag": "dataset_0", "type": "load_dataset", "config": {}},
			{"tag": "train_begin_0", "type": "train_begin", "config": {}},
			{"tag": "run_model_0", "type": "run_model", "config": {}},
			{"tag": "output_map_0", "type": "output_map", "config": {}},
			{"tag": "train_step_0", "type": "train_step", "config": {}},
		]],
		"connect_ports": [[
			{"from": {"tag": "dataset_0", "port": 0}, "to": {"tag": "train_begin_0", "port": 0}},
			{"from": {"tag": "train_begin_0", "port": 0}, "to": {"tag": "run_model_0", "port": 0}},
			{"from": {"tag": "run_model_0", "port": 0}, "to": {"tag": "output_map_0", "port": 0}},
			{"from": {"tag": "output_map_0", "port": 0}, "to": {"tag": "train_step_0", "port": 0}},
		]],
		"delete_nodes": [],
		"disconnect_ports": [],
	}

	var migrated: Dictionary = parser.call("_migrate_deprecated_actions", actions)
	var nodes: Array = migrated["change_nodes"][0]
	var connections: Array = migrated["connect_ports"][0]

	for node in nodes:
		assert(node.get("type") != "output_map", "deprecated OutputMap must not be created")
	assert(connections.size() == 3, "OutputMap's two edges must become one direct edge")
	assert(_has_connection(connections, "run_model_0", "train_step_0"), "RunModel must connect directly to TrainStep")
	assert(not _touches_tag(connections, "output_map_0"), "no migrated edge may reference OutputMap")

	await graphs.delete_all()
	await parser.model_changes_apply(_raw_actions(), "")
	for _frame in 5:
		await get_tree().process_frame

	var run_model := glob.tags_1d.get("run_model_0") as Graph
	var train_step := glob.tags_1d.get("train_step_0") as Graph
	var train_begin := glob.tags_1d.get("train_begin_0") as Graph
	assert(is_instance_valid(run_model), "AI action must create RunModel")
	assert(is_instance_valid(train_step), "AI action must create TrainStep")
	assert(not glob.tags_1d.has("output_map_0"), "AI action must not create deprecated OutputMap")
	if is_instance_valid(run_model) and is_instance_valid(train_step):
		assert(
			run_model.output_keys[0].outputs.values().any(func(spline): return spline.tied_to.parent_graph == train_step),
			"AI-created RunModel must be connected directly to TrainStep"
		)
	if is_instance_valid(train_begin) and is_instance_valid(train_step):
		assert(
			graphs.simple_reach(train_begin).has(train_step),
			"the migrated training graph must be reachable without a null graph"
		)

	print("PASS test_ai_output_map_migration")
	get_tree().quit(0)


func _has_connection(connections: Array, from_tag: String, to_tag: String) -> bool:
	for connection in connections:
		if str(connection.from.tag) == from_tag and str(connection.to.tag) == to_tag:
			return true
	return false


func _touches_tag(connections: Array, tag: String) -> bool:
	for connection in connections:
		if str(connection.from.tag) == tag or str(connection.to.tag) == tag:
			return true
	return false


func _raw_actions() -> Dictionary:
	return {
		"change_nodes": [JSON.stringify([
			{"tag": "dataset_0", "type": "load_dataset", "config": {}},
			{"tag": "train_begin_0", "type": "train_begin", "config": {}},
			{"tag": "run_model_0", "type": "run_model", "config": {}},
			{"tag": "output_map_0", "type": "output_map", "config": {}},
			{"tag": "train_step_0", "type": "train_step", "config": {}},
		])],
		"connect_ports": [JSON.stringify([
			{"from": {"tag": "dataset_0", "port": 0}, "to": {"tag": "train_begin_0", "port": 0}},
			{"from": {"tag": "train_begin_0", "port": 0}, "to": {"tag": "run_model_0", "port": 0}},
			{"from": {"tag": "run_model_0", "port": 0}, "to": {"tag": "output_map_0", "port": 0}},
			{"from": {"tag": "output_map_0", "port": 0}, "to": {"tag": "train_step_0", "port": 0}},
		])],
		"delete_nodes": ["[]"],
		"disconnect_ports": ["[]"],
	}
