extends SceneTree

const UpdateManagerClass := preload("res://scripts/update_state.gd")


func _initialize() -> void:
	var manager = UpdateManagerClass.new()
	var actual: String = manager._local_version()
	if actual != "1.0.8":
		push_error("expected project version 1.0.8, got %s" % actual)
		quit(1)
		return
	print("PASS test_update_version")
	quit(0)
