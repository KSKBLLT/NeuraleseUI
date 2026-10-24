extends RefCounted
## Real editor scenes and connections; no model files or numeric runtime.
static func build(manager: Node) -> Dictionary:
	var result: Dictionary = {}
	for entry in [["text_input",Vector2(0,200)],["tokenizer",Vector2(285,200)],["embedding",Vector2(600,165)],["concat",Vector2(1230,180)],["layer",Vector2(1490,200)],["softmax",Vector2(1710,200)],["token_labels",Vector2(1920,90)]]:
		var node = manager.get_graph(entry[0])
		node.position=entry[1]
		result[entry[0]]=node
	for i in 4:
		var head = manager.get_graph(&"attention_head")
		head.position=Vector2(940,i*285)
		result["head%d" % i]=head
		result.concat.add_unit({},true)
	result.layer.line_edit.max_value=65536
	result.layer.update_config({"neuron_count":8192})
	for key in ["concat","layer","softmax"]:
		var node=result[key]
		node.set_meta("demo_original_outline",node.base_outline)
		for port in node._inputs+node.outputs:
			port.set_meta("demo_original_colors",[port.color,port.gradient_color])
	_wire(result.text_input,result.tokenizer)
	_wire(result.tokenizer,result.embedding)
	for i in 4:
		_wire(result.embedding,result["head%d" % i])
		var input = result.concat.units[i].get_node("o")
		_output(result["head%d" % i]).connect_to(input)
	_wire(result.concat,result.layer)
	_wire(result.layer,result.softmax)
	_wire(result.softmax,result.token_labels)
	return result

static func _output(node: Node) -> Node:
	for port in node.outputs:
		if not port.config_conn: return port
	return null

static func _wire(from: Node, to: Node) -> void:
	for input in to._inputs:
		if not input.config_conn:
			assert(_output(from).connect_to(input),"Language demo connection rejected")
			return

static func verify_and_capture(tree: SceneTree) -> void:
	# This existing regression fixture tests deterministic UI interactions.
	# Real-model acceptance uses the default ONNX backend in a separate test.
	tree.root.get_node("language_models").set_backend(load("res://scripts/language_models/vocab_language_backend.gd").new())
	if "--language-visual-compare" in OS.get_cmdline_user_args():
		await load("res://scripts/language_models/language_visual_comparison.gd").capture(tree)
		return
	tree.root.size=Vector2i(1600,1000)
	var manager = tree.root.get_node("graphs")
	var nodes := build(manager)
	await tree.process_frame
	if not _verify_types(tree,nodes): tree.quit(1); return
	var saved_config: Dictionary = {}
	for key in nodes: saved_config[key]=nodes[key].cfg.duplicate(true)
	var source = nodes.text_input
	if not await _verify_text_editing(tree,nodes): tree.quit(1); return
	if not await _verify_automatic(tree,nodes): tree.quit(1); return
	for frame in 30: await tree.process_frame
	if source.controller.state!=&"idle":
		push_error("Demo did not finish: "+JSON.stringify(source.controller.last_snapshot)); tree.quit(1); return
	assert(nodes.tokenizer.view.pills.size()>0,"No native token pills")
	assert(nodes.token_labels.view.rows.size()==5,"Vocabulary display not bounded")
	nodes.token_labels.update_config({"top_n":10})
	for frame in 2: await tree.process_frame
	if nodes.token_labels.view.rows.size()!=10 or source.controller.state!=&"idle": push_error("Display count invalidated generation or failed to update"); tree.quit(1); return
	nodes.token_labels.update_config({"top_n":5})
	_settle_layout(nodes)
	for key in ["text_input"]:
		if not is_equal_approx(nodes[key]._visual_extent.x,nodes[key].editor.size.x): push_error("Text clipping uses a different width than its editor: "+key); tree.quit(1); return
	for key in nodes:
		var expected: Dictionary = saved_config[key]
		var actual: Dictionary = nodes[key].get_info().cfg
		assert(expected == actual, "Preview modified saved config: " + key)
	if not _verify_layout(nodes): tree.quit(1); return
	source.clear_language_trace()
	if not _verify_layout(nodes): tree.quit(1); return
	if DisplayServer.get_name()=="headless":
		if not await _verify_detach(tree,nodes): tree.quit(1); return
		print("PASS test_language_editor"); tree.quit(0); return
	# The startup onboarding can keep the graph's ancestors hidden during capture.
	var global_state=tree.root.get_node("glob")
	global_state.base_node.get_node("WIN_GRAPH").window_show()
	global_state.fg.show()
	tree.root.get_node("ui").cl.hide()
	var original_language: String=tree.root.get_node("glob").get_lang()
	for language in ["en","ru","kz"]:
		tree.root.get_node("glob").change_lang(language)
		await tree.process_frame
		_settle_layout(nodes)
		if not _verify_layout(nodes): tree.quit(1); return
		for key in ["tokenizer","text_input","embedding","head0","token_labels"]:
			var node = nodes[key]
			var capture_path = "user://neuralese-language-ui/%s-%s.png" % [language,key] if OS.get_name()=="Windows" else "/tmp/neuralese-language-ui/%s-%s.png" % [language,key]
			var status: Dictionary = await tree.root.get_node("ui").capture_control(node,capture_path,{"padding":16,"render_scale":2})
			assert(status.get("ok",false),str(status))
	tree.root.get_node("glob").change_lang(original_language)
	if not await _verify_detach(tree,nodes): tree.quit(1); return
	print("PASS test_language_editor")
	tree.quit(0)

