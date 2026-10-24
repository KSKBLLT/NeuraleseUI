extends SceneTree

class CancelableLesson:
	extends Node
	var current_step_index := 0

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var manager = root.get_node_or_null("ui")
	_expect(manager != null, "ui autoload is available")
	if manager == null:
		_finish()
		return
	var target_layer := CanvasLayer.new()
	target_layer.transform = Transform2D(Vector2(2.0, 0.0), Vector2(0.0, 2.0), Vector2(80.0, 40.0))
	root.add_child(target_layer)
	var target := Control.new()
	target.position = Vector2(120.0, 80.0)
	target.size = Vector2(160.0, 48.0)
	target.add_to_group("tutorial_ui_target")
	target.set_meta("tutorial_target_id", "test_action")
	target_layer.add_child(target)
	await process_frame

	manager.reset_tutorial_ui_config()
	_expect(manager.show_arrow_ui("test_action", "bottom"), "visible UI target accepts an arrow")
	var arrow = manager.arrows.keys().front() if not manager.arrows.is_empty() else null
	_expect(is_instance_valid(arrow), "arrow is created")
	if is_instance_valid(arrow):
		_expect(arrow.get_parent() == manager.tutorial_arrow_layer, "UI arrow renders above the foreground tutorial layer")
		_expect(arrow.thickness == 3.0, "regular tutorials retain the pre-configuration arrow thickness")
		_expect(arrow.end_size == 12.0, "regular tutorials retain the pre-configuration arrow head size")
		_expect(not arrow.shadow_enabled, "regular tutorials do not gain a shadow")
		_expect(manager.WOBBLE_AMPL == 50.0, "regular tutorials retain the pre-configuration arrow wobble")
		var expected_tip: Vector2 = target.get_global_transform_with_canvas() * Vector2(target.size.x * 0.5, target.size.y)
		var expected_start: Vector2 = manager.tutorial_arrow_layer.transform.affine_inverse() * expected_tip + Vector2.DOWN * manager.UI_ARROW_DISTANCE
		_expect(arrow.position.distance_to(expected_start) < 1.0, "arrow uses the target CanvasLayer transform")
		_expect(absf(arrow.end.x) < 0.01, "bottom arrow is centered on the target")
		await process_frame
		var before: Vector2 = arrow.position
		target.queue_free()
		await process_frame
		target = Control.new()
		target.position = Vector2(190.0, 110.0)
		target.size = Vector2(160.0, 48.0)
		target.add_to_group("tutorial_ui_target")
		target.set_meta("tutorial_target_id", "test_action")
		target_layer.add_child(target)
		for _frame in 5:
			await process_frame
		var followed_delta: Vector2 = arrow.position - before
		_expect(absf(followed_delta.x - 140.0) < 4.0 and absf(followed_delta.y - 60.0) < 55.0, "arrow follows a recreated UI target")

	await manager.hide_arrows()
	manager.configure_tutorial_ui({
		"arrow_style": {
			"thickness": 11.0,
			"head_size": 30.0,
			"wobble_amplitude": 8.0,
			"shadow": {
				"enabled": true,
				"color": Color(0.0, 0.0, 0.0, 0.72),
				"offset": Vector2(4.0, 5.0),
				"thickness_add": 5.0,
				"head_size_add": 6.0,
			},
		},
		"highlight_style": {
			"center_opacity": 0.48,
			"padding": 30.0,
			"fade_in": 0.08,
			"fade_out": 0.08,
		},
	})
	_expect(manager.show_arrow_ui("test_action", "bottom"), "lesson-specific arrow style can be applied")
	var styled_arrow = manager.arrows.keys().front() if not manager.arrows.is_empty() else null
	_expect(styled_arrow != null and styled_arrow.thickness == 11.0, "configured arrow thickness reaches the renderer")
	_expect(styled_arrow != null and styled_arrow.end_size == 30.0, "configured arrow head size reaches the renderer")
	_expect(styled_arrow != null and styled_arrow.shadow_enabled, "configured arrow shadow reaches the renderer")
	_expect(styled_arrow != null and styled_arrow.shadow_offset == Vector2(4.0, 5.0), "configured shadow offset is preserved")

	_expect(manager.show_highlight_ui("test_action"), "visible UI target accepts a radial highlight")
	var highlight = manager.tutorial_highlights.values().front() if not manager.tutorial_highlights.is_empty() else null
	_expect(is_instance_valid(highlight), "radial highlight is created")
	if is_instance_valid(highlight):
		_expect(highlight.get_parent() == manager.tutorial_attention_layer, "highlight renders on the highest tutorial CanvasLayer")
		_expect(highlight.texture is GradientTexture2D, "highlight uses a radial gradient texture")
		_expect(highlight.texture.fill == GradientTexture2D.FILL_RADIAL, "highlight gradient is circular")
		_expect(highlight.material is CanvasItemMaterial, "highlight uses CanvasItemMaterial")
		_expect(highlight.material.blend_mode == CanvasItemMaterial.BLEND_MODE_ADD, "highlight uses additive blending")
		_expect(absf(highlight.center_opacity - 0.48) < 0.001, "highlight center opacity is configurable")
		_expect(highlight.size.x >= maxf(target.size.x, target.size.y) + 60.0, "highlight includes transparent padding around its target")
		_expect(highlight.modulate.a < 1.0, "highlight starts with a fade-in instead of popping in")
		await create_timer(0.12).timeout
		_expect(is_equal_approx(highlight.modulate.a, 1.0), "highlight reaches full opacity after fade-in")

	var release_event := InputEventMouseButton.new()
	release_event.button_index = MOUSE_BUTTON_LEFT
	release_event.pressed = false
	Callable(func(): target.gui_input.emit(release_event)).call_deferred()
	_expect(await manager.wait_for_tutorial_ui("test_action"), "tutorial can wait for a target click without graph hints")
	var canceled_lesson := CancelableLesson.new()
	root.add_child(canceled_lesson)
	Callable(func(): canceled_lesson.current_step_index = -1).call_deferred()
	_expect(
		not await manager.wait_for_tutorial_ui("test_action", canceled_lesson),
		"skipping a lesson cancels its pending UI wait"
	)
	canceled_lesson.queue_free()
	var fading_highlight = highlight
	manager.hide_ui_highlights()
	_expect(manager.tutorial_highlights.is_empty(), "all tutorial highlights can be cleared")
	_expect(is_instance_valid(fading_highlight), "highlight remains alive during fade-out")
	await create_timer(0.12).timeout
	_expect(not is_instance_valid(fading_highlight), "highlight is released after fade-out")
	manager.reset_tutorial_ui_config()

	target.queue_free()
	target_layer.queue_free()
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_ui_tutorial_arrow")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
