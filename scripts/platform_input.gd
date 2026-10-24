extends RefCounted


static func content_scale_for_platform(os_name: String, reported_scale: float) -> float:
	if os_name != "macOS":
		return 1.0
	if is_nan(reported_scale) or is_inf(reported_scale):
		return 1.0
	return clampf(reported_scale, 1.0, 4.0)


static func logical_window_size(physical_size: Vector2, content_scale: float) -> Vector2:
	return physical_size / maxf(content_scale, 1.0)


static func preview_camera_zoom(content_scale: float) -> float:
	return 2.0 / maxf(content_scale, 1.0)


static func texture_pixel_rect(
	logical_rect: Rect2,
	logical_viewport_size: Vector2,
	texture_size: Vector2i
) -> Rect2i:
	var scale_x := float(texture_size.x) / maxf(logical_viewport_size.x, 1.0)
	var scale_y := float(texture_size.y) / maxf(logical_viewport_size.y, 1.0)
	var pixel_rect := Rect2i(
		Vector2i(
			roundi(logical_rect.position.x * scale_x),
			roundi(logical_rect.position.y * scale_y)
		),
		Vector2i(
			roundi(logical_rect.size.x * scale_x),
			roundi(logical_rect.size.y * scale_y)
		)
	)
	return pixel_rect.intersection(Rect2i(Vector2i.ZERO, texture_size))


static func trackpad_pan_offset(
	gesture_delta: Vector2,
	camera_zoom: float,
	pan_speed: float
) -> Vector2:
	var safe_zoom := maxf(absf(camera_zoom), 0.001)
	return -gesture_delta * pan_speed / safe_zoom


static func make_shortcut_event(shortcut: int) -> InputEventKey:
	var event := InputEventKey.new()
	event.keycode = shortcut & KEY_CODE_MASK
	event.shift_pressed = bool(shortcut & KEY_MASK_SHIFT)
	event.alt_pressed = bool(shortcut & KEY_MASK_ALT)
	event.command_or_control_autoremap = bool(shortcut & KEY_MASK_CMD_OR_CTRL)
	return event


static func shortcut_matches(event: InputEvent, shortcut: int) -> bool:
	if not event is InputEventKey or not event.pressed or event.echo:
		return false

	var key_event := event as InputEventKey
	if key_event.keycode != shortcut & KEY_CODE_MASK:
		return false
	if key_event.shift_pressed != bool(shortcut & KEY_MASK_SHIFT):
		return false
	if key_event.alt_pressed != bool(shortcut & KEY_MASK_ALT):
		return false

	var expects_primary := bool(shortcut & KEY_MASK_CMD_OR_CTRL)
	if expects_primary:
		return key_event.is_command_or_control_pressed()
	return not key_event.ctrl_pressed and not key_event.meta_pressed
