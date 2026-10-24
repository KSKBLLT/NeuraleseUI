extends Node2D
const GraphRoles = preload("res://scripts/language_models/graph_roles.gd")
const LanguageAdapter = preload("res://scripts/language_models/language_graph_adapter.gd")

const NodePaletteCatalog = preload("res://scripts/node_palette_catalog.gd")
const PlatformInput = preload("res://scripts/platform_input.gd")
const NodeCatalog = preload("res://scripts/generated/node_catalog.gd")
const UICaptureCore = preload("res://scripts/ui_capture.gd")


var storage: GraphStorage

var propagation_q = {}
var _propagated_from = {}
func next_frame_propagate(tied_to: Connection, key: int, value: Variant):
	propagation_q.get_or_add(tied_to, {}).get_or_add(key, []).append(value)

func next_frame_from(from: Connection, tied_to: Connection):
	_propagated_from.get_or_add(from, []).append(tied_to)

var gather_q = {}
var gather_tree = {}
func next_frame_gather(tied_to: Connection, key: int):
	pass
	#(propagation_q)

func gather_cycle():
	pass


const csize: int = 10
var chunks: Dictionary[int, Dictionary] = {}
var colliders: Dictionary[ColorRect, Collider] = {}

class Collider:
	var size: Vector2
	var used_chunks: Dictionary
	var position: Vector2
	func _init(_size: Vector2):
		size = _size; used_chunks = {}; position = Vector2()

var dragged: Dictionary[Graph, Array] = {}

func drag(graph: Graph) -> void:
	var from = graph.get_index()
	var last = storage.get_child_count() - 1
	dragged[graph] = [graph.z_index, from]
	if from == last:
		return
	var kids = storage.get_children()
	var carry = graph.z_index
	for i in range(from + 1, kids.size()):
		var k = kids[i]
		if k is CanvasItem:
			var z = k.z_index
			k.z_index = carry
			carry = z
	graph.z_index = carry
	storage.move_child(graph, -1)

var shadow_rect = preload("res://scenes/graph_shadow.tscn")

func stop_drag(graph: Graph) -> void:
	dragged.erase(graph)

func pack64(x: int, y: int) -> int:
	return ((x & 0xFFFFFFFF) << 32) | (y & 0xFFFFFFFF)

func mark_rect(graph: Graph):
	var rect: ColorRect = graph.rect
	var chunk_dims = Vector2i(ceil(float(rect.size.x) / csize), ceil(float(rect.size.y) / csize))
	var init_chunk = Vector2i(rect.global_position / csize)
	if not colliders.has(rect): colliders[rect] = Collider.new(rect.size)
	var collider = colliders[rect]
	collider.position = graph.global_position
	
	var prev_used = collider.used_chunks
	var new_used = {}
	var overlapped_something: bool = false
	for i: int in chunk_dims.x*chunk_dims.y:
		var y: int = i / chunk_dims.x; var x: int = i % chunk_dims.x
		var index: int = pack64(x + init_chunk.x, y + init_chunk.y)
		chunks.get_or_add(index, {})[collider] = true
		prev_used.erase(index)
		new_used[index] = true
	for i in prev_used:
		chunks[i].erase(collider)
	collider.used_chunks = new_used
	
func can_move(graph: Graph, vec: Vector2) -> Vector2:
	return Vector2()
	
# deltas. Changes/adds/deletes of different types of things
const DELETE: int = 0; const ADD: int = 2


var conns_active = {}

class Deltas:
	var snapshot = null
	var iterable = null
	var dtype_snapshot: int
	func _init(_iterable, default):
		iterable = _iterable
		snapshot = default
		dtype_snapshot = -30

var delta_paths = {}
var delta_objects = {}
var owners_deltas = null
var deltas_between_owners = null

var prev_graphs: Dictionary[int, bool] = {}
func get_deltas() -> Dictionary:
	var object_adds = {}
	var object_deletes = {}
	var graph_adds = []
	var graph_deletes = []
	for g:int in _graphs:
		var graph = _graphs[g]
		var res = store_delta(graph)
		if res[0]:object_adds[g] = res[0]
		if res[1]:object_deletes[g] = res[1]
		if not g in prev_graphs:
			graph_adds.append(g)
		prev_graphs.erase(g)
	for prev_graph in prev_graphs:
		graph_deletes.append(prev_graph)
	prev_graphs = _graphs_ids.duplicate()
	return {"graph_adds": graph_adds, 
	"graph_deletes": graph_deletes, 
	"object_adds": object_adds,
	"object_deletes": object_deletes}

func store_delta(graph: Graph):
	var new_info: Dictionary = graph.get_info()
	var delta_paths = delta_paths.get_or_add(graph, {})
	var delta_objects = delta_objects.get_or_add(graph, {})
	var delta_roots = owners_deltas if typeof(owners_deltas) == TYPE_DICTIONARY else {}
	if typeof(delta_roots) != TYPE_DICTIONARY:
		delta_roots = {}
	owners_deltas = delta_roots

	var q = [[new_info, TYPE_DICTIONARY, ["origin"], false]]
	var globdelta = delta_roots.get(graph)
	if globdelta == null:
		var root_deltas = Deltas.new(new_info, {})
		q[0][3] = root_deltas
		delta_roots[graph] = root_deltas
	else:
		q[0][3] = globdelta

	var result_adds = {}
	var result_deletes = {}

	while q.size() > 0:
		var popped = q.pop_back()
		var cur_iterable = popped[0]
		var parent_dtype: int = popped[1]
		var path = popped[2]
		var deltas = popped[3]

		delta_objects[cur_iterable] = path

		if not delta_paths.has(path):
			delta_paths[path] = Deltas.new(cur_iterable, glob.list(parent_dtype))
			deltas = delta_paths[path]
		else:
			deltas = delta_paths[path]

		if deltas.dtype_snapshot != parent_dtype:
			result_adds.get_or_add(path, {})["__type__"] = parent_dtype
			deltas.dtype_snapshot = parent_dtype

		for key in cur_iterable if not (parent_dtype in glob.arrays) else len(cur_iterable):
			var value = cur_iterable[key]
			var dtype: int = typeof(value)
			if dtype in glob.iterables:
				var next_path = path.duplicate()
				next_path.append(key)
				q.append([value, dtype, next_path, false])
			else:
				var dict: bool = parent_dtype == TYPE_DICTIONARY
				if ((dict and (not deltas.snapshot.has(key) or deltas.snapshot[key] != value))
					or (!dict and (key >= len(deltas.snapshot) or deltas.snapshot[key] != value))):
					result_adds.get_or_add((path), {})[key] = value

		if deltas.snapshot:
			if parent_dtype == TYPE_DICTIONARY:
				for k in deltas.snapshot:
					if not cur_iterable.has(k):
						result_deletes.get_or_add((path), {})[k] = deltas.snapshot[k]
			else:
				var old_len = len(deltas.snapshot)
				var cur_len = len(cur_iterable)
				if old_len > cur_len:
					for i in range(cur_len, old_len):
						result_deletes.get_or_add((path), {})[i] = deltas.snapshot[i]

		deltas.snapshot = cur_iterable.duplicate()
	
	var pathed_adds = {}; var pathed_deletes = {}
	for i in result_adds:
		pathed_adds["/".join(i)] = result_adds[i]
	for i in result_deletes:
		pathed_deletes["/".join(i)] = result_deletes[i]
	
	return [pathed_adds, pathed_deletes]

