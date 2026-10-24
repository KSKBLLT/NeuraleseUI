extends RefCounted
class_name UICapture

const PlatformInput = preload("res://scripts/platform_input.gd")


static func capture_control(
	target: Control,
	output_path: String,
	options: Dictionary = {}
) -> Dictionary:
	if not is_instance_valid(target):
		return _error("Target control is invalid.")
	if not target.is_inside_tree():
		return _error("Target control is not inside the scene tree.")
	if not target.is_visible_in_tree():
		return _error("Target control is not visible in the scene tree: %s" % target.get_path())
	if target.size.x <= 0.0 or target.size.y <= 0.0:
		return _error("Target control has an empty size: %s" % target.get_path())

	var viewport := target.get_viewport()
	if not is_instance_valid(viewport):
		return _error("Target control has no viewport.")

	var padding := maxf(0.0, float(options.get("padding", 0.0)))
	var requested_scale := maxf(1.0, float(options.get("render_scale", 1.0)))
	var alpha_mode := str(options.get("alpha_mode", "preserve")).strip_edges().to_lower()
	if alpha_mode not in ["preserve", "black_matte"]:
		return _error("Unknown alpha mode: %s" % alpha_mode)
	var settle_frames := maxi(1, int(options.get("settle_frames", 2)))
	var original_rect := control_viewport_rect(target)
	var render_state := _begin_render_transform(
		target,
		viewport,
		original_rect,
		padding,
		requested_scale
	)
	var render_scale: float = render_state.get("scale", 1.0)
	var isolation_state := _isolate_target(target, viewport)
	for _frame in settle_frames:
		await target.get_tree().process_frame
	_refresh_render_transform(render_state)
	await RenderingServer.frame_post_draw
	_refresh_render_transform(render_state)

	var logical_rect := control_viewport_rect(target).grow(padding * render_scale)
	var viewport_image := viewport.get_texture().get_image()
	var result: Dictionary = {}
	if viewport_image == null or viewport_image.is_empty():
		result = _error("Viewport did not produce an image.")
	else:
		var pixel_rect := PlatformInput.texture_pixel_rect(
			logical_rect,
			viewport.get_visible_rect().size,
			viewport_image.get_size()
		)
		if pixel_rect.size.x <= 0 or pixel_rect.size.y <= 0:
			result = _error("Target is outside the viewport: %s" % target.get_path())
			result["logical_rect"] = logical_rect
			result["render_scale"] = render_scale
		else:
			var image := viewport_image.get_region(pixel_rect)
			if alpha_mode == "black_matte":
				_apply_black_matte(image, float(options.get("matte_alpha", 0.5)))
			else:
				_unpremultiply_alpha(image)

			var absolute_output := ProjectSettings.globalize_path(output_path)
			var output_dir := absolute_output.get_base_dir()
			var directory_error := DirAccess.make_dir_recursive_absolute(output_dir)
			if directory_error != OK:
				result = _error("Cannot create capture directory: %s" % output_dir)
			else:
				var save_error := image.save_png(absolute_output)
				if save_error != OK:
					result = _error("Cannot save capture: %s" % error_string(save_error))
				else:
					result = {
						"ok": true,
						"path": output_path,
						"absolute_path": absolute_output,
						"logical_rect": logical_rect,
						"pixel_rect": pixel_rect,
						"image_size": image.get_size(),
						"render_scale_requested": requested_scale,
						"render_scale": render_scale,
						"alpha_mode": alpha_mode,
					}

	_restore_render_transform(render_state)
	_restore_isolation(isolation_state)
	return result


static func control_viewport_rect(target: Control) -> Rect2:
	return _control_rect_with_transform(target, target.get_global_transform_with_canvas())


static func _control_rect_with_transform(target: Control, transform: Transform2D) -> Rect2:
	var local_rect := Rect2(Vector2.ZERO, target.size)
	if target is Graph and is_instance_valid(target.rect):
		local_rect = Rect2(target.rect.position, target.rect.size)
	var p0 := local_rect.position
	var p1 := Vector2(local_rect.end.x, local_rect.position.y)
	var p2 := local_rect.end
	var p3 := Vector2(local_rect.position.x, local_rect.end.y)
	var points := PackedVector2Array([
		transform * p0,
		transform * p1,
		transform * p2,
		transform * p3,
	])
	var minimum := points[0]
	var maximum := points[0]
	for point in points.slice(1):
		minimum = minimum.min(point)
		maximum = maximum.max(point)
	return Rect2(minimum, maximum - minimum)


