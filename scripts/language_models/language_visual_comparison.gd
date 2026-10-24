extends RefCounted
## Editor-only visual QA: every node uses the same canvas transform and pixel scale.
static func capture(tree: SceneTree) -> void:
	tree.root.size=Vector2i(1600,1000)
	tree.root.content_scale_factor=1.0
	for frame in 3: await tree.process_frame
	var global_state = tree.root.get_node("glob")
	var original_language: String=global_state.get_lang()
	global_state.change_lang("ru")
	var manager = tree.root.get_node("graphs")
	var stage := Control.new()
	stage.name="LanguageVisualComparison"
	stage.size=Vector2(760,330)
	stage.process_mode=Node.PROCESS_MODE_ALWAYS
	global_state.base_node.get_node("WIN_GRAPH").add_child(stage)
	var image = _add(global_state,manager,stage,&"input",Vector2(-150,60))
	var conv = _add(global_state,manager,stage,&"conv2d",Vector2(90,60))
	var pool = _add(global_state,manager,stage,&"maxpool",Vector2(300,500))
	var tokenizer = _add(global_state,manager,stage,&"tokenizer",Vector2(420,500))
	var focus_kind:=&"attention_head" if "--language-visual-head" in OS.get_cmdline_user_args() else &"embedding"
	var embedding = _add(global_state,manager,stage,focus_kind,Vector2(420,60))
	var source_embedding: Node=null
	if focus_kind==&"attention_head": source_embedding=_add(global_state,manager,stage,&"embedding",Vector2(420,800))
	var head = _add(global_state,manager,stage,&"attention_head",Vector2(1300,60))
	for frame in 5: await tree.process_frame
	conv.update_config({"filters":8,"stride":1,"window":3})
	_wire(image,conv)
	_wire(conv,pool)
	if source_embedding!=null:
		_wire(tokenizer,source_embedding)
		_wire(source_embedding,embedding)
	else: _wire(tokenizer,embedding)
	_wire(embedding,head)
	var backend = load("res://scripts/language_models/dummy_language_backend.gd").new()
	var data: Dictionary = backend.preview(backend.tokenize("The cat sat on the").ids,[],[{"id":str(embedding.graph_id),"op":str(focus_kind),"config":{}}])
	embedding.apply_language_trace(data.nodes[str(embedding.graph_id)])
	for frame in 100: embedding._after_process(1.0/60)
	for frame in 30: await tree.process_frame
	# Copy the native Line2D render objects so the capture isolation keeps real wires.
	for graph in [image,conv,tokenizer,embedding]+([source_embedding] if source_embedding!=null else []):
		for port in graph.outputs:
			for spline in port.outputs.values():
				if spline.line_2d==null: continue
				var line = spline.line_2d.duplicate()
				line.z_index=-1
				stage.add_child(line)
	var result: Dictionary = await tree.root.get_node("ui").capture_control(stage,"/tmp/neuralese-language-ui/conv2d-"+str(focus_kind)+"-comparison.png",{"padding":16,"render_scale":1})
	print("LANGUAGE_VISUAL_COMPARISON ",JSON.stringify(result))
	global_state.change_lang(original_language)
	tree.quit(0 if result.get("ok",false) else 1)

static func _add(global_state: Node, manager: Node, stage: Control, id: StringName, at: Vector2) -> Node:
	var node = global_state.base_node.instantiate_node(id)
	node.set_meta("created_with",id)
	node.position=at
	node.z_index=0
	stage.add_child(node)
	manager.add(node)
	return node

static func _wire(from: Node, to: Node) -> void:
	for output in from.outputs:
		if output.config_conn: continue
		for input in to._inputs:
			if not input.config_conn:
				assert(output.connect_to(input))
				return
