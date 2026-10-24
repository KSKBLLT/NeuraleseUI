extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var validator = load("res://scripts/language_models/language_graph_validator.gd")
	if validator == null: push_error("Missing language graph validator"); quit(1); return
	var graph := {"source_id":"s","nodes":[{"id":"s","op":"text_input","config":{}},{"id":"t","op":"tokenizer","config":{}},{"id":"e","op":"embedding","config":{"width":256}},{"id":"a","op":"attention_head","config":{"width":64}},{"id":"b","op":"attention_head","config":{"width":64}},{"id":"c","op":"concat","config":{"input_order":["slot_1","slot_2"]}},{"id":"d","op":"layer","config":{"neuron_count":8192}},{"id":"p","op":"softmax","config":{}},{"id":"o","op":"token_labels","config":{}}],"edges":[]}
	for pair in [["s","t"],["t","e"],["e","a"],["e","b"],["a","c"],["b","c"],["c","d"],["d","p"],["p","o"]]:
		graph.edges.append({"from_node":pair[0],"to_node":pair[1],"from_port":"out","to_port":"slot_2" if pair[0]=="b" else "slot_1"})
	var result: Dictionary = validator.validate(graph,{"vocab_size":8192},5)
	if not result.ok or result.shapes.c.output_shape != [5,128] or result.shapes.p.output_shape != [8192]:
		push_error("Incorrect language shape inference: " + str(result)); quit(1); return
	var derived: Dictionary = validator.validate(graph,{"vocab_size":8192,"model_width":128,"head_count":8},5)
	if not derived.ok or derived.shapes.e.output_shape!=[5,128] or derived.shapes.a.output_shape!=[5,16]: push_error("Embedding/head dimensions must come from the model, not a manual Width"); quit(1); return
	var reversed := graph.duplicate(true)
	reversed.nodes.reverse(); reversed.edges.reverse()
	if validator.validate(reversed,{"vocab_size":8192},5).shapes != result.shapes:
		push_error("Graph order changed shapes"); quit(1); return
	var bad := graph.duplicate(true)
	bad.edges.append({"from_node":"o","to_node":"t","from_port":"out","to_port":"in"})
	if validator.validate(bad,{"vocab_size":8192},5).ok: push_error("Cycle accepted"); quit(1); return
	bad = graph.duplicate(true)
	bad.nodes[6].config.neuron_count = 3
	if validator.validate(bad,{"vocab_size":8192},5).ok: push_error("Wrong vocabulary width accepted"); quit(1); return
	var real: Dictionary = validator.validate(bad,{"vocab_size":20002,"model_width":256,"head_count":4,"head_dim":64,"loose_architecture":true},5)
	if not real.ok or real.shapes.d.output_shape != [5,256] or real.shapes.p.output_shape != [20002]:
		push_error("Pretrained profiles must expose their effective dimensions while loosely adapting user widths"); quit(1); return
	var sequential := graph.duplicate(true)
	sequential.edges[4].from_node = "a"
	if not validator.validate(sequential,{"vocab_size":20002,"model_width":256,"head_count":4,"head_dim":64,"loose_architecture":true},5).ok:
		push_error("Sequential real attention heads must retain the checkpoint's head width"); quit(1); return
	bad = graph.duplicate(true)
	bad.nodes[2].op = "conv2d"
	if validator.validate(bad,{"vocab_size":8192},5).ok: push_error("Numeric-only node accepted"); quit(1); return
	var roles = load("res://scripts/language_models/graph_roles.gd")
	var alternatives: Array = roles.alternatives(&"layer",[&"conv2d",&"attention_head",&"concat",&"text_input"],true)
	if alternatives != [&"attention_head",&"concat"]: push_error("Language replacement crosses numeric/source domain"); quit(1); return
	if roles.alternatives(&"text_input",[&"input",&"input_1d",&"embedding"]) != [&"input",&"input_1d"]: push_error("Input replacement must include other source forms only"); quit(1); return
	print("PASS test_language_graph")
	quit(0)
