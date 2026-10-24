extends Node

const LanguageAdapter = preload("res://scripts/language_models/language_graph_adapter.gd")
const SelectVocabulary = preload("res://scripts/select_vocabulary.gd")

var failures: Array[String] = []


func _ready() -> void:
	for frame in 15:
		await get_tree().process_frame
	await _run_tests()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error("FAIL: " + message)


func _run_tests() -> void:
	print("[1/6] Deleting existing graphs...")
	await graphs.delete_all()
	print("[2/6] Testing visual & structural parity with classifier_graph.tscn...")
	await _test_visual_and_structural_parity_with_classifier()
	print("[3/6] Testing general-purpose numeric network & presets...")
	await _test_general_purpose_numeric_network_and_presets()
	print("[4/6] Testing select_vocabulary splash menu...")
	await _test_select_vocabulary_splash_menu()
	print("[5/6] Testing training chain binding & disable logic...")
	await _test_training_chain_binding_and_disable()
	print("[6/7] Testing language trace & top_n resizing...")
	await _test_language_trace_and_top_n_resizing()
	await _test_small_real_probabilities_keep_their_order()
	print("[7/7] Testing node lifecycle and autosave safety...")
	await _test_node_lifecycle_and_autosave_safety()

	if "--capture-top-output" in OS.get_cmdline_user_args() and DisplayServer.get_name() != "headless":
		print("[capture] Rendering visual verification screenshots...")
		await _capture_visual_verification()

	if failures.is_empty():
		print("PASS test_top_output_node")
		get_tree().quit(0)
	else:
		get_tree().quit(1)

func _test_small_real_probabilities_keep_their_order() -> void:
	await graphs.delete_all()
	var node = graphs.get_graph(&"token_labels")
	var scores: Array = []
	scores.resize(20); scores.fill(0.0)
	scores[19] = 0.9999995
	scores[12] = 0.0000005
	node.apply_language_trace({"preview":{"scores":scores,"labels":{"19":"end","12":"small","0":"zero"}}})
	_expect(node.units[0].get_node("Label").text == "end" and node.units[1].get_node("Label").text == "small", "Small real probabilities must rank above zero, without approximate ties")


