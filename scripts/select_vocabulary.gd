extends SplashMenu

@onready var list = $ColorRect/list
@onready var search: ValidInput = $ColorRect/Label2

const BUILTIN_LABEL_SETS := {
	"bpe_8192": [],
	"cifar10": ["airplane", "automobile", "bird", "cat", "deer", "dog", "frog", "horse", "ship", "truck"],
	"mnist": ["0", "1", "2", "3", "4", "5", "6", "7", "8", "9"],
	"iris": ["setosa", "versicolor", "virginica"],
	"titanic": ["no", "yes"],
	"eco_ai": ["Glass", "Metal", "Paper", "Plastic"],
}

var _search_revision := 0
var _vocab_source: String = "bpe_8192"
var _mode: String = "all_datasets"
var _chains: Array = []
var _label_names: Array = []
var _visible_entries: Array = []


func _process(delta: float) -> void:
	var prev_s = $ColorRect.scale
	super(delta)
	if !glob.is_vec_approx(prev_s, $ColorRect.scale):
		list.update_children_reveal()


func _ready() -> void:
	if emitter == null and is_instance_valid(ui):
		emitter = ui.ResultEmitter.new()
	if is_instance_valid(search) and not search.text_changed.is_connected(_on_search_changed):
		search.text_changed.connect(_on_search_changed)
	_load_passed_data()
	super()
	await get_tree().process_frame
	if is_instance_valid(list):
		list.passed_who = str(passed_data.get("with_who", "preset:" + _vocab_source))
	_refresh_list(search.text if is_instance_valid(search) else "")


func _splash() -> void:
	_load_passed_data()
	if is_node_ready() and is_instance_valid(list):
		list.passed_who = str(passed_data.get("with_who", "preset:" + _vocab_source))
	_refresh_list(search.text if is_instance_valid(search) else "")


func _just_go_away() -> void:
	if is_instance_valid(ui):
		ui.splashed_in.erase(self)


func _load_passed_data() -> void:
	_vocab_source = str(passed_data.get("vocab_source", "bpe_8192"))
	_mode = str(passed_data.get("mode", "all_datasets"))
	_chains = []
	var passed_chains = passed_data.get("chains", [])
	if passed_chains is Array:
		_chains = passed_chains.duplicate(true)
	_label_names = []
	var passed_labels = passed_data.get("label_names", [])
	if passed_labels is Array:
		_label_names = passed_labels.duplicate()


func _suffix_text() -> String:
	return _localized("(output classes)", "(выходные классы)", "(шығыс сыныптары)")


func _localized(en: String, ru: String, kz: String) -> String:
	if is_instance_valid(glob) and glob.has_method("get_lang"):
		match str(glob.get_lang()):
			"ru":
				return ru
			"kz":
				return kz
	return en


func _collect_presets() -> Dictionary:
	var presets := BUILTIN_LABEL_SETS.duplicate(true)
	if is_instance_valid(glob) and glob.dataset_datas is Dictionary:
		for ds_key in glob.dataset_datas:
			var preview = DsObjRLE.get_preview(glob.dataset_datas[ds_key])
			if preview is Dictionary:
				var outputs_arr = preview.get("outputs", [])
				if outputs_arr is Array:
					for out_spec in outputs_arr:
						if out_spec is Dictionary:
							var out_labels = out_spec.get("label_names", [])
							if out_labels is Array and not out_labels.is_empty():
								presets[str(ds_key)] = out_labels.duplicate()
								break
	return presets


func _on_search_changed(query: String) -> void:
	_search_revision += 1
	_apply_search.call_deferred(query, _search_revision)


func _apply_search(query: String, revision: int) -> void:
	if revision != _search_revision or not is_instance_valid(list):
		return
	_refresh_list(query)


func set_query(query: String) -> void:
	if is_instance_valid(search):
		search.text = query
	_search_revision += 1
	_refresh_list(query)


func get_visible_entries() -> Array:
	return _visible_entries.duplicate(true)


func _refresh_list(query: String) -> void:
	var q := query.strip_edges().to_lower()
	var items: Array = []
	var suffix := _suffix_text()

	if _mode == "chains_only" and not _chains.is_empty():
		# Condition 2: Show only datasets connected in complete training chains
		var seen := {}
		for chain in _chains:
			if not (chain is Dictionary):
				continue
			var ds_name := str(chain.get("dataset_name", "")).strip_edges()
			if ds_name == "" or seen.has(ds_name):
				continue
			seen[ds_name] = true
			if q != "" and not q in ds_name.to_lower():
				continue
			var labels: Array = chain.get("label_names", [])
			items.append({
				"id": "preset:" + ds_name,
				"text": "%s %s" % [ds_name, suffix],
				"is_preset": true,
				"payload": {
					"preset": ds_name,
					"dataset_name": ds_name,
					"label_names": labels.duplicate(),
				},
			})
	else:
		# Condition 1: Show all datasets & presets
		var presets := _collect_presets()
		for preset_name in presets.keys():
			var name_str := str(preset_name)
			if q != "" and not q in name_str.to_lower():
				continue
			var labels: Array = presets[preset_name]
			items.append({
				"id": "preset:" + name_str,
				"text": "%s %s" % [name_str, suffix],
				"is_preset": true,
				"payload": {
					"preset": name_str,
					"dataset_name": name_str,
					"label_names": labels.duplicate(),
				},
			})

	_visible_entries = items
	if is_instance_valid(list):
		list.show_up(items)


func _resultate(data: Dictionary) -> void:
	if emitter != null:
		emitter.res.emit(data)
	go_away()


func _on_list_child_button_release(button: BlockComponent) -> void:
	var payload: Dictionary = button.metadata.get("payload", {})
	resultate(payload)
