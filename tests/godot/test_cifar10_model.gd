extends "res://scripts/generated/node_sources.gd"
## A CIFAR-10 model put together through the app's own graph builder (the
## change_nodes / connect_ports text Axon sends, parser.model_changes_apply),
## with the architecture and settings chosen here rather than by Axon:
## Input RGB -> convolution 16 stride 2 -> convolution 32 stride 2 -> Flatten
## -> Dense 64 -> Dense 10 -> Softmax -> answers, Adam at 3e-3, trained by
## Dataset cifar10 -> TrainBegin -> RunModel -> TrainStep. Strided
## convolutions instead of convolution + pooling: the same accuracy for a
## fifth of the arithmetic (about 5 s an epoch on one thread instead of 25).
## The app must take it as a training job. With
## NEURALESE_CIFAR_REQUEST_OUT set, the request local training gets is written
## there; tests/local_runtime/test_cifar10_training.py trains it.

const CLASSES := ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"]

const NODES := """[
  {"tag": "model_cifar", "type": "model_name", "config": {"name": "cifar_cnn"}},
  {"tag": "picture", "type": "input_image_rgb", "config": {}},
  {"tag": "relu_1", "type": "activation", "config": {"activ": "relu"}},
  {"tag": "conv_1", "type": "conv2d_layer", "config": {"filters": 16, "window": 3, "stride": 2}},
  {"tag": "relu_2", "type": "activation", "config": {"activ": "relu"}},
  {"tag": "conv_2", "type": "conv2d_layer", "config": {"filters": 32, "window": 3, "stride": 2}},
  {"tag": "flat", "type": "flatten", "config": {}},
  {"tag": "relu_3", "type": "activation", "config": {"activ": "relu"}},
  {"tag": "dense_64", "type": "dense_layer", "config": {"neuron_amount": 64}},
  {"tag": "dense_10", "type": "dense_layer", "config": {"neuron_amount": 10}},
  {"tag": "soft", "type": "softmax", "config": {}},
  {"tag": "answers", "type": "out_labels", "config": {"label_names": %s, "title": "objects"}},
  {"tag": "cifar", "type": "load_dataset", "config": {"dataset_name": "cifar10"}},
  {"tag": "begin", "type": "train_begin", "config": {}},
  {"tag": "run", "type": "run_model", "config": {"branches": {"objects": "cross_entropy"}, "mapped": {"objects": "object"}}},
  {"tag": "step", "type": "train_step", "config": {"optimizer": "adam", "lr": 1, "momentum": 0.0, "weight_decay": 0}}
]"""

const PORTS := """[
  {"from": {"tag": "model_cifar", "port": 0}, "to": {"tag": "picture", "port": 0}},
  {"from": {"tag": "picture", "port": 0}, "to": {"tag": "conv_1", "port": 1}},
  {"from": {"tag": "relu_1", "port": 0}, "to": {"tag": "conv_1", "port": 0}},
  {"from": {"tag": "conv_1", "port": 0}, "to": {"tag": "conv_2", "port": 1}},
  {"from": {"tag": "relu_2", "port": 0}, "to": {"tag": "conv_2", "port": 0}},
  {"from": {"tag": "conv_2", "port": 0}, "to": {"tag": "flat", "port": 0}},
  {"from": {"tag": "flat", "port": 0}, "to": {"tag": "dense_64", "port": 1}},
  {"from": {"tag": "relu_3", "port": 0}, "to": {"tag": "dense_64", "port": 0}},
  {"from": {"tag": "dense_64", "port": 0}, "to": {"tag": "dense_10", "port": 1}},
  {"from": {"tag": "dense_10", "port": 0}, "to": {"tag": "soft", "port": 0}},
  {"from": {"tag": "soft", "port": 0}, "to": {"tag": "answers", "port": 0}},
  {"from": {"tag": "cifar", "port": 0}, "to": {"tag": "begin", "port": 0}},
  {"from": {"tag": "begin", "port": 0}, "to": {"tag": "run", "port": 0}},
  {"from": {"tag": "model_cifar", "port": 0}, "to": {"tag": "run", "port": 1}},
  {"from": {"tag": "run", "port": 0}, "to": {"tag": "step", "port": 0}}
]"""

var failures: Array[String] = []


func _ready() -> void:
	super()
	_run.call_deferred()