func _test_visual_and_structural_parity_with_classifier() -> void:
	await graphs.delete_all()
	var clf: Graph = graphs.get_graph(&"classifier")
	var top_out: Graph = graphs.get_graph(&"token_labels")
	clf.position = Vector2(200, 200)
	top_out.position = Vector2(450, 200)
	for i in 5:
		clf.add_unit({"text": "label_%d" % i}, true)
	for frame in 5:
		await get_tree().process_frame

	_expect(top_out is OutputGraph, "token_labels must inherit OutputGraph (classifier.gd)")
	_expect(top_out is TopOutputGraph, "token_labels must be a TopOutputGraph instance")
	_expect(top_out.server_typename == &"ClassifierNode", "token_labels server_typename must be ClassifierNode")
	_expect(top_out.is_head, "token_labels must have is_head = true")
	_expect(top_out.units.size() == 5, "token_labels must spawn 5 DynamicGraphUnit rows by default")

	# Frame / ColorRect shader & geometry parity
	_expect(top_out.rect.material == clf.rect.material, "ColorRect material must match classifier_graph.tscn")
	_expect(is_equal_approx(top_out.rect.size.x, clf.rect.size.x), "ColorRect width must match classifier_graph.tscn (169px)")
	for param in [&"outline_color", &"tuning", &"corner_radius_width_add"]:
		var a = top_out.rect.get_instance_shader_parameter(param)
		var b = clf.rect.get_instance_shader_parameter(param)
		_expect(a == b, "ColorRect shader parameter %s must match classifier_graph.tscn: %s vs %s" % [param, str(a), str(b)])

	# Header LineEdit parity
	var clf_header: LineEdit = clf.get_node("ColorRect/root/Label")
	var top_header: LineEdit = top_out.get_node("ColorRect/root/Label")
	_expect(top_header.theme == clf_header.theme, "Header theme must match classifier_graph.tscn")
	_expect(top_header.scale.is_equal_approx(clf_header.scale), "Header scale must match classifier_graph.tscn")
	_expect(top_header.position.is_equal_approx(clf_header.position), "Header position must match classifier_graph.tscn")
	_expect(top_header.get_theme_color("font_color").is_equal_approx(clf_header.get_theme_color("font_color")), "Header font_color must match classifier_graph.tscn")
	_expect(top_header.get_theme_color("font_placeholder_color").is_equal_approx(clf_header.get_theme_color("font_placeholder_color")), "Header font_placeholder_color must match classifier_graph.tscn")
	_expect(top_header.get_theme_font_size("font_size") == clf_header.get_theme_font_size("font_size"), "Header font_size must match classifier_graph.tscn")
	_expect(top_out.get_title() == "BestAnswer", "Default title fallback must be 'BestAnswer', got '%s'" % top_out.get_title())

	# Unit cards parity
	for i in 5:
		var u_top: Control = top_out.units[i]
		var u_clf: Control = clf.units[i]
		_expect(u_top is DynamicGraphUnit, "Unit %d must be DynamicGraphUnit" % i)
		_expect(u_top.size.is_equal_approx(u_clf.size), "Unit %d size must match classifier unit" % i)
		_expect(is_equal_approx(u_top.position.y, u_clf.position.y), "Unit %d y position must match classifier unit: %s vs %s" % [i, u_top.position.y, u_clf.position.y])
		_expect(u_top.get_node("ColorRect").material == u_clf.get_node("ColorRect").material, "Unit %d panel material must match classifier unit" % i)

	# Input port parity
	var clf_port: Connection = clf._inputs[0]
	var top_port: Connection = top_out._inputs[0]
	_expect(top_port.color.is_equal_approx(clf_port.color), "Input port color must match classifier_graph.tscn")
	_expect(top_port.gradient_color.is_equal_approx(clf_port.gradient_color), "Input port gradient_color must match classifier_graph.tscn")
	_expect(top_port.position.is_equal_approx(clf_port.position), "Input port position must match classifier_graph.tscn")

	# Footer button parity
	var clf_btn: BlockComponent = clf.add_button
	var top_btn: BlockComponent = top_out.add_button
	_expect(top_btn.material == clf_btn.material, "Footer button material must match classifier_graph.tscn")
	_expect(top_btn.scale.is_equal_approx(clf_btn.scale), "Footer button scale must match classifier_graph.tscn")
	_expect(top_btn.base_size.is_equal_approx(Vector2(112, 42)), "Footer button base_size must be widened to (112, 42)")


