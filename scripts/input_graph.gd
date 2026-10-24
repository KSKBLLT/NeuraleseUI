extends "res://scripts/input_base.gd"


func _infer_debug(message: String, data: Dictionary = {}) -> void:
	var suffix: String = ""
	if not data.is_empty():
		suffix = " " + JSON.stringify(data)
	print("[Input2DInfer graph_id=%s context=%s] %s%s" % [str(graph_id), str(context_id), message, suffix])


func _auto_infer_enabled() -> bool:
	return bool(glob.AUTO_INPUT_INFERENCE_ENABLED)


func _auto_infer_diag(message: String, data: Dictionary = {}) -> void:
	if not bool(glob.AUTO_INPUT_INFERENCE_DIAGNOSTICS):
		return
	_infer_debug(message, data)


func _auto_infer_payload_diag(payload: Dictionary) -> Dictionary:
	var raw_values = payload.get("raw_values", [])
	return {
		"enabled": _auto_infer_enabled(),
		"has_channel": nn.is_infer_channel(self),
		"has_external_lease": nn.infer_channel_has_external_lease(self),
		"opening": _auto_infer_opening,
		"pending": _auto_infer_pending_payload is Dictionary,
		"raw_len": raw_values.size() if raw_values is Array else -1,
		"shape": payload.get("shape", null),
	}


func _can_drag() -> bool:
	return !$TextureRect.mouse_inside and not run.is_mouse_inside()


func image_channels() -> int:
	return 3 if $TextureRect.colour else 1


func image_value_count() -> int:
	return image_dims.x * image_dims.y * image_channels()


## The canvas's pixels from 0 to 1, row by row; a colour canvas gives all its
## red, then all its green, then all its blue, the way the model reads them.
func get_raw_values():
	var image: Image = $TextureRect.image
	var data := image.get_data()
	var count: int = image.get_width() * image.get_height()
	var res = []
	res.resize(count * image_channels())
	if image_channels() == 1:
		for i in count:
			res[i] = data[i] / 255.0
	else:
		for i in count:
			res[i] = data[i * 3] / 255.0
			res[count + i] = data[i * 3 + 1] / 255.0
			res[2 * count + i] = data[i * 3 + 2] / 255.0
	return res


## The canvas becomes this many pixels, and the layers after it learn the size.
func set_image_size(pixels: Vector2i) -> void:
	pixels = Vector2i(maxi(1, pixels.x), maxi(1, pixels.y))
	cfg["columns"] = pixels.x
	cfg["rows"] = pixels.y
	if pixels == image_dims and $TextureRect.image.get_size() == pixels:
		return
	image_dims = pixels
	$TextureRect.resize_canvas(pixels)
	_fit_canvas()
	graphs.push_2d(pixels.x, pixels.y, get_first_descendants(), image_channels())
	graphs.invalidate_training_snapshot("image_size")


func _config_field(field: StringName, _value: Variant) -> void:
	if field in [&"rows", &"columns"]:
		set_image_size(Vector2i(int(cfg.get("columns", image_dims.x)), int(cfg.get("rows", image_dims.y))))


## Where the scene puts the canvas; a picture that is not square sits in it
## whole, in the middle.
var _canvas_box := Rect2()

func _fit_canvas() -> void:
	var canvas: TextureRect = $TextureRect
	if _canvas_box.size == Vector2.ZERO:
		_canvas_box = Rect2(canvas.position, canvas.size)
	var fit := _canvas_box.size
	if image_dims.x != image_dims.y:
		fit = Vector2(image_dims) * minf(fit.x / image_dims.x, fit.y / image_dims.y)
	canvas.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	canvas.size = fit
	canvas.position = _canvas_box.position + (_canvas_box.size - fit) * 0.5 * canvas.scale


## The pictures of the dataset this model learns from set the canvas's size,
## so the two always match. Without such a dataset the size stays as it is.
var _adopt_queued := false

func _on_graphs_changed(_reason: String = "") -> void:
	if _adopt_queued:
		return
	_adopt_queued = true
	_adopt_dataset_size.call_deferred()


func _adopt_dataset_size() -> void:
	_adopt_queued = false
	if not is_inside_tree():
		return
	var pictures := _training_pictures()
	if not pictures.is_empty():
		set_image_size(Vector2i(int(pictures["x"]), int(pictures["y"])))


## The image inputs of a dataset a training node trains this model on, or {}.
func _training_pictures() -> Dictionary:
	var model = graphs.get_input_name_by_graph(self)
	if model == null:
		return {}
	for graph in graphs._graphs.values():
		if not is_instance_valid(graph) or graph.server_typename != "TrainBegin":
			continue
		var inputs: Dictionary = graph.dataset_meta.get("inputs", {})
		if str(inputs.get("datatype", "")) != "2d" or int(inputs.get("x", 0)) <= 0 or int(inputs.get("y", 0)) <= 0:
			continue
		var found := {}
		graphs.reach(graph, func(_from: Connection, to: Connection, _cache: Dictionary):
			if to.parent_graph.server_typename == "RunModel" and str(to.parent_graph.name_graph) == str(model):
				found["model"] = true)
		if found:
			return inputs
	return {}


