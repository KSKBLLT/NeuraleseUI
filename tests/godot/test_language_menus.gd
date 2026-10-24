extends Node

const Catalog = preload("res://scripts/generated/node_catalog.gd")
var failures: Array[String] = []

func _ready() -> void:
	for frame in 20: await get_tree().process_frame
	_expect(not ResourceLoader.exists("res://scenes/top_output_graph.tscn"), "Obsolete duplicate token-output node must be deleted")
	_expect(not ResourceLoader.exists("res://scenes/language_models/text_output.tscn") and not Catalog.DEFINITIONS.has(&"text_output"), "TextOutput must be removed from scenes and the node catalog")
	var legacy := {1:{"created_with":"softmax","outputs":{"soft_out":[300,200]}},2:{"created_with":"text_output","inputs":{300:"scores_in"},"outputs":{}}}
	var migrated: Dictionary = graphs._migrate_output_map_nodes(legacy)
	_expect(not migrated.has(2) and migrated[1].outputs.soft_out==[200], "Older saved graphs must drop TextOutput and its wires while retaining their other nodes")
	var menu = glob.menus["select_node"]
	get_parent().get_node("WIN_GRAPH/Cta")._on_input_released()
	for frame in 2: await get_tree().process_frame
	_expect(menu._source_names == Catalog.input_types(), "Create Input must offer every registered input, including TextInput")
	menu.show_nodes([], Vector2(300, 200), false)
	for frame in 2: await get_tree().process_frame
	_expect(menu._source_names.is_empty() and menu.button_by_hint.is_empty(), "An explicitly empty replacement list must remain empty")
	menu.show_all_nodes(Vector2(300, 200), false)
	for frame in 2: await get_tree().process_frame
	_expect(menu._source_names.has(&"text_input") and not menu._source_names.has(&"text_output"), "General selector must restore registered language nodes")
	menu.set_node_list([])
	for frame in 2: await get_tree().process_frame
	_expect(menu._source_names.is_empty() and menu.button_by_hint.is_empty(), "Empty set_node_list must not restore the entire catalog")
	menu.clear_node_list()
	for frame in 2: await get_tree().process_frame
	_expect(menu._source_names.has(&"text_input"), "clear_node_list must explicitly restore the catalog")
	menu.menu_hide()
	await graphs.delete_all()
	var numeric = graphs.get_graph(&"input")
	_expect(graphs.get_alt_nodes(numeric).has(&"text_input"), "Numeric input replacement must include TextInput")
	numeric.delete()
	for frame in 3: await get_tree().process_frame
	var source = graphs.get_graph(&"text_input")
	_expect(graphs.get_alt_nodes(source).has(&"input") and graphs.get_alt_nodes(source).has(&"input_1d") and graphs.get_alt_nodes(source).has(&"input_rgb"), "TextInput replacement must offer the other input forms")
	var classifier = graphs.get_graph(&"classifier")
	_expect(graphs.get_alt_nodes(classifier).has(&"token_labels") and not graphs.get_alt_nodes(classifier).has(&"text_output"), "Output replacement must include BestAnswer without TextOutput")
	var output = graphs.get_graph(&"token_labels")
	_expect(graphs.get_alt_nodes(output).has(&"classifier"), "BestAnswer replacement must include the existing label output")
	var begin = graphs.get_graph(&"train_begin")
	var train_label: String = begin.train.text
	await begin.train_start()
	_expect(not begin.training and not begin.delaying, "Text-only project must not leave numeric training in Stop state")
	_expect(begin.get_node("YY").editable and begin.train.text == train_label, "Rejected training must preserve editable controls")
	_expect(graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME) == null, "TextInput must not masquerade as a named numeric model")
	_expect(not nn.check_valid(source, false), "Text graph must stay outside numeric inference")
	source.delete()
	for frame in 3: await get_tree().process_frame
	graphs.get_graph(&"input")
	# Also cover the ordinary disconnected training node: no numeric request
	# should start and its controls must remain usable.
	begin.training = false
	begin.delaying = false
	begin.get_node("YY").editable = true
	begin.train.text = train_label
	await begin.train_start()
	_expect(not begin.training and begin.get_node("YY").editable, "Missing TrainInput must not leave numeric training in Stop state")
	for pair in [[&"input", &"text_input"], [&"text_input", &"input_1d"], [&"classifier", &"token_labels"], [&"token_labels", &"classifier"]]:
		await _replace_and_undo(pair[0], pair[1])
	if failures.is_empty():
		print("PASS test_language_menus")
		get_tree().quit(0)
	else:
		for failure in failures: push_error(failure)
		get_tree().quit(1)

func _expect(condition: bool, message: String) -> void:
	if not condition: failures.append(message)

func _replace_and_undo(from_type: StringName, to_type: StringName) -> void:
	await graphs.delete_all()
	var original = graphs.get_graph(from_type, Graph.Flags.NEW)
	if from_type == &"text_input": original.update_config({"text":"Undo restores my text"})
	for frame in 8: await get_tree().process_frame
	var original_id: int = original.graph_id
	var saved: Dictionary = original.cfg.duplicate(true)
	glob.undo_redo.clear_history()
	var menu = glob.menus["select_node"]
	menu.show_nodes(graphs.get_alt_nodes(original), Vector2(300,200), false, original.delete_call, original.get_center_pos())
	if not menu.button_by_hint.has(to_type):
		_expect(false, "Missing replacement button: " + str(to_type))
		return
	await menu._menu_handle_release(menu.button_by_hint[to_type])
	for frame in 8: await get_tree().process_frame
	_expect(graphs._graphs.size()==1 and _has_type(to_type), "Replacement must leave exactly the chosen node: " + str(to_type))
	glob.undo_redo.undo()
	for frame in 8: await get_tree().process_frame
	_expect(graphs._graphs.size()==1 and graphs._graphs.has(original_id), "Undo must restore the original node: " + str(from_type))
	if graphs._graphs.has(original_id):
		_expect(graphs._graphs[original_id].cfg==saved, "Undo must restore the original configuration: " + str(from_type))
	glob.undo_redo.redo()
	for frame in 8: await get_tree().process_frame
	_expect(graphs._graphs.size()==1 and _has_type(to_type), "Redo must restore the replacement: " + str(to_type))

func _has_type(type_id: StringName) -> bool:
	for node in graphs._graphs.values():
		if is_instance_valid(node) and StringName(node.get_meta("created_with", ""))==type_id: return true
	return false
