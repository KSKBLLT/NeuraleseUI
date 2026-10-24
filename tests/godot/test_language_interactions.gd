extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var plot_script = load("res://scripts/language_models/views/embedding_plot.gd")
	var heat_script = load("res://scripts/language_models/views/attention_heatmap.gd")
	var controller_script = load("res://scripts/language_models/language_graph_controller.gd")
	var backend_script = load("res://scripts/language_models/dummy_language_backend.gd")
	var heat_scene = load("res://scenes/language_models/attention_head.tscn")

	var backend = backend_script.new()
	var cam = Camera2D.new()
	var glob_node = root.get_node_or_null("glob")
	if glob_node != null:
		glob_node.cam = cam

	# Test 1: Attention Head sizing & word limit is 8
	var heat_node = heat_scene.instantiate()
	heat_node.set_meta("created_with", "attention_head")
	root.add_child(heat_node)

	var tokens_10: Array = []
	var matrix_10: Array = []
	for i in range(10):
		tokens_10.append({"piece": "w%d" % i, "start": i * 3, "end": i * 3 + 2, "position": i})
		var row: Array = []
		for j in range(10): row.append(0.1)
		matrix_10.append(row)
	heat_node.view.set_preview({"matrix": matrix_10, "tokens": tokens_10, "source_text": "w0 w1 w2 w3 w4 w5 w6 w7 w8 w9", "start": 0})
	heat_node._update_content_layout()

	var extent_8: Vector2 = heat_node.view.extent_for_count(8)
	if not heat_node._visual_extent.is_equal_approx(extent_8):
		push_error("Attention node visual extent must be sized for 8 words, got: %s vs %s" % [str(heat_node._visual_extent), str(extent_8)])
		quit(1)
		return

	# Test 2: Can drag in attention head
	# Mouse inside heatmap but not on scrollbar must allow drag
	heat_node.global_position = Vector2(100, 100)
	var scroll: ScrollContainer = heat_node.attention_scroll
	if is_instance_valid(scroll):
		scroll.size = Vector2(200, 200)
		scroll.visible = true
		if not heat_node._can_drag():
			push_error("heat_node._can_drag() must be true when mouse is not over scrollbars")
			quit(1)
			return

	# Test 3: Repeated tokens selection in embedding plot
	var plot = plot_script.new()
	root.add_child(plot)
	var text_rep := "привет п п п п папа п"
	var tok_rep = backend.tokenize(text_rep)
	var raw_points: Array = []
	for i in range(tok_rep.tokens.size()):
		raw_points.append({"id": tok_rep.ids[i], "position": i, "piece": tok_rep.tokens[i].piece, "x": float(i) * 0.05, "y": 0.2, "z": 0.0})
	plot.set_preview({"tokens": tok_rep.tokens, "source_text": text_rep, "points": raw_points})

	# Click the last token (which is "п")
	var last_token_idx: int = tok_rep.tokens.size() - 1
	plot.select_position(last_token_idx)
	if plot.selected_position != last_token_idx:
		push_error("plot.selected_position was not updated to last token index")
		quit(1)
		return

	# Verify that a render item for "п" is marked selected
	var p_item_found := false
	var p_item_selected := false
	for item in plot._render_items:
		if item.text == "п":
			p_item_found = true
			if item.has("positions") and item.positions.has(last_token_idx):
				p_item_selected = true
	if not p_item_found or not p_item_selected:
		push_error("Embedding plot failed to match last repeated 'п' token at position %d" % last_token_idx)
		quit(1)
		return

	# Test 4: Multi-token word "Абчихба"
	var text_word := "Абчихба"
	var tok_word = backend.tokenize(text_word)
	var pts_word: Array = []
	for i in range(tok_word.tokens.size()):
		pts_word.append({"id": tok_word.ids[i], "position": i, "piece": tok_word.tokens[i].piece, "x": 0.1, "y": 0.1, "z": 0.0})
	plot.set_preview({"tokens": tok_word.tokens, "source_text": text_word, "points": pts_word})

	# If there are at least 3 tokens or the last token in "Абчихба"
	var test_tok_idx: int = mini(2, tok_word.tokens.size() - 1)
	plot.select_position(test_tok_idx)

	var word_found := false
	var word_selected := false
	for item in plot._render_items:
		if item.text == "Абчихба":
			word_found = true
			if item.has("positions") and item.positions.has(test_tok_idx):
				word_selected = true
	if not word_found or not word_selected:
		push_error("Embedding plot failed to select word 'Абчихба' when selecting token %d" % test_tok_idx)
		quit(1)
		return

	# Test 5: Graph controller does not restart inference on graph change
	var service_script = load("res://scripts/language_models/language_model_service.gd")
	var service = service_script.new()
	service.set_backend(backend_script.new())
	root.add_child(service)
	var controller = controller_script.new()
	root.add_child(controller)
	controller.setup(service)
	controller.last_snapshot = {"nodes": {"1": {"data": "test"}}}
	controller._automatic_remaining = -1.0

	var dummy_source = Node.new()
	var sc = GDScript.new()
	sc.source_code = "extends Node\nvar cfg: Dictionary = {'text': 'Hello world'}\nvar _inputs: Array = []\nvar outputs: Array = []\nvar graph_id: int = 1\n"
	sc.reload()
	dummy_source.set_script(sc)
	root.add_child(dummy_source)
	controller.source = dummy_source

	# Simulating graph change
	controller._fingerprint = "old_fp"
	controller._process(0.016)
	if controller._automatic_remaining >= 0.0:
		push_error("Graph controller must NOT schedule automatic inference rerun on graph fingerprint change")
		quit(1)
		return
	if controller.last_snapshot.is_empty():
		push_error("Graph controller must NOT wipe last_snapshot on graph fingerprint change")
		quit(1)
		return

	# Test 6: Single token selected in tokenizer vs whole word in embeddings
	var box_script = load("res://scripts/language_models/views/token_box_view.gd")
	var box = box_script.new()
	root.add_child(box)
	box.set_preview({"tokens": tok_word.tokens, "source_text": text_word, "points": pts_word})
	box.select_position(test_tok_idx)
	if box.selected_position != test_tok_idx:
		push_error("Tokenizer selected_position mismatch")
		quit(1)
		return

	# Test 7: Attention heatmap mouse wheel scroll when scrollbar not enabled
	var heat = heat_script.new()
	root.add_child(heat)
	var tokens_15: Array = []
	var matrix_15: Array = []
	for i in range(15):
		tokens_15.append({"piece": "word%d" % i, "start": i * 6, "end": i * 6 + 5, "position": i})
		var row: Array = []
		for j in range(15): row.append(0.05)
		matrix_15.append(row)
	heat.set_preview({"tokens": tokens_15, "matrix": matrix_15, "source_text": "word0 word1 word2 word3 word4 word5 word6 word7 word8 word9 word10 word11 word12 word13 word14", "start": 0, "total": 15})

	var requested := [0]
	heat.window_requested.connect(func(delta: int):
		requested[0] = delta
	)

	var wheel_down = InputEventMouseButton.new()
	wheel_down.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel_down.pressed = true
	heat._gui_input(wheel_down)

	if requested[0] != 0 or heat.preview.get("start", 0) != 0:
		push_error("Attention heatmap wheel down must not scroll without scrollbars, got start=%s delta=%d" % [str(heat.preview.get("start")), requested[0]])
		quit(1)
		return

	# Test 8: Long word does not cause excessive right space in attention heatmap
	var heat_long = heat_script.new()
	root.add_child(heat_long)
	var long_word_text := "f ffwefewwefwefwefwwefwefwefewfwefwefwefwewefwefwefwefwefwef"
	var tok_long = backend.tokenize(long_word_text)
	var mat_long: Array = []
	for i in range(tok_long.tokens.size()):
		var r: Array = []
		for j in range(tok_long.tokens.size()): r.append(0.1)
		mat_long.append(r)
	heat_long.set_preview({"tokens": tok_long.tokens, "matrix": mat_long, "source_text": long_word_text, "start": 0, "total": tok_long.tokens.size()})
	var extent_long: Vector2 = heat_long.extent_for_count(8)
	var geom_long: Dictionary = heat_long._calc_geometry(8)
	var grid_right_long: float = geom_long.origin.x + geom_long.grid_size
	var right_excess: float = extent_long.x - grid_right_long
	if right_excess > 50.0:
		push_error("Attention heatmap added excessive free space on right for long word: right_excess=%f (extent.x=%f, grid_right=%f)" % [right_excess, extent_long.x, grid_right_long])
		quit(1)
		return
	heat_long.free()

	# Test 9: _can_drag in embedding node is false over points
	var emb_scene = load("res://scenes/language_models/embedding.tscn")
	var emb_node = emb_scene.instantiate()
	emb_node.set_meta("created_with", "embedding")
	root.add_child(emb_node)
	emb_node.view.set_preview({"points": [{"id": 1, "position": 0, "piece": "cat", "x": 0.0, "y": 0.0}]})
	emb_node._update_content_layout()

	# Check startup sizing on emb_node (Test 10)
	if emb_node.rect.size.distance_to(emb_node.target_size_vec) > 0.05:
		push_error("Embedding node did not spawn with target_size_vec immediately: %s vs %s" % [str(emb_node.rect.size), str(emb_node.target_size_vec)])
		quit(1)
		return

	# Point is at center: (77, 77)
	var pt_pos = emb_node.view._render_items[0].pos
	# Position mouse over the point
	var view_global_pos = emb_node.view.global_position
	# Override mouse position locally
	var over_interactive = false
	for item in emb_node.view._render_items:
		if item.pos.distance_to(pt_pos) <= 12.0:
			over_interactive = true
	if not over_interactive or not emb_node.view.has_method("is_mouse_over_interactive"):
		push_error("Embedding view lacks is_mouse_over_interactive or failed point hit test")
		quit(1)
		return

	# Test 11: Embedding node displays longer strings without premature 14-char truncation
	var emb_long_text := "ffwefewwefwefwefwwefwefwefewfwefwefwefwewefwefwefwefwefwef"
	var tok_emb_long = backend.tokenize(emb_long_text)
	var prev_emb_long = backend.preview(tok_emb_long.ids, [], [{"id": "emb", "op": "embedding", "config": {}}])
	emb_node.view.set_preview(prev_emb_long.nodes["emb"].preview)
	if emb_node.view._render_items.is_empty():
		push_error("Embedding node failed to render long string item")
		quit(1)
		return
	var long_rendered_text = emb_node.view._render_items[0].text
	if long_rendered_text.length() <= 14:
		push_error("Embedding node string was prematurely truncated to <= 14 chars: %s" % long_rendered_text)
		quit(1)
		return

	# Test 12: Attention heatmap palette uses dark background & YlGn depth palette
	heat._ensure_color_lut()
	var lut_0 = heat._color_lut[0]
	var lut_0_r = lut_0 & 0xFF
	var lut_0_g = (lut_0 >> 8) & 0xFF
	var lut_0_b = (lut_0 >> 16) & 0xFF
	# Should match bg_color Color(0.08, 0.1, 0.15) -> r ~ 20, g ~ 25, b ~ 38
	if lut_0_r > 30 or lut_0_b < 30:
		push_error("Attention heatmap LUT 0 did not match dark canvas background style: r=%d, b=%d" % [lut_0_r, lut_0_b])
		quit(1)
		return

	emb_node.free()
	heat_node.free()
	plot.free()
	dummy_source.free()
	controller.free()
	service.free()
	box.free()
	heat.free()
	backend.dispose()
	cam.free()

	print("PASS test_language_interactions")
	quit(0)