var _graphs_ids: Dictionary[int, bool] = {}
var _graphs: Dictionary[int, Graph] = {}

var _graph_names = {}

func nodes_of_type(type: String) -> Dictionary:
	return _graph_names.get(type, {})

func add(graph: Graph):
	_graph_names.get_or_add(graph.server_typename, {})[graph] = true
	_graphs[graph.graph_id] = graph
	_graphs_ids[graph.graph_id] = true

func remove(graph: Graph):
	_graph_names.get(graph.server_typename, {}).erase(graph)
	# A delayed _exit_tree from an older project must never erase a newly loaded
	# graph that legitimately reuses the same persisted id.
	if _graphs.get(graph.graph_id) == graph:
		_graphs.erase(graph.graph_id)
		_graphs_ids.erase(graph.graph_id)
	stop_drag(graph)

func get_by_id(graph_id: int) -> Graph:
	return _graphs.get(graph_id)

func attach_edge(from_conn: Connection, to_conn: Connection):
	learner.notify_update.call_deferred()


func remove_edge(from_conn: Connection, to_conn: Connection):
	pass

func validate_acyclic_edge(from_conn: Connection, to_conn: Connection) -> bool:
	if from_conn.parent_graph == to_conn.parent_graph:
		return false
	var reached: Array = [false]
	var _cycle_check = func(fc: Connection, tc: Connection, _branch_cache: Dictionary) -> void:
		#(tc.parent_graph.graph_id, " ", from_conn.parent_graph.graph_id)
		if tc.parent_graph.graph_id == from_conn.parent_graph.graph_id:
			reached[0] = true
			#(reached)
	reach(to_conn.parent_graph, _cycle_check)
	#(reached)
	return not reached[0]


func _reach_input(from: Graph, custom: String = ""):
	# Empty means any registered data input; explicit names select training grammar roots.
	if (GraphRoles.is_input(from) if custom.is_empty() else from.server_typename == custom): return from
	var next_frame = {from: true}
	var visited: Dictionary = {}
	while true:
		var new_frame = {}
		for i: Graph in next_frame:
			if visited.has(i): continue
			visited[i] = true
			if (GraphRoles.is_input(i) if custom.is_empty() else i.server_typename == custom): return i
			for conn in i._inputs:
				for spline in conn.inputs:
					new_frame[spline.origin.parent_graph] = true
		if new_frame.is_empty(): break
		next_frame = new_frame
	return null

var _conn_spaces: Dictionary[StringName, Dictionary] = {}

func _ensure_conn_space(ns: StringName) -> Dictionary:
	return _conn_spaces.get_or_add(ns, {
		"candidates": [],    # Array[Connection]
		"chosen": null,      # Connection (this frame)
		"next_chosen": null, # Connection (exposed next frame)
	})

func register_conn_candidate(conn: Connection, ns: StringName = "activate") -> void:
	# Skip invalids early
	if not is_instance_valid(conn):
		return
	_ensure_conn_space(ns)["candidates"].append(conn)

func _distance_key(c: Connection, mouse_pos: Vector2) -> Array:
	# Prefer actual plug point for distance
	var p = c.get_origin()
	var d2 = mouse_pos.distance_squared_to(p)
	# Tiebreakers: higher z on top (CanvasItem); then smaller rect
	var zi := (c as CanvasItem).z_index if c is CanvasItem else 0
	var rect := c.get_global_rect()
	var area := rect.size.x * rect.size.y
	# Sort ascending by d2, then descending by z, then ascending by area
	return [d2, -zi, area]

func choose_conn_under_mouse(ns: StringName = "activate") -> Connection:
	var space = _ensure_conn_space(ns)
	var candidates: Array = space["candidates"]
	var n := candidates.size()
	if n == 0:
		space["chosen"] = null
		return null

	var mouse_pos = get_global_mouse_position()

	# Deduplicate candidates that may have been added twice in the same frame
	var uniq := {}
	for c in candidates:
		if is_instance_valid(c):
			uniq[c] = true

	var best: Connection = null
	var best_key: Array = []
	for c in uniq.keys():
		# Optional namespace filtering: only INPUTs are hover targets
		if rev_input:
			if ns == "hover" and c.connection_type != Connection.OUTPUT:
				continue
		else:
			if ns == "hover" and c.connection_type != Connection.INPUT:
				continue
		var key = _distance_key(c, mouse_pos)
		if best == null or key < best_key:
			best = c
			best_key = key

	space["chosen"] = best
	return best

func clear_conn_candidates(ns: StringName = "activate") -> void:
	var space = _ensure_conn_space(ns)
	space["candidates"].clear()
	space["chosen"] = null

func chosen_conn(ns: StringName = "activate") -> Connection:
	return _ensure_conn_space(ns)["next_chosen"]

func advance_conn_frame(ns: StringName = "activate") -> void:
	var space = _ensure_conn_space(ns)
	space["next_chosen"] = space["chosen"]
	clear_conn_candidates(ns)



var key_to_graph: Dictionary[int, Graph] = {}
var graph_to_key: Dictionary[Graph, int] = {}


var connection_ids: Dictionary[int, Connection] = {}

func reg_conn(who: Connection):
	connection_ids[who.conn_id] = who

func del_conn(who: Connection):
	if connection_ids.get(who.conn_id) == who:
		connection_ids.erase(who.conn_id)

#func get_info() -> Dictionary:
	#var inputs = {}
	#var outputs_ = {}
	#for i in input_keys:
		#inputs[input_keys[i].conn_id] = i
	#for i in output_keys:
		#var port = [output_keys[i].conn_id]
		#for o in output_keys[i].outputs:
			#port.append(output_keys[i].outputs[o].tied_to.conn_id)
		#outputs_[i] = port
			##input_spline.
	#var base = {
		#"position": position,
		#"inputs": inputs,
		#"outputs": outputs_,
		#"created_with": get_meta("created_with")
	#}

