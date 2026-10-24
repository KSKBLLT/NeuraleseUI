extends Node2D

const NodeCatalog = preload("res://scripts/generated/node_catalog.gd")
const UICaptureCore = preload("res://scripts/ui_capture.gd")

func _enter_tree() -> void:
	glob.base_node = self

var importance_chain: Array[StringName] = NodeCatalog.load_order()


func generate_node_icons_from_cli() -> void:
	var output_dir := ""
	var type_names: Array = []
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--node-icons-output="):
			output_dir = argument.trim_prefix("--node-icons-output=").strip_edges()
		elif argument.begins_with("--node-icon-types="):
			for type_name in argument.trim_prefix("--node-icon-types=").split(",", false):
				type_names.append(StringName(type_name.strip_edges()))

	var result: Dictionary = await graphs.generate_previews(type_names, output_dir)
	print("NODE_ICON_GENERATION %s" % JSON.stringify(result))
	var errors: Variant = result.get("errors", PackedStringArray(["Generator returned no status."]))
	get_tree().quit(0 if errors.is_empty() else 1)


func generate_ui_captures_from_cli() -> void:
	var node_paths: PackedStringArray = []
	var output_dir := "res://ui_captures"
	var single_output := ""
	var padding := 12.0
	var render_scale := 1.0
	var alpha_mode := "preserve"
	var matte_alpha := 0.5
	var graph_type := ""
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--ui-capture-node="):
			node_paths.append(argument.trim_prefix("--ui-capture-node=").strip_edges())
		elif argument.begins_with("--ui-capture-output-dir="):
			output_dir = argument.trim_prefix("--ui-capture-output-dir=").strip_edges()
		elif argument.begins_with("--ui-capture-output="):
			single_output = argument.trim_prefix("--ui-capture-output=").strip_edges()
		elif argument.begins_with("--ui-capture-padding="):
			padding = maxf(0.0, argument.trim_prefix("--ui-capture-padding=").to_float())
		elif argument.begins_with("--ui-capture-scale="):
			render_scale = maxf(1.0, argument.trim_prefix("--ui-capture-scale=").to_float())
		elif argument.begins_with("--ui-capture-alpha-mode="):
			alpha_mode = argument.trim_prefix("--ui-capture-alpha-mode=").strip_edges().to_lower()
		elif argument.begins_with("--ui-capture-matte-alpha="):
			matte_alpha = clampf(
				argument.trim_prefix("--ui-capture-matte-alpha=").to_float(),
				0.01,
				1.0
			)
		elif argument.begins_with("--ui-capture-graph="):
			graph_type = argument.trim_prefix("--ui-capture-graph=").strip_edges()

	var generated: PackedStringArray = []
	var errors: PackedStringArray = []
	if node_paths.is_empty():
		errors.append("At least one --ui-capture-node is required.")
	if not single_output.is_empty() and node_paths.size() != 1:
		errors.append("--ui-capture-output can only be used with one node path.")

	for requested_path in node_paths:
		if not errors.is_empty() and not single_output.is_empty():
			break
		var output_path := single_output
		if output_path.is_empty():
			var filename_source := requested_path
			if not graph_type.is_empty():
				filename_source = "%s_%s" % [graph_type, requested_path]
			output_path = output_dir.path_join("%s.png" % _ui_capture_filename(filename_source))
		var options := {
			"padding": padding,
			"render_scale": render_scale,
			"alpha_mode": alpha_mode,
			"matte_alpha": matte_alpha,
		}
		var result: Dictionary
		if graph_type.is_empty():
			var target := _resolve_ui_capture_target(requested_path)
			if not is_instance_valid(target):
				errors.append("UI capture target is not a Control: %s" % requested_path)
				continue
			result = await ui.capture_control(target, output_path, options)
		else:
			result = await graphs.capture_graph_control(
				StringName(graph_type),
				requested_path,
				output_path,
				options
			)
		if bool(result.get("ok", false)):
			generated.append(str(result.get("path", output_path)))
		else:
			errors.append("%s: %s" % [requested_path, result.get("error", "capture failed")])

	var status := {"generated": generated, "errors": errors}
	print("UI_CAPTURE_GENERATION %s" % JSON.stringify(status))
	get_tree().quit(0 if errors.is_empty() else 1)


func _resolve_ui_capture_target(requested_path: String) -> Control:
	return UICaptureCore.resolve_control(self, requested_path)


func _ui_capture_filename(node_path: String) -> String:
	var filename := node_path.strip_edges().replace("\\", "_").replace("/", "_")
	filename = filename.replace(":", "_").replace(" ", "_")
	while filename.begins_with("_"):
		filename = filename.trim_prefix("_")
	return filename if not filename.is_empty() else "ui-element"

func _ready() -> void:
	if glob.RUN_TESTS_DEBUG_ONLY:
		print("Starting automated test suite from Godot Editor...")
		const TestRunner = preload("res://scripts/run_all_tests.gd")
		TestRunner.run_all_tests(get_tree())





func _process(delta: float) -> void:
	pass
	#if Input.is_action_just_pressed("ui_accept"):
		#var compressed = glob.compress_dict_gzip({"train": 1, 
		#"session": "neriqward", 
		#"graph": graphs.get_syntax_tree(graphs._input_origin_graph)})
		##("fjfjf")
		#var a = sockets.connect_to("ws/train", train_state_received)
			#
		#a.connected.connect(func():
			#a.send(compressed))
		#a.closed.connect(print)
		
