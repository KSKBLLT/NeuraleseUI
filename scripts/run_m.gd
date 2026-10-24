extends DynamicGraph
#forwardpass
var name_graph: String = ""
var language_preparation: Dictionary = {}

func language_source() -> Graph:
	if _training_dataset_meta().get("input_kind","")!="text" and _training_dataset_meta().get("name","")!="language_stories": return null
	var sources: Array[Graph] = []
	for node in graphs._graphs.values():
		if is_instance_valid(node) and not node.is_queued_for_deletion() and node.get_meta("created_with","")=="text_input": sources.append(node)
	return sources[0] if sources.size()==1 else null


static func dataset_training_loss(dataset_meta: Dictionary, configured_loss: String) -> String:
	var required_loss := str(dataset_meta.get("training_loss", "")).strip_edges()
	if required_loss in ["cross_entropy", "mse"]:
		return required_loss
	return configured_loss


func _training_dataset_meta() -> Dictionary:
	var train_begin = graphs._reach_input(self, "TrainBegin")
	if not is_instance_valid(train_begin):
		return {}
	var selected_meta: Dictionary = train_begin.dataset_meta
	var dataset_name := str(selected_meta.get("name", ""))
	if glob.FULLY_LOCAL_BUILTIN_DATASETS.has(dataset_name):
		return glob.FULLY_LOCAL_BUILTIN_DATASETS[dataset_name]
	return selected_meta



var unit_keys = {}
func _dataset_output_labels() -> Array[String]:
	var labels: Array[String] = []
	for output in _training_dataset_meta().get("outputs", []):
		var label := str(output.get("label", "")).strip_edges()
		if not label.is_empty():
			labels.append(label)
	return labels

func _automatic_branch_maps() -> Dictionary:
	var labels := _dataset_output_labels()
	var result := {}
	var index := 0
	for unit in units:
		if not is_instance_valid(unit) or not unit.has_meta("points_to"):
			continue
		var output_graph = unit.get_meta("points_to")
		var branch_id = output_graph.get_ancestor().graph_id
		var title := str(unit_titles.get(unit, output_graph.get_title()))
		var target := title if title in labels else (labels[index] if index < labels.size() else title)
		result[branch_id] = target
		index += 1
	return result

func _useful_properties() -> Dictionary:
	var branch_losses := {}
	var dataset_meta := _training_dataset_meta()
	for unit in units:
		if not is_instance_valid(unit) or not unit.has_meta("points_to"):
			continue
		var output_graph = unit.get_meta("points_to")
		var branch_id = output_graph.graph_id
		var real_id = output_graph.get_ancestor().graph_id
		var configured_loss := str(cfg["branches"].get(str(branch_id), "mse"))
		branch_losses[real_id] = dataset_training_loss(dataset_meta, configured_loss)
	return {
		"config": {
			"branch_losses": branch_losses,
			"branch_maps": _automatic_branch_maps(),
			"forward_mode": "fused",
		}
	}

func get_mapped(targets: bool = true, origins: bool = false) -> Array:
	var mappings: Array = []
	var by_branch := _automatic_branch_maps()
	for unit in units:
		if not is_instance_valid(unit) or not unit.has_meta("points_to"):
			continue
		var output_graph = unit.get_meta("points_to")
		var branch_id = output_graph.get_ancestor().graph_id
		mappings.append({
			"got_label": by_branch.get(branch_id, str(unit_titles.get(unit, ""))),
			"out_labels_title": str(unit_titles.get(unit, "")),
		})
	return mappings
func _llm_map(pack: Dictionary):
	await get_tree().process_frame
	await get_tree().process_frame
	#(pack)
	var output_labels = get_dataset_output_labels()
	#(omap)
	if output_labels:
		var new_mapped = {}; var keys = output_labels.keys()
		var i: int = -1
		for map in (pack["mapped"]):
			i += 1
			if keys.size() == i: break
			#(keys[i])
			new_mapped[map] = keys[i]
		pack["mapped"] = new_mapped
		update_config({"mapped": pack["mapped"]})
	#cfg["branches"].clear()
	#for i in pack["mapped"]:
	#
	for i in pack.get("branches", []):
		#i = cfg[""]
		#var node = glob.tags_1d.get(i)
		#(node)
		for branch_str in cfg["branches"]:
			#(pack["loss_heads"][i])
			if not int(branch_str) in graphs._graphs: continue
			if graphs._graphs[int(branch_str)].get_title() == i:
				set_loss_type(branch_str, pack["branches"][i])
		#else:
		#	print("Skipping one...")

