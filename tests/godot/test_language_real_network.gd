extends Node

const Demo = preload("res://scripts/language_models/language_demo.gd")
var nodes: Dictionary = {}
var packets: Array[Dictionary] = []
var forwards := 0
var errors: Array = []
var evidence: Dictionary = {}

func _ready() -> void:
	Engine.max_fps = 120
	for frame in 12: await get_tree().process_frame
	language_models.response_ready.connect(_record)
	await graphs.delete_all()
	graphs.loading = true
	nodes = Demo.build(graphs)
	nodes.autoregression = graphs.get_graph(&"autoregression")
	nodes.autoregression.position = Vector2(2240, 180)
	for port in nodes.token_labels.outputs:
		if port.server_name == &"autoregress_out":
			if not port.connect_to(nodes.autoregression._inputs[0]): fail("Real network autoregression edge rejected"); return
	graphs.loading = false
	var source = nodes.text_input
	var controller = source.controller
	controller.failed.connect(func(error: Dictionary): errors.append(error))
	var prompt := "Copy exactly: red cup"
	source.update_config({"text":prompt})
	controller.start(source)
	if not await idle(controller): return
	if not errors.is_empty() or controller.last_snapshot.get("vocab_size",0) != 20002:
		fail("Real graph failed with loosely adapted Dense width: " + JSON.stringify(errors)); return
	if packets.is_empty() or packets[-1].is_dummy or packets[-1].provider_id != "onnx-clean1000":
		fail("The default network did not use the real provider"); return
	if not controller.generated_ids.is_empty(): fail("Real preview generated text"); return
	if nodes.tokenizer.view.tokens.size() != controller.prefix_ids.size(): fail("Real tokenizer UI lost token IDs"); return
	var words: Array = nodes.embedding.trace.preview.points
	if words.size() != 4 or words[0].vector.size() != 256 or not nodes.embedding.trace.preview.points_are_words:
		fail("Real embedding UI did not receive whole-word vectors"); return
	var first: Array = nodes.head0.trace.preview.matrix
	if first.is_empty() or first == nodes.head1.trace.preview.matrix or nodes.head0.trace.preview.vector.size() != 64:
		fail("Parallel attention heads did not expose distinct real tensors"); return
	if int(controller.last_snapshot.selected_id) != 768: fail("Real logits disagree with checkpoint greedy reference"); return
	nodes.autoregression.get_node("ColorRect/Creativity/HSlider").value = 0
	nodes.autoregression.get_node("ColorRect/Candidates/HSlider").value = 1
	glob.base_node.get_node("WIN_GRAPH").window_show()
	nodes.autoregression.hold_for_frame()
	nodes.autoregression.btn_step.press()
	nodes.autoregression.btn_step.press()
	# Native press() queues an event; an offscreen/new graph needs a processing
	# frame before the button emits it. Wait for dispatch, not a guessed 3 frames.
	var dispatch_deadline := Time.get_ticks_msec()+2000
	while controller._pending<0 and controller.generated_ids.is_empty() and Time.get_ticks_msec()<dispatch_deadline:
		nodes.autoregression.hold_for_frame()
		await get_tree().process_frame
	if not await idle(controller): return
	if controller.generated_ids != [768] or source.editor.text != prompt + "red" or nodes.autoregression.editor.text != "red":
		var button = nodes.autoregression.btn_step
		fail("Real one-step/rapid-click continuation failed: " + str([controller.generated_ids,button.is_visible_in_tree(),button.freedom,button.is_processing(),button.press_request,button.state.pressing,nodes.autoregression.process_mode,button.process_mode,controller.state])); return
	var previous_count := forwards
	await get_tree().create_timer(0.45).timeout
	if forwards != previous_count: fail("Generated append restarted inference"); return
	nodes.autoregression.request_step()
	if not await idle(controller): return
	if controller.generated_ids != [768,7700] or nodes.autoregression.editor.text != "red cup": fail("Second real token did not accumulate"); return
	nodes.autoregression.request_step()
	if not await idle(controller): return
	if controller.state != &"completed" or controller.generated_ids != [768,7700] or source.cfg.text != prompt + "red cup":
		fail("Real EOS was printed or reset the prompt"); return
	evidence = {"provider_id":packets[-1].provider_id,"is_dummy":packets[-1].is_dummy,"model_id":controller.last_snapshot.model_id,"generated_ids":controller.generated_ids.duplicate(),"decoded_text":controller.last_snapshot.decoded_text,"embedding_words":words.map(func(word): return word.text),"vocab_size":20002,"default_dense_width":nodes.layer.cfg.neuron_count,"real_attention_heads":4}
	# A second sequential stage is an accepted edge into a new offscreen head.
	var second = graphs.get_graph(&"attention_head")
	second.position = Vector2(1270, 840)
	nodes.second_stage = second
	previous_count = forwards
	var old_embedding: Dictionary = nodes.embedding.trace.duplicate(true)
	source.process_mode = Node.PROCESS_MODE_DISABLED
	if not Demo._output(nodes.head0).connect_to(second._inputs[0]): fail("Sequential attention connection rejected"); return
	if not await idle(controller): return
	if forwards != previous_count + 1 or second.trace.is_empty() or nodes.embedding.trace != old_embedding or controller.generated_ids != [768,7700]:
		fail("Real accepted edge did not refresh only its receiver"); return
	var mapping: Dictionary = controller.last_snapshot.mapping
	if mapping.requested_depth != 2 or mapping.effective_depth != 10 or mapping.profile_id != "identity": fail("Real two-stage graph misreported physical depth"); return
	evidence.mapping = mapping
	previous_count = forwards
	second.position += Vector2(50,20)
	second.select(); second.unselect()
	nodes.layer.update_config({"neuron_count":13})
	await get_tree().create_timer(0.4).timeout
	if forwards != previous_count: fail("Moving/selecting/changing unrelated parameters ran the real model"); return
	# Native disconnect → undo → redo: only the undo's recreated edge previews.
	Demo._output(nodes.head0).disconnect_from(second._inputs[0], false, true)
	await get_tree().create_timer(0.1).timeout
	if not second.trace.is_empty() or forwards != previous_count: fail("Real disconnect launched inference or retained stale data"); return
	glob.undo_redo.undo()
	if not await idle(controller): return
	if second.trace.is_empty() or forwards != previous_count + 1: fail("Undo did not preview its recreated language edge"); return
	glob.undo_redo.redo()
	await get_tree().create_timer(0.1).timeout
	if not second.trace.is_empty() or forwards != previous_count + 1: fail("Redo disconnect ran the model"); return
	if not Demo._output(nodes.head0).connect_to(second._inputs[0]): fail("Final sequential edge rejected"); return
	if not await idle(controller): return
	source.process_mode = Node.PROCESS_MODE_INHERIT
	# A multi-byte prompt must populate all words beyond the first eight BPE IDs.
	source.update_config({"text":"мама папа король королева ана әке патша патшайым hello world"})
	controller._process(0.31)
	if not await idle(controller): return
	if nodes.head0.view.labels().size() != 10 or nodes.embedding.trace.preview.points.size() != 10:
		fail("Unicode real attention/embedding lost complete words: " + str(nodes.head0.view.labels())); return
	evidence.unicode_words = nodes.head0.view.labels()
	evidence.forward_count = forwards
	evidence.errors = errors
	if not errors.is_empty(): fail("Real acceptance received runtime errors: " + JSON.stringify(errors)); return
	# Batch loading round trip keeps stable graph IDs and suppresses intermediate work.
	var state: Dictionary = graphs.get_project_data().graphs
	var registry := {}
	for key in Graph._subgraph_registry: registry[key] = Graph._subgraph_registry[key].map(func(node): return node.graph_id)
	await graphs.delete_all()
	previous_count = forwards
	if not await graphs.load_graph(state.duplicate(true), registry): fail("Real graph round-trip failed"); return
	for frame in 4: await get_tree().process_frame
	if forwards != previous_count: fail("Batch loading ran intermediate real forwards"); return
	nodes.clear()
	for node in graphs._graphs.values():
		var kind: String = str(node.get_meta("created_with", ""))
		if kind == "attention_head":
			var count := nodes.keys().filter(func(key): return str(key).begins_with("head")).size()
			nodes["head%d" % count] = node
		else: nodes[kind] = node
	source = nodes.text_input
	controller = source.controller
	controller.start(source)
	if not await idle(controller): return
	if not controller.generated_ids.is_empty() or controller.last_snapshot.model_id != evidence.model_id:
		fail("Reloaded graph did not rebuild a real session"); return
	if "--capture-language-real" in OS.get_cmdline_user_args(): await capture_live()
	print("REAL_LANGUAGE_NETWORK ", JSON.stringify(evidence))
	print("PASS test_language_real_network")
	if "--keep-language-live" not in OS.get_cmdline_user_args(): get_tree().quit(0)