static func resolve_control(root_node: Node, requested_path: String) -> Control:
	if not is_instance_valid(root_node):
		return null
	var normalized := requested_path.replace("\\", "/").strip_edges().trim_prefix("/")
	var direct := root_node.get_node_or_null(NodePath(normalized)) as Control
	if is_instance_valid(direct):
		return direct
	var requested_parts := normalized.split("/", false)
	if requested_parts.is_empty():
		return root_node as Control if normalized.is_empty() else null
	var target_name := requested_parts[-1]
	for candidate in root_node.find_children(target_name, "", true, false):
		if candidate is Control and _runtime_relative_path(root_node, candidate) == "/".join(requested_parts):
			return candidate as Control
	return null


static func _runtime_relative_path(root_node: Node, target: Node) -> String:
	var parts: PackedStringArray = []
	var current := target
	while is_instance_valid(current) and current != root_node:
		if not current.name.begins_with("@"):
			parts.insert(0, current.name)
		current = current.get_parent()
	return "/".join(parts)


static func _begin_render_transform(
	target: Control,
	viewport: Viewport,
	target_rect: Rect2,
	padding: float,
	requested_scale: float
) -> Dictionary:
	var viewport_size := viewport.get_visible_rect().size
	var padded_size := target_rect.size + Vector2.ONE * padding * 2.0
	var fit_scale := requested_scale
	if padded_size.x > 0.0 and padded_size.y > 0.0:
		fit_scale = minf(
			requested_scale,
			minf(viewport_size.x / padded_size.x, viewport_size.y / padded_size.y)
		)
	var scale := maxf(1.0, fit_scale)
	var scaled_size := target_rect.size * scale
	var desired_position := (viewport_size - scaled_size) * 0.5
	var translation := desired_position - target_rect.position * scale
	var zoom_transform := Transform2D(
		Vector2(scale, 0.0),
		Vector2(0.0, scale),
		translation
	)
	var canvas_layer := target.get_canvas_layer_node()
	if is_instance_valid(canvas_layer):
		var previous_transform: Transform2D = canvas_layer.transform
		canvas_layer.transform = zoom_transform * previous_transform
		return {
			"kind": "canvas_layer",
			"canvas_layer": canvas_layer,
			"transform": previous_transform,
			"render_transform": zoom_transform * previous_transform,
			"scale": scale,
		}

	var camera := viewport.get_camera_2d()
	if is_instance_valid(camera):
		var previous_position := camera.global_position
		var previous_zoom := camera.zoom
		var previous_processing := camera.is_processing()
		var previous_physics_processing := camera.is_physics_processing()
		var previous_target_position: Variant = camera.get("target_position")
		var previous_target_zoom: Variant = camera.get("target_zoom")
		var world_rect := _control_rect_with_transform(target, target.get_global_transform())
		var render_position := world_rect.get_center()
		var render_zoom := previous_zoom * scale
		camera.set_process(false)
		camera.set_physics_process(false)
		camera.global_position = render_position
		camera.zoom = render_zoom
		if previous_target_position != null:
			camera.set("target_position", camera.position)
		if previous_target_zoom != null:
			camera.set("target_zoom", render_zoom.x)
		if camera.has_method("reset_smoothing"):
			camera.reset_smoothing()
		return {
			"kind": "camera",
			"camera": camera,
			"position": previous_position,
			"zoom": previous_zoom,
			"processing": previous_processing,
			"physics_processing": previous_physics_processing,
			"target_position": previous_target_position,
			"target_zoom": previous_target_zoom,
			"render_position": render_position,
			"render_zoom": render_zoom,
			"scale": scale,
		}
	var previous_canvas_transform := viewport.canvas_transform
	viewport.canvas_transform = zoom_transform * previous_canvas_transform
	return {
		"kind": "viewport",
		"viewport": viewport,
		"transform": previous_canvas_transform,
		"render_transform": zoom_transform * previous_canvas_transform,
		"scale": scale,
	}


