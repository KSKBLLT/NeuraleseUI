extends Node

var replies: Array[Dictionary] = []

func _ready() -> void:
	call_deferred("_run")

func _run() -> void:
	var backend_script = load("res://scripts/language_models/onnx_language_backend.gd")
	if backend_script == null: push_error("Real language backend is missing"); get_tree().quit(1); return
	var backend = backend_script.new()
	backend.response_ready.connect(func(packet: Dictionary): replies.append(packet))
	backend.submit({"schema_version":1,"request_id":1,"session_id":"","graph_revision":7,"method":"capabilities","params":{}})
	var deadline: int = Time.get_ticks_msec()+15000
	while replies.is_empty() and Time.get_ticks_msec()<deadline:
		backend.poll()
		await get_tree().process_frame
	if replies.is_empty() or not replies[0].ok or replies[0].is_dummy or replies[0].result.vocab_size!=20002:
		push_error("Real capabilities failed: "+JSON.stringify(replies)); backend.dispose(); get_tree().quit(1); return
	# Simulate a long idle interval without actually delaying the test. A new
	# request must get its own response window rather than inherit this deadline.
	nn.inference_sockets[language_models].last_request_msec = Time.get_ticks_msec()-60000
	backend.submit({"schema_version":1,"request_id":2,"session_id":"","graph_revision":7,"method":"tokenize","params":{"text":"мама"}})
	backend.poll()
	while replies.size()<2 and Time.get_ticks_msec()<deadline:
		backend.poll()
		await get_tree().process_frame
	if replies.size()!=2 or not replies[1].ok or replies[1].result.ids!=[142,122,9539,142,122,9539]:
		push_error("Godot did not receive the checkpoint tokenizer: "+JSON.stringify(replies)); backend.dispose(); get_tree().quit(1); return
	var graph := {"nodes":[{"id":"e","op":"embedding"},{"id":"a","op":"attention_head"}],"edges":[{"from_node":"e","to_node":"a"}]}
	var opened := await _request(backend,3,"open_session",{"graph":graph})
	if not opened.get("ok",false): _fail(backend,opened); return
	var sid: String = opened.result.session_id
	var tokenized := await _request(backend,4,"tokenize",{"text":"Copy exactly: red cup"},sid)
	if not tokenized.get("ok",false): _fail(backend,tokenized); return
	var ids: Array = tokenized.result.ids
	var preview := await _request(backend,5,"preview",{"prefix_ids":ids},sid)
	if not preview.get("ok",false): _fail(backend,preview); return
	if preview.result.nodes.a.preview.matrix.is_empty() or not preview.result.nodes.e.preview.points_are_words:
		_fail(backend,preview); return
	var generated: Array = []
	var decoded := ""
	for index in range(4):
		var step := await _request(backend,6+index,"run_step",{"prefix_ids":ids,"generated_ids":generated,"temperature":0,"top_k":5},sid)
		if not step.get("ok",false): _fail(backend,step); return
		generated=step.result.generated_ids
		decoded=step.result.decoded_text.strip_edges()
		if step.result.finished: break
	if decoded!="red cup": _fail(backend,{"decoded":decoded}); return
	backend.dispose()
	var training=load("res://tests/godot/test_language_training.gd").new()
	training.quit_when_done=false
	get_tree().root.add_child(training)
	await training.completed
	print("PASS exported inference: real attention, word embeddings, red cup, learning previews")
	print("PASS test_language_real_backend")
	get_tree().quit(0)

func _request(backend: RefCounted, id: int, method: String, params: Dictionary, sid: String="") -> Dictionary:
	backend.submit({"schema_version":1,"request_id":id,"session_id":sid,"graph_revision":7,"method":method,"params":params})
	var deadline := Time.get_ticks_msec()+30000
	while Time.get_ticks_msec()<deadline:
		backend.poll()
		for reply in replies:
			if int(reply.request_id)==id: return reply
		await get_tree().process_frame
	return {"ok":false,"error":"Timed out: "+method}

func _fail(backend: RefCounted, packet: Dictionary) -> void:
	push_error("Full language backend failed: "+JSON.stringify(packet))
	backend.dispose()
	get_tree().quit(1)
