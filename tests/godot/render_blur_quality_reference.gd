extends SceneTree

const VIEWPORT_SIZE := Vector2i(1024, 640)


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var output_path := _argument_value("--output=")
	if output_path.is_empty() or not output_path.is_absolute_path():
		push_error("--output=<absolute png path> is required")
		quit(2)
		return

	root.size = VIEWPORT_SIZE
	root.content_scale_size = VIEWPORT_SIZE
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED

	var background := TextureRect.new()
	background.name = "ReferencePattern"
	background.position = Vector2.ZERO
	background.size = Vector2(VIEWPORT_SIZE)
	background.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	background.texture = ImageTexture.create_from_image(_make_reference_image())
	root.add_child(background)

	_add_glass_panel(
		"ForegroundGlass",
		"res://resources/fg_block.tres",
		Rect2(70.0, 70.0, 390.0, 230.0)
	)
	_add_glass_panel(
		"ContextGlass",
		"res://resources/context_menu.tres",
		Rect2(360.0, 215.0, 470.0, 250.0)
	)
	_add_glass_panel(
		"SplashGlass",
		"res://scenes/splash.tres",
		Rect2(680.0, 55.0, 280.0, 520.0)
	)

	for _frame in 20:
		await process_frame
	await RenderingServer.frame_post_draw

	var capture := root.get_texture().get_image()
	var save_error := capture.save_png(output_path)
	if save_error != OK:
		push_error("failed to save reference render to %s: %s" % [output_path, save_error])
		quit(1)
		return
	print("PASS render_blur_quality_reference: %s" % output_path)
	quit(0)


func _argument_value(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return ""


func _make_reference_image() -> Image:
	var image := Image.create(VIEWPORT_SIZE.x, VIEWPORT_SIZE.y, false, Image.FORMAT_RGBA8)
	var solid_rects := [
		[Rect2i(96, 90, 184, 142), Color("2354d8")],
		[Rect2i(430, 285, 238, 170), Color("f2ad31")],
		[Rect2i(765, 125, 165, 330), Color("8d36ba")],
	]
	for y in VIEWPORT_SIZE.y:
		for x in VIEWPORT_SIZE.x:
			var checker := ((x / 8) + (y / 8)) as int
			var color := Color(0.93, 0.93, 0.93, 1.0) if checker % 2 == 0 else Color(0.06, 0.06, 0.06, 1.0)
			if x % 32 == 0:
				color = Color(1.0, 0.0, 0.0, 1.0)
			elif y % 32 == 0:
				color = Color(0.0, 1.0, 0.0, 1.0)
			for rect_and_color in solid_rects:
				if (rect_and_color[0] as Rect2i).has_point(Vector2i(x, y)):
					color = rect_and_color[1]
			image.set_pixel(x, y, color)
	return image


func _add_glass_panel(panel_name: String, material_path: String, panel_rect: Rect2) -> void:
	var source_material := load(material_path) as ShaderMaterial
	if source_material == null:
		push_error("failed to load ShaderMaterial: %s" % material_path)
		quit(1)
		return
	var panel := ColorRect.new()
	panel.name = panel_name
	panel.position = panel_rect.position
	panel.size = panel_rect.size
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.material = source_material.duplicate(true)
	root.add_child(panel)
