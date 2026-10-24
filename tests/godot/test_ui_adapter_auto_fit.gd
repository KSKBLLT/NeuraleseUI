extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	# Loading UIAdapter after autoload initialization avoids the standalone
	# SceneTree runner compiling BlockComponent before project globals exist.
	await process_frame
	var adapter: GDScript = load("res://scripts/ui_adapter.gd")
	_expect(adapter != null, "UIAdapter loads")
	if adapter == null:
		_finish()
		return

	var host := Control.new()
	root.add_child(host)

	var fit_x: Variant = adapter.call("build", {
		"id": "fit_x",
		"type": "block",
		"text": "This button needs considerably more horizontal room",
		"size": [80, 36],
		"auto_fit": "x",
		"fit_padding": [12, 8]
	})
	adapter.call("mount", host, fit_x)

	var fit_y: Variant = adapter.call("build", {
		"id": "fit_y",
		"type": "block",
		"text": "This text wraps onto several lines while the button keeps its authored width",
		"size": [120, 24],
		"auto_fit": "y",
		"fit_padding": [10, 8]
	})
	adapter.call("mount", host, fit_y)

	var fit_both: Variant = adapter.call("build", {
		"id": "fit_both",
		"type": "block",
		"text": "Wide line\nSecond line",
		"size": [40, 20],
		"auto_fit": true,
		"fit_padding": [8, 6]
	})
	adapter.call("mount", host, fit_both)

	var fit_scaled: Variant = adapter.call("build", {
		"id": "fit_scaled",
		"type": "block",
		"text": "A long dynamic label",
		"size": [120, 40],
		"scale": [0.8, 0.8],
		"alignment": [0.5, 0.5],
		"scale_affects_layout": true,
		"auto_fit": "x",
		"fit_shrink": true,
		"fit_padding": [12, 8]
	})
	adapter.call("mount", host, fit_scaled)

	await process_frame
	await process_frame

	_expect(fit_x.base_size.x > 80.0, "x fit expands width")
	_expect_equal(fit_x.base_size.y, 36.0, "x fit preserves height")
	_expect_equal(fit_y.base_size.x, 120.0, "y fit preserves width")
	_expect(fit_y.base_size.y > 24.0, "y fit expands height")
	_expect(
		fit_y.label.autowrap_mode == TextServer.AUTOWRAP_WORD_SMART,
		"y fit enables word wrapping"
	)
	_expect(fit_both.base_size.x > 40.0, "both fit expands width")
	_expect(fit_both.base_size.y > 20.0, "both fit expands height")
	_expect(
		fit_scaled.scaler.position.is_equal_approx(
			fit_scaled.alignment * fit_scaled.base_size * fit_scaled.base_scale
		),
		"scaled button keeps its hover origin at the configured center"
	)
	_expect(
		fit_scaled._wrapped_in.custom_minimum_size.is_equal_approx(
			fit_scaled.base_size * fit_scaled.base_scale.abs()
		),
		"auto-fit preserves scaled wrapper layout size"
	)

	var original_minimum: Vector2 = fit_x.text_fit_min_size
	var expanded_width: float = fit_x.base_size.x
	fit_x.text = "Short"
	await process_frame
	_expect(
		fit_x.base_size.x < expanded_width,
		"auto fit contracts again when text becomes shorter"
	)
	_expect(
		fit_x.base_size.x >= original_minimum.x,
		"auto fit never shrinks below authored width"
	)
	var scaled_width_before: float = fit_scaled.base_size.x
	fit_scaled.text = "X"
	await process_frame
	_expect(
		fit_scaled.base_size.x < scaled_width_before and fit_scaled.base_size.x < 120.0,
		"fit_shrink allows dynamic button states to remove unused width"
	)
	_expect(
		fit_scaled.size.is_equal_approx(fit_scaled.base_size)
		and fit_scaled.scaler.size.is_equal_approx(fit_scaled.base_size),
		"fit_shrink contracts the rendered button together with its layout wrapper"
	)

	host.queue_free()
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_ui_adapter_auto_fit")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
