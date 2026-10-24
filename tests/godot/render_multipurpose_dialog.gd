extends SceneTree

func _initialize() -> void:
	call_deferred("_render")


func _render() -> void:
	DisplayServer.window_set_size(Vector2i(1000, 700))
	var background := ColorRect.new()
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.color = Color(0.12, 0.12, 0.12, 1.0)
	root.add_child(background)

	var manager = root.get_node("ui")
	var global_state = root.get_node("glob")
	if manager.topr == null:
		manager.topr = Control.new()
		manager.add_child(manager.topr)
	global_state.tree_windows.erase("env")
	global_state.window_size = Vector2(1000, 700)

	manager.show_dialog({
		"id": "render_test",
		"title": "Update available",
		"body": "Version **1.0.8** is ready to download.\n\n- Faster startup\n- More reliable local runtime\n\nRead the [release notes](https://example.com).",
		"format": "markdown",
		"icon_path": "res://game_assets/icons/download.png",
		"size": {"width": 520, "height": 380},
		"dismiss_on_outside_click": false,
		"progress": {
			"visible": true,
			"value": 42.5,
			"status": "Downloading update",
			"detail": "51.0 MB of 120.0 MB",
		},
		"buttons": [
			{"id": "later", "text": "Later", "style": "secondary"},
			{"id": "download", "text": "Download", "style": "primary"}
		]
	})

	for _frame in 90:
		await process_frame
	var image := root.get_texture().get_image()
	var output_path := OS.get_temp_dir().path_join("neuralese-multipurpose-dialog.png")
	var error := image.save_png(output_path)
	if error == OK:
		print("PASS render_multipurpose_dialog: %s" % output_path)
		quit(0)
		return
	push_error("Could not save dialog render: %s" % error_string(error))
	quit(1)