func _run() -> void:
	await get_tree().create_timer(0.4).timeout
	# The test graph must never be saved into whatever project the app opened.
	glob.loaded_project_once = false
	await graphs.delete_all()
	# The app has the dataset list by the time Axon builds; the test waits for it.
	await glob.get_loaded_datasets()
	await _build()
	for _frame in 30:
		await get_tree().process_frame
	_check_model()
	await _check_training_job()
	_finish()


## The text Axon would send, through the same parser.
func _build() -> void:
	var text := "<change_nodes>\n%s\n</change_nodes>\n<connect_ports>\n%s\n</connect_ports>\n<delete_nodes>\n[]\n</delete_nodes>\n<disconnect_ports>\n[]\n</disconnect_ports>\n" % [
		NODES % JSON.stringify(CLASSES), PORTS]
	var sock := {"cache": {}}
	parser.parse_stream_tags(sock, text)
	await parser.model_changes_apply(sock.cache.actions, "")


func _node(tag: String) -> Graph:
	var node = glob.tags_1d.get(tag, null)
	_expect(is_instance_valid(node), "the graph has its %s node" % tag)
	return node if is_instance_valid(node) else null


func _check_model() -> void:
	var picture := _node("picture")
	var begin := _node("begin")
	var flat := _node("flat")
	if picture == null or begin == null or flat == null:
		return
	_expect(str(picture.get_meta("created_with")) == "input_rgb", "Axon's input_image_rgb is Input RGB")
	_expect(str(begin.dataset_meta.get("name", "")) == "cifar10", "the training node trains on cifar10: %s" % begin.dataset_meta.get("name", ""))
	_expect(picture.image_dims == Vector2i(32, 32) and picture.image_channels() == 3, "the input is 32 x 32 in colour")
	# Stride 2 halves the picture (rounded up, as local training computes it):
	# 32 -> 16 -> 8, with conv_2's 32 filters.
	var conv_2 := _node("conv_2")
	if conv_2 != null:
		_expect(conv_2.grid == Vector2i(16, 16), "the second convolution sees 16 x 16: %s" % conv_2.grid)
	_expect(int(flat.display_count) == 8 * 8 * 32, "Flatten counts every channel: %d" % int(flat.display_count))


func _check_training_job() -> void:
	var prepared = nn._build_train_payload(_node("step"), true)
	_expect(prepared is Dictionary, "the app takes the model as a training job")
	if not prepared is Dictionary:
		return
	var ds_meta: Dictionary = nn._training_dataset_meta("cifar10", prepared["train_input_origin"].dataset_meta)
	var picture := _node("picture")
	var model_out := -1
	for node in graphs.simple_reach(prepared["execute_input_origin"], true):
		if node.server_typename == "ClassifierNode":
			model_out = nn.classifier_model_output_width(node)
	var shape_error: String = nn.training_dataset_shape_error(ds_meta, int(picture.useful_properties()["shape"]), model_out, -1, "en", picture.image_channels())
	_expect(shape_error.is_empty(), "the model fits CIFAR-10: %s" % shape_error)

	var payload: Dictionary = prepared["payload"].duplicate(true)
	var input_config := {}
	for page in payload["graph"].get("pages", {}).values():
		for node in page.values():
			if str(node.get("type", "")) == "InputNode":
				input_config = node.get("props", {}).get("config", {})
	_expect(int(input_config.get("channels", 0)) == 3 and int(input_config.get("rows", 0)) == 32 and int(input_config.get("columns", 0)) == 32,
		"local training is told about a 32 x 32 colour input: %s" % input_config)

	var step_config := {}
	for page in payload["train_graph"].get("pages", {}).values():
		for node in page.values():
			if str(node.get("type", "")) == "TrainInput":
				step_config = node.get("props", {}).get("config", {})
	_expect(str(step_config.get("lr", "")) == "3e-3", "the learning rate set when building stays: %s" % step_config)

	# What _start_train_fully_local writes to request.json before the worker runs it.
	payload["dataset_ref"] = {"kind": "builtin_numpy", "name": "cifar10"}
	payload.erase("local")
	var out := OS.get_environment("NEURALESE_CIFAR_REQUEST_OUT")
	if not out.is_empty():
		var file := FileAccess.open(out, FileAccess.WRITE)
		_expect(file != null, "the request can be written to %s" % out)
		if file != null:
			file.store_string(JSON.stringify(payload, "  "))
			file.close()
			print("cifar10 request written: ", out)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_cifar10_model")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
