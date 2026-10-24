extends Node
const Adapter = preload("res://scripts/language_models/language_graph_adapter.gd")
const Validator = preload("res://scripts/language_models/language_graph_validator.gd")
signal state_changed(state: StringName)
signal snapshot_ready(snapshot: Dictionary)
signal training_preview_applied()
signal failed(error: Dictionary)
const AUTOMATIC_DELAY := 0.3
var state: StringName = &"idle"
var training_active := false
var generated_ids: Array = []
var prefix_ids: Array = []
var last_snapshot: Dictionary = {}
var graph_revision := 0
var session_id := ""
var source: Node
var service: Node
var capabilities: Dictionary = {}
var _pending := -1
var _phase := ""
var _visual_request := -1
var _auto := false
var _graph: Dictionary = {}
var _text := ""
var _displayed_text := ""
var _fingerprint := ""
var _session_fingerprint := ""
var _view_nodes: Array = []
var _automatic_remaining := -1.0
var _intent := "preview"
var _target := ""
var _temperature := 0.7
var _top_k := 5
var _connection_targets: Array[Node] = []

func setup(value: Node) -> void:
	# GraphManager disables offscreen Graph nodes; the controller keeps receiving edges.
	process_mode = Node.PROCESS_MODE_ALWAYS
	if is_instance_valid(service) and service.response_ready.is_connected(_response): service.response_ready.disconnect(_response)
	service = value
	service.response_ready.connect(_response)
	if not graphs.spline_connected.is_connected(on_language_connection_added):
		graphs.spline_connected.connect(on_language_connection_added)
		graphs.spline_disconnected.connect(_on_connection_removed)

func on_text_edited() -> void:
	_cancel_session()
	_auto = false
	_connection_targets.clear()
	generated_ids = []
	prefix_ids = []
	last_snapshot = {}
	_automatic_remaining = -1.0 if training_active else AUTOMATIC_DELAY
	_state(&"training" if training_active else &"idle")

func begin_training() -> void:
	reset(false)
	training_active=true
	_state(&"training")

func apply_training_snapshot(snapshot: Dictionary, skip_nodes: Array = []) -> void:
	if not training_active: return
	last_snapshot=snapshot
	snapshot_ready.emit(snapshot)
	_apply_snapshot(snapshot,skip_nodes)

func training_visible_nodes() -> Array:
	var result: Array=[]
	if not is_instance_valid(source): return result
	for node in Adapter.component(source):
		if not is_instance_valid(node) or not node.is_visible_in_tree(): continue
		var bounds: Rect2=node.rect.get_global_transform_with_canvas()*Rect2(Vector2.ZERO,node.rect.size)
		if node.get_viewport_rect().intersects(bounds): result.append(node)
	return result

func apply_training_preview(snapshot: Dictionary) -> Array:
	var applied: Array=[]
	if not training_active: return applied
	var traces: Dictionary=snapshot.get("nodes",{})
	for node in training_visible_nodes():
		var id := str(node.graph_id)
		if traces.has(id) and node.has_method("apply_language_trace"):
			node.apply_language_trace(traces[id])
			applied.append(id)
	if not applied.is_empty(): training_preview_applied.emit()
	return applied

func clear_training_snapshot() -> void:
	reset(true)
	_state(&"training" if training_active else &"idle")

func end_training() -> void:
	training_active=false
	_state(&"idle")
	_pump_connections()

func start(node: Node) -> void:
	reset(false)
	source = node
	_begin(Adapter.collect(node), str(node.cfg.get("text", "")), "preview")

func start_graph(graph: Dictionary, text: String) -> void:
	reset(false)
	_begin(graph, text, "preview")

func step(temperature: float = 0.7, top_k: int = 5) -> void:
	if training_active or _pending >= 0 or state == &"completed": return
	_auto = false
	_temperature = clampf(temperature, 0, 2)
	_top_k = clampi(top_k, 1, 20)
	_intent = "run_step"
	_target = ""
	_automatic_remaining = -1
	var graph: Dictionary = Adapter.collect(source) if is_instance_valid(source) else _graph
	if session_id == "" or _session_fingerprint != _graph_fingerprint(graph):
		_begin(graph, _prompt(), "run_step")
	else:
		_graph = graph
		_forward()

# Kept for the explicit Run action and deterministic regression fixtures.
func continue_generation() -> void:
	if training_active: return
	_auto = true
	_intent = "run_step"
	if _pending >= 0: return
	if state == &"completed": return
	if session_id == "":
		var graph: Dictionary = Adapter.collect(source) if is_instance_valid(source) else _graph
		_begin(graph, _prompt(), "run_step")
	else: _forward()

