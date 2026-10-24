extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene := load("res://scenes/simulations/simulation_editor.tscn") as PackedScene
	var editor = scene.instantiate()
	get_root().add_child(editor)
	await process_frame
	var marquee := editor.get_node_or_null("SelectionMarquee")
	_expect(marquee is ColorRect, "simulation marquee must reuse the Graphs selector-box control")
	_expect(
		marquee != null and marquee.material is ShaderMaterial,
		"simulation marquee must reuse the selector-box shader treatment"
	)
	var first = editor.create_object(&"block", Vector2(100.0, 100.0))
	var first_id := str(first.object_id)
	var second = editor.create_object(&"crate", Vector2(300.0, 300.0))
	var second_id := str(second.object_id)
	_expect(
		editor.has_method("begin_selection_marquee")
		and editor.has_method("update_selection_marquee")
		and editor.has_method("end_selection_marquee"),
		"editor must expose empty-canvas marquee selection"
	)
	if editor.has_method("begin_selection_marquee"):
		editor.select_object(null)
		editor.begin_selection_marquee(Vector2(40.0, 40.0))
		_expect(not editor.camera.navigation_enabled(), "marquee selection must lock camera navigation")
		editor.update_selection_marquee(Vector2(170.0, 170.0))
		var selected = editor.end_selection_marquee()
		_expect(selected == first, "marquee must select the object intersecting the drawn rectangle")
		_expect(editor.selected_object == first, "marquee selection must update editor selection")
		_expect(editor.camera.navigation_enabled(), "ending a marquee must restore camera navigation")
		editor.begin_selection_marquee(Vector2(500.0, 500.0))
		editor.update_selection_marquee(Vector2(600.0, 600.0))
		selected = editor.end_selection_marquee()
		_expect(selected == null, "an empty marquee must clear the selection")
		_expect(second != editor.selected_object, "objects outside the marquee must remain unselected")

		# A marquee can select several objects, and a single drag moves the whole
		# selection by one shared delta with one undoable history operation.
		editor.select_ids([first_id, second_id], second_id)
		_expect(editor.selected_object_ids.size() == 2, "marquee selection state must retain every matching object")
		var first_before: Vector2 = editor.world_state.position_at(editor.world_state.index_of(first_id))
		var second_before: Vector2 = editor.world_state.position_at(editor.world_state.index_of(second_id))
		editor.begin_object_drag(editor.selected_object, second_before)
		editor.update_object_drag(second_before + Vector2(48.0, -24.0))
		editor.end_object_drag()
		_expect(
			editor.world_state.position_at(editor.world_state.index_of(first_id)).is_equal_approx(first_before + Vector2(48.0, -24.0)),
			"group drag must move the first selected object by the shared delta"
		)
		_expect(
			editor.world_state.position_at(editor.world_state.index_of(second_id)).is_equal_approx(second_before + Vector2(48.0, -24.0)),
			"group drag must move a rigid object by the shared delta"
		)
		editor.undo_last()
		_expect(
			editor.world_state.position_at(editor.world_state.index_of(first_id)).is_equal_approx(first_before)
			and editor.world_state.position_at(editor.world_state.index_of(second_id)).is_equal_approx(second_before),
			"one undo must restore every object in a group drag"
		)

	editor.free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_selection_marquee")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_selection_marquee: %d failure(s)" % failures.size())
	quit(1)
