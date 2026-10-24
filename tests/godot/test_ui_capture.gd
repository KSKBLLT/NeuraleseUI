extends SceneTree

const UICaptureCore := preload("res://scripts/ui_capture.gd")

var _failures := 0


func _initialize() -> void:
	call_deferred("_run")


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error(message)


func _run() -> void:
	var viewport := SubViewport.new()
	viewport.size = Vector2i(220, 160)
	viewport.transparent_bg = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	root.add_child(viewport)

	var container := Control.new()
	container.size = Vector2(220, 160)
	viewport.add_child(container)

	var sibling := ColorRect.new()
	sibling.position = Vector2(45, 35)
	sibling.size = Vector2(70, 46)
	sibling.color = Color.BLUE
	container.add_child(sibling)

	var target := ColorRect.new()
	target.position = Vector2(50, 40)
	target.size = Vector2(60, 36)
	target.color = Color(0.9, 0.1, 0.2, 1.0)
	container.add_child(target)

	for _frame in 3:
		await process_frame

	var output_path := "user://ui-capture-test.png"
	var result: Dictionary = await UICaptureCore.capture_control(target, output_path, {
		"padding": 5.0,
	})
	_expect(bool(result.get("ok", false)), "capture must succeed: %s" % result)
	_expect(sibling.visible, "capture must restore unrelated sibling visibility")
	_expect(container.self_modulate.is_equal_approx(Color.WHITE), "capture must restore ancestor self-modulate")
	_expect(target.visible, "capture must leave the target visible")

	if bool(result.get("ok", false)):
		var image := Image.load_from_file(ProjectSettings.globalize_path(output_path))
		_expect(image.get_size() == Vector2i(70, 46), "capture must include logical padding")
		_expect(image.get_pixel(0, 0).a < 0.05, "capture padding must remain transparent")
		var center := image.get_pixel(image.get_width() / 2, image.get_height() / 2)
		_expect(center.r > 0.75 and center.g < 0.25, "capture must contain the target pixels")
		var edge := image.get_pixel(2, image.get_height() / 2)
		_expect(edge.a < 0.05, "overlapping siblings must be isolated from the capture")

	target.color = Color(0.8, 0.2, 0.1, 0.5)
	var preserve_alpha_path := "user://ui-capture-preserve-alpha-test.png"
	var preserve_alpha_result: Dictionary = await UICaptureCore.capture_control(
		target,
		preserve_alpha_path
	)
	_expect(bool(preserve_alpha_result.get("ok", false)), "straight-alpha capture must succeed")
	if bool(preserve_alpha_result.get("ok", false)):
		var preserve_alpha_image := Image.load_from_file(ProjectSettings.globalize_path(preserve_alpha_path))
		var preserve_center := preserve_alpha_image.get_pixel(
			preserve_alpha_image.get_width() / 2,
			preserve_alpha_image.get_height() / 2
		)
		_expect(preserve_center.r > 0.7, "preserve mode must unpremultiply RGB for PNG")
		_expect(preserve_center.a > 0.45 and preserve_center.a < 0.55, "preserve mode must retain source alpha")
	var matte_path := "user://ui-capture-matte-test.png"
	var matte_result: Dictionary = await UICaptureCore.capture_control(target, matte_path, {
		"padding": 5.0,
		"render_scale": 2.0,
		"alpha_mode": "black_matte",
		"matte_alpha": 0.5,
	})
	_expect(bool(matte_result.get("ok", false)), "scaled matte capture must succeed: %s" % matte_result)
	_expect(viewport.canvas_transform.is_equal_approx(Transform2D.IDENTITY), "viewport transform must be restored")
	if bool(matte_result.get("ok", false)):
		var matte_image := Image.load_from_file(ProjectSettings.globalize_path(matte_path))
		_expect(matte_image.get_size() == Vector2i(140, 92), "render scale must add real output pixels")
		var matte_center := matte_image.get_pixel(matte_image.get_width() / 2, matte_image.get_height() / 2)
		_expect(matte_center.a > 0.98, "black matte must make the component interior opaque")
		_expect(matte_center.r > 0.35 and matte_center.r < 0.5, "black matte must composite RGB over black")
		_expect(matte_image.get_pixel(0, 0).a < 0.05, "black matte surroundings must remain transparent")

	var canvas_layer := CanvasLayer.new()
	viewport.add_child(canvas_layer)
	var layer_target := ColorRect.new()
	layer_target.position = Vector2(20, 20)
	layer_target.size = Vector2(30, 20)
	layer_target.color = Color(0.2, 0.8, 0.4, 1.0)
	canvas_layer.add_child(layer_target)
	for _frame in 2:
		await process_frame
	var layer_path := "user://ui-capture-layer-test.png"
	var layer_result: Dictionary = await UICaptureCore.capture_control(layer_target, layer_path, {
		"padding": 4.0,
		"render_scale": 3.0,
	})
	_expect(bool(layer_result.get("ok", false)), "CanvasLayer capture must succeed: %s" % layer_result)
	_expect(canvas_layer.transform.is_equal_approx(Transform2D.IDENTITY), "CanvasLayer transform must be restored")
	if bool(layer_result.get("ok", false)):
		var layer_image := Image.load_from_file(ProjectSettings.globalize_path(layer_path))
		_expect(layer_image.get_size() == Vector2i(114, 84), "CanvasLayer render scale must be applied")
		_expect(layer_image.get_pixel(layer_image.get_width() / 2, layer_image.get_height() / 2).g > 0.7, "CanvasLayer target pixels must be captured")

	viewport.queue_free()
	if _failures == 0:
		print("PASS test_ui_capture")
	quit(_failures)