var caches = {}
var bound = {}

func bind_cache(who: Graph, name: String, whose: Graph = null):
	if whose: name = str(whose.graph_id) + name
	bound.get_or_add(who, {})[name] = true
	caches.get_or_add(name, {})[who] = true

func where_am_i(who: Graph):
	return bound.get(who, {}).keys()

func uncache(who: Graph, name: String, whose: Graph = null):
	if whose: name = str(whose.graph_id) + name
	bound.get_or_add(who, {}).erase(name)
	caches.get_or_add(name, {}).erase(who)

func get_cache(name: String, whose: Graph = null):
	if whose: name = str(whose.graph_id) + name
	return caches.get(name, {})

var loading: bool = false

func _migrate_output_map_nodes(state: Dictionary, reg: Dictionary = {}) -> Dictionary:
	var migrated := state.duplicate(true)
	var obsolete_ids: Array = []
	for node_id in migrated:
		var pack: Dictionary = migrated[node_id]
		# Retired TextOutput was a leaf: remove its input wires while preserving
		# the rest of an older project. OutputMap additionally bridges its outputs.
		if str(pack.get("created_with", "")) not in ["output_map", "text_output"]:
			continue
		var input_connection_ids: Array = pack.get("inputs", {}).keys()
		var downstream_connection_ids: Array = []
		for port_key in pack.get("outputs", {}):
			var connections: Array = pack.outputs[port_key]
			if connections.size() > 1:
				downstream_connection_ids.append_array(connections.slice(0, connections.size() - 1))
		for source_id in migrated:
			if source_id == node_id:
				continue
			var source_pack: Dictionary = migrated[source_id]
			for port_key in source_pack.get("outputs", {}):
				var connections: Array = source_pack.outputs[port_key]
				var own_connection_id = connections[-1] if not connections.is_empty() else null
				var targets: Array = connections.slice(0, max(0, connections.size() - 1))
				var changed := false
				for obsolete_connection_id in input_connection_ids:
					if obsolete_connection_id in targets:
						targets.erase(obsolete_connection_id)
						for downstream_id in downstream_connection_ids:
							if downstream_id not in targets:
								targets.append(downstream_id)
						changed = true
				if changed:
					targets.append(own_connection_id)
					source_pack.outputs[port_key] = targets
		obsolete_ids.append(node_id)
	for node_id in obsolete_ids:
		migrated.erase(node_id)
	_recover_detached_legacy_train_step(migrated, reg)
	return migrated


func _recover_detached_legacy_train_step(state: Dictionary, reg: Dictionary) -> void:
	# OutputMap used to sit exclusively between RunModel and TrainStep. Some
	# projects were saved after that node disappeared but before its two edges
	# were bridged. The remaining graph then has a live training pipeline ending
	# at an otherwise detached TrainStep, which later makes the auto-prepare path
	# call reach(null). Recover only the unambiguous shape; do not guess when a
	# project contains several detached training branches.
	var train_step_inputs := {}
	var train_begin_targets := {}
	for node_id in state:
		var pack: Dictionary = state[node_id]
		var created_with := str(pack.get("created_with", ""))
		if created_with == "train_input":
			for connection_id in pack.get("inputs", {}):
				train_step_inputs[connection_id] = node_id
		if created_with == "train_begin":
			for port_key in pack.get("outputs", {}):
				var output_connections: Array = pack.outputs[port_key]
				if output_connections.size() > 1:
					for connection_id in output_connections.slice(0, output_connections.size() - 1):
						train_begin_targets[connection_id] = true

	if train_step_inputs.is_empty():
		return

	var connected_train_step_inputs := {}
	for node_id in state:
		var pack: Dictionary = state[node_id]
		for port_key in pack.get("outputs", {}):
			var output_connections: Array = pack.outputs[port_key]
			if output_connections.size() <= 1:
				continue
			for connection_id in output_connections.slice(0, output_connections.size() - 1):
				if train_step_inputs.has(connection_id):
					connected_train_step_inputs[connection_id] = true

	var orphan_input_ids: Array = []
	for connection_id in train_step_inputs:
		if not connected_train_step_inputs.has(connection_id):
			orphan_input_ids.append(connection_id)
	if orphan_input_ids.size() != 1:
		return

	var detached_run_models: Array = []
	for node_id in state:
		var pack: Dictionary = state[node_id]
		if str(pack.get("created_with", "")) != "run_model":
			continue
		var cfg: Dictionary = pack.get("cfg", {})
		if cfg.get("branches", {}).is_empty() and cfg.get("mapped", {}).is_empty():
			continue
		var follows_train_begin := false
		for input_id in pack.get("inputs", {}):
			if train_begin_targets.has(input_id):
				follows_train_begin = true
				break
		if not follows_train_begin:
			continue
		var outputs: Dictionary = pack.get("outputs", {})
		if not outputs.has(0):
			continue
		var output_connections: Array = outputs[0]
		if output_connections.size() != 1:
			continue
		detached_run_models.append(node_id)

	if detached_run_models.size() != 1:
		return

	var train_step_id = train_step_inputs[orphan_input_ids[0]]
	var train_step_pack: Dictionary = state[train_step_id]
	# A user-disconnected node is split into its own registered subgraph. The
	# broken OutputMap deletion is distinguishable because it left this flag
	# false even though the preceding training pipeline was already configured.
	if bool(train_step_pack.get("subgraph_occupied", false)):
		return
	var run_model_pack: Dictionary = state[detached_run_models[0]]
	var run_outputs: Array = run_model_pack.outputs[0]
	run_outputs.insert(run_outputs.size() - 1, orphan_input_ids[0])
	run_model_pack.outputs[0] = run_outputs
	# Persist the same subgraph/context which connect_to() will establish during
	# loading. This also repairs a registry which omitted the detached node.
	train_step_pack.subgraph_id = run_model_pack.get("subgraph_id", train_step_pack.get("subgraph_id", 0))
	train_step_pack.context_id = run_model_pack.get("context_id", train_step_pack.get("context_id", 0))
	train_step_pack.root_context_id = run_model_pack.get("root_context_id", train_step_pack.get("root_context_id", 0))
	train_step_pack.subgraph_occupied = true
	var subgraph_id: int = int(train_step_pack.subgraph_id)
	var registered_node_ids: Array = reg.get(subgraph_id, [])
	if train_step_id not in registered_node_ids:
		registered_node_ids.append(train_step_id)
		reg[subgraph_id] = registered_node_ids
	push_warning("Recovered a legacy OutputMap training edge from RunModel to TrainStep.")

