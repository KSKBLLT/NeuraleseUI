extends "res://scripts/generated/node_sources.gd"
## Input RGB in the real workspace: its buttons and colours, painting in
## colour, what goes to the model, pictures opened in their own colours, and
## both image inputs taking their size from the dataset they are trained on.

const InputRgb = preload("res://scripts/input_rgb.gd")

var failures: Array[String] = []


func _ready() -> void:
	super()
	_run.call_deferred()


func _run() -> void:
	await get_tree().create_timer(0.4).timeout
	glob.loaded_project_once = false
	await _colour_node()
	await _grey_node()
	await _size_from_dataset()
	await _replace_lists()
	_finish()


## "Replace" offers an input only another input, and other nodes no input.
func _replace_lists() -> void:
	var layer = graphs.get_graph(&"layer", Graph.Flags.NONE)
	var colour = graphs.get_graph(&"input_rgb", Graph.Flags.NONE)
	await get_tree().process_frame
	var for_layer: Array = graphs.get_alt_nodes(layer)
	for type_id in [&"input", &"input_rgb", &"input_1d", &"text_input"]:
		_expect(not type_id in for_layer, "a layer cannot be replaced by %s" % type_id)
	var for_colour: Array = graphs.get_alt_nodes(colour)
	_expect(for_colour.size() == 3 and &"input" in for_colour and &"input_1d" in for_colour and &"text_input" in for_colour,
		"Input RGB is replaced only by the other inputs: %s" % [for_colour])
	var ask: String = preload("res://scripts/train_begin.gd").no_input_text("ru")
	_expect(ask == "Сначала создайте узел ввода: Ввод2D, Ввод RGB, Ввод1D или ВводТекста.", "the missing input names every input: %s" % ask)
	layer.queue_free()
	colour.queue_free()


func _colour_node() -> void:
	var node = graphs.get_graph(&"input_rgb", Graph.Flags.NONE)
	await get_tree().process_frame
	await get_tree().process_frame
	var canvas = node.get_node("TextureRect")
	_expect(node.server_typename == &"InputNode", "a colour input is an ordinary input for the model")
	_expect(node.image_channels() == 3 and node.image_dims == Vector2i(32, 32), "a new colour input is 32 x 32 in colour")
	_expect(int(node.cfg.get("columns", 0)) == 32 and int(node.cfg.get("rows", 0)) == 32, "the size is kept in the node's settings")
	_expect(node._buttons.size() == 2 and node._swatches.size() == 6, "two header buttons and six colours")
	var open_button = node._buttons["open"]
	var open_anchor: Control = open_button._wrapped_in if open_button.wrapped else open_button
	_expect(open_anchor.position == InputRgb.HEADER["open"], "the open button stands where the mockup puts it: %s" % open_anchor.position)
	_expect(canvas.brush_color == Color.WHITE, "the brush starts white, as Input2D draws")
	_expect(node._swatches[1].color == InputRgb.CHOSEN, "the white circle is ringed")

	node._swatches[2].released.emit()
	_expect(canvas.brush_color == InputRgb.COLOURS[2], "a press on a colour gives the brush that colour")
	_expect(node._swatches[2].color == InputRgb.CHOSEN and node._swatches[1].color == Color.WHITE, "only the chosen colour is ringed")
	canvas._accumulate_circle_at(Vector2(16.5, 16.5), 0.5)
	var painted: Color = canvas.image.get_pixel(16, 16)
	_expect(painted.r > 0.8 and painted.g < 0.4, "the brush paints red: %s" % painted)

	canvas.image.fill(Color.BLACK)
	canvas.image.set_pixel(0, 0, Color(1.0, 0.5, 0.0))
	var values: Array = node.get_raw_values()
	_expect(values.size() == 32 * 32 * 3, "three values a pixel")
	_expect(is_equal_approx(values[0], 1.0) and absf(values[1024] - 0.5) < 0.01 and is_zero_approx(values[2048]),
		"all red, then all green, then all blue")
	_expect(int(node.useful_properties()["config"]["channels"]) == 3 and int(node.useful_properties()["shape"]) == 3072,
		"the model is told about three channels")

	node._buttons["clear"].released.emit()
	_expect(canvas.image.get_pixel(0, 0) == Color.BLACK, "the clear button empties the canvas")

	# A wide picture: red left half, blue right half, a muddy green stripe in
	# the very middle that no brush colour has.
	var picture := Image.create(64, 32, false, Image.FORMAT_RGBA8)
	picture.fill_rect(Rect2i(0, 0, 32, 32), Color.RED)
	picture.fill_rect(Rect2i(32, 0, 32, 32), Color.BLUE)
	picture.fill_rect(Rect2i(30, 0, 4, 32), Color(0.3, 0.6, 0.2))
	canvas.take_picture(picture)
	_expect(canvas.image.get_size() == Vector2i(32, 32), "the picture is scaled to the canvas")
	_expect(canvas.image.get_pixel(4, 16).is_equal_approx(Color.RED), "the picture is cut from its middle")
	var middle: Color = canvas.image.get_pixel(15, 16)
	_expect(absf(middle.r - 0.3) < 0.12 and absf(middle.g - 0.6) < 0.12, "a picture keeps its own colours: %s" % middle)
	var clear := Image.create(8, 8, false, Image.FORMAT_RGBA8)
	clear.fill(Color(1, 1, 1, 0))
	canvas.take_picture(clear)
	_expect(canvas.image.get_pixel(3, 3).is_equal_approx(Color.BLACK), "what is transparent becomes black")
	node.queue_free()


