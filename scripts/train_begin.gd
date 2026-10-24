extends Graph

const NodeCatalog = preload("res://scripts/generated/node_catalog.gd")
## Asks for an input node, naming every input the catalog has.
static func no_input_text(lang: String) -> String:
	var titles: PackedStringArray = []
	for type_id in NodeCatalog.input_types():
		var title: Dictionary = NodeCatalog.DEFINITIONS[type_id].title
		titles.append(str(title.get(lang, title.en)))
	var last := titles[titles.size() - 1]
	titles.remove_at(titles.size() - 1)
	var listed := ", ".join(titles)
	match lang:
		"ru":
			return "Сначала создайте узел ввода: %s или %s." % [listed, last]
		"kz":
			return "Алдымен кіріс түйінін жасаңыз: %s немесе %s." % [listed, last]
	return "Create an input node first: %s or %s." % [listed, last]


func get_training_data():
	#(not dataset_meta["name"] in glob._load)
	if get_ancestor() and get_ancestor().cfg["name"]:
		return {"epochs": epochs if epochs else 1, "dataset": get_ancestor().cfg["name"], "test_dataset": "", 
		"batch_size": 0, "local": not dataset_meta["name"] in glob._load}

@onready var clearbut = $train2

var dataset_meta: Dictionary = {}

func display_ds_meta():
	$ColorRect2/Control.push_cfg(dataset_meta)

func set_dataset_meta(meta: Dictionary):
	#(meta)
	var old_meta = dataset_meta
#	print(meta)
	dataset_meta = meta
	#(meta)
	display_ds_meta()
	var a 
	#(meta)
	#(graphs.simple_reach(self))
	#for i in graphs.get_cache("", self):
	#	i.push_meta(self, dataset_meta)
	#(dataset_meta)
	set_meta("input_features", dataset_meta.get("inputs", {}))
	if dataset_meta.get("inputs", {}).has("is_env"):
		dataset_meta = dataset_meta.duplicate()
		dataset_meta["inputs"] = {}
	# Image inputs take the size of the dataset's pictures from here.
	graphs.invalidate_training_snapshot("dataset_meta")
	await get_tree().process_frame
#	print(get_descendant())
#	print(get_descendant().input_keys[0].hint)
	if not graphs.loading and not "env" in old_meta and get_descendant() and not get_descendant()._is_suitable_other_conn(outputs[0], get_descendant().input_keys[0]):
		#(get_descendant()._is_suitable_conn(outputs[0], get_descendant().input_keys[0]))
		#await get_tree().process_frame
		#(dataset_meta["name"])
		#_stack()
		outputs[0].disconnect_all()

#func _just_attached(other_conn: Connection, my_conn: Connection):
		#set_dataset_meta({"name": "mnist", "outputs": [
		#{"label": "bbox", "length": 5, "dtype": "1d"}, {"label": "bbox", "length": 5, "dtype": "1d"}
	#]})

var scrolling = false
@onready var vbar = $ColorRect2/Control/ScrollContainer.get_v_scroll_bar()
func _ready() -> void:
	super()
	_paint_train_button(false)


## Pixel design: "Учись!" is the green run action and turns red while it
## reads "Стоп", as green means run and red means stop across the app.
func _paint_train_button(running: bool) -> void:
	if design.pixel:
		design.set_fill(train, design.STOP if running else design.GO)

func get_training_head():
	var r = []
	var def_call = func(from: Connection, to: Connection, branch_cache: Dictionary):
		if graphs.is_node(to.parent_graph, "TrainInput"):
			r.append(to.parent_graph)
	graphs.reach(self, def_call)
	return r[0] if r else null

func _can_train() -> bool:
	var res = true
	return res

func _stop_label() -> String:
	match glob.get_lang():
		"kz":
			return "Тоқта"
		"ru":
			return "Стоп"
		_:
			return "Stop"

func _show_training_progress(data: Dictionary) -> void:
	train.text=_stop_label()
	_paint_train_button(true)
	if not training: return