func _record(packet: Dictionary) -> void:
	if packet.get("ok", false) and packet.get("result") is Dictionary and packet.result.has("nodes"):
		packets.append(packet)
		forwards += 1

func idle(controller: Node) -> bool:
	var deadline := Time.get_ticks_msec() + 25000
	while controller._pending >= 0 or not controller._connection_targets.is_empty():
		if Time.get_ticks_msec() > deadline: fail("Real language network timed out"); return false
		await get_tree().create_timer(0.01).timeout
	if controller.state == &"error": fail("Real controller error: " + JSON.stringify(errors)); return false
	return true

func capture_live() -> void:
	var root := get_tree().root
	root.size = Vector2i(1600,1000)
	root.content_scale_factor = 1
	glob.change_lang("ru")
	glob.fg.set_scene_name("Реальная языковая модель")
	glob.base_node.get_node("WIN_GRAPH").window_show()
	glob.fg.show()
	ui.cl.hide()
	var palette = glob.base_node.get_node("WIN_GRAPH/NodePalette")
	palette.hide()
	var directory := ProjectSettings.globalize_path("res://docs/assets/real-language-model")
	DirAccess.make_dir_recursive_absolute(directory)
	_camera(Vector2(800,260),1.5)
	await screenshot(directory.path_join("real-unicode-embedding-attention.png"))
	nodes.text_input.update_config({"text":"mother father queen king cat dog garden school"})
	nodes.text_input.controller.start(nodes.text_input)
	if not await idle(nodes.text_input.controller): return
	glob.change_lang("en")
	await screenshot(directory.path_join("real-english-embedding-attention.png"))
	# Return to a short real generated answer for the overview and style comparisons.
	nodes.text_input.update_config({"text":"Copy exactly: red cup"})
	nodes.text_input.controller.start(nodes.text_input)
	if not await idle(nodes.text_input.controller): return
	nodes.autoregression.update_config({"creativity":0,"candidates":1})
	for step in 3:
		nodes.autoregression.request_step()
		if not await idle(nodes.text_input.controller): return
	_camera(Vector2(1180,420),0.53)
	await screenshot(directory.path_join("real-network.png"))
	var conv = graphs.get_graph(&"conv2d")
	conv.position = Vector2(2540,180)
	var classifier = graphs.get_graph(&"classifier")
	classifier.position = Vector2(2540,440)
	for language in ["en","ru","kz"]:
		glob.change_lang(language)
		_camera(Vector2(2250,315),1.4)
		await screenshot(directory.path_join("%s-autoregression-best-answer-conv2d.png" % language))
	# Generate actual longer text, exercising the bounded field and native scrolling.
	nodes.text_input.update_config({"text":"Copy exactly: A curious little cat watched the rain from the window and dreamed about a bright garden full of flowers."})
	nodes.text_input.controller.start(nodes.text_input)
	if not await idle(nodes.text_input.controller): return
	for step in 24:
		if nodes.text_input.controller.state == &"completed": break
		nodes.autoregression.request_step()
		if not await idle(nodes.text_input.controller): return
	for language in ["en","ru","kz"]:
		glob.change_lang(language)
		await screenshot(directory.path_join("%s-long-output.png" % language))
	glob.change_lang("ru")
	conv.delete()
	classifier.delete()
	for frame in 3: await get_tree().process_frame
	var exported: PackedByteArray = await glob.export_project()
	FileAccess.open(directory.path_join("clean1000-network.nls"),FileAccess.WRITE).store_buffer(exported)
	evidence.long_generated_ids = nodes.text_input.controller.generated_ids
	evidence.long_output = nodes.autoregression.editor.text
	FileAccess.open(directory.path_join("real-network-acceptance.json"),FileAccess.WRITE).store_string(JSON.stringify(evidence,"  "))
	palette.show()
	_camera(Vector2(2140,250),1.4)
	print("LANGUAGE_LIVE_READY")

func _camera(at: Vector2, zoom: float) -> void:
	glob.cam.position = at
	glob.cam.target_position = at
	glob.cam.zoom = Vector2.ONE * zoom
	glob.cam.target_zoom = zoom

func screenshot(path: String) -> void:
	for frame in 30: await get_tree().process_frame
	await RenderingServer.frame_post_draw
	get_tree().root.get_texture().get_image().save_png(path)

func fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