func _grey_node() -> void:
	var node = graphs.get_graph(&"input", Graph.Flags.NONE)
	await get_tree().process_frame
	await get_tree().process_frame
	var canvas = node.get_node("TextureRect")
	_expect(node.image_channels() == 1 and node.image_dims == Vector2i(28, 28), "Input2D stays 28 x 28 grey")
	var picture := Image.create(4, 4, false, Image.FORMAT_RGB8)
	picture.fill(Color.WHITE)
	canvas.take_picture(picture)
	_expect(canvas.image.get_format() == Image.FORMAT_L8 and canvas.image.get_pixel(5, 5).r > 0.95, "a picture on a grey canvas turns grey")
	_expect(node.get_raw_values().size() == 28 * 28, "one value a pixel on a grey canvas")
	node.update_config({"columns": 40, "rows": 30})
	_expect(node.image_dims == Vector2i(40, 30) and canvas.image.get_size() == Vector2i(40, 30), "a size from the settings is taken (as on loading)")
	var box: Vector2 = node._canvas_box.size
	_expect(is_equal_approx(canvas.size.x, box.x) and canvas.size.y < box.y, "a wide picture sits whole in the canvas's place")
	node.queue_free()


func _size_from_dataset() -> void:
	var input = graphs.get_graph(&"input_rgb", Graph.Flags.NONE)
	var begin = graphs.get_graph(&"train_begin", Graph.Flags.NONE)
	var run = graphs.get_graph(&"run_model", Graph.Flags.NONE)
	await get_tree().process_frame
	await get_tree().process_frame
	input._bind_as_default_model_input(true)
	run.name_graph = glob.DEFAULT_MODEL_NAME
	begin.outputs[0].connect_to(run.input_keys[0], true)
	begin.set_dataset_meta({"name": "pets", "inputs": {"x": 64, "y": 48, "datatype": "2d"},
		"outputs": [{"label": "pet", "x": 2, "datatype": "1d", "label_names": ["cat", "dog"]}]})
	for _frame in 4:
		await get_tree().process_frame
	_expect(input.image_dims == Vector2i(64, 48), "the canvas takes the size of the dataset's pictures: %s" % input.image_dims)
	_expect(input.get_node("TextureRect").image.get_size() == Vector2i(64, 48), "and so does its picture")
	_expect(int(input.cfg["columns"]) == 64 and int(input.cfg["rows"]) == 48, "and its settings, for the next time the project opens")

	var cifar: Dictionary = glob.FULLY_LOCAL_BUILTIN_DATASETS["cifar10"]
	_expect(nn.training_dataset_shape_error(cifar, 32 * 32 * 3, 10, -1, "ru", 3).is_empty(), "CIFAR-10 fits a 32 x 32 colour input")
	var grey_error: String = nn.training_dataset_shape_error(cifar, 32 * 32, 10, -1, "ru", 1)
	_expect("Ввод RGB" in grey_error, "a grey input on CIFAR-10 is told to take Input RGB: %s" % grey_error)
	input.queue_free()
	begin.queue_free()
	run.queue_free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_input_rgb")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