func additional_call(dict):
	if training:
		var phase := str(dict.get("phase", ""))
		if phase == "progress":
			_show_training_progress(dict.get("data", {}))
		if phase == "state":
			_show_training_progress({"stage":"epoch_end","epoch_seconds":dict.get("data",{}).get("data",{}).get("epoch_seconds",-1.0)})
			#(dict)
			if "epoch" in dict["data"] and $YY.text.is_valid_int():
				var new_text = max(0, int(dict["data"].get("left", 0)))
				$YY.set_line(str(new_text) if new_text else "")
			train.text = _stop_label()
		if phase in ["done", "stopped", "error"]:
			train_stop(true, false)

var epochs: int = 0

var training: bool = false
var delaying: bool = false
func train_stop(force: bool = false, send: bool = true):
	#$ColorRect2.alive = false
	if training and (not delaying or force) and _can_train():
		$YY.editable = true
		delaying = true
		training = false
		train.text = "Train!"
		_paint_train_button(false)
		if old_head:
			old_head.train_stop()
			if send:
				nn.stop_train(old_head)
		if int($YY.text) <= 1:
			$YY.set_line("")
		await glob.wait(2)
		delaying = false

func vbox_focus():
	#($ColorRect2/Control/ScrollContainer.get_v_scroll_bar().get_global_rect().has_point(get_global_mouse_position()))
	#if scrolling:
	#	return true
	return vbox_vis() and glob.mouse_pressed and $ColorRect2/Control/ScrollContainer.get_v_scroll_bar().get_global_rect().has_point(get_global_mouse_position())

func vbox_vis():
	return $ColorRect2/Control/ScrollContainer.get_v_scroll_bar().visible

func _can_drag() -> bool:
	return not train.is_mouse_inside() and not ui.is_focus($YY) and not vbox_focus() and not clearbut.is_mouse_inside()

func _stopped_processing():
	glob.set_scroll_possible(self)

func _process(delta: float) -> void:
	#if glob.space_just_pressed:
	#	print(get_training_data())
	super(delta)
	if $ColorRect2.get_global_rect().has_point(get_global_mouse_position()) and vbox_vis():
		glob.set_scroll_impossible(self)
	else:
		glob.set_scroll_possible(self)
	#(func(): scrolling = false).call_deferred()
		

func _proceed_hold() -> bool:
	#if glob.space_just_pressed:
	#	set_dataset_meta({"outputs": [{"label": "hii"}]})
	return ui.is_focus($YY) or vbox_focus()

var old_head = null
func train_start():
	#timing_offset = -$ColorRect2.get_time()
	if not training and not delaying:
		if not graphs.has_input():
			ui.error(no_input_text(str(glob.get_lang())))
			return
		var head = get_training_head()
		if not is_instance_valid(head):
			nn._report_runtime_code("training_graph_invalid", "training")
			return
		
		$YY.editable = false
		training = true
		train.text = _stop_label()
		_paint_train_button(true)
		old_head = head
		#(old_head)
		if not $YY.text: $YY.set_line("1"); epochs = 1
		else: epochs = int($YY.text)
		if old_head:
			#("AA")
			old_head.train_start()
			if not await nn.start_train(old_head, additional_call, train):
				hold_for_frame()
				train_stop(false, false)
		#($YY.text)

@onready var train = $train
func _on_train_released() -> void:
	if training:
		train_stop()
	else:
		events.event_ping("train", {"id": graph_id, })
		train_start()


func _on_train_2_released() -> void:
	var anc = null

	for i in graphs.simple_reach(self):
		if graphs.is_node(i, "RunModel"):
			var active_name: String = i.name_graph
			if active_name == "":
				active_name = glob.DEFAULT_MODEL_NAME

			anc = graphs.get_input_graph_by_name(active_name)

		if graphs.is_node(i, "TrainInput"):
			i.clear()

	if is_instance_valid(anc):
		nn.delete_ctx(anc.context_id)
		#await web.POST("delete_ctx", {"user": cookies.user(), "pass": cookies.pwd(), "scene": str(glob.get_project_id()), "contexts": [str(anc.context_id)]})