static func _refresh_render_transform(state: Dictionary) -> void:
	if state.get("kind") == "canvas_layer":
		var canvas_layer: CanvasLayer = state.get("canvas_layer")
		if is_instance_valid(canvas_layer):
			canvas_layer.transform = state.get("render_transform", canvas_layer.transform)
		return
	if state.get("kind") == "camera":
		var camera: Camera2D = state.get("camera")
		if is_instance_valid(camera):
			camera.global_position = state.get("render_position", camera.global_position)
			camera.zoom = state.get("render_zoom", camera.zoom)
			if camera.has_method("reset_smoothing"):
				camera.reset_smoothing()
		return
	var viewport: Viewport = state.get("viewport")
	if is_instance_valid(viewport):
		viewport.canvas_transform = state.get("render_transform", viewport.canvas_transform)


static func _restore_render_transform(state: Dictionary) -> void:
	if state.get("kind") == "canvas_layer":
		var canvas_layer: CanvasLayer = state.get("canvas_layer")
		if is_instance_valid(canvas_layer):
			canvas_layer.transform = state.get("transform", Transform2D.IDENTITY)
		return
	if state.get("kind") == "camera":
		var camera: Camera2D = state.get("camera")
		if is_instance_valid(camera):
			camera.global_position = state.get("position", camera.global_position)
			camera.zoom = state.get("zoom", camera.zoom)
			var target_position: Variant = state.get("target_position")
			var target_zoom: Variant = state.get("target_zoom")
			if target_position != null:
				camera.set("target_position", target_position)
			if target_zoom != null:
				camera.set("target_zoom", target_zoom)
			camera.set_process(bool(state.get("processing", true)))
			camera.set_physics_process(bool(state.get("physics_processing", true)))
		return
	var viewport: Viewport = state.get("viewport")
	if is_instance_valid(viewport):
		viewport.canvas_transform = state.get("transform", Transform2D.IDENTITY)


static func _apply_black_matte(image: Image, matte_alpha: float) -> void:
	var normalization_alpha := clampf(matte_alpha, 0.01, 1.0)
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a <= 0.0:
				continue
			var coverage := minf(1.0, color.a / normalization_alpha)
			var rgb_scale := 1.0 / coverage
			image.set_pixel(x, y, Color(
				color.r * rgb_scale,
				color.g * rgb_scale,
				color.b * rgb_scale,
				coverage
			))


static func _unpremultiply_alpha(image: Image) -> void:
	for y in image.get_height():
		for x in image.get_width():
			var color := image.get_pixel(x, y)
			if color.a <= 0.0 or color.a >= 1.0:
				continue
			var inverse_alpha := 1.0 / color.a
			image.set_pixel(x, y, Color(
				minf(1.0, color.r * inverse_alpha),
				minf(1.0, color.g * inverse_alpha),
				minf(1.0, color.b * inverse_alpha),
				color.a
			))


static func _isolate_target(target: Control, viewport: Viewport) -> Array[Dictionary]:
	var canvas_items: Array[CanvasItem] = []
	_collect_canvas_items(viewport, viewport, canvas_items)
	var state: Array[Dictionary] = []
	for item in canvas_items:
		if item == target or target.is_ancestor_of(item):
			continue
		if item.is_ancestor_of(target):
			state.append({
				"item": item,
				"visible": item.visible,
				"self_modulate": item.self_modulate,
			})
			var transparent := item.self_modulate
			transparent.a = 0.0
			item.self_modulate = transparent
			continue
		if not item.visible:
			continue
		state.append({
			"item": item,
			"visible": item.visible,
			"self_modulate": item.self_modulate,
		})
		item.visible = false
	return state


static func _collect_canvas_items(
	node: Node,
	viewport: Viewport,
	result: Array[CanvasItem]
) -> void:
	for child in node.get_children():
		if child is Viewport and child != viewport:
			continue
		if child is CanvasItem and child.get_viewport() == viewport:
			result.append(child)
		_collect_canvas_items(child, viewport, result)


static func _restore_isolation(state: Array[Dictionary]) -> void:
	for entry in state:
		var item: CanvasItem = entry.get("item")
		if not is_instance_valid(item):
			continue
		item.self_modulate = entry.get("self_modulate", Color.WHITE)
		item.visible = bool(entry.get("visible", true))


static func _error(message: String) -> Dictionary:
	return {"ok": false, "error": message}