func _just_connected(who: Connection, to: Connection):
	pass

func _request_save():
	set_name_graph(name_graph)
	var mapped := {}
	for item in get_mapped(false, false):
		mapped[item.out_labels_title] = item.got_label
	manually = true
	update_config({"mapped": mapped})
	manually = false
func dis():
	$Label2.hide()

func loss_button(bt: BlockComponent):
	#("AA")
	#(bt.is_contained.get_parent().name)
	var got = str(bt.is_contained.graph.get_meta("points_to", {"graph_id": ""}).graph_id)

	set_loss_type(got, bt.hint)
	bt.is_contained.text = bt.text
	bt.is_contained.menu_hide()

func _llm_config(prev: Dictionary) -> Dictionary:
	var res = prev
	res["branch_res"] = {}
	for branch_str in prev["branches"].keys():
		if not int(branch_str) in graphs._graphs: continue
		res["branch_res"][graphs._graphs[int(branch_str)].get_title()] = prev["branches"][branch_str]
	res["branches"] = res["branch_res"]
	#(res)
	#(res)
	return res

var manually: bool = false
## record_undo is false when the loss follows from the graph (set_name_graph
## re-maps every branch on each model change): only a pupil's own choice is
## an undo step, or Undo would revert the re-mapping before their action.
func set_loss_type(of_id, loss: String, inner=false, record_undo := true):
	#if not has_config_subfield("branches/" + str(node.graph_id)):

	if of_id == "":
		return
	if not inner:
		manually = true
		if record_undo:
			open_undo_redo()
		update_config_subfield({"branches": {str(of_id): loss}})
		if record_undo:
			close_undo_redo()
	#(of_id, unit_keys)

	if of_id in unit_keys and is_instance_valid(unit_keys[of_id]):
		var ls = unit_keys[of_id].get_node("loss")
		if ls:
			ls.text = ls.button_by_hint[loss].text
	if not inner:
		manually = false

func _map_properties(pack: Dictionary):
	pass

func get_dataset_output_labels():
	var result := {}
	for label in _dataset_output_labels():
		result[label] = label
	return result
func _config_field(field: StringName, value: Variant):
	if field.begins_with("branches/") and not manually:
		set_loss_type(field.trim_prefix("branches/"), value, true)

func edit_unit(node: Graph, u: Control):
	u.get_node("Control/Label").text = node.get_title()
	u.get_node("Control/Label").resize()
	u.set_meta("points_to", node)
	unit_keys[str(node.graph_id)] = u
	unit_titles[u] = node.get_title()
	#set_loss_type(str(node.graph_id), "mse")
	#("A!")




func _process(delta: float) -> void:
	super(delta)
	#if glob.space_just_pressed:
	#	print(get_mapped())
		#(_useful_properties())

func _just_deattached(other_conn: Connection, my_conn: Connection):
	pass

func _just_attached(other_conn: Connection, my_conn: Connection):
	pass
func _is_suitable_other_conn(other: Connection, mine: Connection) -> bool:
	if mine.hint == 1: return true
	#("is_emv")



	if other.parent_graph.get_meta("input_features", {}).has("is_env"):
		return true
	var active_name: String = name_graph
	if active_name == "":
		active_name = glob.DEFAULT_MODEL_NAME

	var anc = graphs.get_input_graph_by_name(active_name)
	# Always allow connection. Training start logic will catch missing models.
	return true



func get_input_format(who: Graph) -> String:
	if who.get_meta("created_with","")=="text_input": return "text"
	return who.repr()
	#if who.base_dt == "1d":
		#return "1d(" + str(len(who.to_tensor())) + ")"
	#else:
		#return "2d" + str(len(who.get_raw_values()))



