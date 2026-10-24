extends RefCounted
const Contract = preload("res://scripts/language_models/language_contract.gd")

static func validate(graph: Dictionary, capabilities: Dictionary, token_count: int = -1) -> Dictionary:
	var nodes: Dictionary = {}
	var incoming: Dictionary = {}
	var shapes: Dictionary = {}
	var kinds: Dictionary = {}
	var order: Array = []
	var time: Variant = token_count if token_count >= 0 else "T"
	if token_count == 0 or token_count > 512: return fail("context_limit", "Use 1–512 tokens", "")
	if graph.get("nodes",[]).size() > 64: return fail("graph_limit", "Use at most 64 nodes", "")
	var sources := 0
	var loose := bool(capabilities.get("loose_architecture", false))
	for node in graph.get("nodes",[]):
		var id := str(node.get("id",""))
		if id == "" or nodes.has(id): return fail("node_id", "Node IDs must be unique", id)
		if not StringName(node.get("op","")) in Contract.OPS: return fail("unsupported_node", "This node cannot process text", id)
		nodes[id] = node
		incoming[id] = []
		if node.op == "text_input": sources += 1
	if sources != 1: return fail("source_count", "Connect one TextInput", "")
	for edge in graph.get("edges",[]):
		if not nodes.has(str(edge.get("from_node"))) or not nodes.has(str(edge.get("to_node"))): return fail("missing_node", "Connection references a missing node", "")
		incoming[str(edge.to_node)].append(edge)
	var pending: Array = nodes.keys()
	pending.sort()
	while not pending.is_empty():
		var changed := false
		for id in pending.duplicate():
			var ready := true
			for edge in incoming[id]:
				if not shapes.has(str(edge.from_node)): ready = false
			if not ready: continue
			var node: Dictionary = nodes[id]
			var config: Dictionary = node.get("config",{})
			var edges: Array = incoming[id]
			var port_order: Array = config.get("input_order",[])
			edges.sort_custom(func(a, b): return port_order.find(a.to_port) < port_order.find(b.to_port) if not port_order.is_empty() else str(a.to_port) < str(b.to_port))
			if node.op != "text_input" and edges.is_empty(): return fail("missing_input", "Connect the input", id)
			if node.op not in ["text_input","concat"] and edges.size() != 1: return fail("input_count", "This node needs one input", id)
			if node.op == "text_input" and not edges.is_empty(): return fail("source_input", "TextInput cannot have an input", id)
			var input_shape: Array = [] if edges.is_empty() else shapes[str(edges[0].from_node)].output_shape
			var input_kind := "" if edges.is_empty() else str(kinds[str(edges[0].from_node)])
			var output: Array = []
			var kind := "features"
			match node.op:
				"text_input": output = []; kind = "text"
				"tokenizer":
					if input_kind != "text": return fail("datatype", "Tokenizer needs text", id)
					output = [time]; kind = "tokens"
				"embedding":
					if input_kind != "tokens": return fail("datatype", "Embedding needs tokens", id)
					output = [time,int(capabilities.get("model_width",256))]
				"attention_head", "layer":
					if input_kind != "features": return fail("datatype", "This layer needs token vectors", id, order, shapes)
					if node.op == "attention_head":
						var heads:=int(capabilities.get("head_count",4))
						if heads<1 or (not loose and int(input_shape[1])%heads!=0): return fail("head_width", "Vector size must divide evenly between model heads",id, order, shapes)
						output=[time,int(capabilities.get("head_dim", int(int(capabilities.get("model_width",256))/heads))) if loose else int(int(input_shape[1])/heads)]
					else:
						var neurons := int(config.get("neuron_count", 0))
						if neurons <= 0 and input_shape.size() >= 2:
							neurons = int(input_shape[1])
						output = [time, int(capabilities.get("model_width",256)) if loose else neurons]
				"concat":
					var width := 0
					var seen: Dictionary = {}
					for edge in edges:
						var source := str(edge.from_node)
						if kinds[source] != "features" or shapes[source].output_shape[0] != time: return fail("concat_shape", "Combine vectors of the same tokens", id, order, shapes)
						if seen.has(source) or seen.has("port:"+str(edge.to_port)): return fail("duplicate_input", "Connect each branch to a separate slot once", id, order, shapes)
						seen[source] = true; seen["port:"+str(edge.to_port)] = true
						width += int(shapes[source].output_shape[1])
					output = [time,width]
				"softmax":
					if input_kind != "features" or input_shape.size() != 2: return fail("datatype", "Softmax needs token vectors", id, order, shapes)
					if not loose and input_shape[1] != int(capabilities.get("vocab_size",8192)):
						if edges.size() == 1 and nodes.has(str(edges[0].from_node)) and nodes[str(edges[0].from_node)].op == "layer" and int(nodes[str(edges[0].from_node)].get("config",{}).get("neuron_count",0)) > 0 and int(nodes[str(edges[0].from_node)].get("config",{}).get("neuron_count",0)) != int(capabilities.get("vocab_size",8192)):
							return fail("vocabulary_width", "Last Dense must match the vocabulary size", id, order, shapes)
					output = [int(capabilities.get("vocab_size",8192))]; kind = "scores"
				"token_labels":
					if input_kind != "scores": return fail("datatype", "Connect Softmax probabilities", id, order, shapes)
					output = input_shape; kind = "scores"
				"autoregression":
					if nodes[str(edges[0].from_node)].op not in ["token_labels","top_output"]: return fail("datatype", "Connect BestAnswer", id, order, shapes)
					output = []; kind = "autoregression"
			if output.size() == 2 and (int(output[1]) < 1 or int(output[1]) > 65536): return fail("width", "Layer width must be between 1 and 65536", id, order, shapes)
			var input_type: String=Contract.INPUT_TYPES.get(str(node.op),"")
			var output_type: String=Contract.OUTPUT_TYPES.get(str(node.op),"")
			shapes[id] = {"input_shape":input_shape,"output_shape":output,"input_type":input_type,"output_type":output_type,"input_dtype":Contract.DTYPES.get(input_type,""),"output_dtype":Contract.DTYPES.get(output_type,"autoregression")}
			kinds[id] = kind
			order.append(id)
			pending.erase(id)
			changed = true
		if not changed: return fail("cycle", "Remove the cycle", str(pending[0]), order, shapes)
	return {"ok":true,"errors":[],"order":order,"shapes":shapes}

static func fail(code: String, message: String, node_id: String, order: Array = [], shapes: Dictionary = {}) -> Dictionary:
	return {"ok":false,"errors":[{"code":code,"message":message,"node_id":node_id}],"order":order,"shapes":shapes}
