extends Node

const RunManagerScript := preload("res://scripts/run_manager.gd")


func _ready() -> void:
	var base := {
		"graph": {"pages": {"0": {"1": {"type": "Dense", "config": {"units": 16}}}}},
		"train_graph": {"pages": {"0": {"2": {"type": "TrainInput", "config": {"optimizer": "adam", "lr": "1e-3"}}}}},
		"dataset_ref": {"kind": "godot_json", "path": "C:/dataset.json", "revision": "a"},
		"epochs": 1,
		"batch_size": 32,
	}
	var run_only := base.duplicate(true)
	run_only["epochs"] = 20
	run_only["batch_size"] = 256
	run_only["train_graph"]["pages"]["0"]["2"]["config"]["lr"] = "1e-2"
	assert(
		RunManagerScript.training_structural_fingerprint(base)
		== RunManagerScript.training_structural_fingerprint(run_only)
	)

	var topology_change := base.duplicate(true)
	topology_change["graph"]["pages"]["0"]["1"]["config"]["units"] = 32
	assert(
		RunManagerScript.training_structural_fingerprint(base)
		!= RunManagerScript.training_structural_fingerprint(topology_change)
	)

	var dataset_change := base.duplicate(true)
	dataset_change["dataset_ref"]["revision"] = "b"
	assert(
		RunManagerScript.training_structural_fingerprint(base)
		!= RunManagerScript.training_structural_fingerprint(dataset_change)
	)

	var reasons: Array[String] = []
	graphs.training_snapshot_invalidated.connect(func(reason: String): reasons.append(reason), CONNECT_ONE_SHOT)
	graphs.invalidate_training_snapshot("test_mutation")
	assert(reasons == ["test_mutation"])

	print("PASS test_training_prepare_flow")
	get_tree().quit()