const PICTURE_TYPES := ["png", "jpg", "jpeg", "webp", "bmp"]

## A picture from a file onto the canvas, in its own colours.
func open_picture(path: String) -> void:
	if not path.get_extension().to_lower() in PICTURE_TYPES:
		return
	var picture := Image.load_from_file(path)
	if picture == null or picture.is_empty():
		return
	$TextureRect.take_picture(picture)


## A picture dropped from the computer onto the canvas opens on it.
func _on_files_dropped(files: PackedStringArray) -> void:
	if files.is_empty() or not is_visible_in_tree():
		return
	if $TextureRect.get_global_rect().has_point(get_global_mouse_position()):
		open_picture(files[0])


func get_netname():
	return null


func _bind_as_default_model_input(force: bool = false) -> void:
	var current = graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME)

	if is_instance_valid(current) and current != self and not force:
		return

	if is_instance_valid(current) and current != self and force:
		graphs.forget_input_graph(current)

	graphs.add_input_graph_name(self, glob.DEFAULT_MODEL_NAME)
	graphs.model_updated.emit(glob.DEFAULT_MODEL_NAME)


func _exit_tree() -> void:
	super()
	graphs.forget_input_graph(self)

func _just_connected(who: Connection, to: Connection):
	_bind_as_default_model_input(true)
	graphs.push_2d(image_dims.x, image_dims.y, to.parent_graph, image_channels())


@onready var run = $run


func _just_disconnected(who: Connection, to: Connection):
	graphs.forget_input_graph(self)


func graph_updated():
	_bind_as_default_model_input()

	if nn.is_infer_channel(self):
		_infer_debug("graph_updated: sending full_graph")
		nn.send_inference_data(self, {"full_graph": graphs.get_syntax_tree(self)})


func _useful_properties() -> Dictionary:
	return {
		"raw_values": get_raw_values(),
		"config": {
			"rows": image_dims.y,
			"columns": image_dims.x,
			"channels": image_channels(),
			"subname": "Input2D"
		},
		"shape": image_value_count()
	}


func repr():
	var tensorified: PackedStringArray = []
	tensorified.append(str(image_dims.x))
	tensorified.append(str(image_dims.y))
	if image_channels() > 1:
		tensorified.append(str(image_channels()))
	return base_dt + "(" + "x".join(tensorified) + ")"


func validate(pack: Dictionary):
	return base_dt == pack.get("datatype", "") and pack.get("x", 0) == image_dims.x and pack.get("y", 0) == image_dims.y \
		and int(pack.get("channels", 1)) == image_channels()


var running: bool = false
var cd: float = 0.0
var last_sent_hash = null
var _last_image_change_version: int = -1
const AUTO_INFER_IDLE_CLOSE_SECONDS := 10.0
var _auto_infer_last_activity_msec: int = 0
var _auto_infer_opening: bool = false
var _auto_infer_pending_payload = null


func _raw_values_hash(values: Array) -> int:
	return values.hash()
	#
	#var ctx = HashingContext.new()
	#ctx.start(HashingContext.HASH_MD5)
#
	#for value in values:
		#ctx.update(str(glob.cap(float(value), 4)).to_utf8_buffer())
		#ctx.update(",".to_utf8_buffer())
#
	#return ctx.finish().hex_encode().hash()


func _process(delta: float) -> void:
	super(delta)

	var image_change_version := int($TextureRect.change_version)
	if _last_image_change_version < 0:
		_last_image_change_version = image_change_version

	if image_change_version != _last_image_change_version and cd < 0.01:
		cd = 0.3
		_last_image_change_version = image_change_version

		var raw_values = get_raw_values()
		var raw_hash = _raw_values_hash(raw_values)

		if last_sent_hash == null or last_sent_hash != raw_hash:
			last_sent_hash = raw_hash
			_auto_infer_diag("auto drawing changed", {
				"drawing": $TextureRect.drawing,
				"raw_len": raw_values.size(),
				"hash": raw_hash,
				"enabled": _auto_infer_enabled(),
			})
			_auto_infer_touch(_useful_properties())

	if cd >= 0.0:
		cd -= delta
	else:
		cd = 0.0

	_auto_infer_close_if_idle()


func _auto_infer_touch(payload: Dictionary) -> void:
	if not _auto_infer_enabled():
		_auto_infer_diag("auto touch suppressed: disabled", _auto_infer_payload_diag(payload))
		return
	if nn.infer_channel_has_external_lease(self):
		_auto_infer_diag("auto touch suppressed: channel leased", _auto_infer_payload_diag(payload))
		return
	_auto_infer_last_activity_msec = Time.get_ticks_msec()
	if nn.is_infer_channel(self):
		_auto_infer_diag("auto touch sending on existing channel", _auto_infer_payload_diag(payload))
		running = true
		nn.send_inference_data(self, payload)
		return
	_auto_infer_pending_payload = payload
	if _auto_infer_opening:
		_auto_infer_diag("auto touch queued while opening", _auto_infer_payload_diag(payload))
		return
	_auto_infer_diag("auto touch scheduling open", _auto_infer_payload_diag(payload))
	_auto_infer_open_and_send.call_deferred(payload)


