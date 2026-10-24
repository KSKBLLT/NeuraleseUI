extends Node

class RecordingBackend extends "res://scripts/language_models/dummy_language_backend.gd":
	var steps: Array = []
	var previews: Dictionary = {}
	func submit(request: Dictionary) -> void:
		if request.method == "run_step": steps.append(request.params.duplicate(true))
		if request.method in ["preview", "preview_node"]:
			previews[request.request_id] = request.params.get("generated_ids", []).duplicate()
			request = request.duplicate(true)
			request.method = "run_step"
		super.submit(request)
	func _deliver(response: Dictionary) -> void:
		if response.ok:
			if previews.has(response.request_id):
				response.result.generated_ids = previews[response.request_id]
				response.result.decoded_text = decode(previews[response.request_id])
				response.result.finished = false
			for trace in response.result.get("nodes", {}).values():
				trace.preview.decoded_text = response.result.decoded_text
		super._deliver(response)

func _ready() -> void:
	for frame in 12: await get_tree().process_frame
	var backend := RecordingBackend.new()
	language_models.set_backend(backend)
	var nodes: Dictionary = load("res://scripts/language_models/language_demo.gd").build(graphs)
	var auto = graphs.get_graph(&"autoregression")
	if not auto.has_method("request_step"):
		fail("Autoregression must be replaced with the single-step node"); return
	var best = nodes.token_labels
	if auto._inputs.size() != 1 or not auto.outputs.is_empty():
		fail("Autoregression needs exactly one input and no bottom/output ports"); return
	var port: Connection = auto._inputs[0]
	if port.dir_vector != Vector2.UP or absf(port.position.x + port.size.x / 2 - auto.rect.size.x / 2) > 0.1:
		fail("Autoregression input must be centered above the frame"); return
	for property in [&"outline_color", &"tuning", &"corner_radius_width_add"]:
		if auto.rect.get_instance_shader_parameter(property) != best.rect.get_instance_shader_parameter(property):
			fail("Autoregression frame differs from BestAnswer: " + property); return
	if auto.rect.material != best.rect.material:
		fail("Autoregression must reuse BestAnswer's frame material"); return
	var title: LineEdit = auto.get_node("ColorRect/root/Label")
	var reference: LineEdit = best.get_node("ColorRect/root/Label")
	if title.scale != reference.scale or title.position != reference.position or title.get_theme_color("font_color") != reference.get_theme_color("font_color"):
		fail("Autoregression header differs from BestAnswer"); return
	var conv = graphs.get_graph(&"conv2d")
	for row in [auto.get_node("ColorRect/Creativity"), auto.get_node("ColorRect/Candidates")]:
		if row.scale != conv.get_node("Label").scale or row.get_theme_font("font") != conv.get_node("Label").get_theme_font("font"):
			fail("Parameter rows must copy Conv2D's native controls"); return
		if row.get_node("HSlider").scale != conv.get_node("Label/HSlider").scale:
			fail("Parameter sliders differ from Conv2D"); return
		if row.get_node("HSlider").size != conv.get_node("Label/HSlider").size:
			fail("Parameter slider tracks must have Conv2D's compact width"); return
		if row.get_node("n").position.x != conv.get_node("Label/n").position.x:
			fail("Parameter values must sit beside the compact slider, as in Conv2D"); return
	var classifier = graphs.get_graph(&"classifier")
	var add: BlockComponent = classifier.add_button
	if auto.btn_step.base_size != add.base_size or auto.btn_step.material != add.material or auto.btn_step.label.scale != add.label.scale or auto.btn_step.label.theme != add.label.theme:
		fail("Step must copy the compact Add button from LabelGroup"); return
	for property in [&"outline_color", &"tuning", &"corner_radius_width_add"]:
		if auto.btn_step.get_instance_shader_parameter(property) != add.get_instance_shader_parameter(property):
			fail("Step button differs from Add: " + property); return
	var best_out: Connection
	for output in best.outputs:
		if output.server_name == &"autoregress_out": best_out = output
	if best_out == null or best_out.color != best._inputs[0].color or port.color != best._inputs[0].color or best_out.gradient_color != Color.WHITE or port.gradient_color != best._inputs[0].gradient_color:
		fail("Generation ports must keep the native green body and BestAnswer's lower spline must be white"); return
	if best_out.z_index + best_out.get_parent().z_index >= best.rect.z_index or port.z_index >= auto.rect.z_index:
		fail("Generation ports must draw underneath their node bodies"); return
	best._after_process(0.016)
	var left_exposure: float = best.rect.position.x-best._inputs[0].position.x
	var bottom_exposure: float = best_out.position.y+best_out.size.y+best_out.get_parent().position.y-best.rect.position.y-best.rect.size.y
	var top_exposure: float = auto.rect.position.y-port.position.y
	if absf(bottom_exposure-left_exposure)>0.01 or absf(top_exposure-left_exposure)>0.01:
		fail("Port protrusion must match the reference left port on every side: " + str([left_exposure,bottom_exposure,top_exposure])); return
	for lang in ["en", "ru", "kz"]:
		glob.change_lang(lang)
		await get_tree().process_frame
		for row in [auto.get_node("ColorRect/Creativity"), auto.get_node("ColorRect/Candidates")]:
			var end: float = row.position.x + row.get_theme_font("font").get_string_size(row.text, HORIZONTAL_ALIGNMENT_LEFT, -1, row.get_theme_font_size("font_size")).x * row.scale.x
			if end > row.position.x + row.get_node("HSlider").position.x * row.scale.x - 2:
				fail("Short parameter label overlaps its slider: " + lang); return
	glob.change_lang("ru")
	if auto.get_node("ColorRect/Creativity").text != "Смело" or auto.get_node("ColorRect/Candidates").text != "Выбор":
		fail("Use the short child-friendly parameter labels"); return
	for control in [auto.get_node("ColorRect/TextPanel"), auto.btn_step]:
		if not auto.rect.get_global_rect().grow(0.1).encloses(control.get_global_rect()):
			fail("Autoregression content overflows its frame: " + str([control.name, control.position, control.size, control.scale, auto.rect.size])); return
	if not auto.has_method("_can_drag_at"):
		fail("Autoregression must keep knob and Step gestures separate from dragging the graph"); return
	for control in [auto.editor, auto.btn_step, auto.get_node("ColorRect/Creativity/HSlider"), auto.get_node("ColorRect/Candidates/HSlider")]:
		if auto._can_drag_at(control.get_global_rect().get_center()):
			fail("An interactive control starts dragging the Autoregression node: " + str(control.name)); return
	for output in best.outputs:
		if output.server_name == &"autoregress_out" and not output.connect_to(port):
			fail("BestAnswer could not connect to Autoregression"); return
	for spline in best_out.outputs.values():
		if spline.color_a != Color.WHITE: fail("The lower BestAnswer port did not give its spline a white start color"); return
	var source = nodes.text_input
	source.controller.set_process(false)
	source.update_config({"text":"Привет 👋"})
	source.controller.start(source)
	for frame in 12: await get_tree().process_frame
	if not backend.steps.is_empty() or not source.controller.generated_ids.is_empty():
		fail("Preview must not generate a token"); return
	auto.update_config({"creativity":0.0,"candidates":1})
	auto.request_step()
	auto.request_step()
	for frame in 12: await get_tree().process_frame
	if backend.steps.size() != 1 or source.controller.generated_ids.size() != 1:
		fail("One click must generate one token; concurrent clicks must be ignored"); return
	if backend.steps[0].temperature != 0.0 or backend.steps[0].top_k != 1:
		fail("Sampling knobs did not reach the numeric backend"); return
	if source.editor.text != "Привет 👋" + auto.editor.text or source.cfg.text != source.editor.text:
		fail("Both text fields must show the same Unicode-safe continuation"); return
	# Selection after generation traverses a mixed component: TextInput,
	# Autoregression and BestAnswer do not all expose a `view` property.
	var continuation := str(auto.editor.text)
	nodes.tokenizer.view.select_position(0)
	nodes.tokenizer.view.token_selected.emit(0)
	if nodes.embedding.view.selected_position!=0:
		fail("Tokenizer click after generation did not reach embedding selection"); return
	nodes.tokenizer._select(-1)
	if nodes.embedding.view.selected_position!=-1 or auto.editor.text!=continuation:
		fail("Leaving tokenizer must clear selection without changing generated text"); return
	for frame in 30: source.controller._process(0.02); await get_tree().process_frame
	if backend.steps.size() != 1:
		fail("Appending generated text started another inference"); return
	auto.request_step()
	for frame in 12: await get_tree().process_frame
	var before_eos: String = source.editor.text
	auto.request_step()
	for frame in 12: await get_tree().process_frame
	if backend.steps.size() != 3 or source.editor.text != before_eos or source.controller.state != &"completed":
		fail("EOS must complete without printing a special token: " + str([backend.steps.size(), source.editor.text, before_eos, source.controller.state, source.controller.generated_ids])); return
	print("PASS test_language_autoregression")
	get_tree().quit(0)

func fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)
