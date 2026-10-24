extends Node

const GraphicsQualityConfigScript := preload("res://scripts/graphics_quality.gd")
const BackgroundScene := preload("res://scenes/bg.tscn")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	await get_tree().process_frame
	await get_tree().process_frame

	var project := get_parent()
	var camera := project.get_node_or_null("WIN_GRAPH/Camera2D") as Camera2D
	var graph_background := project.get_node_or_null("WIN_GRAPH/bg") as CanvasLayer
	_expect(camera != null, "project graph camera must exist")
	_expect(graph_background != null, "project graph background must exist")
	if camera == null or graph_background == null:
		_finish()
		return

	glob.cam = camera
	GraphicsQualityConfigScript.apply(GraphicsQualityConfigScript.Level.Medium)
	graph_background.call("activate")

	var sharp := graph_background.get_node_or_null("SubViewport") as SubViewport
	var blur := graph_background.get_node_or_null("BlurBake") as SubViewport
	_expect(blur != null, "Medium must create a BlurBake viewport")
	_expect(graph_background.has_method("mark_dirty"), "background must expose mark_dirty()")
	if sharp == null or blur == null or not graph_background.has_method("mark_dirty"):
		GraphicsQualityConfigScript.apply(GraphicsQualityConfigScript.Level.High)
		_finish()
		return

	var downscale := int(graph_background.get_script().get_script_constant_map().get("_BLUR_DOWNSCALE", 8))
	var expected_size := Vector2i(
		maxi(1, sharp.size.x / downscale),
		maxi(1, sharp.size.y / downscale)
	)
	_expect(blur.size == expected_size, "BlurBake must be 1/%d resolution" % downscale)
	_expect(blur.disable_3d, "BlurBake must disable 3D")
	_expect(blur.transparent_bg, "BlurBake must preserve source alpha")
	_expect(blur.gui_disable_input, "BlurBake must ignore GUI input")

	var initial_sequence := await _collect_update_sequence(graph_background, sharp, blur)
	_expect_update_sequence(initial_sequence, "initial Medium bake")

	graph_background.call("mark_dirty")
	var dirty_sequence := await _collect_update_sequence(graph_background, sharp, blur)
	_expect_update_sequence(dirty_sequence, "mark_dirty bake")

	var settled := await _observe_pre_draw(sharp, blur)
	_expect(
		settled == [SubViewport.UPDATE_DISABLED, SubViewport.UPDATE_DISABLED],
		"settled background must leave both viewports disabled"
	)

	GraphicsQualityConfigScript.apply(GraphicsQualityConfigScript.Level.High)
	var high_sequence := await _collect_update_sequence(graph_background, sharp, blur)
	_expect(
		graph_background.active_texture == sharp.get_texture(),
		"High must republish the sharp background texture"
	)
	# High keeps baking: the bake is bg_soft, which blurred blocks blend to
	# because the sharp viewport texture has no mipmaps (block_body.gdshaderinc).
	_expect_update_sequence(high_sequence, "High bg_soft bake")
	_expect(
		await _observe_pre_draw(sharp, blur) == [SubViewport.UPDATE_DISABLED, SubViewport.UPDATE_DISABLED],
		"a settled High background must leave both viewports disabled"
	)
	_expect(not GraphicsQualityConfigScript.bakes_blur(), "High must disable baked blur mode")

	GraphicsQualityConfigScript.apply(GraphicsQualityConfigScript.Level.Medium)
	var rebake_sequence := await _collect_update_sequence(graph_background, sharp, blur)
	_expect_update_sequence(rebake_sequence, "runtime Medium rebake")
	_expect(
		graph_background.active_texture == blur.get_texture(),
		"Medium must republish the baked background texture"
	)

	await RenderingServer.frame_post_draw
	_assert_opaque_texture(graph_background.active_texture, "Graph background")
	# Dataset and Net do not own another background scene; both are rendered over
	# the active workspace background. Check the shared source under each logical
	# consumer name so a future split cannot silently introduce transparent blur.
	_assert_opaque_texture(graph_background.active_texture, "Dataset shared background")
	_assert_opaque_texture(graph_background.active_texture, "Net shared background")

	var simulation_background := BackgroundScene.instantiate() as CanvasLayer
	simulation_background.register_global = false
	project.add_child(simulation_background)
	simulation_background.call("activate")
	var simulation_sharp := simulation_background.get_node("SubViewport") as SubViewport
	var simulation_blur := simulation_background.get_node("BlurBake") as SubViewport
	await _collect_update_sequence(simulation_background, simulation_sharp, simulation_blur)
	await RenderingServer.frame_post_draw
	_assert_opaque_texture(simulation_background.active_texture, "Simulation background")
	simulation_background.queue_free()

	GraphicsQualityConfigScript.apply(GraphicsQualityConfigScript.Level.High)
	_finish()


func _collect_update_sequence(
	background: CanvasLayer,
	sharp: SubViewport,
	blur: SubViewport
) -> Array:
	var sequence: Array = []
	for _index in 4:
		var modes := await _observe_pre_draw(sharp, blur)
		sequence.append(modes)
		if (
			sequence.size() >= 3
			and modes == [SubViewport.UPDATE_DISABLED, SubViewport.UPDATE_DISABLED]
		):
			break
	return sequence


func _observe_pre_draw(sharp: SubViewport, blur: SubViewport) -> Array:
	var capture := {"done": false, "modes": []}
	RenderingServer.frame_pre_draw.connect(
		func() -> void:
			capture["modes"] = [
				sharp.render_target_update_mode,
				blur.render_target_update_mode,
			]
			capture["done"] = true,
		RenderingServer.CONNECT_ONE_SHOT
	)
	while not capture["done"]:
		await get_tree().process_frame
	return capture["modes"]


func _expect_update_sequence(sequence: Array, label: String) -> void:
	var sharp_updates := 0
	var blur_updates := 0
	for modes: Array in sequence:
		if modes[0] == SubViewport.UPDATE_ONCE:
			sharp_updates += 1
		if modes[1] == SubViewport.UPDATE_ONCE:
			blur_updates += 1
	_expect(
		sharp_updates == 1,
		"%s must update sharp source exactly once; sequence=%s" % [label, sequence]
	)
	_expect(
		blur_updates == 1,
		"%s must update blur source exactly once; sequence=%s" % [label, sequence]
	)
	# Both render on the same frame, the sharp source first by tree order, so a
	# continuous camera pan cannot keep postponing the blur (bg.gd, 9b500b2).
	_expect(
		sequence.find([SubViewport.UPDATE_ONCE, SubViewport.UPDATE_ONCE]) >= 0,
		"%s must render the sharp source and the blur on the same frame; sequence=%s" % [label, sequence]
	)


func _assert_opaque_texture(texture: Texture2D, label: String) -> void:
	var image := texture.get_image() if texture != null else null
	_expect(image != null and not image.is_empty(), "%s must be readable" % label)
	if image == null or image.is_empty():
		return
	for y in image.get_height():
		for x in image.get_width():
			if image.get_pixel(x, y).a < 0.999:
				failures.append("%s has transparent pixel at (%d, %d)" % [label, x, y])
				return


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_background_blur_cache")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