func _parse_and_validate_state(state: Dictionary) -> Dictionary:
	var type_layers = {}
	var sequence = {}
	var chain = glob.base_node.importance_chain
	for i in len(chain):
		type_layers[chain[i]] = i
		sequence[i] = []
		
	for id in state:
		var pack = state[id]
		if typeof(pack) != TYPE_DICTIONARY: return {}
		if not pack.has("created_with") or not type_layers.has(pack.created_with): return {}
		if not pack.has("outputs") or typeof(pack.outputs) != TYPE_DICTIONARY: return {}
		if not pack.has("inputs") or typeof(pack.inputs) != TYPE_DICTIONARY: return {}
		if not pack.has("position"): return {}
		
		pack.id = id
		sequence[type_layers[pack.created_with]].append(pack)
		
	return {"sequence": sequence}

func load_graph(state: Dictionary, reg: Dictionary):
	state = _migrate_output_map_nodes(state, reg)
	
	var parsed = _parse_and_validate_state(state)
	if parsed.is_empty():
		push_error("Savefile corruption detected: Schema validation failed.")
		return false
		
	z_count = RenderingServer.CANVAS_ITEM_Z_MIN
	loading = true
	_graphs.clear()
	
	var sequence = parsed["sequence"]
	
	var edges = {} # from: [to1, to2, ...]
	var skip = {}
	for layer in sequence:
		for pack in sequence[layer]:
			var graph: Graph = get_graph(pack.created_with, Graph.Flags.NONE, pack.id, pack.llm_tag)
			graph.position = pack.position
			graph.set_meta("pack", pack)
			for port_key in pack.outputs:
				var id = pack.outputs[port_key][-1]
				graph.output_keys[port_key].update_conn_id(id)
				pack.outputs[port_key].remove_at(-1)
				edges[id] = pack.outputs[port_key]
			if graph.server_typename == "DatasetName":
				skip[graph] = true
			#	print(pack)
				graph.map_properties(pack)
			for port_id in pack.inputs:
				if not graph.input_keys.has(pack.inputs[port_id]):
					continue
				graph.input_keys[pack.inputs[port_id]].update_conn_id(port_id)
	await get_tree().process_frame
	for conn_id in edges:
		for other_conn_id in edges[conn_id]:
			if not conn_id in connection_ids:
				continue
			if not other_conn_id in connection_ids:
				continue
			connection_ids[conn_id].connect_to(connection_ids[other_conn_id], true)
			if connection_ids[conn_id].parent_graph.server_typename == "TrainBegin":
				#(connection_ids[conn_id].parent_graph.server_typename)
				#("connection happens..!")
				skip[connection_ids[conn_id].parent_graph] = true
			if connection_ids[conn_id].parent_graph.server_typename == "DatasetName":
				#(connection_ids[conn_id].parent_graph.server_typename)
				#("connection happens..! (dsname)")
				skip[connection_ids[conn_id].parent_graph] = true
	Graph._subgraph_registry.clear()
	for g in _graphs:
		if _graphs[g] in skip:
			#("fkfk")
			continue
		_graphs[g].map_properties(_graphs[g].get_meta("pack", {}))
		_graphs[g].hold_for_frame.call_deferred()
	
	for sub_id in reg:
		Graph._subgraph_registry[int(sub_id)] = []
		for gid in reg[sub_id]:
			for node_id in graphs._graphs:
				if graphs._graphs[node_id].graph_id == gid:
					Graph._subgraph_registry[int(sub_id)].append(graphs._graphs[node_id])
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	loading = false
	return true
	#Graph.debug_print_contexts()


var selected_nodes: Dictionary[Graph, bool] = {}

func set_selected(graph: Graph):
	selected_nodes[graph] = true

func unselect(graph: Graph):
	selected_nodes.erase(graph)

var rev_input = null

func unselect_all():
	for i in selected_nodes.keys():
		i.unselect()
		


func delete_all():
	# Project switches are the one intentional hard stop for decorative
	# inference state; it also invalidates delayed BFS hops before nodes leave.
	if is_instance_valid(ui):
		ui.stop_inference_anim()
	Graph._subgraph_registry.clear()
	var deleting_graphs: Array[Graph] = []
	# The scene tree is authoritative for lifecycle. A previous interrupted load
	# may have left a visible graph unregistered, and registry-only cleanup would
	# preserve that orphan forever.
	if is_instance_valid(storage):
		for child in storage.get_children():
			if child is Graph:
				deleting_graphs.append(child)
	for graph in deleting_graphs:
		graph.allow_deletion()
		graph.delete()
	# Graph.delete() intentionally waits one frame before queue_free(). Waiting
	# only one frame here used to let load_graph() start while the old nodes and
	# connection ids were still alive. Their later _exit_tree() could then erase
	# freshly loaded entries with the same saved ids. Do not return until every
	# old graph has actually left the scene tree.
	for graph in deleting_graphs:
		if is_instance_valid(graph) and graph.is_inside_tree():
			await graph.tree_exited
	# All scene-owned graphs and their Connection children have exited now. Clear
	# any orphaned bookkeeping left by an earlier interrupted transition.
	_graphs.clear()
	_graphs_ids.clear()
	_graph_names.clear()
	connection_ids.clear()
	return true
	

func get_project_data() -> Dictionary:
	var data = {"graphs": {}, "lua": {}}
	for i in _graphs:
		data["graphs"][i] = _graphs[i].get_info()
	for i in glob.tree_windows["env"].get_texts():
		pass
	return data


func save():
	pass
	#var bytes = JSON.stringify(get_project_data()).to_utf8_buffer()
	#var compressed = bytes.compress(FileAccess.CompressionMode.COMPRESSION_ZSTD)
	#(len(compressed), " ", len(bytes))
	
	# TODO: make actual delta transfer

	#var deltas = get_deltas()
	#var pull_nodes = deltas["graph_adds"]
	#deltas.erase("graph_adds")
	#var dict = {
		#"pull_nodes": pull_nodes,
		#"deltas": Marshalls.raw_to_base64(var_to_bytes(deltas))
	#}
	#var bytes = JSON.stringify(dict).to_utf8_buffer()
	#web.POST("save", bytes.compress(FileAccess.CompressionMode.COMPRESSION_ZSTD), true)

var _training_head: Graph = null
var _train_origin_graph: Graph = null
var _input_origin_graph: Graph = null

func get_abstract(graph: Graph, emit = {}) -> Dictionary:
	return {
		"type": graph.server_typename,
		"props": graph.useful_properties(),
		"emit": emit
	}