func _test_general_purpose_numeric_network_and_presets() -> void:
	await graphs.delete_all()
	var inp: Graph = graphs.get_graph(&"input_1d")
	var dense: Graph = graphs.get_graph(&"layer")
	var smax: Graph = graphs.get_graph(&"softmax")
	var top_out: Graph = graphs.get_graph(&"top_output")
	_expect(is_instance_valid(top_out), "graphs.get_graph('top_output') alias must instantiate TopOutputGraph")

	dense.update_config({"neuron_count": 10})
	for frame in 3:
		await get_tree().process_frame

	_expect(inp.outputs[0].connect_to(dense.input_keys[1]), "input_1d -> layer connection failed")
	_expect(dense.outputs[0].connect_to(smax._inputs[0]), "layer -> softmax connection failed")
	_expect(smax.outputs[0].connect_to(top_out._inputs[0]), "softmax -> top_output numeric connection must succeed")

	_expect(not LanguageAdapter.is_language(inp), "Numeric network with top_output must not be classified as a language graph")
	_expect(not LanguageAdapter.is_language(top_out), "top_output in numeric network must not be classified as a language graph")

	var syntax_tree: Dictionary = graphs.get_syntax_tree(inp)
	_expect(not syntax_tree.is_empty(), "Numeric syntax tree must serialize cleanly with top_output")

	# Push 10-class probability distribution
	var probs := [0.02, 0.03, 0.42, 0.05, 0.01, 0.23, 0.04, 0.12, 0.06, 0.02]
	top_out.push_values(probs, true)
	for frame in 2:
		await get_tree().process_frame

	# Expected top-5 indices: 2 (0.42), 5 (0.23), 7 (0.12), 8 (0.06), 3 (0.05)
	_expect(is_equal_approx(top_out.units[0]._target_weight, 0.42), "Slot 0 weight must be 0.42")
	_expect(is_equal_approx(top_out.units[1]._target_weight, 0.23), "Slot 1 weight must be 0.23")
	_expect(is_equal_approx(top_out.units[2]._target_weight, 0.12), "Slot 2 weight must be 0.12")
	_expect(is_equal_approx(top_out.units[3]._target_weight, 0.06), "Slot 3 weight must be 0.06")
	_expect(is_equal_approx(top_out.units[4]._target_weight, 0.05), "Slot 4 weight must be 0.05")
	_expect(is_equal_approx(top_out.other_mass, 0.12), "other_mass must equal 0.12 (got %s)" % top_out.other_mass)
	_expect("\n12.0%" in top_out.get_node("input/OtherLabel").text, "OtherLabel must display \\n12.0%")

	# Automatic dataset resolution from DatasetName node in the graph
	var ds_node: Graph = graphs.get_graph(&"dataset")
	ds_node.cfg["name"] = "cifar10"
	top_out._refresh_display()
	for frame in 2:
		await get_tree().process_frame

	var expected_cifar := ["bird", "dog", "horse", "ship", "cat"]
	for i in 5:
		var actual_lbl: String = top_out.units[i].get_node("Label").text
		_expect(actual_lbl == expected_cifar[i], "Auto dataset CIFAR-10 slot %d expected '%s', got '%s'" % [i, expected_cifar[i], actual_lbl])
	ds_node.delete()
	for frame in 2:
		await get_tree().process_frame

	# Apply CIFAR-10 preset explicitly
	top_out.apply_vocabulary_selection({
		"preset": "cifar10",
		"label_names": SelectVocabulary.BUILTIN_LABEL_SETS["cifar10"],
	})
	for frame in 2:
		await get_tree().process_frame

	for i in 5:
		var actual_lbl: String = top_out.units[i].get_node("Label").text
		_expect(actual_lbl == expected_cifar[i], "CIFAR-10 slot %d expected '%s', got '%s'" % [i, expected_cifar[i], actual_lbl])

	# Apply Iris 3-class preset (< 5 classes)
	top_out.apply_vocabulary_selection({
		"preset": "iris",
		"label_names": SelectVocabulary.BUILTIN_LABEL_SETS["iris"],
	})
	top_out.push_values([0.15, 0.75, 0.10], true)
	for frame in 2:
		await get_tree().process_frame

	_expect(top_out.units[0].get_node("Label").text == "versicolor", "Iris slot 0 must be 'versicolor'")
	_expect(top_out.units[1].get_node("Label").text == "setosa", "Iris slot 1 must be 'setosa'")
	_expect(top_out.units[2].get_node("Label").text == "virginica", "Iris slot 2 must be 'virginica'")
	_expect(top_out.units[3].get_node("Label").text == "—", "Iris slot 3 must be '—' when class count < top_n")
	_expect(top_out.units[4].get_node("Label").text == "—", "Iris slot 4 must be '—' when class count < top_n")
	_expect(is_equal_approx(top_out.other_mass, 0.0), "other_mass must be 0.0 when all 3 classes are shown")


func _clear_startup_splashes() -> void:
	ui.close_top_level_splashes()
	for s in ui.splashed.keys():
		if is_instance_valid(s):
			s.hide()
	ui.splashed.clear()
	ui.splashed_in.clear()
	ui._active_splashed = false


func _click_block_button(btn: BlockComponent, host_graph: Graph = null) -> void:
	btn.press(0.04)
	var guard := 0
	while (btn.press_request or btn.ins_request or btn.state.pressing) and guard < 120:
		if is_instance_valid(host_graph):
			host_graph.hold_for_frame()
		await get_tree().process_frame
		guard += 1
	for frame in 6:
		if is_instance_valid(host_graph):
			host_graph.hold_for_frame()
		await get_tree().process_frame


