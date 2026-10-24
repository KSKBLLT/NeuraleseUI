extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var cam := Camera2D.new()
	root.add_child(cam)
	cam.make_current()
	_expect(cam.is_processing_internal(), "plain Camera2D must initially poll internally")

	IdleCamera.apply(cam)
	_expect(not cam.is_processing_internal(), "IdleCamera must disable internal polling")
	_expect(not cam.is_physics_processing_internal(), "IdleCamera must disable physics polling")

	var half := Vector2(root.get_visible_rect().size) * 0.5
	cam.position = Vector2(100.0, 40.0)
	await process_frame
	_expect(
		root.canvas_transform.origin.is_equal_approx(half - Vector2(100.0, 40.0)),
		"position assignment must still update the canvas transform"
	)
	cam.zoom = Vector2(2.0, 2.0)
	await process_frame
	_expect(
		root.canvas_transform.get_scale().is_equal_approx(Vector2(2.0, 2.0)),
		"zoom assignment must still update the canvas transform"
	)

	root.remove_child(cam)
	root.add_child(cam)
	_expect(not cam.is_processing_internal(), "polling must stay disabled after tree re-entry")

	IdleCamera.apply(cam)
	IdleCamera.apply(cam)
	_expect(
		cam.tree_entered.get_connections().size() == 1,
		"IdleCamera.apply() must install one tree-entered hook"
	)

	var win_graph_source := (load("res://scripts/win_graph.gd") as GDScript).source_code
	_expect(
		win_graph_source.contains("IdleCamera.apply(camera)"),
		"tab camera enable path must reapply IdleCamera"
	)

	cam.queue_free()
	if failures.is_empty():
		print("PASS test_idle_camera")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