func reg_gather(gather_into, expect: Dictionary) -> Dictionary:
	var result = {}
	for conn: Connection in gather_into:
		if !conn.outputs:
			continue
		var emit = {}
		for node_conn: Connection in conn.parent_graph.outputs:
			emit[node_conn.server_name] = {}
		for i in conn.outputs:
			var tgt_conn: Connection = conn.outputs[i].tied_to
			if not is_instance_valid(tgt_conn):
				continue
			var tgt_name = tgt_conn.server_name
			var tgt_id = tgt_conn.parent_graph.graph_id
			for node_conn: Connection in conn.parent_graph.outputs:
				emit[node_conn.server_name].get_or_add(tgt_id, []).append(tgt_name)
			expect.get_or_add(tgt_id, {}).get_or_add(tgt_name, 0)
			expect[tgt_id][tgt_name] += 1
		result[conn.parent_graph.graph_id] = get_abstract(conn.parent_graph, emit)
	return result

func propagate_cycle(gather: Variant=null) -> void:
	if not propagation_q:
		return
	var dup = propagation_q
	propagation_q = {}
	for conn: Connection in dup:
		if gather != null:
			if gather in glob.arrays:
				gather.append(conn)
			else:
				gather[conn] = true
		conn.parent_graph.propagate(dup[conn])



func _relationship():
	pass


func _chain(from: Connection, to: Connection, branch_cache: Dictionary):
	var chain = branch_cache.get_or_add("chain", [])
	chain.append(from.parent_graph)
	to.parent_graph._chain_incoming(branch_cache)
	#if type.server_typename == "NeuronLayer": type = type.layer_name
	#else: type = type.server_typename
	#var starts_input: bool = chain[0].server_typename == "InputNode"
	#if type == "Conv2D":
		#var broke: bool = false
		#if len(chain) <= 1 or !starts_input:
			#broke = true
		#else:
			#for i: Graph in chain:
				#if not i.server_typename in types_2d:
					#broke = true; break
		#if not broke:
			#to.parent_graph.neurons_fixed = true
			#to.parent_graph.push_neuron_count(
			#chain[0].image_dims.x * chain[0].image_dims.y)
		#else:
			#to.parent_graph.neurons_fixed = false



func update_dependencies(from: Graph = null):
	if is_instance_valid(from):
		reach(from, _chain)
	elif is_instance_valid(_input_origin_graph):
		reach(_input_origin_graph, _chain)


func def_call(from: Connection, to: Connection, branch_cache: Dictionary):
	pass
	#branch_cache.get_or_add("a", []).append(from.parent_graph.server_typename)
	#(branch_cache)
	#(from.parent_graph.server_typename, " ", to.parent_graph.server_typename)

var reach_mode: bool = false



var input_graph_names: Dictionary[String, Graph] = {}
var input_graphs: Dictionary[Graph, String] = {}
func add_input_graph_name(who: Graph, name_: String):
	input_graph_names[name_] = who
	input_graphs[who] = name_

func has_named_input_graph(who: Graph) -> bool:
	return who in input_graphs

func input_graph_name_exists(strr: String) -> bool:
	return strr in input_graph_names

func rename_input_graph(who: Graph, name_: String):
	if not who in input_graphs: return
	input_graph_names.erase(input_graphs[who])
	input_graphs[who] = name_
	input_graph_names[name_] = who

func get_input_graph_by_name(name_: String):
	return input_graph_names.get(name_)

signal model_updated(who: String)
signal training_snapshot_invalidated(reason: String)

func invalidate_training_snapshot(reason: String = "graph_changed") -> void:
	training_snapshot_invalidated.emit(reason)

func get_input_name_by_graph(input: Graph):
	return input_graphs.get(input)

func forget_input_graph_name(name_: String):
	if name_ in input_graph_names:
		input_graphs.erase(input_graph_names[name_])
		input_graph_names.erase(name_)

signal input_graph_forgot
func forget_input_graph(who: Graph):
	if who in input_graphs:
		input_graph_forgot.emit()
		input_graph_names.erase(input_graphs[who])
		input_graphs.erase(who)
		model_updated.emit(glob.DEFAULT_MODEL_NAME)




signal spline_connected(from_conn: Connection, to_conn: Connection)
signal spline_disconnected(from_conn: Connection, to_conn: Connection)


func simple_reach(from_graph: Graph, configs: bool = false) -> Dictionary[Graph, bool]:
	var gathered: Dictionary[Graph, bool] = {}
	var callable = func(from: Connection, to: Connection, branch_cache: Dictionary):
		gathered[to.parent_graph] = true
		gathered[from.parent_graph] = true
		if configs:
			for i in to.parent_graph.config_conns:
				if !i.inputs: continue
				gathered[i.inputs.keys()[0].origin.parent_graph] = true
	if configs and is_instance_valid(from_graph):
		for i in from_graph.config_conns:
			if !i.inputs: continue
			gathered[i.inputs.keys()[0].origin.parent_graph] = true
	reach(from_graph, callable)
	return gathered

var fork_allowed: bool = false

func allow_deletion_all():
	for i in graphs._graphs.values():
		var g: Graph = i
		g.allow_deletion()

func set_fork_allow(do: bool):
	fork_allowed = do
	for i in graphs._graphs.values():
		var g: Graph = i
		for conn in g.input_key_by_conn:
			conn.set_fork_allowed(do) 
		for conn in g.output_key_by_conn:
			conn.set_fork_allowed(do) 

func reach(from_graph: Graph, call: Callable = def_call):
	reach_mode = true
	
	var node_caches = {}
	node_caches[from_graph] = {}
	from_graph._chain_incoming(node_caches[from_graph])
	
	var visited_graphs = {}

	var gather = func(iter):
		var page = {}
		for me: Connection in iter:
			var parent = me.parent_graph
			if visited_graphs.has(parent):
				continue
			visited_graphs[parent] = true

			if me.connection_type == Connection.OUTPUT:
				var from_cache = node_caches.get(parent, {})
				for other in iter[me]:
					var branch_cache = from_cache.duplicate(true)
					node_caches[other.parent_graph] = branch_cache
					call.call(me, other, branch_cache)
			page[parent] = true
		return page

	from_graph.propagate({})
	var gathered = []
	var prev_q = {}
	gathered.append(gather.call(_propagated_from))
	while _propagated_from:
		_propagated_from.clear()
		prev_q = propagation_q
		propagate_cycle()
		gathered.append(gather.call(_propagated_from))
	gathered[-1] = gather.call(prev_q)
	reach_mode = false