static func _verify_text_editing(tree: SceneTree,nodes: Dictionary) -> bool:
	var source=nodes.text_input
	var input_base: Script=source.get_script().get_base_script()
	if input_base.resource_path!="res://scripts/input_base.gd" or load("res://scripts/input_graph.gd").get_base_script()!=input_base: push_error("TextInput must inherit the same Input base as Input2D"); return false
	var normal: StyleBoxFlat=source.editor.get_theme_stylebox("normal")
	var native: StyleBoxFlat=load("res://resources/theme.tres").get_stylebox("normal","LineEdit")
	if normal.bg_color!=native.bg_color or normal.border_width_left<1: push_error("TextInput needs the existing native text field background and border: "+str([normal.bg_color,native.bg_color,normal.border_width_left])); return false
	var saved: String=source.cfg.text
	var controller=source.controller
	controller.set_process(false)
	var started: Array=[]
	var finished: Array=[]
	var on_started:=func(input: Graph,id: int):
		if input==source: started.append(id)
	var on_finished:=func(input: Graph,id: int):
		if input==source: finished.append(id)
	var runner=tree.root.get_node("nn")
	runner.inference_dispatched.connect(on_started)
	runner.inference_finished.connect(on_finished)
	var dimensions: Array[Vector2]=[]
	for text in ["cat","The cat sat on the mat and watched the cold rain falling outside the window for hours and hours until the deep evening slowly came into the dark room. Then the cat closed its eyes, listened to the rain on the roof and dreamed of a warm and sunny morning by the sea.","cat\ndog\nbird\nfish\nmouse","Привет, мир! 👋"]:
		source.editor.select_all()
		source.editor.insert_text_at_caret(text)
		for frame in 2: await tree.process_frame
		if source.cfg.text!=text: push_error("Native text editing did not update the input config"); return false
		_settle_layout(nodes)
		dimensions.append(source.rect.size)
		var padding: Vector2=source.rect.size-source.body.position-source.editor.size
		if not padding.is_equal_approx(load("res://scripts/language_models/language_layout.gd").input_padding()): push_error("Text field growth changed input padding"); return false
		var painted:=Rect2(source.editor.position-Vector2(normal.expand_margin_left,normal.expand_margin_top),source.editor.size+Vector2(normal.expand_margin_left+normal.expand_margin_right,normal.expand_margin_top+normal.expand_margin_bottom))
		if not Rect2(Vector2.ZERO,source.visual_clip.size).grow(0.05).encloses(painted): push_error("Input clipping cuts off the native rounded field border: "+str([source.visual_clip.size,painted])); return false
		var expected_height: float=source.editor.get_line_height()*(source.editor.get_line_count()+source.editor.get_line_wrap_count(0))+normal.get_minimum_size().y
		if source.editor.size.y+0.1<expected_height: push_error("Long or multiline input was clipped"); return false
		controller._process(0.31)
		for frame in 30: await tree.process_frame
		var expected: Array=tree.root.get_node("language_models").backend.tokenize(text).ids
		if controller.prefix_ids!=expected: push_error("Edited text did not trigger automatic tokenization"); return false
		for i in expected.size():
			if nodes.tokenizer.view.tokens[i].id!=expected[i]: push_error("Tokenizer pills show an older prompt"); return false
		var displayed: String=""
		for pill in nodes.tokenizer.view.pills: displayed+=pill.text
		if not displayed.begins_with(load("res://scripts/language_models/token_text.gd").visible(text)): push_error("Live token pills replaced source text with byte codes"); return false
	if dimensions[1].y<=dimensions[0].y or dimensions[2].y<=dimensions[0].y: push_error("Text input failed to grow with wrapped and multiline text: "+str(dimensions)); return false
	source.editor.select_all(); source.editor.insert_text_at_caret("cat")
	for frame in 2: await tree.process_frame
	_settle_layout(nodes)
	if not source.rect.size.is_equal_approx(dimensions[0]): push_error("Text input did not shrink after deleting text"); return false
	if started.is_empty() or started!=finished: push_error("Text inference did not use the shared Input visual lifecycle"); return false
	runner.inference_dispatched.disconnect(on_started)
	runner.inference_finished.disconnect(on_finished)
	source.update_config({"text":saved})
	controller.set_process(true)
	return true

