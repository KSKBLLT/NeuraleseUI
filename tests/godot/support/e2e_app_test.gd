extends Node
## Shared driver for the end-to-end tests that run inside the real app scene
## (project.tscn) with --perfbench. Clicks cannot reach a headless window, so
## every step calls the handler its button or drop target calls.
##
## These tests write projects, datasets and settings. They run only in the
## throwaway profile tests/godot/run_all.sh sets up (NEURALESE_TEST_PROFILE=1);
## anywhere else they fail before touching anything.

const ECO_SENSORS := ["weight", "transparency", "magnetic", "hardness"]
const ECO_MATERIALS := ["Glass", "Metal", "Paper", "Plastic"]
const DIGITS := ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"]

var marker := "PASS e2e"
var failures: Array[String] = []
var _drop_x := 260.0
var _step := "start"
var _finished := false


## Call first. False means the test must stop: the profile is not a test one.
func _begin(seconds: float) -> bool:
	if OS.get_environment("NEURALESE_TEST_PROFILE") != "1":
		failures.append("run through tests/godot/run_all.sh: this test writes projects and settings and needs its throwaway profile")
		_finish()
		return false
	_watchdog(seconds)
	await _frames(20)
	await glob.get_loaded_datasets()
	return true


## A step that never returns (a coroutine that died on a script error) fails
## the test instead of hanging the suite.
func _watchdog(seconds: float) -> void:
	await get_tree().create_timer(seconds).timeout
	if not _finished:
		failures.append("timed out during: " + _step)
		_finish()


func _new_project(project_name: String) -> int:
	var id: int = await glob.create_empty_project(project_name)
	await glob.load_empty_scene(id, project_name)
	await _frames(5)
	_expect(glob.get_project_id() == id, "project %s is open" % project_name)
	return id


# --- graphs -----------------------------------------------------------------

func _drop(type_id: StringName) -> Graph:
	# NodePalette._on_node_type_dropped makes this exact call on a drop.
	var graph := graphs.create_graph_at_screen_position(type_id, Vector2(_drop_x, 420.0))
	_drop_x += 40.0
	_expect(is_instance_valid(graph), "the palette creates %s" % type_id)
	return graph


func _wire(from: Graph, output: String, to: Graph, input: String) -> bool:
	for port in from.outputs:
		if port.server_name != StringName(output):
			continue
		for target in to._inputs:
			if target.server_name == StringName(input):
				var ok: bool = port.connect_to(target)
				_expect(ok, "%s.%s connects to %s.%s" % [from.server_typename, output, to.server_typename, input])
				return ok
	_expect(false, "%s has %s and %s has %s" % [from.server_typename, output, to.server_typename, input])
	return false


## Dataset -> TrainBegin -> RunModel -> TrainStep, the lessons' training chain.
func _training_chain(dataset_name: String) -> Dictionary:
	var dataset := _drop(&"dataset")
	var begin := _drop(&"train_begin")
	var run := _drop(&"run_model")
	var step := _drop(&"train_input")
	await _frames(3)
	_wire(dataset, "netname", begin, "netname")
	_wire(begin, "input_out", run, "model_in")
	_wire(run, "model_out", step, "pred_in")
	await _choose_dataset(dataset, dataset_name)
	return {"dataset": dataset, "begin": begin, "run": run, "step": step}


## The dataset node's "+" opens select_dataset; picking a row there resolves it.
func _choose_dataset(dataset: Graph, dataset_name: String) -> void:
	# Runs until it waits for the menu's answer, then finishes on its own.
	dataset._on_run_released()
	var menu: SplashMenu = null
	var deadline := Time.get_ticks_msec() + 10000
	var row: BlockComponent = null
	while row == null and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		# The select_dataset scene registers itself as "datasets".
		menu = ui.get_splash("datasets")
		if menu != null:
			var list = menu.get_node_or_null("ColorRect/list")
			if list != null and list.get("button_by_hint") is Dictionary:
				row = list.button_by_hint.get(StringName(dataset_name))
	_expect(row != null, "select_dataset lists the %s dataset" % dataset_name)
	if row == null:
		return
	menu._on_list_child_button_release(row)
	while str(dataset.cfg.get("name", "")) != dataset_name and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await _frames(5)
	_expect(str(dataset.cfg.get("name", "")) == dataset_name, "the dataset node holds %s" % dataset_name)


