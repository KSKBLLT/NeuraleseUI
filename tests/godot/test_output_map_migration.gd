extends Node

func _ready() -> void:
	var manager_script = load("res://scripts/graph_manager.gd")
	var manager = manager_script.new()
	var state = {
		"run": {"created_with": "run_model", "outputs": {0: [201, 101]}, "inputs": {}},
		"map": {"created_with": "output_map", "outputs": {0: [301, 202]}, "inputs": {201: 0}},
		"train": {"created_with": "train_input", "outputs": {}, "inputs": {301: 0}},
	}
	var migrated: Dictionary = manager._migrate_output_map_nodes(state)
	if migrated.has("map"):
		push_error("OutputMap node was not removed")
		get_tree().quit(1)
		return
	if migrated["run"].outputs[0] != [301, 101]:
		push_error("RunModel was not connected directly to TrainStep: %s" % [migrated["run"].outputs[0]])
		get_tree().quit(1)
		return
	print("PASS test_output_map_migration")
	get_tree().quit(0)