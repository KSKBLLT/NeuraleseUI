extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var scene := load("res://scenes/default_spline.tscn") as PackedScene
	_expect(scene != null, "default spline scene must load")
	if scene == null:
		_finish()
		return
	var spline := scene.instantiate() as Spline
	root.add_child(spline)
	await process_frame
	spline.update_points(Vector2.ZERO, Vector2(220.0, 0.0), Vector2.RIGHT, Vector2.LEFT)
	spline.color_a = Color("4cabe6")
	spline.color_b = Color("d1a3ff")
	var line := spline.line_2d
	_expect(line != null, "spline must expose its Line2D")

	spline.play_inference_flow(0.08)
	_expect(spline.is_inference_flow_playing(), "flow must start")
	_expect(line.gradient != null, "active flow must use a temporary pulse gradient")

	# Restart while the first pass is still active, then recolour it. The flow
	# must finish with the latest source colours rather than a stale snapshot.
	spline.play_inference_flow(0.04)
	spline.color_a = Color("66d9ef")
	spline.color_b = Color("f6c177")
	spline._update_inference_flow(0.10)
	_expect(not spline.is_inference_flow_playing(), "restarted flow must finish")
	_expect(line.gradient == null, "finished flow must restore the normal spline renderer")
	_expect(line.texture != null, "finished flow must restore the normal spline texture")
	if line.texture != null:
		var restored := line.texture.get_image()
		_expect(_colors_close(restored.get_pixel(0, 0), spline.color_a), "flow must restore the current first colour")
		_expect(_colors_close(restored.get_pixel(1, 0), spline.color_b), "flow must restore the current last colour")

	spline.play_inference_flow(1.0)
	spline.hide()
	spline._notification(CanvasItem.NOTIFICATION_VISIBILITY_CHANGED)
	_expect(not spline.is_inference_flow_playing(), "hiding a spline must cancel its flow")
	_expect(line.gradient == null, "hidden spline must not retain a pulse gradient")
	spline.queue_free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _colors_close(left: Color, right: Color) -> bool:
	return (
		absf(left.r - right.r) <= 0.01
		and absf(left.g - right.g) <= 0.01
		and absf(left.b - right.b) <= 0.01
		and absf(left.a - right.a) <= 0.01
	)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_spline_inference_flow")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