func is_node(who: Graph, typename: String) -> bool:
	return who.server_typename == typename

func is_nodes(who: Graph, ...typenames: Array) -> bool:
	for typename in typenames:
		if who.server_typename == typename:
			return true
	return false

func in_nodes(who: Graph, typenames: Dictionary) -> bool:
#	print(typenames)
	if who.server_typename in typenames:
		return true
	return false

func get_syntax_tree(input) -> Dictionary:
	if is_instance_valid(input) and LanguageAdapter.is_language(input):
		push_error("Language demo graphs use LanguageGraphAdapter, not the numeric runtime serializer")
		return {}
	var gathered = {}
	var expect = {}
	var index_counter: int = 0
	if not input: return {}
	
	input.propagate({})
	gathered[str(index_counter)] = reg_gather(input.outputs, expect)

	var prev_q = {}
	while _propagated_from:
		index_counter += 1
		_propagated_from.clear()
		prev_q = propagation_q
		propagate_cycle()
		gathered[str(index_counter)] = reg_gather(_propagated_from, expect)
		for conn in prev_q:
			var g: Graph = conn.parent_graph
			if not gathered[str(index_counter)].has(g.graph_id):
				gathered[str(index_counter)][g.graph_id] = get_abstract(g)
	return {
		"pages": gathered,
		"expect": expect,
		"train": 1
	}

func get_llm_summary():
	#var summary = {}
	var summary = {"nodes": {}, "edges": []}
	for i in _graphs:
		var node: Graph = _graphs[i]
		var outputs = {}
		for j in node.outputs:
			var output_splines = []
			for o in j.outputs:
				output_splines.append({"to": j.outputs[o].tied_to.parent_graph.llm_tag, "port": j.outputs[o].tied_to.hint})
				summary["edges"].append({"from": 
					{"port": j.outputs[o].origin.hint, "tag": j.outputs[o].origin.parent_graph.llm_tag},
					"to":
					{"port": j.outputs[o].tied_to.hint, "tag": j.outputs[o].tied_to.parent_graph.llm_tag}})
			outputs[j.hint] = output_splines
		#(node.llm_tag)
		summary["nodes"][node.llm_tag] = {"type": glob.llm_name_unmapping[node.get_meta("created_with")],
		"config": node.llm_config(), "outputs": outputs}
	#(summary)
	return summary
	#(JSON.stringify(summary, "\t"))

#func run_request():
	#save()
	#var syntax_tree = get_syntax_tree(_input_origin_graph)
	#await web.POST("train", compress_dict_gzip({"train": 0, 
	#"session": "neriqward", 
	#"graph": syntax_tree}), true)


var graph_types: Dictionary = NodeCatalog.source_map()

var node_names = graph_types.keys()

var input_types = glob.to_set(NodeCatalog.input_types())

func get_alt_nodes(of_node: Graph):
	var created_with = of_node.get_meta("created_with")
	var result = []
	if created_with in input_types:
		result = input_types.keys()
	else:
		result = graph_types.keys()

	return GraphRoles.alternatives(StringName(created_with), result, LanguageAdapter.is_language(of_node))

func has_input():
	for i in _graphs:
		if is_instance_valid(_graphs[i]) and GraphRoles.is_input(_graphs[i]):
			return true
	return false

func is_input_valid():
	for i in _graphs:
		if is_instance_valid(_graphs[i]) and GraphRoles.is_input(_graphs[i]):
			return true
	return false
	



func _enter_tree() -> void:
	_reindex_for_buttons()

var graph_buttons: Array[Dictionary] = []

func _reindex_for_buttons():
	graph_buttons = NodeCatalog.button_definitions()

var top_graph_at_mouse: Graph = null

func _top_graph_under_mouse(pad: float = 10.0) -> Graph:
	if not is_instance_valid(storage):
		return null
	var mouse := get_global_mouse_position()
	var best: Graph = null
	var best_z := -INF
	for g in storage.get_children():
		if g is Graph:
			var r: ColorRect = g.rect
			var tl := r.global_position - Vector2.ONE * pad
			var sz := r.size + Vector2(pad, pad) * 2.0
			if Rect2(tl, sz).has_point(mouse):
				# Pick highest z_index
				if g.z_index > best_z:
					best_z = g.z_index
					best = g
	return best


func delete_graph_by_id(id: int):
	if id in _graphs:
		_graphs[id].delete()

var z_count: int = RenderingServer.CANVAS_ITEM_Z_MIN
func get_graph(typename = "base", flags = Graph.Flags.NONE, id: int = 0, tag: String = "") -> Graph:
	if str(typename) == "top_output":
		typename = &"token_labels"
	var type_id := StringName(typename)
	var new := glob.base_node.instantiate_node(type_id) as Graph
	if not is_instance_valid(new):
		return null
	new.set_meta("created_with", typename)
	if id:
		new.graph_id = id
	new.graph_flags = flags
	var last = storage.get_child(-1) if storage.get_child_count() else null
	z_count += last.z_space if last else 0
	new.z_index = z_count
	if tag:
		glob.set_llm_tag(new, tag)
	else:
		glob.set_llm_tag(new, glob.get_llm_tag(new))
	new.invoked_with = get_graph.bind(typename, flags, id, tag)
	storage.add_child(new)
	add(new)
	if flags == Graph.Flags.NEW:
		node_added.emit(new)
		learner.notify_update()
	#storage.move_child(new, -1)
	return new


func create_graph_at_screen_position(type_id: StringName, screen_position: Vector2) -> Graph:
	if not graph_types.has(type_id):
		return null
	var graph := get_graph(type_id, Graph.Flags.NEW)
	var world_position := glob.screen_to_world(screen_position)
	if is_instance_valid(graph.rect):
		graph.global_position = world_position - graph.rect.position - graph.rect.size / 2.0
	else:
		graph.global_position = world_position
	return graph


signal node_added(who: Graph)

signal preview_generation_finished(request_id: int, result: Dictionary)
signal graph_control_capture_finished(request_id: int, result: Dictionary)

var _preview_request_id := 0
var _preview_results: Dictionary[int, Dictionary] = {}
var _graph_capture_request_id := 0
var _graph_capture_results: Dictionary[int, Dictionary] = {}


func queue_preview_generation(type_names: Array = [], output_dir: String = "") -> int:
	_preview_request_id += 1
	var request_id := _preview_request_id
	_preview_results.erase(request_id)
	_run_queued_preview_generation.call_deferred(request_id, type_names.duplicate(), output_dir)
	return request_id


func preview_generation_result(request_id: int) -> Dictionary:
	return _preview_results.get(request_id, {})