func _auto_infer_open_and_send(payload: Dictionary) -> void:
	if not _auto_infer_enabled():
		_auto_infer_diag("auto open suppressed: disabled", _auto_infer_payload_diag(payload))
		_auto_infer_pending_payload = null
		return
	if nn.infer_channel_has_external_lease(self):
		_auto_infer_diag("auto open suppressed: channel leased", _auto_infer_payload_diag(payload))
		_auto_infer_pending_payload = null
		return
	if _auto_infer_opening:
		_auto_infer_diag("auto open skipped: already opening", _auto_infer_payload_diag(payload))
		return
	_auto_infer_opening = true
	_bind_as_default_model_input(true)
	cd = max(cd, 0.3)

	if not nn.validate_infer_channel(self):
		_auto_infer_diag("auto open rejected: channel invalid", _auto_infer_payload_diag(payload))
		_auto_infer_opening = false
		_auto_infer_pending_payload = null
		return

	_auto_infer_diag("auto open_infer_channel begin", _auto_infer_payload_diag(payload))
	var opened = await nn.open_infer_channel(self, _auto_infer_closed)
	_auto_infer_opening = false

	_auto_infer_diag("auto open_infer_channel returned", {
		"opened_truthy": (opened is bool and opened != false) or (opened != null),
		"opened_type": typeof(opened),
		"has_channel": nn.is_infer_channel(self),
	})

	if opened and nn.is_infer_channel(self):
		if _auto_infer_pending_payload is Dictionary:
			payload = _auto_infer_pending_payload
		_auto_infer_pending_payload = null
		running = true
		_auto_infer_diag("auto sending after open", _auto_infer_payload_diag(payload))
		nn.send_inference_data(self, payload)
	else:
		_auto_infer_diag("auto open produced no active channel", _auto_infer_payload_diag(payload))
		_auto_infer_pending_payload = null


func _auto_infer_close_if_idle() -> void:
	pass

func _auto_infer_closed() -> void:
	_auto_infer_diag("auto infer closed", {
		"running_before": running,
		"enabled": _auto_infer_enabled(),
	})
	running = false
	_auto_infer_opening = false
	_auto_infer_pending_payload = null
	last_sent_hash = null


func _proceed_hold() -> bool:
	if running:
		return true
	return false


var image_dims = Vector2i(1, 1)


func _after_ready() -> void:
	super()
	graphs._input_origin_graph = self
	image_dims = Vector2i($TextureRect.image.get_width(), $TextureRect.image.get_height())
	set_image_size(Vector2i(int(cfg.get("columns", image_dims.x)), int(cfg.get("rows", image_dims.y))))
	_fit_canvas()
	graphs.training_snapshot_invalidated.connect(_on_graphs_changed)
	get_window().files_dropped.connect(_on_files_dropped)
	_on_graphs_changed()

	await get_tree().process_frame
	_bind_as_default_model_input(true)

func set_state_open():
	_infer_debug("set_state_open")

	running = true
	run_but.text_offset.x = 0

	match glob.get_lang():
		"kz":
			run_but.text = "Тоқта"
		"ru":
			run_but.text = "Стоп"
		_:
			run_but.text = "Stop"


@onready var run_but = $run


func _on_run_released() -> void:
	_bind_as_default_model_input(true)

	_infer_debug("run button released", {
		"running": running,
		"is_channel": nn.is_infer_channel(self),
		"text": run_but.text,
	})
	await glob.wait(2, true)
	hold_for_frame()
	return

	if not nn.is_infer_channel(self):
		cd = 2.0
		last_sent_hash = null

		var opened = await nn.open_infer_channel(self, close_runner, run_but)

		_infer_debug("open_infer_channel returned", {
			"opened": (opened is bool and opened != false) or (opened != null)
		})

		if opened:
			running = true
			run_but.text_offset.x = 0

			match glob.get_lang():
				"kz":
					run_but.text = "Тоқта"
				"ru":
					run_but.text = "Стоп"
				_:
					run_but.text = "Stop"

			await glob.wait(0.2)
			nn.send_inference_data(self, _useful_properties())

	else:
		_infer_debug("run button closing active channel")
		nn.close_infer_channel(self)

	await glob.wait(2, true)
	hold_for_frame()


func close_runner():
	_infer_debug("close_runner called", {
		"text_before": run_but.text,
		"running_before": running
	})

	run_but.text_offset.x = 2
	run_but.text = "Run!"
	running = false
	_auto_infer_opening = false
	_auto_infer_pending_payload = null
	last_sent_hash = null

	_infer_debug("close_runner finished", {
		"text_after": run_but.text,
		"running_after": running
	})
