extends Node
const Dummy = preload("res://scripts/language_models/dummy_language_backend.gd")
const VocabBackend = preload("res://scripts/language_models/vocab_language_backend.gd")
const OnnxBackend = preload("res://scripts/language_models/onnx_language_backend.gd")
const Contract = preload("res://scripts/language_models/language_contract.gd")
const Adapter = preload("res://scripts/language_models/language_graph_adapter.gd")
signal response_ready(response: Dictionary)
signal progress_ready(response: Dictionary)
var backend: RefCounted
var _serial := 0

func _init() -> void:
	set_backend(OnnxBackend.new())

func _process(_delta: float) -> void:
	if backend!=null and backend.has_method("poll"): backend.poll()

func set_backend(value: RefCounted) -> void:
	if backend != null:
		backend.response_ready.disconnect(_receive)
		backend.progress_ready.disconnect(_receive_progress)
		backend.dispose()
	backend = value
	backend.response_ready.connect(_receive)
	backend.progress_ready.connect(_receive_progress)

func request(method: StringName, params: Dictionary, session_id: String, graph_revision: int) -> int:
	_serial += 1
	backend.submit(Contract.make_request(method, params, _serial, session_id, graph_revision))
	return _serial

func _receive(response: Dictionary) -> void:
	var errors := Contract.validate_response(response)
	if not errors.is_empty():
		response = response.duplicate()
		response["ok"] = false
		response["result"] = null
		response["error"] = {"code":"invalid_response","message":", ".join(errors),"node_id":""}
	response_ready.emit(response)

func _receive_progress(response: Dictionary) -> void:
	if Contract.validate_response(response).is_empty(): progress_ready.emit(response)

func cancel(request_id: int) -> void:
	request(&"cancel",{"target_request_id":request_id},"",0)

func close_session(session_id: String) -> void:
	if session_id != "": request(&"close_session",{},session_id,0)

func accepts_connection(from: Node, to: Node) -> bool:
	return Adapter.accepts_connection(from,to)

func connection_datatype(from: Node, to: Node) -> Variant:
	return Adapter.connection_datatype(from,to)

func _exit_tree() -> void:
	if backend != null: backend.dispose()

func refresh_profile(node: Node) -> void:
	var language := Adapter.is_language(node)
	var members:=Adapter.component(node)
	for member in members:
		if member.get_meta("created_with", "") not in ["layer","concat","softmax"]: continue
		for output in member.outputs:
			if output.config_conn: continue
			if not output.has_meta("numeric_branching"):
				output.set_meta("numeric_branching",{"multiple":output.multiple_splines,"limits":output.max_splines_by_keyword.duplicate()})
			var original: Dictionary = output.get_meta("numeric_branching")
			output.multiple_splines=true if language else original.multiple
			output.max_splines_by_keyword=original.limits.duplicate()
			if language: output.max_splines_by_keyword[&"layer"]=32
		if member.get_meta("created_with", "")=="layer": member.line_edit.max_value=65536 if language else 2048
	# Every endpoint must have its final profile before updating shared splines.
	for member in members:
		for port in member.outputs:
			if port.config_conn: continue
			for spline in port.outputs.values():
				spline.color_a=port.gradient_color
				if is_instance_valid(spline.tied_to): spline.color_b=spline.tied_to.gradient_color; spline.set_fork_color(spline.tied_to.gradient_color)