func _run_queued_preview_generation(
	request_id: int,
	type_names: Array,
	output_dir: String
) -> void:
	var result := await generate_previews(type_names, output_dir)
	_preview_results[request_id] = result
	preview_generation_finished.emit(request_id, result)


func capture_graph_control(
	type_name: StringName,
	control_path: String,
	output_path: String,
	options: Dictionary = {}
) -> Dictionary:
	if not graph_types.has(type_name):
		return {"ok": false, "error": "Unknown graph type: %s" % type_name}
	var graph := get_graph(type_name, Graph.Flags.NONE)
	if not is_instance_valid(graph):
		return {"ok": false, "error": "Cannot instantiate graph type: %s" % type_name}
	for _frame in 3:
		await get_tree().process_frame
	var target := UICaptureCore.resolve_control(graph, control_path)
	if not is_instance_valid(target):
		graph.queue_free()
		await get_tree().process_frame
		return {
			"ok": false,
			"error": "Graph control is not found: %s/%s" % [type_name, control_path],
		}
	var result: Dictionary = await ui.capture_control(target, output_path, options)
	result["graph_type"] = str(type_name)
	result["control_path"] = control_path
	graph.queue_free()
	await get_tree().process_frame
	return result


func queue_graph_control_capture(
	type_name: StringName,
	control_path: String,
	output_path: String,
	options: Dictionary = {}
) -> int:
	_graph_capture_request_id += 1
	var request_id := _graph_capture_request_id
	_graph_capture_results.erase(request_id)
	_run_queued_graph_control_capture.call_deferred(
		request_id,
		type_name,
		control_path,
		output_path,
		options.duplicate(true)
	)
	return request_id


func graph_control_capture_result(request_id: int) -> Dictionary:
	return _graph_capture_results.get(request_id, {})


func _run_queued_graph_control_capture(
	request_id: int,
	type_name: StringName,
	control_path: String,
	output_path: String,
	options: Dictionary
) -> void:
	var result := await capture_graph_control(type_name, control_path, output_path, options)
	_graph_capture_results[request_id] = result
	graph_control_capture_finished.emit(request_id, result)


func generate_previews(type_names: Array = [], output_dir: String = "") -> Dictionary:
	var generated: PackedStringArray = []
	var errors: PackedStringArray = []
	if not is_instance_valid(storage) or not is_instance_valid(glob.cam):
		return {"generated": generated, "errors": PackedStringArray(["Graph workspace is not ready."])}

	var names := type_names.duplicate() if not type_names.is_empty() else graph_types.keys()
	var camera: Camera2D = glob.cam
	var previous_position := camera.position
	var previous_zoom := camera.zoom
	var previous_target_position: Variant = camera.get("target_position")
	var previous_target_zoom: Variant = camera.get("target_zoom")
	var palette: CanvasLayer = null
	var create_cta: CanvasItem = null
	if is_instance_valid(glob.base_node):
		palette = glob.base_node.get_node_or_null("WIN_GRAPH/NodePalette") as CanvasLayer
		create_cta = glob.base_node.get_node_or_null("WIN_GRAPH/Cta") as CanvasItem
	var palette_was_visible := false
	var create_cta_was_visible := false
	var foreground_was_visible: bool = glob.fg.visible
	glob.fg.hide()
	if is_instance_valid(palette):
		palette_was_visible = palette.visible
	if is_instance_valid(create_cta):
		create_cta_was_visible = create_cta.visible

	if is_instance_valid(palette):
		palette.visible = false
	if is_instance_valid(create_cta):
		create_cta.visible = false
	var preview_zoom := PlatformInput.preview_camera_zoom(
		get_tree().root.content_scale_factor
	)
	camera.position = Vector2.ZERO
	camera.zoom = Vector2.ONE * preview_zoom
	if previous_target_position != null:
		camera.set("target_position", Vector2.ZERO)
	if previous_target_zoom != null:
		camera.set("target_zoom", preview_zoom)

	if not output_dir.is_empty():
		var absolute_output := ProjectSettings.globalize_path(output_dir)
		var make_dir_error := DirAccess.make_dir_recursive_absolute(absolute_output)
		if make_dir_error != OK:
			errors.append("Cannot create preview output directory: %s" % output_dir)

	var original_lang = glob.get_lang()
	for requested_name in names:
		var type_id := StringName(requested_name)
		if not graph_types.has(type_id):
			errors.append("Unknown graph type: %s" % type_id)
			continue

		for lang in ["en", "ru", "kz"]:
			glob.change_lang(lang)
			var node := get_graph(type_id, Graph.Flags.NONE)
			await get_tree().process_frame
			await get_tree().process_frame
			if not is_instance_valid(node) or not is_instance_valid(node.rect):
				if lang == "en":
					errors.append("Graph type has no preview rect: %s" % type_id)
				if is_instance_valid(node):
					node.queue_free()
				await get_tree().process_frame
				continue

			node.global_position = -node.rect.position - node.rect.size / 2.0
			await get_tree().process_frame
			await get_tree().process_frame
			var rect := node.get_graph_rect().grow(20.0)
			var screen_rect := Rect2(
				glob.world_to_screen(rect.position),
				glob.world_to_screen(rect.end) - glob.world_to_screen(rect.position)
			)
			var path := NodePaletteCatalog.icon_path(type_id) if output_dir.is_empty() else output_dir.path_join(lang).path_join(NodePaletteCatalog.icon_filename(type_id))
			
			var dir_path := ProjectSettings.globalize_path(path.get_base_dir())
			if not DirAccess.dir_exists_absolute(dir_path):
				DirAccess.make_dir_recursive_absolute(dir_path)

			await ui.graph_shot(screen_rect, path)
			if FileAccess.file_exists(path):
				generated.append(path)
				if output_dir.is_empty() and lang == "en":
					# Older callers use the unlocalized path as their fallback.
					var fallback := "res://node_icons/" + NodePaletteCatalog.icon_filename(type_id)
					DirAccess.copy_absolute(ProjectSettings.globalize_path(path), ProjectSettings.globalize_path(fallback))
			else:
				errors.append("Preview was not written: %s" % path)
			node.queue_free()
			await get_tree().process_frame

	glob.change_lang(original_lang)
	glob.fg.visible = foreground_was_visible

	camera.position = previous_position
	camera.zoom = previous_zoom
	if previous_target_position != null:
		camera.set("target_position", previous_target_position)
	if previous_target_zoom != null:
		camera.set("target_zoom", previous_target_zoom)
	if is_instance_valid(palette):
		palette.visible = palette_was_visible
	if is_instance_valid(create_cta):
		create_cta.visible = create_cta_was_visible
	return {"generated": generated, "errors": errors}