static func _verify_automatic(tree: SceneTree,nodes: Dictionary) -> bool:
	var source=nodes.text_input
	var controller=source.controller
	# Advance the debounce explicitly; backend replies still travel through the real service.
	controller.set_process(false)
	controller._process(0.31)
	for frame in 30: await tree.process_frame
	if controller.state!=&"idle" or controller.last_snapshot.is_empty() or not controller.generated_ids.is_empty(): push_error("Connected text graph must preview without generating"); return false
	var saved_text: String=source.cfg.text
	source.update_config({"text":"The cat"}); controller._process(0.1)
	source.update_config({"text":"The dog"}); controller._process(0.1)
	controller._process(0.19)
	if controller._pending>=0 or not controller.last_snapshot.is_empty(): push_error("Automatic inference ignored the typing debounce"); return false
	controller._process(0.02)
	# Cancel an in-flight request with a newer edit, before its deferred reply arrives.
	source.update_config({"text":"The cat sat"}); controller._process(0)
	for frame in 8: await tree.process_frame
	if not controller.last_snapshot.is_empty(): push_error("Stale automatic response replaced a newer edit"); return false
	controller._process(0.31)
	for frame in 30: await tree.process_frame
	if controller._text!="The cat sat" or controller.last_snapshot.is_empty(): push_error("Automatic inference did not use the latest text"); return false
	source.update_config({"text":"The cat sat on"}); controller._process(0)
	controller.stop(); controller._process(1)
	for frame in 8: await tree.process_frame
	if controller.state!=&"stopped" or not controller.last_snapshot.is_empty(): push_error("Stop failed to cancel queued automatic inference"); return false
	var errors: Array=[]
	var record_error:=func(error: Dictionary): errors.append(error)
	controller.failed.connect(record_error)
	nodes.layer.update_config({"neuron_count":8191}); controller._process(0.31)
	for frame in 8: await tree.process_frame
	if errors.size()!=0 or controller.state!=&"stopped": push_error("Parameter change must not start inference"); return false
	controller.start(source)
	for frame in 8: await tree.process_frame
	if controller.state!=&"error" or errors.size()!=1 or not controller.last_snapshot.is_empty(): push_error("Invalid automatic graph must fail once without generating"); return false
	controller.failed.disconnect(record_error)
	nodes.layer.update_config({"neuron_count":8192}); controller._process(0.31)
	controller.start(source)
	for frame in 30: await tree.process_frame
	if controller.state!=&"idle" or not source._error_message.is_empty(): push_error("Automatic graph did not recover after its dimensions were corrected"); return false
	source.update_config({"text":""}); controller._process(1)
	for frame in 8: await tree.process_frame
	if controller.session_id!="" or not controller.last_snapshot.is_empty() or not nodes.tokenizer.view.pills.is_empty(): push_error("Empty input retained automatic results"); return false
	source.update_config({"text":saved_text}); controller._process(0.31)
	for frame in 30: await tree.process_frame
	# A newly connected output must populate without a click, including offscreen inputs.
	var extra=tree.root.get_node("graphs").get_graph(&"token_labels")
	if not _output(nodes.softmax).connect_to(extra._inputs[0]): push_error("Automatic output connection rejected"); return false
	source.process_mode=Node.PROCESS_MODE_DISABLED
	controller._process(0.31)
	for frame in 30: await tree.process_frame
	if extra.trace.is_empty(): push_error("A newly accepted edge did not preview the receiving node"); return false
	_output(nodes.softmax).disconnect_from(extra._inputs[0],false,true)
	controller._process(0)
	if not extra.trace.is_empty(): push_error("Detached automatic output kept stale results"); return false
	extra.free()
	source.process_mode=Node.PROCESS_MODE_INHERIT
	controller._process(0.31)
	for frame in 30: await tree.process_frame
	controller.set_process(true)
	return true

