extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load("res://scenes/simulations/simulation_editor.tscn") as PackedScene
	var editor = scene.instantiate()
	get_root().add_child(editor)
	await process_frame
	var block = editor.create_object(&"block", Vector2(100.0, 100.0))
	var block_id: String = block.object_id
	editor.select_object(block)
	var gizmo := editor.get_node_or_null("TransformGizmo")
	_expect(gizmo != null, "selected simulation objects must expose a canvas transform gizmo")
	_expect(
		editor.has_method("begin_gizmo_transform")
		and editor.has_method("update_gizmo_transform")
		and editor.has_method("end_gizmo_transform"),
		"editor must expose one-gesture gizmo transforms"
	)
	if gizmo != null and editor.has_method("begin_gizmo_transform"):
		var original_size: Vector2 = block.object_size
		_expect(
			editor.begin_gizmo_transform(&"resize", Vector2(132.0, 132.0)),
			"resize handle must begin a transform gesture"
		)
		_expect(not editor.camera.navigation_enabled(), "camera navigation must lock during object transforms")
		editor.update_gizmo_transform(Vector2(180.0, 150.0))
		editor.end_gizmo_transform()
		_expect(block.object_size == Vector2(160.0, 100.0), "resize gizmo must stretch object dimensions")
		_expect(editor.camera.navigation_enabled(), "camera navigation must resume after object transforms")
		editor.undo_last()
		editor.select_id(block_id)
		block = editor.selected_object
		_expect(block.object_size == original_size, "one undo must restore the whole resize gesture")

		editor.select_object(block)
		_expect(
			editor.begin_gizmo_transform(&"rotate", Vector2(100.0, 48.0)),
			"rotation handle must begin a transform gesture"
		)
		editor.update_gizmo_transform(Vector2(152.0, 100.0))
		editor.end_gizmo_transform()
		_expect(is_equal_approx(block.rotation, PI * 0.5), "rotation gizmo must rotate around the object center")

	editor.free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_transform_gizmo")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_transform_gizmo: %d failure(s)" % failures.size())
	quit(1)