var graph_layers: Dictionary[int, CanvasLayer] = {}
func _ready():
	pass
	#generate_previews()
	#(await web.send_get("test"))



func is_layer(g: Graph, layer: StringName):
	return g.server_typename == "NeuronLayer" and g.layer_name == layer

func push_1d(columns: int, who: Graph):
	var target = who.get_first_descendants()
	#(columns)
	#(target)
	for i in target:
		#(i.server_typename)
		if is_node(i, "Reshape2D"):
			i.reload_config()
		if is_node(i, "SoftmaxNode"):
			#("Ff")
			i.upd(columns)
		if is_node(i, "Flatten"):
			push_1d(columns, i)
		if is_node(i, "ClassifierNode"):
			i.push_result_meta({"datatype": "1d", "x": columns})
		if is_node(i, "Concat"):
			push_1d(i.get_x(), i)

## A picture's size (and its channels: 1 grey, 3 colour, or a convolution's
## filters) passed on to the nodes that take it.
func push_2d(columns: int, rows: int, target, channels: int = 1):
	#("repush..")
	if !glob.is_iterable(target): target = [target]
	for i in target:
		if i.has_method("set_image_shape"):
			i.set_image_shape(columns, rows, channels)
		if is_layer(i, "Conv2D"):
			i.input_channels = channels
			i.update_grid(columns, rows)
		if is_layer(i, "MaxPool2D"):
			i.input_channels = channels
			i.update_grid(columns, rows)
		if i.server_typename == "Flatten":
			i.set_count(rows * columns * channels)

func unpush_2d(target):
	if !glob.is_iterable(target): target = [target]
	for i in target:
		if is_layer(i, "Conv2D"):
			i.update_grid(0, 0)
		if is_layer(i, "MaxPool2D"):
			i.update_grid(0, 0)

func conning() -> bool:
	return conns_active.size() > 0 or rev_input

var pos_cache: Dictionary = {}
var last_frame_visible: bool = true
func _process(delta: float) -> void:
	#(_graphs.size())
	#(get_llm_summary().nodes.keys())
	#for i in input_graph_names.keys():
	#	if not is_instance_valid(input_graph_names[i]):
	#		input_graphs.erase(input_graph_names[i])
	#		input_graph_names.erase(i)
	
	if selected_nodes.size() > 0:
		glob.set_menu_type(self, "edit_graph")
		var who = selected_nodes.keys()[0]
		if glob.mouse_alt_just_pressed and not who.dragging:
			who.define_graph()
		#print("a")
	else:
		glob.reset_menu_type(self, "edit_graph")
	if glob.get_occupied("graph_buffer") and glob.get_occupied("graph_buffer").process_mode == Node.PROCESS_MODE_DISABLED:
		glob.un_occupy(glob.get_occupied("graph_buffer"), "graph_buffer")

	choose_conn_under_mouse("activate")
	choose_conn_under_mouse("hover")

	var prev = glob.hovered_connection
	var now = chosen_conn("hover")
	if prev != now:
		glob.hovered_connection_changed = true
		if is_instance_valid(prev) and is_instance_valid(prev.parent_graph):
			prev.parent_graph.hold_for_frame()
	glob.hovered_connection = now
	if is_instance_valid(now) and is_instance_valid(now.parent_graph):
		now.parent_graph.hold_for_frame()

	#if glob.space_just_pressed:
	#	print(get_llm_summary())
	advance_conn_frame("activate")
	advance_conn_frame("hover")

	top_graph_at_mouse = _top_graph_under_mouse( 0 )

	if is_instance_valid(top_graph_at_mouse):
		top_graph_at_mouse.hold_for_frame()

	if not last_frame_visible: 
		last_frame_visible = visible; return
	last_frame_visible = visible
	
	var vp = Rect2(Vector2.ZERO, glob.window_size)
	var dc = 0
	
	if not is_instance_valid(storage): return

	for graph: Graph in storage.get_children():
		#("F")
		var r = graph.rect
		
		var vis: bool = visible
		graph.hold_process = graph.hold_process or graph.exist_time < 1.0
		if not graph.dragging and visible:
			if graph.hold_process:
				vis = true
			else:
				var rect = r.get_global_rect()
				var gp = rect.position - Vector2(10,10)
				var s  = rect.size + Vector2(20,20)

				var p0 = glob.world_to_screen(gp)
				var p1 = glob.world_to_screen(gp + Vector2(s.x, 0.0))
				var p2 = glob.world_to_screen(gp + Vector2(0.0, s.y))
				var p3 = glob.world_to_screen(gp + s)

				var minx = min(p0.x, p1.x, p2.x, p3.x)
				var maxx = max(p0.x, p1.x, p2.x, p3.x)
				var miny = min(p0.y, p1.y, p2.y, p3.y)
				var maxy = max(p0.y, p1.y, p2.y, p3.y)
				var rect_screen = Rect2(Vector2(minx, miny), Vector2(maxx - minx, maxy - miny))

				vis = rect_screen.intersects(vp)
			#(graph.get_title())
		#elif graph.hold_process:
		#	print("..")
		
		var force_held: bool = false
		if !visible and last_frame_visible: force_held = true
		if visible and (vis or graph.hold_process or graph.dragging or graph.active_output_connections or graph.hold_process):
			var inside = graph.is_mouse_inside()
			var padded_inside = (Rect2(graph.rect.global_position-Vector2(50,50), 
			graph.rect.size * graph.rect.scale * graph.scale + 2*Vector2(50,50)).has_point(get_global_mouse_position()))
			if not ui.active_splashed() and (graph.hold_process or padded_inside or graph.active_output_connections):
				graph.process_mode = PROCESS_MODE_INHERIT
				#(graph.hold_process)
				if inside:
					force_held = true
					graph.hold_for_frame()
			else:
				if graph.process_mode != PROCESS_MODE_DISABLED:
					#("GJKGJ")
		#			print(graph.get_title())
					graph.stopped_processing()
				graph.process_mode = PROCESS_MODE_DISABLED
			graph.show()
		elif not graph.hold_process:
			#("h..")
			graph.hide()
			if graph.process_mode != PROCESS_MODE_DISABLED:
			#	print("GJKGJ")
				graph.stopped_processing()
			graph.process_mode = PROCESS_MODE_DISABLED

		if graph.hold_process and !force_held:
			graph.hold_process = false
		
		dc += int(graph.process_mode != PROCESS_MODE_DISABLED)
	#(dc)
