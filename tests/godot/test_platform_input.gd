extends SceneTree

var _failures: int = 0


func _initialize() -> void:
	_test_display_scaling_preserves_retina_quality()
	_test_macos_export_preserves_retina_quality()
	_test_project_shortcuts_use_primary_modifier()
	_test_platform_input_helpers()
	_test_platform_content_scale()
	_test_texture_pixel_rect()
	_test_top_bar_navigation_layout()
	_test_camera_trackpad_pan()
	_test_camera_middle_drag_respects_navigation_blockers()

	if _failures == 0:
		print("platform input tests: PASS")
	else:
		push_error("platform input tests: %d failure(s)" % _failures)
	quit(_failures)


func _test_display_scaling_preserves_retina_quality() -> void:
	_expect(
		bool(ProjectSettings.get_setting("display/window/dpi/allow_hidpi", true)),
		"project runs must keep HiDPI rendering enabled on Retina displays"
	)


func _test_macos_export_preserves_retina_quality() -> void:
	var config := ConfigFile.new()
	_expect(config.load("res://export_presets.cfg") == OK, "export presets must load")
	_expect(
		bool(config.get_value("preset.4.options", "display/high_res", false)),
		"macOS exports must keep high-resolution rendering enabled"
	)


func _expect(condition: bool, message: String) -> void:
	if condition:
		return
	_failures += 1
	push_error(message)


func _test_project_shortcuts_use_primary_modifier() -> void:
	for action_name in [&"ctrl_s", &"ctrl_z", &"ctrl_y"]:
		var supports_primary_modifier := false
		for event in InputMap.action_get_events(action_name):
			if event is InputEventKey and event.command_or_control_autoremap:
				supports_primary_modifier = true
				break
		_expect(
			supports_primary_modifier,
			"%s must use Command on macOS and Ctrl elsewhere" % action_name
		)

	var shortcut_cases := [
		[&"ctrl_s", KEY_S, false],
		[&"ctrl_z", KEY_Z, false],
		[&"ctrl_y", KEY_Y, false],
		[&"ctrl_y", KEY_Z, true],
	]
	for shortcut_case in shortcut_cases:
		var event := InputEventKey.new()
		event.physical_keycode = shortcut_case[1]
		event.shift_pressed = shortcut_case[2]
		event.pressed = true
		if OS.get_name() == "macOS":
			event.meta_pressed = true
		else:
			event.ctrl_pressed = true
		_expect(
			InputMap.event_is_action(event, shortcut_case[0], true),
			"%s must match its platform shortcut" % shortcut_case[0]
		)


func _test_platform_input_helpers() -> void:
	var script_path := "res://scripts/platform_input.gd"
	_expect(ResourceLoader.exists(script_path), "platform input helper must exist")
	if not ResourceLoader.exists(script_path):
		return

	var platform_input = load(script_path)
	var pan_offset: Vector2 = platform_input.trackpad_pan_offset(
		Vector2(2.0, -3.0),
		2.0,
		20.0
	)
	_expect(
		pan_offset.is_equal_approx(Vector2(-20.0, 30.0)),
		"trackpad pan must follow the fingers and account for camera zoom"
	)

	var shortcut_event := InputEventKey.new()
	shortcut_event.keycode = KEY_S
	shortcut_event.pressed = true
	if OS.get_name() == "macOS":
		shortcut_event.meta_pressed = true
	else:
		shortcut_event.ctrl_pressed = true
	_expect(
		platform_input.shortcut_matches(
			shortcut_event,
			KEY_MASK_CMD_OR_CTRL | KEY_S
		),
		"primary save shortcut must match the platform modifier"
	)
	shortcut_event.shift_pressed = true
	_expect(
		not platform_input.shortcut_matches(
			shortcut_event,
			KEY_MASK_CMD_OR_CTRL | KEY_S
		),
		"shortcut matching must reject unexpected modifiers"
	)

	var generated_event: InputEventKey = platform_input.make_shortcut_event(
		KEY_MASK_CMD_OR_CTRL | KEY_MASK_SHIFT | KEY_Z
	)
	_expect(generated_event.command_or_control_autoremap, "generated shortcut must auto-remap Ctrl/Cmd")
	_expect(generated_event.shift_pressed, "generated shortcut must preserve Shift")
	_expect(generated_event.keycode == KEY_Z, "generated shortcut must preserve the keycode")


func _test_platform_content_scale() -> void:
	var platform_input = load("res://scripts/platform_input.gd")
	_expect(
		platform_input.has_method("content_scale_for_platform"),
		"platform helper must expose content scaling"
	)
	_expect(
		platform_input.has_method("logical_window_size"),
		"platform helper must expose logical window sizing"
	)
	_expect(
		platform_input.has_method("preview_camera_zoom"),
		"platform helper must expose a display-scale-aware preview zoom"
	)
	if (
		not platform_input.has_method("content_scale_for_platform")
		or not platform_input.has_method("logical_window_size")
		or not platform_input.has_method("preview_camera_zoom")
	):
		return

	_expect(
		is_equal_approx(platform_input.content_scale_for_platform("macOS", 2.0), 2.0),
		"macOS must use the display-reported Retina scale"
	)
	_expect(
		is_equal_approx(platform_input.content_scale_for_platform("Windows", 2.0), 1.0),
		"Windows rendering scale must remain unchanged"
	)
	_expect(
		platform_input.logical_window_size(Vector2(3024.0, 1964.0), 2.0).is_equal_approx(Vector2(1512.0, 982.0)),
		"layout must use logical coordinates after Retina scaling"
	)
	_expect(
		platform_input.logical_window_size(Vector2(2880.0, 1800.0), 2.0).is_equal_approx(
			platform_input.logical_window_size(Vector2(1440.0, 900.0), 1.0)
		),
		"the same logical viewport must produce identical layout coordinates on Retina macOS and Windows"
	)
	_expect(
		is_equal_approx(platform_input.preview_camera_zoom(2.0), 1.0),
		"Retina icon generation must avoid applying the two-times scale twice"
	)
	_expect(
		is_equal_approx(platform_input.preview_camera_zoom(1.0), 2.0),
		"one-times icon generation must retain the authored two-times preview zoom"
	)
	_expect(
		is_equal_approx(platform_input.content_scale_for_platform("macOS", NAN), 1.0),
		"invalid display scale reports must safely fall back to one"
	)
	_expect(
		is_equal_approx(platform_input.content_scale_for_platform("macOS", 8.0), 4.0),
		"invalidly large display scale reports must be capped before they shrink the UI"
	)


