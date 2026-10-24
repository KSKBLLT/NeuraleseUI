extends RefCounted
const Contract = preload("res://scripts/language_models/language_contract.gd")

static func component(start: Node) -> Array:
	var queue: Array = [start]
	var seen: Array = []
	while not queue.is_empty() and seen.size() <= 128:
		var node = queue.pop_front()
		if not is_instance_valid(node) or seen.has(node): continue
		seen.append(node)
		for port in node._inputs:
			if port.config_conn: continue
			for spline in port.inputs:
				if is_instance_valid(spline.origin): queue.append(spline.origin.parent_graph)
		for port in node.outputs:
			if port.config_conn: continue
			for spline in port.outputs.values():
				if is_instance_valid(spline.tied_to): queue.append(spline.tied_to.parent_graph)
	return seen

static func is_language(node: Node) -> bool:
	for item in component(node):
		if Contract.EXCLUSIVE_LANGUAGE_TYPES.has(StringName(item.get_meta("created_with",""))): return true
	return false

static func downstream(start: Node) -> Array:
	var queue: Array = [start]
	var seen: Array = []
	while not queue.is_empty() and seen.size() <= 128:
		var node = queue.pop_front()
		if not is_instance_valid(node) or seen.has(node): continue
		seen.append(node)
		for port in node.outputs:
			if port.config_conn: continue
			for spline in port.outputs.values():
				if is_instance_valid(spline.tied_to): queue.append(spline.tied_to.parent_graph)
	return seen

static func upstream(target: Node, source: Node) -> Dictionary:
	var queue: Array = [target]
	var ids: Dictionary = {}
	while not queue.is_empty() and ids.size() <= 128:
		var node = queue.pop_front()
		if not is_instance_valid(node) or ids.has(str(node.graph_id)): continue
		ids[str(node.graph_id)] = true
		for port in node._inputs:
			if port.config_conn: continue
			for spline in port.inputs:
				if is_instance_valid(spline.origin): queue.append(spline.origin.parent_graph)
	var graph := collect(source)
	# Validation and rendering use the accepted upstream chain; physical layer
	# and head selection still use its complete connected component.
	graph["mapping_graph"] = graph.duplicate(true)
	graph.nodes = graph.nodes.filter(func(node): return ids.has(str(node.id)))
	graph.edges = graph.edges.filter(func(edge): return ids.has(str(edge.from_node)) and ids.has(str(edge.to_node)))
	return graph

static func accepts_connection(from: Node, to: Node) -> bool:
	if from.config_conn or to.config_conn: return true
	var members := component(from.parent_graph)
	for member in component(to.parent_graph):
		if not members.has(member): members.append(member)
	var language := false
	for member in members:
		if Contract.EXCLUSIVE_LANGUAGE_TYPES.has(StringName(member.get_meta("created_with",""))): language = true
	if not language: return true
	for member in members:
		if not Contract.OPS.has(StringName(member.get_meta("created_with",""))): return false
	if not _typed_pair(from,to): return false
	# A bridge must not reclassify an existing incompatible numeric chain as text.
	for member in members:
		for port in member.outputs:
			if port.config_conn: continue
			for spline in port.outputs.values():
				if is_instance_valid(spline.tied_to) and not _typed_pair(port,spline.tied_to): return false
	return true

static func _typed_pair(from: Node, to: Node) -> bool:
	var source:=str(from.parent_graph.get_meta("created_with",""))
	var target:=str(to.parent_graph.get_meta("created_with",""))
	return Contract.OUTPUT_TYPES.has(source) and Contract.OUTPUT_TYPES[source]==Contract.INPUT_TYPES.get(target,"")

static func connection_datatype(from: Node, to: Node) -> Variant:
	if from.config_conn or to.config_conn: return null
	if is_language(from.parent_graph) or is_language(to.parent_graph): return accepts_connection(from,to)
	return null

static func collect(source: Node) -> Dictionary:
	var nodes: Array = []
	var edges: Array = []
	var members := component(source)
	members.sort_custom(func(a,b): return a.graph_id < b.graph_id)
	var head := 0
	for member in members:
		var config: Dictionary = member.cfg.duplicate(true)
		var op := str(member.get_meta("created_with",""))
		if op == "top_output": op = "token_labels"
		if op == "autoregression":
			# Sampling changes the next step, never the model/session topology.
			config.erase("creativity")
			config.erase("candidates")
		if op == "token_labels":
			config.erase("top_n")
			config.erase("label_names")
			config.erase("vocab_source")
			config.erase("title")
		if op == "layer":
			for port in member._inputs:
				if port.config_conn and port.accepted_datatypes.has(&"activation"):
					for spline in port.inputs:
						config["activation"]=str(spline.origin.parent_graph.selected_activation)
		if op == "concat":
			var input_order: Array = []
			for unit in member.units: input_order.append(str(unit.get_node("o").server_name))
			config["input_order"] = input_order
		if op in ["embedding","attention_head"]: config.erase("width")
		if op == "attention_head": config["head_index"] = config.get("_head_order",head); head += 1
		nodes.append({"id":str(member.graph_id),"op":op,"config":config})
		for port in member.outputs:
			if port.config_conn: continue
			for spline in port.outputs.values():
				if not is_instance_valid(spline.tied_to): continue
				edges.append({"from_node":str(member.graph_id),"from_port":str(port.server_name),"to_node":str(spline.tied_to.parent_graph.graph_id),"to_port":str(spline.tied_to.server_name)})
	edges.sort_custom(func(a,b): return JSON.stringify(a) < JSON.stringify(b))
	return {"source_id":str(source.graph_id),"nodes":nodes,"edges":edges}