func _prompt() -> String:
	if not is_instance_valid(source): return _text
	var text := str(source.cfg.get("text", ""))
	if text == _displayed_text: return _text
	generated_ids = []
	prefix_ids = []
	return text

func _begin(graph: Dictionary, text: String, intent: String, target: String = "") -> void:
	_cancel_session()
	_graph = graph.duplicate(true)
	_text = text
	_displayed_text = str(source.cfg.get("text", text)) if is_instance_valid(source) else text
	_intent = intent
	_target = target
	prefix_ids = []
	if is_instance_valid(source):
		_view_nodes = Adapter.component(source)
		_fingerprint = _graph_fingerprint(Adapter.collect(source))
	if text.strip_edges().is_empty():
		reset(true)
		return
	_state(&"running")
	# Model-specific shape validation must wait for actual capabilities.
	_send("capabilities", {})

func _send(method: String, params: Dictionary) -> void:
	_phase = method
	_pending = service.request(StringName(method), params, session_id, graph_revision)
	if method in ["run_step", "preview", "preview_node"] and is_instance_valid(source) and source.has_method("begin_input_visual"):
		_visual_request = _pending
		source.begin_input_visual(_visual_request)

func _finish_input_visual() -> void:
	if _visual_request >= 0 and is_instance_valid(source): source.finish_input_visual(_visual_request)
	_visual_request = -1

func _response(response: Dictionary) -> void:
	if response.get("request_id") != _pending or response.get("graph_revision") != graph_revision: return
	if _phase not in ["capabilities", "open_session"] and response.get("session_id", "") != session_id: return
	_finish_input_visual()
	_pending = -1
	if not response.ok:
		_error(response.error)
		return
	var result: Dictionary = response.result
	match _phase:
		"capabilities":
			capabilities = result
			if not _validate(): return
			_send("open_session", {"graph":_graph})
		"open_session":
			session_id = result.session_id
			_session_fingerprint = _graph_fingerprint(_graph)
			_send("tokenize", {"text":_text})
		"tokenize":
			prefix_ids = result.ids
			_forward()
		"preview", "preview_node", "run_step":
			if _phase == "run_step":
				generated_ids = result.generated_ids
				_displayed_text = _text + str(result.decoded_text)
				if is_instance_valid(source): source.apply_generated_text(_displayed_text)
			last_snapshot = result
			snapshot_ready.emit(result)
			_apply_snapshot(result)
			if result.get("finished", false) or generated_ids.size() >= 32:
				_auto = false
				_state(&"completed")
			elif _auto:
				_next_frame()
			else:
				_state(&"idle")
				_pump_connections()

func _validate() -> bool:
	var count := prefix_ids.size() + generated_ids.size() if not prefix_ids.is_empty() else -1
	var validation := Validator.validate(_graph, capabilities, count)
	if not validation.ok:
		_error(validation.errors[0])
		return false
	for node in _graph.nodes:
		if validation.shapes.has(str(node.id)): node.merge(validation.shapes[str(node.id)], true)
	return true

func _forward() -> void:
	if prefix_ids.is_empty():
		_send("tokenize", {"text":_text})
		return
	if not _validate(): return
	_state(&"running")
	var params := {"graph":_graph, "prefix_ids":prefix_ids, "generated_ids":generated_ids}
	if _intent == "run_step": params.merge({"temperature":_temperature, "top_k":_top_k})
	if _intent == "preview_node": params.target_id = _target
	_send(_intent, params)

func _next_frame() -> void:
	await get_tree().process_frame
	if _auto and _pending < 0 and is_inside_tree():
		_intent = "run_step"
		_forward()

func _apply_snapshot(snapshot: Dictionary, skip_nodes: Array = []) -> void:
	if not is_instance_valid(source): return
	var traces: Dictionary = snapshot.get("nodes", {})
	for node in Adapter.component(source):
		if is_instance_valid(node) and not str(node.graph_id) in skip_nodes and traces.has(str(node.graph_id)) and node.has_method("apply_language_trace"):
			node.apply_language_trace(traces[str(node.graph_id)])

func update_views_from_snapshot() -> void:
	_apply_snapshot(last_snapshot)

