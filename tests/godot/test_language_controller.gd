extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var service_script = load("res://scripts/language_models/language_model_service.gd")
	var controller_script = load("res://scripts/language_models/language_graph_controller.gd")
	if service_script == null or controller_script == null: push_error("Language controller not implemented"); quit(1); return
	var service = service_script.new()
	service.set_backend(load("res://scripts/language_models/dummy_language_backend.gd").new())
	root.add_child(service)
	var controller = controller_script.new()
	root.add_child(controller)
	controller.setup(service)
	var graph := {"source_id":"s","nodes":[{"id":"s","op":"text_input","config":{}}],"edges":[]}
	controller.start_graph(graph, "The cat")
	controller.reset()
	for i in 8: await process_frame
	if not service.backend.sessions.is_empty(): push_error("Cancelled open leaked a backend session"); quit(1); return
	if not controller.generated_ids.is_empty() or controller.state != &"idle": push_error("Reset allowed stale response"); quit(1); return
	controller.start_graph(graph,"The cat")
	controller.continue_generation()
	for i in 20: await process_frame
	if controller.state != &"completed" or controller.generated_ids != [21,22]: push_error("EOS state/continuation incorrect: " + str(controller.state)); quit(1); return
	var typed_graph: Dictionary={"source_id":"s","nodes":[{"id":"s","op":"text_input","config":{}},{"id":"t","op":"tokenizer","config":{}},{"id":"e","op":"embedding","config":{}},{"id":"a","op":"attention_head","config":{}}],"edges":[{"from_node":"s","to_node":"t","from_port":"out","to_port":"in"},{"from_node":"t","to_node":"e","from_port":"out","to_port":"in"},{"from_node":"e","to_node":"a","from_port":"out","to_port":"in"}]}
	controller.start_graph(typed_graph,"The cat")
	controller.continue_generation()
	for i in 20: await process_frame
	var vectors: Dictionary=controller.last_snapshot.nodes.e
	if vectors.output_shape[0]!=controller.last_snapshot.token_count or vectors.output_type!="language_vectors" or vectors.output_dtype!="float32":
		push_error("Sequence shape/type stayed stale as generation grew"); quit(1); return
	# Simulate the valid session / pending tokenization boundary, then Stop → Run.
	controller.prefix_ids=[]; controller.generated_ids=[]
	controller._pending=service.request(&"tokenize",{"text":"The cat"},controller.session_id,controller.graph_revision)
	controller.stop()
	controller.continue_generation()
	for i in 20: await process_frame
	if controller.state!=&"completed" or controller.generated_ids!=[21,22]: push_error("Stop during tokenization cannot resume"); quit(1); return
	controller.start_graph(graph,"The cat")
	controller.stop()
	for i in 8: await process_frame
	if controller.state != &"stopped" or not controller.generated_ids.is_empty(): push_error("Stop allowed stale response"); quit(1); return
	if controller.AUTOMATIC_DELAY != 0.3: push_error("Inference debounce must be 300ms"); quit(1); return
	controller.free()
	service.free()
	print("PASS test_language_controller")
	quit(0)