func _test_select_vocabulary_splash_menu() -> void:
	await graphs.delete_all()
	_clear_startup_splashes()
	glob.base_node.get_node("WIN_GRAPH").window_show()
	glob.fg.show()
	var top_out: Graph = graphs.get_graph(&"token_labels")
	for frame in 5:
		top_out.hold_for_frame()
		await get_tree().process_frame

	# When 0 complete training chains exist, button must be ENABLED
	_expect(top_out.add_button.mouse_filter == Control.MOUSE_FILTER_STOP, "0 chains: Vocab button mouse_filter must be STOP")
	_expect(is_equal_approx(top_out.add_button.modulate.a, 1.0), "0 chains: Vocab button alpha must be 1.0")

	# 1. Press-and-release the real "Словарь" / "Vocab" BlockComponent button on TopOutputGraph
	await _click_block_button(top_out.add_button, top_out)

	_expect(ui.is_splashed("select_vocabulary"), "Clicking Vocab button must open select_vocabulary splash via ui.splash_and_get_result")
	_expect(top_out.add_button.in_splash, "add_button.in_splash must be true while select_vocabulary is open")
	var vocab_scene: SplashMenu = ui.get_splash("select_vocabulary")
	_expect(is_instance_valid(vocab_scene), "ui.get_splash('select_vocabulary') must return the active SplashMenu")

	if is_instance_valid(vocab_scene):
		var ds_scene: Control = load("res://scenes/select_dataset.tscn").instantiate()
		add_child(ds_scene)
		await get_tree().process_frame
		var ds_rect: ColorRect = ds_scene.get_node("ColorRect")
		var vocab_rect: ColorRect = vocab_scene.get_node("ColorRect")
		_expect(vocab_rect.material == ds_rect.material, "select_vocabulary ColorRect material must match select_dataset.tscn")
		_expect(vocab_rect.size.is_equal_approx(ds_rect.size), "select_vocabulary ColorRect size must match select_dataset.tscn")
		_expect(vocab_scene.get_node("ColorRect/root/Label").text == "/vocabulary", "select_vocabulary path header must be /vocabulary")
		ds_scene.queue_free()

		var entries: Array = vocab_scene.get_visible_entries()
		_expect(not entries.is_empty(), "select_vocabulary must populate dataset preset cards")
		for item in entries:
			_expect(item is Dictionary, "Item must be a Dictionary")
			var item_id := str(item.get("id", ""))
			_expect(not item_id.begins_with("token:"), "select_vocabulary must NEVER contain raw token cards: " + item_id)
			var txt := str(item.get("text", ""))
			_expect("(выходные классы)" in txt or "(output classes)" in txt, "Card text must have '(выходные классы)' suffix: " + txt)

		vocab_scene.set_query("cifar")
		for frame in 3:
			await get_tree().process_frame
		var filtered: Array = vocab_scene.get_visible_entries()
		_expect(filtered.size() == 1, "select_vocabulary search for 'cifar' must return exactly 1 preset")

		vocab_scene.set_query("")
		for frame in 3:
			await get_tree().process_frame

		# 2. Press-and-release preset:cifar10 card
		var list_comp: BlockComponent = vocab_scene.get_node("ColorRect/list")
		var cifar_card: BlockComponent = list_comp.button_by_hint.get(&"preset:cifar10")
		_expect(is_instance_valid(cifar_card), "ColorRect/list must contain clickable BlockComponent card for preset:cifar10")
		if is_instance_valid(cifar_card):
			await _click_block_button(cifar_card, top_out)

	for frame in 15:
		top_out.hold_for_frame()
		await get_tree().process_frame

	_expect(not ui.is_splashed("select_vocabulary"), "Selecting a preset card must close select_vocabulary splash")
	_expect(not top_out.add_button.in_splash, "add_button.in_splash must reset to false after splash closes")
	_expect(str(top_out.cfg.get("vocab_source", "")) == "cifar10", "Selecting preset:cifar10 must update top_out.cfg['vocab_source'] to 'cifar10'")
	_expect(top_out.units[0].get_node("Label").text == "airplane", "Slot 0 default label after selecting cifar10 must be 'airplane'")