func on_language_connection_added(from_conn: Connection, to_conn: Connection) -> void:
	if graphs.loading or from_conn.config_conn or to_conn.config_conn or not is_instance_valid(source): return
	if not Adapter.component(to_conn.parent_graph).has(source): return
	var from_kind := StringName(from_conn.parent_graph.get_meta("created_with", ""))
	var to_kind := StringName(to_conn.parent_graph.get_meta("created_with", ""))
	if not Adapter.Contract.OPS.has(from_kind) or not Adapter.Contract.OPS.has(to_kind): return
	var target: Node = to_conn.parent_graph
	_connection_targets.append(target)
	_fingerprint = _graph_fingerprint(Adapter.collect(source))
	_pump_connections()

func _pump_connections() -> void:
	if training_active or _pending >= 0 or _connection_targets.is_empty(): return
	var target := _connection_targets.pop_front() as Node
	if not is_instance_valid(target) or not Adapter.component(target).has(source):
		_pump_connections()
		return
	_begin(Adapter.upstream(target, source), _prompt(), "preview_node", str(target.graph_id))

func _on_connection_removed(from_conn: Connection, to_conn: Connection) -> void:
	if from_conn.config_conn or to_conn.config_conn or not is_instance_valid(source): return
	if not Adapter.component(from_conn.parent_graph).has(source) and not Adapter.component(to_conn.parent_graph).has(source): return
	_cancel_session()
	_auto = false
	_connection_targets.clear()
	# The signal precedes edge removal; descendants can already be collected safely.
	for node in Adapter.downstream(to_conn.parent_graph):
		if node.has_method("clear_language_trace"): node.clear_language_trace()
	_fingerprint = ""
	_state(&"training" if training_active else &"idle")

func _cancel_session() -> void:
	_finish_input_visual()
	graph_revision += 1
	if is_instance_valid(service):
		if _pending >= 0: service.cancel(_pending)
		service.close_session(session_id)
	_pending = -1
	session_id = ""
	_session_fingerprint = ""

func invalidate_graph() -> void:
	_cancel_session()
	_auto = false
	_fingerprint = ""

func stop() -> void:
	_cancel_session()
	_auto = false
	_automatic_remaining = -1
	_connection_targets.clear()
	last_snapshot = {}
	_state(&"stopped")

func reset(clear_views: bool = false) -> void:
	_cancel_session()
	_auto = false
	_automatic_remaining = -1
	_connection_targets.clear()
	generated_ids = []
	prefix_ids = []
	last_snapshot = {}
	if clear_views:
		var previous := _view_nodes.duplicate()
		if is_instance_valid(source):
			for node in Adapter.component(source):
				if not previous.has(node): previous.append(node)
		for node in previous:
			if is_instance_valid(node) and node.has_method("clear_language_trace"): node.clear_language_trace()
		_view_nodes.clear()
	_state(&"idle")

func _graph_fingerprint(graph: Dictionary) -> String:
	var parts := PackedStringArray([str(graph.get("source_id", ""))])
	for node in graph.get("nodes", []):
		parts.append("%s:%s:%s" % [str(node.id), str(node.op), "" if node.op == "text_input" else JSON.stringify(node.get("config", {}))])
	parts.append(JSON.stringify(graph.get("edges", [])))
	return "|".join(parts)

func _process(delta: float) -> void:
	if not is_instance_valid(source) or training_active: return
	var fingerprint := _graph_fingerprint(Adapter.collect(source))
	if fingerprint != _fingerprint:
		_fingerprint = fingerprint
		# Parameter/topology edits invalidate the session, never refresh content.
		if session_id != "" or _pending >= 0:
			_cancel_session()
			_auto = false
			_connection_targets.clear()
			_state(&"idle")
	if _automatic_remaining < 0: return
	_automatic_remaining -= delta
	if _automatic_remaining <= 0:
		_automatic_remaining = -1
		generated_ids = []
		_begin(Adapter.collect(source), str(source.cfg.get("text", "")), "preview")

func _error(error: Dictionary) -> void:
	_auto = false
	_state(&"error")
	failed.emit(error)
	if is_instance_valid(source):
		for node in Adapter.component(source):
			if str(node.graph_id) == str(error.get("node_id", "")) and node.has_method("_show_error"): node._show_error(error)
	_pump_connections()

func _state(value: StringName) -> void:
	state = value
	state_changed.emit(state)

func _exit_tree() -> void:
	_cancel_session()
	_view_nodes.clear()
	if is_instance_valid(service) and service.response_ready.is_connected(_response): service.response_ready.disconnect(_response)