func set_name_graph(st: String, remove = null):
	if st == "":
		st = glob.DEFAULT_MODEL_NAME

	var input_graph = graphs.get_input_graph_by_name(st)
	if _training_dataset_meta().get("input_kind","")=="text": input_graph=language_source()
	if st and input_graph:
		$ColorRect/root/Label.position.y = 3
		$ColorRect/root/input_fmt.show()
	else:

		$ColorRect/root/input_fmt.hide()
		$ColorRect/root/Label.position.y = 9

	hold_for_frame()

	var old_len = len(units)
	var branch_ends = {}
	var cachify = func (from: Connection, to: Connection, branch_cache: Dictionary):
		if to.parent_graph == remove:
			return
		if to.parent_graph.is_head:
			branch_ends[to.parent_graph] = true; return
		#	branch_ends[to.parent_graph] = true
	name_graph = st
	#(graphs.graph_map)
	#(input_graph)
	if !is_instance_valid(input_graph):
		for unit in len(units):
			remove_unit(len(units)-1)
		dis()
		return

	$ColorRect/root/input_fmt.text = "in " + get_input_format(input_graph)
	graphs.reach(input_graph, cachify)
	var prev_by_title := {}
	for id in cfg["branches"]:
		if not int(id) in graphs._graphs: continue
		prev_by_title[graphs._graphs[int(id)].get_title()] = cfg["branches"][id]
	var required_loss := dataset_training_loss(_training_dataset_meta(), "")
	var new_len = len(branch_ends)
	for unitt in range(new_len, old_len):
		remove_unit(len(units)-1)
	if !new_len:
		dis()
	else:
		$Label2.show()
	var ct: int = -1
	for j: OutputGraph in (branch_ends):
		ct += 1
		if ct >= old_len:
			add_unit({"text": j.get_title()}, true)
		edit_unit(j, units[ct])
		#if ct >= old_len:
		set_loss_type(str(j.graph_id), "mse", false, false)
		unit_set_meta(units[ct], j.res_meta)
	#(prev_branches)
	#(old_units)
	#(prev_branches)
	#(unit_keys)
	for j in branch_ends:
		var title = j.get_title()
		var loss = required_loss if not required_loss.is_empty() else prev_by_title.get(title, "mse")
		set_loss_type(str(j.graph_id), loss, false, false)

func _unit_removal(id: int):
	pass

func unit_set_meta(unit: Control, kw: Dictionary):
	if language_source()!=null:
		unit.get_node("ColorRect/Label2").text=load("res://scripts/language_models/language_style.gd").localized("text","текст","мәтін")
		return
	if not "datatype" in kw:
		return
	var vec = str(kw["x"]) if kw["datatype"] == "1d" else str(kw["x"]) + "," + str(kw["y"])
	unit.get_node("ColorRect/Label2").text = kw["datatype"] + "(" + vec + ")"

var unit_titles = {}
func _get_unit(kw: Dictionary) -> Control: #virtual
	var dup = _unit.duplicate()
	dup.get_node("loss").graph = dup
	dup.get_node("loss").auto_ready = true
	unit_titles[dup] = kw["text"]
	for child in dup.get_node("loss").get_children():
		if child is BlockComponent:
			child.auto_ready = true
	dup.get_node("imp").graph = dup
	dup.get_node("imp").auto_ready = true
	for child in dup.get_node("imp").get_children():
		if child is BlockComponent:
			child.auto_ready = true
	dup.get_node("loss").child_button_release.connect(loss_button)
	dup.get_node("Control/Label").text = kw["text"]
	dup.show()
	dup.modulate.a = 0.0
	appear_units[dup] = true
	#unit_set_meta(dup, kw["end_node"])
	#update_config_subfield({"branches/%s"%})
	#(outputs)
	return dup




func _ready() -> void:
	super()
	await get_tree().process_frame
	await get_tree().process_frame
	await get_tree().process_frame
	set_name_graph(glob.DEFAULT_MODEL_NAME)

	graphs.model_updated.connect(func(model_name: String):
		print(model_name)
		if model_name == glob.DEFAULT_MODEL_NAME:
			set_name_graph(glob.DEFAULT_MODEL_NAME)
	)
	graphs.spline_connected.connect(func(f, t):
		set_name_graph(glob.DEFAULT_MODEL_NAME)
	)
	graphs.spline_disconnected.connect(func(f, t):
		set_name_graph(glob.DEFAULT_MODEL_NAME, f.parent_graph)
	)



	#set_name_graph("")