static func _verify_detach(tree: SceneTree, nodes: Dictionary) -> bool:
	_output(nodes.softmax).disconnect_from(nodes.token_labels._inputs[0],false,true)
	for frame in 3: await tree.process_frame
	if not nodes.token_labels.view.rows.is_empty(): push_error("Detached labels retained a stale trace"); return false
	var numeric=tree.root.get_node("graphs").get_graph(&"layer")
	var input: Node=null
	for port in numeric._inputs:
		if not port.config_conn: input=port; break
	var original: Color=input.gradient_color
	var original_outline: Color=numeric.base_outline
	numeric.select()
	if not _output(nodes.embedding).connect_to(input): push_error("Sequence Dense bridge rejected"); return false
	if input.gradient_color!=original or numeric.base_outline!=original_outline: push_error("Sequence connection changed native Dense styling"); return false
	_output(nodes.embedding).disconnect_from(input,false,true)
	for frame in 3: await tree.process_frame
	if input.gradient_color!=original: push_error("Numeric Dense color was not restored after detach"); return false
	numeric.unselect()
	if not numeric.rect.get_instance_shader_parameter("outline_color").is_equal_approx(original_outline): push_error("Selection highlight replaced numeric outline"); return false
	numeric.free()
	return true

static func _verify_layout(nodes: Dictionary) -> bool:
	var layout=load("res://scripts/language_models/language_layout.gd")
	for key in ["text_input","tokenizer","embedding","head0"]:
		var node = nodes[key]
		var expected_pos: Vector2 = layout.input_origin() if (key=="text_input" or key=="tokenizer") else layout.content_origin()
		if not node.body.position.is_equal_approx(expected_pos):
			push_error("Inconsistent node padding: "+key); return false
		var title=node.get_node("ColorRect/root/Label")
		if key=="text_input" or key=="tokenizer":
			if title.scale!=layout.input_property("ColorRect/root/Label",&"scale") or title.position!=Vector2(7,5): push_error("Header differs from Input2D: "+key); return false
			if key=="text_input":
				if title.get_theme_color("font_color")!=layout.input_property("ColorRect/root/Label",&"theme_override_colors/font_color"): push_error("TextInput header color differs from Input2D"); return false
				for property in [&"outline_color",&"tuning",&"corner_radius_width_add"]:
					var actual: Variant=node.base_outline if property==&"outline_color" else node.rect.get_instance_shader_parameter(property)
					if actual!=layout.input_property("ColorRect",StringName("instance_shader_parameters/"+property)): push_error("TextInput frame differs from Input2D: "+property); return false
				if not node._footer.is_empty(): push_error("TextInput must infer automatically without a Run! button"); return false
		else:
			if not is_equal_approx(title.scale.x,0.374766): push_error("Header scale differs from Conv2D: "+key); return false
			if not is_equal_approx(title.position.y,layout.header_y()) or absf(title.position.x+title.size.x*title.scale.x/2-node.rect.size.x/2)>0.1:
				push_error("Header must keep Conv2D's top inset and remain centered: "+key+str([title.position,title.size,title.scale,node.rect.size])); return false
			if node.rect.get_instance_shader_parameter("corner_radius_width_add")!=layout.radius_adjustment(): push_error("Frame radius differs from Conv2D: "+key); return false
		var status_rect:=Rect2(node.status_label.position,node.status_label.size)
		if node.status_label.visible and (status_rect.end.x>node.rect.size.x-11.5 or status_rect.end.y>node.rect.size.y-7.5):
			push_error("Status/error overflow: "+key); return false
		var previous: Array[Rect2]=[]
		for control in node._footer:
			var rect:=Rect2(control.position,control.size*control.scale)
			if rect.end.x>node.body.size.x+0.5 or rect.end.y>node.body.size.y+0.5:
				push_error("Footer overflow: "+key+" "+str(rect)); return false
			for other in previous:
				if other.intersects(rect): push_error("Overlapping footer controls: "+key); return false
			previous.append(rect)
		for port in node._inputs+node.outputs:
			if port.z_index!=0 or port.get_index()>node.rect.get_index():
				push_error("Port paint order differs from Conv2D: "+key); return false
			var expected_center: float=node.rect.size.x+(2 if key=="text_input" else -1)
			if port.connection_type==1 and not is_equal_approx(port.position.x+port.size.x/2,expected_center):
				push_error("Output port extends beyond native inset: "+key); return false
	for pill in nodes.tokenizer.view.pills:
		if pill.position.y+pill.size.y>nodes.tokenizer.view.custom_minimum_size.y+0.5:
			push_error("Token pill clipped by viewport"); return false
	var top_out = nodes.token_labels
	if not (top_out is OutputGraph):
		push_error("BestAnswer must extend OutputGraph (classifier_graph.tscn)"); return false
	var top_title = top_out.get_node("ColorRect/root/Label")
	if not top_title.scale.is_equal_approx(Vector2(0.414803, 0.414803)):
		push_error("BestAnswer header scale differs from classifier_graph.tscn"); return false
	# The pixel design recolours every node title alike; the classic one keeps the scene's mint.
	var design_ui: Node = (Engine.get_main_loop() as SceneTree).root.get_node_or_null(^"design")
	var classic: bool = design_ui == null or not design_ui.pixel
	if classic and not top_title.get_theme_color("font_color").is_equal_approx(Color(0, 1, 0.7176471, 1)):
		push_error("BestAnswer header color differs from classifier_graph.tscn"); return false
	if top_out.units.size() != int(top_out.cfg.get("top_n", 5)):
		push_error("BestAnswer unit count does not match top_n"); return false
	for unit in top_out.units:
		if not (unit is DynamicGraphUnit):
			push_error("BestAnswer rows must be DynamicGraphUnit instances"); return false
	if top_out.get_node_or_null("input/OtherLabel") == null or not is_instance_valid(top_out.add_button):
		push_error("BestAnswer footer must have OtherLabel and Vocab button"); return false
	return true

