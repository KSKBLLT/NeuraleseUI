extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	var project_scene = load("res://scenes/project.tscn").instantiate()
	root.add_child(project_scene)
	await process_frame

	var graph_window = project_scene.get_node_or_null("WIN_GRAPH")
	var palette = project_scene.get_node_or_null("WIN_GRAPH/NodePalette")
	_expect(graph_window != null, "graph window must exist")
	_expect(palette is CanvasLayer, "graph window must contain the node palette canvas")
	if graph_window == null or palette == null:
		_finish(project_scene)
		return

	await _test_palette_matches_add_graph_order(project_scene, palette)
	await _test_training_pipeline_nodes_are_not_user_creatable(project_scene)
	_test_existing_input_suppression_rule(project_scene)
	await _test_unchanged_catalog_keeps_palette_items(palette)
	var global_state := root.get_node_or_null("glob")

	graph_window._window_hide()
	_expect(not palette.visible, "palette must hide together with the Graphs window")
	_expect(
		global_state == null or global_state.splines_layer == null or not global_state.splines_layer.visible,
		"graph spline layer must hide with the Graphs window"
	)
	_expect(
		global_state == null or global_state.top_splines_layer == null or not global_state.top_splines_layer.visible,
		"top graph spline layer must hide with the Graphs window"
	)

	graph_window._window_show()
	_expect(palette.visible, "palette must return together with the Graphs window")
	_expect(
		global_state == null or global_state.splines_layer == null or global_state.splines_layer.visible,
		"graph spline layer must return with the Graphs window"
	)
	_expect(
		global_state == null or global_state.top_splines_layer == null or global_state.top_splines_layer.visible,
		"top graph spline layer must return with the Graphs window"
	)

	var worlds_window = load("res://scenes/net_tab.tscn").instantiate()
	var worlds_canvas = worlds_window.get_node_or_null("CanvasLayer")
	_expect(worlds_canvas is CanvasLayer, "Worlds window must expose its canvas")
	worlds_window.window_hide()
	_expect(
		worlds_canvas != null and not worlds_canvas.visible,
		"a detached Worlds window must hide before it is attached to the application tree"
	)
	root.add_child(worlds_window)
	await process_frame
	_expect(
		worlds_canvas != null and not worlds_canvas.visible,
		"Worlds must remain hidden after it enters the application tree"
	)
	worlds_window.queue_free()

	_finish(project_scene)


func _test_palette_matches_add_graph_order(project_scene: Node, palette: CanvasLayer) -> void:
	var add_graph = project_scene.get_node_or_null("WIN_GRAPH/menus/add_graph")
	_expect(add_graph != null, "Add Graph menu must exist")
	_expect(
		add_graph != null and add_graph.has_method("ordered_creation_type_ids"),
		"Add Graph must expose its canonical type order"
	)
	_expect(
		palette.has_method("entry_type_ids"),
		"node palette must expose the type order it renders"
	)
	var graph_manager = root.get_node_or_null("graphs")
	_expect(
		graph_manager != null and graph_manager.model_updated.is_connected(palette._on_model_updated),
		"node palette must rebuild after an input is registered to a model"
	)
	if (
		add_graph == null
		or not add_graph.has_method("ordered_creation_type_ids")
		or not palette.has_method("entry_type_ids")
	):
		return

	add_graph._showing()
	await process_frame
	await process_frame
	var rendered_type_ids: Array[StringName] = []
	for button in add_graph._contained:
		rendered_type_ids.append(StringName(button.hint))
	_expect(
		palette.entry_type_ids() == rendered_type_ids,
		"node palette order and contents must exactly match Add Graph"
	)
	await process_frame


func _test_existing_input_suppression_rule(project_scene: Node) -> void:
	var add_graph = project_scene.get_node_or_null("WIN_GRAPH/menus/add_graph")
	_expect(
		add_graph != null and add_graph.has_method("should_hide_input_creation"),
		"Add Node must expose its input availability rule"
	)
	if add_graph == null or not add_graph.has_method("should_hide_input_creation"):
		return
	_expect(
		add_graph.should_hide_input_creation(false, true),
		"single-input mode must hide input node types after an input exists"
	)
	_expect(
		not add_graph.should_hide_input_creation(false, false),
		"single-input mode must keep input node types available before an input exists"
	)
	_expect(
		not add_graph.should_hide_input_creation(true, true),
		"multi-input mode must keep input node types available"
	)


func _test_training_pipeline_nodes_are_not_user_creatable(project_scene: Node) -> void:
	var add_graph = project_scene.get_node_or_null("WIN_GRAPH/menus/add_graph")
	if add_graph == null or not add_graph.has_method("ordered_creation_type_ids"):
		return

	var type_ids: Array[StringName] = add_graph.ordered_creation_type_ids()
	for internal_type in [
		&"output_map",
	]:
		_expect(
			not type_ids.has(internal_type),
			"training pipeline node %s must stay out of Add Node and the left palette" % internal_type
		)
	await process_frame


func _test_unchanged_catalog_keeps_palette_items(palette: CanvasLayer) -> void:
	var items = palette.get_node_or_null("Root/Panel/Content/Scroll/Items")
	_expect(items != null and items.get_child_count() > 0, "node palette must render catalog items")
	if items == null or items.get_child_count() == 0:
		return

	var first_item := items.get_child(0)
	palette.rebuild()
	await process_frame
	await process_frame
	_expect(
		is_instance_valid(first_item) and items.get_child(0) == first_item,
		"an unchanged graph catalog must not recreate palette items or reset scrolling"
	)


func _finish(project_scene: Node) -> void:
	project_scene.queue_free()
	await process_frame
	if failures.is_empty():
		print("PASS test_node_palette_window_visibility: 8 cases")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