func _test_training_chain_binding_and_disable() -> void:
	await graphs.delete_all()
	_clear_startup_splashes()
	var top_out: Graph = graphs.get_graph(&"token_labels")
	top_out.position = Vector2(700, 200)
	for frame in 5:
		top_out.hold_for_frame()
		await get_tree().process_frame

	# Phase 1: 0 complete training chains -> button is ENABLED
	_expect(top_out.add_button.mouse_filter == Control.MOUSE_FILTER_STOP, "0 chains: button mouse_filter must be STOP")
	_expect(is_equal_approx(top_out.add_button.modulate.a, 1.0), "0 chains: button alpha must be 1.0")

	# Phase 2: Add 1 complete training chain: Dataset(cifar10) -> TrainBegin -> RunModel
	var ds1: Graph = graphs.get_graph(&"dataset")
	ds1.cfg["name"] = "cifar10"
	ds1.position = Vector2(100, 100)
	var tb1: Graph = graphs.get_graph(&"train_begin")
	tb1.position = Vector2(300, 100)
	var rm1: Graph = graphs.get_graph(&"run_model")
	rm1.position = Vector2(500, 100)
	for frame in 3:
		await get_tree().process_frame

	var ds1_out: Connection = null
	for p in ds1.outputs:
		if p.server_name == &"netname":
			ds1_out = p; break
	var tb1_in: Connection = null
	for p in tb1._inputs:
		if p.server_name == &"netname":
			tb1_in = p; break
	_expect(ds1_out != null and tb1_in != null, "Found netname ports for ds1 -> tb1")
	ds1_out.connect_to(tb1_in)

	var tb1_out: Connection = null
	for p in tb1.outputs:
		if p.server_name == &"input_out":
			tb1_out = p; break
	var rm1_in: Connection = null
	for p in rm1._inputs:
		if p.server_name == &"model_in":
			rm1_in = p; break
	_expect(tb1_out != null and rm1_in != null, "Found ports for tb1 -> rm1")
	tb1_out.connect_to(rm1_in)

	for frame in 10:
		await get_tree().process_frame

	# Phase 2 verification: Exactly 1 complete chain -> Button is DISABLED (0.4 alpha), auto-bound to cifar10
	_expect(top_out.add_button.mouse_filter == Control.MOUSE_FILTER_IGNORE, "1 chain: button mouse_filter must be IGNORE")
	_expect(is_equal_approx(top_out.add_button.modulate.a, 0.4), "1 chain: button alpha must be 0.4 (semi-transparent), got %s" % top_out.add_button.modulate.a)
	_expect(top_out.add_button.modulate.r < 0.5, "1 chain: button must be darkened (r < 0.5), got %s" % top_out.add_button.modulate.r)
	_expect(top_out._current_dataset_name == "cifar10", "1 chain: top_out must auto-bind to cifar10")
	_expect(top_out.units[0].get_node("Label").text == "airplane", "1 chain: top_out slot 0 must be 'airplane'")

	# Phase 3: Live dataset change with hold_for_frame without mouse hovering
	glob.ds_change.emit("cifar10")
	for frame in 8:
		await get_tree().process_frame
	_expect(top_out.units[0].get_node("Label").text == "airplane", "Live ds_change: top_out updated slot 0 without mouse hover")

	# Phase 4: Add second complete training chain: Dataset(mnist) -> TrainBegin2 -> RunModel2
	var ds2: Graph = graphs.get_graph(&"dataset")
	ds2.cfg["name"] = "mnist"
	ds2.position = Vector2(100, 350)
	var tb2: Graph = graphs.get_graph(&"train_begin")
	tb2.position = Vector2(300, 350)
	var rm2: Graph = graphs.get_graph(&"run_model")
	rm2.position = Vector2(500, 350)
	for frame in 3:
		await get_tree().process_frame

	var ds2_out: Connection = null
	for p in ds2.outputs:
		if p.server_name == &"netname":
			ds2_out = p; break
	var tb2_in: Connection = null
	for p in tb2._inputs:
		if p.server_name == &"netname":
			tb2_in = p; break
	ds2_out.connect_to(tb2_in)

	var tb2_out: Connection = null
	for p in tb2.outputs:
		if p.server_name == &"input_out":
			tb2_out = p; break
	var rm2_in: Connection = null
	for p in rm2._inputs:
		if p.server_name == &"model_in":
			rm2_in = p; break
	tb2_out.connect_to(rm2_in)

	for frame in 10:
		await get_tree().process_frame

	# Phase 4 verification: >= 2 chains -> Button is ENABLED again, defaults to first created dataset (cifar10)
	_expect(top_out.add_button.mouse_filter == Control.MOUSE_FILTER_STOP, ">= 2 chains: button mouse_filter must be STOP")
	_expect(is_equal_approx(top_out.add_button.modulate.a, 1.0), ">= 2 chains: button alpha must be 1.0")
	_expect(top_out._current_dataset_name == "cifar10", ">= 2 chains: must default to first created dataset (cifar10), not jumping to mnist")

	# Click button: splash must open in chains_only mode, showing ONLY cifar10 and mnist
	await _click_block_button(top_out.add_button, top_out)
	_expect(ui.is_splashed("select_vocabulary"), ">= 2 chains: clicking Vocab button must open select_vocabulary splash")
	var splash2: SplashMenu = ui.get_splash("select_vocabulary")
	_expect(is_instance_valid(splash2), "Splash menu must be valid")
	if is_instance_valid(splash2):
		var splash_entries: Array = splash2.get_visible_entries()
		_expect(splash_entries.size() == 2, "chains_only mode: splash must contain exactly the 2 connected datasets, got %d" % splash_entries.size())
		var has_cifar := false
		var has_mnist := false
		for item in splash_entries:
			var txt := str(item.get("text", ""))
			if "cifar10" in txt: has_cifar = true
			if "mnist" in txt: has_mnist = true
		_expect(has_cifar and has_mnist, "Splash must contain cards for both cifar10 and mnist")

		# Click mnist card
		var list_comp: BlockComponent = splash2.get_node("ColorRect/list")
		var mnist_card: BlockComponent = list_comp.button_by_hint.get(&"preset:mnist")
		_expect(is_instance_valid(mnist_card), "ColorRect/list must contain card for preset:mnist")
		if is_instance_valid(mnist_card):
			await _click_block_button(mnist_card, top_out)

	for frame in 15:
		top_out.hold_for_frame()
		await get_tree().process_frame

	_expect(top_out._current_dataset_name == "mnist", "After clicking mnist card, top_out._current_dataset_name must be 'mnist'")
	_expect(top_out.units[0].get_node("Label").text == "0", "TopAnswer slot 0 must be '0' for mnist")