## Lesson 1: four sensors -> Dense 8 (+ ReLU) -> Dense 4 -> answers, on eco_ai.
func _build_lesson1() -> Dictionary:
	var sensors: Array = []
	for name in ECO_SENSORS:
		sensors.append({"text": name, "features": {"n": 0, "on": false, "type": "float"}, "min": 0.0, "max": 1.0})
	var input := _drop(&"input_1d")
	var activation := _drop(&"neuron")
	var hidden := _drop(&"layer")
	var answer_layer := _drop(&"layer")
	var answers := _drop(&"classifier")
	await _frames(3)
	input.update_config({"input_features": sensors})
	activation.update_config({"activ": "relu"})
	hidden.update_config({"neuron_count": 8})
	answer_layer.update_config({"neuron_count": 4})
	answers.update_config({"label_names": ECO_MATERIALS, "title": "material"})
	await _frames(3)
	_wire(input, "input_out", hidden, "layer_in")
	_wire(activation, "activ_out", hidden, "activ_in")
	_wire(hidden, "layer_out", answer_layer, "layer_in")
	_wire(answer_layer, "layer_out", answers, "layer_in")
	var chain := await _training_chain("eco_ai")
	chain.merge({"input": input, "hidden": hidden, "answer_layer": answer_layer, "answers": answers, "activation": activation})
	await _frames(10)
	return chain


## Lesson 3: Input2D -> Conv2D 8/1/3 (+ ReLU) -> MaxPool 2 -> Flatten -> Dense 10
## -> Softmax -> answers, on MNIST.
func _build_lesson3() -> Dictionary:
	var input := _drop(&"input")
	var activation := _drop(&"neuron")
	var conv := _drop(&"conv2d")
	var pool := _drop(&"maxpool")
	var flat := _drop(&"flatten")
	var dense := _drop(&"layer")
	var soft := _drop(&"softmax")
	var answers := _drop(&"classifier")
	await _frames(3)
	activation.update_config({"activ": "relu"})
	conv.update_config({"filters": 8, "stride": 1, "window": 3})
	pool.update_config({"group": 2})
	dense.update_config({"neuron_count": 10})
	answers.update_config({"label_names": DIGITS, "title": "digit"})
	await _frames(3)
	_wire(input, "input_out", conv, "layer_in")
	_wire(activation, "activ_out", conv, "activ_in")
	_wire(conv, "layer_out", pool, "layer_in")
	_wire(pool, "layer_out", flat, "layer_in")
	_wire(flat, "layer_out", dense, "layer_in")
	_wire(dense, "layer_out", soft, "layer_in")
	_wire(soft, "soft_out", answers, "layer_in")
	var chain := await _training_chain("mnist")
	chain.merge({"input": input, "conv": conv, "flat": flat, "answers": answers})
	await _frames(10)
	return chain


## What the app hands local training for this graph, checked like a job.
func _check_training_job(nodes: Dictionary, dataset_name: String, classes: int) -> void:
	var input: Graph = nodes["input"]
	_expect(nn.check_valid(input), "%s model is valid for inference" % dataset_name)
	_expect(str(nodes["begin"].dataset_meta.get("name", "")) == dataset_name, "TrainBegin trains on %s" % dataset_name)
	var prepared = nn._build_train_payload(nodes["step"], true)
	_expect(prepared is Dictionary, "the app accepts the %s graph as a training job" % dataset_name)
	if not prepared is Dictionary:
		return
	var ds_meta: Dictionary = nn._training_dataset_meta(dataset_name, prepared["train_input_origin"].dataset_meta)
	var model_out := nn.classifier_model_output_width(nodes["answers"])
	_expect(model_out == classes, "the answer node has %d outputs: %d" % [classes, model_out])
	var channels: int = input.image_channels() if input.has_method("image_channels") else 1
	var shape_error: String = nn.training_dataset_shape_error(ds_meta, int(input.useful_properties()["shape"]), model_out, -1, "ru", channels)
	_expect(shape_error.is_empty(), "the %s model fits its dataset: %s" % [dataset_name, shape_error])


func _graph_signature() -> Array:
	var rows: Array = []
	for graph in graphs._graphs.values():
		if not is_instance_valid(graph):
			continue
		var wires: Array = []
		for port in graph.outputs:
			for wire in port.outputs.values():
				wires.append("%s>%s" % [str(port.server_name), str(wire.tied_to.parent_graph.graph_id)])
		wires.sort()
		rows.append("%d|%s|%s|%s" % [graph.graph_id, str(graph.get_meta("created_with", "")), JSON.stringify(graph.cfg, "", true), ",".join(wires)])
	rows.sort()
	return rows


func _type_counts() -> Dictionary:
	var counts: Dictionary = {}
	for graph in graphs._graphs.values():
		if is_instance_valid(graph):
			var type_id := StringName(str(graph.get_meta("created_with", "")))
			counts[type_id] = int(counts.get(type_id, 0)) + 1
	return counts


func _wire_count() -> int:
	var total := 0
	for graph in graphs._graphs.values():
		if is_instance_valid(graph):
			for port in graph.outputs:
				total += port.outputs.size()
	return total


# --- helpers ------------------------------------------------------------------

func _frames(count: int) -> void:
	for _frame in count:
		await get_tree().process_frame


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if _finished:
		return
	_finished = true
	nn.close_all(true)
	if failures.is_empty():
		print(marker)
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