func _test_texture_pixel_rect() -> void:
	var platform_input = load("res://scripts/platform_input.gd")
	_expect(
		platform_input.has_method("texture_pixel_rect"),
		"platform helper must convert logical screenshot coordinates to texture pixels"
	)
	if not platform_input.has_method("texture_pixel_rect"):
		return

	_expect(
		platform_input.texture_pixel_rect(
			Rect2(100.0, 50.0, 200.0, 100.0),
			Vector2(1000.0, 500.0),
			Vector2i(2000, 1000)
		) == Rect2i(200, 100, 400, 200),
		"Retina screenshots must scale logical crop coordinates to physical pixels"
	)
	_expect(
		platform_input.texture_pixel_rect(
			Rect2(100.0, 50.0, 200.0, 100.0),
			Vector2(1000.0, 500.0),
			Vector2i(1000, 500)
		) == Rect2i(100, 50, 200, 100),
		"1x screenshots must preserve logical crop coordinates"
	)
	_expect(
		platform_input.texture_pixel_rect(
			Rect2(-10.0, -5.0, 30.0, 20.0),
			Vector2(100.0, 50.0),
			Vector2i(200, 100)
		) == Rect2i(0, 0, 40, 30),
		"screenshot crops must be clamped to the texture bounds"
	)


func _test_top_bar_navigation_layout() -> void:
	var top_bar = load("res://scripts/top_panel.gd")
	_expect(top_bar != null, "top bar script must load for responsive layout tests")
	if top_bar == null:
		return
	var compact: Dictionary = top_bar.navigation_layout(186.0, 448.0)
	_expect(float(compact["scale"]) < 0.75, "compact top bar must shrink navigation to available space")
	_expect(float(compact["left"]) >= 194.0, "navigation must not overlap the project title")
	_expect(float(compact["right"]) <= 440.0, "navigation must not overlap Axon and export actions")
	var desktop: Dictionary = top_bar.navigation_layout(240.0, 980.0)
	_expect(is_equal_approx(float(desktop["scale"]), 1.0), "desktop navigation must retain its authored scale")


func _test_camera_trackpad_pan() -> void:
	var camera_script = load("res://scripts/camera_2d.gd")
	_expect(camera_script != null, "camera script must load")
	if camera_script == null:
		return

	var camera = camera_script.new()
	_expect(camera.has_method("apply_trackpad_pan"), "camera must expose trackpad pan handling")
	if not camera.has_method("apply_trackpad_pan"):
		camera.free()
		return

	camera.target_position = Vector2(100.0, 50.0)
	camera.target_zoom = 2.0
	camera.pan_gesture_speed = 20.0
	camera.apply_trackpad_pan(Vector2(2.0, -3.0))
	_expect(
		camera.target_position.is_equal_approx(Vector2(80.0, 80.0)),
		"camera target must move with a two-finger pan gesture"
	)
	camera.free()


func _test_camera_middle_drag_respects_navigation_blockers() -> void:
	var camera_script = load("res://scripts/camera_2d.gd")
	_expect(camera_script != null, "camera script must load for middle-drag regression coverage")
	if camera_script == null:
		return

	var camera = camera_script.new()
	camera.drag_button = MOUSE_BUTTON_MIDDLE
	var global_state = get_root().get_node_or_null("glob")
	_expect(global_state != null, "global input state must be available to camera tests")
	if global_state == null:
		camera.free()
		return
	var blocker := Control.new()
	global_state.set_scroll_impossible(blocker)

	var press := InputEventMouseButton.new()
	press.button_index = MOUSE_BUTTON_MIDDLE
	press.pressed = true
	camera._input(press)
	_expect(not camera.dragging, "middle-button camera drag must not start while palette navigation is blocked")

	global_state.set_scroll_possible(blocker)
	blocker.free()

	var attention_blocker := Control.new()
	attention_blocker.size = Vector2(800, 800)
	attention_blocker.set_meta("allow_camera_drag", true)
	get_root().add_child(attention_blocker)
	global_state.set_scroll_impossible(attention_blocker)

	camera._input(press)
	_expect(camera.dragging, "middle-button camera drag must start over attention blocker")

	get_root().add_child(camera)
	attention_blocker.position = Vector2(100, 100)
	press.global_position = Vector2(150, 150)
	camera.dragging = false
	camera._input(press)
	_expect(camera.dragging, "middle-button camera drag must start over attention blocker in world coordinates")
	get_root().remove_child(camera)

	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_UP
	wheel.pressed = true
	var orig_zoom = camera.target_zoom
	camera._input(wheel)
	_expect(camera.target_zoom == orig_zoom, "wheel zoom must remain blocked over attention")

	global_state.set_scroll_possible(attention_blocker)
	attention_blocker.queue_free()
	camera.free()