static func _verify_types(tree: SceneTree,nodes: Dictionary) -> bool:
	var service=tree.root.get_node("language_models")
	for pair in [["text_input","tokenizer",true],["tokenizer","embedding",true],["embedding","layer",true],["softmax","token_labels",true],["embedding","token_labels",false],["head0","token_labels",false],["layer","token_labels",false],["softmax","head0",false],["tokenizer","head0",false]]:
		var input: Node=null
		for port in nodes[pair[1]]._inputs:
			if not port.config_conn: input=port; break
		if service.connection_datatype(_output(nodes[pair[0]]),input)!=pair[2]:
			push_error("Wrong language datatype connection: "+str(pair)); return false
	for key in ["concat","layer","softmax"]:
		if nodes[key].base_outline!=nodes[key].get_meta("demo_original_outline"): push_error("Language graph changed a native outline: "+key); return false
		for port in nodes[key]._inputs+nodes[key].outputs:
			if [port.color,port.gradient_color]!=port.get_meta("demo_original_colors"):
				push_error("Language graph changed native port colors: "+key); return false
	for node in nodes.values():
		for port in node.outputs:
			if port.config_conn: continue
			for spline in port.outputs.values():
				if not spline.color_a.is_equal_approx(port.gradient_color) or not spline.color_b.is_equal_approx(spline.tied_to.gradient_color):
					push_error("Transformer wire retained a stale endpoint color"); return false
	return true

static func _verify_content_growth(nodes: Dictionary) -> bool:
	var head=nodes.head0
	var saved: Dictionary=head.trace.duplicate(true)
	var backend=load("res://scripts/language_models/dummy_language_backend.gd").new()
	var id:=str(head.graph_id)
	var small: Dictionary=backend.preview(backend.tokenize("The cat").ids,[],[{"id":id,"op":"attention_head","config":{}}]).nodes[id]
	var large: Dictionary=backend.preview(backend.tokenize("The cat sat on the mat").ids,[],[{"id":id,"op":"attention_head","config":{}}]).nodes[id]
	head.apply_language_trace(small)
	_settle_layout(nodes)
	var small_size: Vector2=head.rect.size
	var anchor: Vector2=head.view._geometry(2).origin
	head.apply_language_trace(large)
	head._update_content_layout()
	if head.target_size_vec.x<=small_size.x or head.target_size_vec.y<=small_size.y or head.view._geometry(6).origin!=anchor:
		push_error("Attention content must grow the frame without moving its origin"); return false
	head._after_process(1.0/60)
	if head.rect.size==small_size or head.rect.size==head.target_size_vec:
		push_error("Attention frame must interpolate, not jump"); return false
	_settle_layout(nodes)
	var layout=load("res://scripts/language_models/language_layout.gd")
	var trailing: Vector2=head.rect.size-head.body.position-head.view.content_size()
	if not trailing.is_equal_approx(layout.trailing_padding()): push_error("Attention trailing padding differs from Conv2D"); return false
	if not head._footer.is_empty(): push_error("Attention must not expose Width or Words controls"); return false
	head.apply_language_trace(saved)
	_settle_layout(nodes)
	return true

static func _settle_layout(nodes: Dictionary) -> void:
	# Deterministic animation time, also when headless renders frames without a cap.
	for frame in 100:
		for node in nodes.values():
			if node.has_method("get_language_op"): node._after_process(1.0/60)