func _test_language_trace_and_top_n_resizing() -> void:
	await graphs.delete_all()
	var top_out: Graph = graphs.get_graph(&"token_labels")
	for frame in 3:
		await get_tree().process_frame

	var saved_cfg: Dictionary = top_out.get_info().cfg.duplicate(true)
	var scores: Array = []
	scores.resize(8192)
	scores.fill(0.0)
	scores[10] = 0.50
	scores[20] = 0.20
	scores[30] = 0.10
	scores[40] = 0.05
	scores[50] = 0.05
	scores[60] = 0.10

	top_out.apply_language_trace({
		"preview": {
			"scores": scores,
			"selected_id": 10,
			"labels": {10: "cat", 20: "dog", 30: "mat", 40: "sat", 50: "on", 60: "bed"},
		}
	})
	for frame in 2:
		await get_tree().process_frame

	_expect(top_out.get_info().cfg == saved_cfg, "apply_language_trace must not mutate saved cfg")
	_expect(top_out.units[0].get_node("Label").text == "cat", "Language trace top-1 must be 'cat'")
	_expect(is_equal_approx(top_out.other_mass, 0.05), "other_mass with 6 active tokens and top_n=5 must be 0.05")

	var size_5: float = top_out.rect.size.y
	top_out.update_config({"top_n": 10})
	for frame in 2:
		await get_tree().process_frame
	_expect(top_out.units.size() == 10, "update_config({'top_n': 10}) must resize units to 10")
	_expect(is_equal_approx(top_out.rect.size.y - size_5, 5.0 * 45.0), "Resizing top_n from 5 to 10 must grow height by 5 * 45px")

	top_out.update_config({"top_n": 5})
	for frame in 2:
		await get_tree().process_frame
	_expect(top_out.units.size() == 5, "update_config({'top_n': 5}) must restore 5 units")

	top_out.clear_language_trace()
	for frame in 2:
		await get_tree().process_frame
	_expect(top_out.trace.is_empty() and top_out.view.rows.is_empty(), "clear_language_trace must clear trace and active rows")


