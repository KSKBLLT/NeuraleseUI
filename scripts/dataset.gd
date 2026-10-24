extends SplashMenu

const DatasetSearch = preload("res://scripts/dataset_search.gd")

@onready var list = $ColorRect/list
@onready var search: ValidInput = $ColorRect/Label2



func _process(delta: float) -> void:
	var prev_s = $ColorRect.scale
	super(delta)
	if !glob.is_vec_approx(prev_s, $ColorRect.scale):
		list.update_children_reveal()

var loaded_datasets = {}
var parsed = {}
var env_mode: bool = false
var _dataset_entries: Dictionary = {}
var _search_revision := 0

func _ready() -> void:
	if not search.text_changed.is_connected(_on_search_changed):
		search.text_changed.connect(_on_search_changed)
	if "env" in passed_data:
		$ColorRect/Label.text = "Select environment"
		$ColorRect/root/Label.text = "/environments"
		env_mode = true
	super()
	await get_tree().process_frame
	#$ColorRect/Label.text = cookies.get_username()
	ui.hourglass_on()
	#"name": "", "outputs": [], "input_format": {}}
	if env_mode:
		loaded_datasets = {"n/gym": 
			{"name": "gym", "outputs": [
			{"label": "digit", "x": 10, "datatype": "1d"}],
			"inputs": {"is_env": {}},
			"input_hints": [{"name": "image", "value": "28x28", "dtype": "image"}],
			"env": true}}
	else:
		loaded_datasets = await glob.get_loaded_datasets()#await glob.request_projects()
	#(loaded_datasets)
	ui.hourglass_off()
	$ColorRect/list.passed_who = passed_data.get("with_who", "")
	#quitting.connect(
#	glob.reset_menu_type.bind($ColorRect/list, &"delete_project"))
	#var a = await web.POST("project_list", {
	#"user": "neri", 
	#"pass": "123"
	#})
	#if a.body:
		#parsed = JSON.parse_string(a.body.get_string_from_utf8())["list"]
	var result = {}
	for i in glob.dataset_datas:
		var preview = DsObjRLE.get_preview(glob.dataset_datas[i])
		#(preview)
		preview["local"] = true
		result[i] = {"data": preview, "local": true}
	for i in loaded_datasets:
		result[i] = {"data": loaded_datasets[i], "local": false}
	_dataset_entries = _pilot_first(result)
	list.show_up(DatasetSearch.filter(_dataset_entries, search.text))
	await get_tree().process_frame


## Pilot datasets lead the list (lesson 1 asks for eco_ai) and built-in sets
## whose files the runtime lacks (cifar10 until it is built) stay out of it.
const _PILOT_ORDER := ["eco_ai", "mnist", "car_track", "iris", "titanic", "cifar10"]
const _BUILT_FILES := {"cifar10": "datasets/cifar10/train.npz"}


static func _pilot_first(entries: Dictionary) -> Dictionary:
	var ordered := {}
	for dataset_id in _PILOT_ORDER:
		if entries.has(dataset_id) and _is_on_disk(dataset_id):
			ordered[dataset_id] = entries[dataset_id]
	for dataset_id in entries:
		if not ordered.has(dataset_id) and _is_on_disk(dataset_id):
			ordered[dataset_id] = entries[dataset_id]
	return ordered.duplicate(true)


static func _is_on_disk(dataset_id: String) -> bool:
	if not _BUILT_FILES.has(dataset_id) or not local_runtime.ensure_ready():
		return true
	# ensure_ready() is synchronous; runtime_root_abs() wraps it in an await.
	return FileAccess.file_exists(local_runtime._runtime_root.path_join(_BUILT_FILES[dataset_id]))


func _on_search_changed(query: String) -> void:
	_search_revision += 1
	_apply_search.call_deferred(query, _search_revision)


func _apply_search(query: String, revision: int) -> void:
	if revision != _search_revision or not is_instance_valid(list):
		return
	list.show_up(DatasetSearch.filter(_dataset_entries, query))

func _resultate(data: Dictionary):
	emitter.res.emit(data)
	go_away()


func _on_list_child_button_release(button: BlockComponent) -> void:
	#(button.metadata["local_preview"])# = DsObjRLE.get_preview(glob.ds_dump[button.hint])
	#(glob.ds_dump[button.hint])
	resultate({"ds": button.hint, "meta": loaded_datasets[button.hint] if not button.metadata["local"] else button.metadata["local_preview"]})


func _on_add() -> void:
	pass
	#can_go = false
	#go_away()
	#await quitting
	#queue_free()
	#ui.splash("project_create", splashed_from, emitter, true)



func _on_logout() -> void:
	pass # Replace with function body.