func _test_node_lifecycle_and_autosave_safety() -> void:
	await graphs.delete_all()
	var top_node: Graph = graphs.get_graph(&"token_labels")
	for frame in 2:
		await get_tree().process_frame
	var gid: int = top_node.graph_id
	_expect(graphs._graphs.has(gid), "New node must be registered in graphs._graphs")
	_expect(graphs._graphs[gid] == top_node, "graphs._graphs[gid] must point to top_node")

	top_node.delete()
	for frame in 5:
		await get_tree().process_frame

	_expect(not graphs._graphs.has(gid), "Deleted TopOutputGraph must be removed from graphs._graphs upon exit_tree")

	# Simulate autosave trigger: must never crash even if any freed node somehow lingered
	nn.request_save()
	var proj_data := glob.get_project_data()
	_expect(proj_data is Dictionary and proj_data.has("graphs"), "Autosave and get_project_data must succeed cleanly")


func _capture_visual_verification() -> void:
	await graphs.delete_all()
	glob.base_node.get_node("WIN_GRAPH").window_show()
	glob.fg.show()
	ui.cl.hide()

	var clf: Graph = graphs.get_graph(&"classifier")
	var top_bpe: Graph = graphs.get_graph(&"token_labels")
	var top_cifar: Graph = graphs.get_graph(&"token_labels")
	clf.position = Vector2(200, 180)
	top_bpe.position = Vector2(440, 180)
	top_cifar.position = Vector2(680, 180)

	var clf_labels := ["cat", "dog", "bird", "horse", "ship"]
	for lbl in clf_labels:
		clf.add_unit({"text": lbl}, true)
	clf.push_values([0.42, 0.23, 0.15, 0.12, 0.08], true)

	var scores: Array = []
	scores.resize(8192)
	scores.fill(0.0)
	scores[260] = 0.42
	scores[265] = 0.23
	scores[270] = 0.12
	scores[275] = 0.06
	scores[280] = 0.05
	scores[285] = 0.12
	top_bpe.apply_language_trace({
		"preview": {
			"scores": scores,
			"selected_id": 260,
			"labels": {260: " floor", 265: " mat", 270: " rug", 275: " bed", 280: " table"},
		}
	})

	top_cifar.apply_vocabulary_selection({
		"preset": "cifar10",
		"label_names": SelectVocabulary.BUILTIN_LABEL_SETS["cifar10"],
	})
	top_cifar.push_values([0.02, 0.03, 0.42, 0.05, 0.01, 0.23, 0.04, 0.12, 0.06, 0.02], true)

	for node in [clf, top_bpe, top_cifar]:
		node._after_process(1.0)
		if node.bottom_attached and is_instance_valid(node.input):
			node.input.position.y = node.target_y + node.input_y_add
		if node.lerp_size and is_instance_valid(node.rect):
			node.rect.size.y = max(node.min_size, node.target_size + node.size_add + node.adding_size_y)
		for unit in node.units:
			unit.modulate.a = 1.0
			node.appear_units.erase(unit)
			unit._visual_weight = unit._target_weight
			unit._apply_weight(unit._visual_weight)

	glob.change_lang("ru")
	for frame in 10:
		await get_tree().process_frame

	var out_dir := "C:/Users/Mike/.gemini/antigravity/brain/095268ef-d090-436a-b2fd-5bff801ed43c/"
	await ui.capture_control(clf, out_dir + "verify_classifier_ru.png", {"padding": 20, "render_scale": 2})
	await ui.capture_control(top_bpe, out_dir + "verify_top_output_bpe_ru.png", {"padding": 20, "render_scale": 2})
	await ui.capture_control(top_cifar, out_dir + "verify_top_output_cifar_ru.png", {"padding": 20, "render_scale": 2})

	var vocab_splash: Control = load("res://scenes/select_vocabulary.tscn").instantiate()
	glob.scale_fg.add_child(vocab_splash)
	for frame in 25:
		await get_tree().process_frame
	await ui.capture_control(vocab_splash.get_node("ColorRect"), out_dir + "verify_select_vocabulary_splash.png", {"padding": 20, "render_scale": 2})
	vocab_splash.queue_free()
	for frame in 3:
		await get_tree().process_frame
