extends OutputGraph
class_name TopOutputGraph

const LanguageAdapter = preload("res://scripts/language_models/language_graph_adapter.gd")
const SelectVocabulary = preload("res://scripts/select_vocabulary.gd")

class ViewProxy extends RefCounted:
	var _owner: TopOutputGraph
	var other_mass: float:
		get:
			return _owner.other_mass if is_instance_valid(_owner) else 0.0
	var rows: Array:
		get:
			if not is_instance_valid(_owner) or not _owner.has_active_predictions():
				return []
			return _owner.units

	func _init(owner_node: TopOutputGraph) -> void:
		_owner = owner_node

@export var language_kind: StringName = &"token_labels"

var disable_unit_delete: bool = true
var trace: Dictionary = {}
var other_mass: float = 0.0
var _trace_labels: Dictionary = {}
var _selected_id: int = -1
var _explicit_bpe: bool = false
var _pinned_dataset_name: String = ""
var _current_dataset_name: String = ""
var _refresh_pending: bool = false
var view: ViewProxy = ViewProxy.new(self)

@onready var other_label: Label = get_node_or_null("input/OtherLabel")


func _after_ready() -> void:
	super()
	if is_instance_valid(rect):
		rect.set_instance_shader_parameter("corner_radius_width_add", Vector2(-2, 0))
		rect.set_instance_shader_parameter("outline_color", Color(1, 1, 1, 1))
		rect.set_instance_shader_parameter("tuning", Color(0.050980393, 0.050980393, 0.050980393, 0.5411765))
		base_outline = Color(1, 1, 1, 1)
	for port in _inputs:
		if not port.config_conn:
			port.accepted_datatypes[&"layer1d"] = true
			port.accepted_datatypes[&"language_scores"] = true
			port.color = Color(0.297, 0.9, 0.72915, 1)
			port.gradient_color = Color(0.298039, 0.901961, 0.729412, 1)
	if is_instance_valid(glob):
		if not glob.language_changed.is_connected(_on_language_changed):
			glob.language_changed.connect(_on_language_changed)
		if not glob.ds_change.is_connected(_on_dataset_changed):
			glob.ds_change.connect(_on_dataset_changed)
		if not glob.ds_invalid.is_connected(_on_dataset_changed):
			glob.ds_invalid.connect(_on_dataset_changed)
	if is_instance_valid(graphs):
		if not graphs.spline_connected.is_connected(_on_topology_changed):
			graphs.spline_connected.connect(_on_topology_changed)
		if not graphs.spline_disconnected.is_connected(_on_topology_changed):
			graphs.spline_disconnected.connect(_on_topology_changed)
		if not graphs.node_added.is_connected(_on_topology_changed):
			graphs.node_added.connect(_on_topology_changed)
		if graphs.has_signal("model_updated") and not graphs.model_updated.is_connected(_on_topology_changed):
			graphs.model_updated.connect(_on_topology_changed)
	var initial_top_n := clampi(int(cfg.get("top_n", 5)), 1, 20)
	_sync_unit_count(initial_top_n, true)
	var initial_title := str(cfg.get("title", ""))
	if initial_title != "" and is_node_ready():
		$ColorRect/root/Label.set_line(initial_title)
	_refresh_training_binding()
	_refresh_display()
	_hold_multiframe(5)


func _exit_tree() -> void:
	super()
	if is_instance_valid(glob):
		if glob.language_changed.is_connected(_on_language_changed):
			glob.language_changed.disconnect(_on_language_changed)
		if glob.ds_change.is_connected(_on_dataset_changed):
			glob.ds_change.disconnect(_on_dataset_changed)
		if glob.ds_invalid.is_connected(_on_dataset_changed):
			glob.ds_invalid.disconnect(_on_dataset_changed)
	if is_instance_valid(graphs):
		if graphs.spline_connected.is_connected(_on_topology_changed):
			graphs.spline_connected.disconnect(_on_topology_changed)
		if graphs.spline_disconnected.is_connected(_on_topology_changed):
			graphs.spline_disconnected.disconnect(_on_topology_changed)
		if graphs.node_added.is_connected(_on_topology_changed):
			graphs.node_added.disconnect(_on_topology_changed)
		if graphs.has_signal("model_updated") and graphs.model_updated.is_connected(_on_topology_changed):
			graphs.model_updated.disconnect(_on_topology_changed)


func _after_process(delta: float) -> void:
	super(delta)
	_layout_generation_port()


func _layout_generation_port() -> void:
	var port := get_node_or_null("input/AutoregressOut") as Connection
	if port == null or _inputs.is_empty(): return
	var exposure: float = rect.position.x - _inputs[0].position.x
	var at := rect.position + Vector2(rect.size.x * 0.5 - port.size.x * 0.5, rect.size.y + exposure - port.size.y) - input.position
	if port.position != at:
		port.position=at
		reposition_splines()


func _on_topology_changed(_arg1 = null, _arg2 = null) -> void:
	_schedule_topology_refresh()


func _on_dataset_changed(_who: String = "") -> void:
	_schedule_topology_refresh()


func _schedule_topology_refresh() -> void:
	if _refresh_pending:
		return
	_refresh_pending = true
	_do_schedule_topology_refresh.call_deferred()


func _do_schedule_topology_refresh() -> void:
	_refresh_pending = false
	if not is_inside_tree():
		return
	_refresh_training_binding()
	_refresh_display()
	_hold_multiframe(5)


func _hold_multiframe(count: int = 5) -> void:
	for i in count:
		hold_for_frame()
		if is_inside_tree():
			await get_tree().process_frame


func _get_complete_training_chains() -> Array[Dictionary]:
	var chains: Array[Dictionary] = []
	if not is_instance_valid(graphs) or not (graphs._graphs is Dictionary):
		return chains

	for g in graphs._graphs.values():
		if not is_instance_valid(g) or g.server_typename != &"TrainBegin":
			continue

		var ds_nodes: Array[Graph] = []
		for ancestor in g.get_first_ancestors():
			if is_instance_valid(ancestor) and ancestor.server_typename == &"DatasetName":
				ds_nodes.append(ancestor)
		if ds_nodes.is_empty():
			for port in g._inputs:
				if port.server_name == &"netname":
					for spline in port.inputs:
						if is_instance_valid(spline.origin) and is_instance_valid(spline.origin.parent_graph):
							if spline.origin.parent_graph.server_typename == &"DatasetName":
								ds_nodes.append(spline.origin.parent_graph)

		var rm_nodes: Array[Graph] = []
		for descendant in g.get_first_descendants():
			if is_instance_valid(descendant) and descendant.server_typename == &"RunModel":
				rm_nodes.append(descendant)
		if rm_nodes.is_empty():
			for port in g.outputs:
				if port.server_name == &"input_out":
					for id in port.outputs:
						var spline = port.outputs[id]
						if is_instance_valid(spline.tied_to) and is_instance_valid(spline.tied_to.parent_graph):
							if spline.tied_to.parent_graph.server_typename == &"RunModel":
								rm_nodes.append(spline.tied_to.parent_graph)

		if ds_nodes.is_empty() or rm_nodes.is_empty():
			continue

		for ds in ds_nodes:
			var ds_name: String = ""
			if ds.get("cfg") is Dictionary:
				ds_name = str(ds.cfg.get("name", ""))
			var labels := _extract_labels_from_meta(ds.get("saved_meta"), ds_name)
			if labels.is_empty() and ds.get("cfg") is Dictionary:
				labels = _extract_labels_from_meta(ds.cfg.get("meta"), ds_name)
			if labels.is_empty():
				labels = _extract_labels_from_meta(ds.get("current_meta"), ds_name)
			if labels.is_empty():
				labels = _extract_labels_from_meta(g.get("dataset_meta"), ds_name)

			chains.append({
				"train_begin": g,
				"dataset_node": ds,
				"run_model_nodes": rm_nodes,
				"dataset_name": ds_name,
				"label_names": labels,
				"index": ds.get_index(),
				"graph_id": ds.graph_id,
			})

	var unique_chains: Array[Dictionary] = []
	var seen: Dictionary = {}
	for c in chains:
		var ds_ref = c["dataset_node"]
		if not seen.has(ds_ref):
			seen[ds_ref] = true
			unique_chains.append(c)

	unique_chains.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		return int(a.get("index", 0)) < int(b.get("index", 0))
	)
	return unique_chains


func _set_vocab_button_enabled(enabled: bool) -> void:
	if not is_instance_valid(add_button):
		return
	if enabled:
		add_button.mouse_filter = Control.MOUSE_FILTER_STOP
		var enabled_color := Color(1.0, 1.0, 1.0, 1.0)
		add_button.modulate = enabled_color
		add_button.base_modulate = enabled_color
		add_button._base_modulate = enabled_color
		add_button.unblock_input(true)
	else:
		add_button.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var disabled_color := Color(0.4, 0.4, 0.4, 0.4)
		add_button.modulate = disabled_color
		add_button.base_modulate = disabled_color
		add_button._base_modulate = disabled_color
		add_button.block_input(true)


func _refresh_training_binding() -> void:
	var chains := _get_complete_training_chains()
	var chain_count := chains.size()

	if chain_count == 0:
		# Condition 1: Training graph is not configured -> button ENABLED
		_set_vocab_button_enabled(true)
	elif chain_count == 1:
		# Condition 3: Exactly 1 complete chain -> button DISABLED (semi-transparent), auto-bind
		_set_vocab_button_enabled(false)
		_apply_bound_chain(chains[0])
	else:
		# Condition 2: Multiple (>= 2) complete chains -> button ENABLED, default to first created dataset
		_set_vocab_button_enabled(true)
		var target_chain: Dictionary = {}
		if _pinned_dataset_name != "":
			for c in chains:
				if str(c.get("dataset_name", "")) == _pinned_dataset_name:
					target_chain = c
					break
		if target_chain.is_empty():
			target_chain = chains[0]
			_pinned_dataset_name = str(target_chain.get("dataset_name", ""))
		_apply_bound_chain(target_chain)


func _apply_bound_chain(chain: Dictionary) -> void:
	var ds_name := str(chain.get("dataset_name", ""))
	var labels: Array = chain.get("label_names", [])
	_current_dataset_name = ds_name
	_explicit_bpe = false

	var current_labels = cfg.get("label_names", [])
	if current_labels != labels or str(cfg.get("vocab_source", "")) != ds_name:
		cfg["vocab_source"] = ds_name
		cfg["label_names"] = labels.duplicate()
	_refresh_display()


func has_active_predictions() -> bool:
	return not value_cache.is_empty() or not trace.is_empty()


func _can_drag() -> bool:
	if is_instance_valid(add_button) and (add_button.is_mouse_inside() or add_button.state.pressing or add_button.in_splash):
		return false
	return super()


func _unit_just_added() -> void:
	learner.notify_update.call_deferred()


func _unit_removal(_id: int) -> void:
	pass


func _request_save() -> void:
	pass


func set_names(names: Array) -> void:
	open_undo_redo(true)
	update_config({
		"label_names": names.duplicate(),
		"vocab_source": "custom" if not names.is_empty() else "bpe_8192",
	})
	close_undo_redo()


func get_title() -> String:
	var header_text: String = $ColorRect/root/Label.text if has_node("ColorRect/root/Label") else ""
	return header_text if header_text != "" else "BestAnswer"


func _config_field(field: StringName, value: Variant) -> void:
	if field == &"top_n":
		var target_n := clampi(int(value), 1, 20)
		_sync_unit_count(target_n, true)
		_refresh_display()
		hold_for_frame()
	elif field == &"label_names":
		_refresh_display()
		hold_for_frame()
	elif field == &"vocab_source":
		var src := str(value)
		if src == "bpe_8192":
			_explicit_bpe = true
		elif src == "auto":
			_explicit_bpe = false
		elif SelectVocabulary.BUILTIN_LABEL_SETS.has(src):
			_explicit_bpe = false
			cfg["label_names"] = SelectVocabulary.BUILTIN_LABEL_SETS[src].duplicate()
		_refresh_display()
		hold_for_frame()
	elif not upd and field == &"title":
		if has_node("ColorRect/root/Label"):
			$ColorRect/root/Label.set_line(str(value))
		ch()


func _sync_unit_count(count: int, instant: bool = true) -> void:
	if _unit == null:
		return
	var target_count := clampi(count, 1, 20)
	while len(units) < target_count:
		add_unit({"text": _default_slot_label(len(units))}, instant)
	while len(units) > target_count:
		remove_unit(len(units) - 1)
	if instant:
		for i in 100:
			if add_q.empty():
				break
			var popped = add_q.pop()
			popped.call()
		for u in units:
			if is_instance_valid(u):
				u.modulate.a = 1.0
				appear_units.erase(u)
		if bottom_attached and is_instance_valid(input):
			input.position.y = target_y + input_y_add
		if lerp_size and is_instance_valid(rect):
			rect.size.y = max(min_size, target_size + size_add + adding_size_y)
			size_changed()
		_layout_generation_port()


func _default_slot_label(slot_idx: int) -> String:
	var labels: Array = _active_label_array()
	if slot_idx >= 0 and slot_idx < labels.size() and str(labels[slot_idx]) != "":
		return str(labels[slot_idx])
	var src := _current_dataset_name if _current_dataset_name != "" else str(cfg.get("vocab_source", "bpe_8192"))
	if src in ["bpe_8192", "auto"]:
		if is_instance_valid(language_models) and language_models.backend != null:
			if language_models.backend.has_method("vocab_piece"):
				return str(language_models.backend.vocab_piece(slot_idx)).replace("\n", "\\n")
			if language_models.backend.has_method("piece"):
				return str(language_models.backend.piece(slot_idx)).replace("\n", "\\n")
	return "#%d" % (slot_idx + 1)


func _extract_labels_from_meta(meta: Variant, ds_name: String = "") -> Array:
	if meta is Dictionary:
		# A text corpus has no classifier labels; do not recursively look up
		# that same builtin corpus or replace the real model's vocabulary.
		if meta.get("input_kind","")=="text" or meta.get("name","")=="language_stories": return []
		var direct = meta.get("label_names", [])
		if direct is Array and not direct.is_empty():
			return direct
		var outputs_arr = meta.get("outputs", [])
		if outputs_arr is Array:
			for out_spec in outputs_arr:
				if out_spec is Dictionary:
					var out_labels = out_spec.get("label_names", [])
					if out_labels is Array and not out_labels.is_empty():
						return out_labels
		if ds_name == "":
			ds_name = str(meta.get("name", ""))
	var clean_name := ds_name.strip_edges().to_lower()
	if clean_name != "":
		var builtin_set = SelectVocabulary.BUILTIN_LABEL_SETS.get(clean_name, [])
		if builtin_set is Array and not builtin_set.is_empty():
			return builtin_set
		if is_instance_valid(glob):
			if glob.FULLY_LOCAL_BUILTIN_DATASETS.has(clean_name):
				var from_builtin := _extract_labels_from_meta(glob.FULLY_LOCAL_BUILTIN_DATASETS[clean_name], "")
				if not from_builtin.is_empty():
					return from_builtin
			var loaded = glob.load_dataset(ds_name)
			if loaded is Dictionary and not loaded.is_empty():
				var from_loaded := _extract_labels_from_meta(loaded, "")
				if not from_loaded.is_empty():
					return from_loaded
	return []


func _active_label_array() -> Array:
	var configured = cfg.get("label_names", [])
	if configured is Array and not configured.is_empty():
		return configured
	var src := _current_dataset_name if _current_dataset_name != "" else str(cfg.get("vocab_source", "bpe_8192"))
	var builtin = SelectVocabulary.BUILTIN_LABEL_SETS.get(src, [])
	if builtin is Array and not builtin.is_empty():
		return builtin
	if src == "bpe_8192" and (_explicit_bpe or LanguageAdapter.is_language(self) or not trace.is_empty() or value_cache.size() >= 256):
		return []
	var from_res := _extract_labels_from_meta(res_meta)
	if not from_res.is_empty():
		return from_res
	if is_instance_valid(graphs) and graphs._graphs is Dictionary:
		var chains := _get_complete_training_chains()
		if not chains.is_empty():
			var chain: Dictionary = chains[0]
			if _pinned_dataset_name != "":
				for c in chains:
					if str(c.get("dataset_name", "")) == _pinned_dataset_name:
						chain = c
						break
			var labels: Array = chain.get("label_names", [])
			if not labels.is_empty():
				return labels
		for g in graphs._graphs.values():
			if not is_instance_valid(g):
				continue
			if g.server_typename == &"TrainBegin":
				var tb_labels := _extract_labels_from_meta(g.get("dataset_meta"))
				if not tb_labels.is_empty():
					return tb_labels
		for g in graphs._graphs.values():
			if not is_instance_valid(g):
				continue
			if g.server_typename == &"DatasetName":
				var ds_name := str(g.cfg.get("name", "")) if g.get("cfg") is Dictionary else ""
				var ds_labels := _extract_labels_from_meta(g.get("saved_meta"), ds_name)
				if ds_labels.is_empty() and g.get("cfg") is Dictionary:
					ds_labels = _extract_labels_from_meta(g.cfg.get("meta"), ds_name)
				if ds_labels.is_empty():
					ds_labels = _extract_labels_from_meta(g.get("current_meta"), ds_name)
				if not ds_labels.is_empty():
					return ds_labels
	return []


func _resolve_label(idx: int) -> String:
	if _trace_labels.has(idx):
		return str(_trace_labels[idx]).replace("\n", "\\n")
	if _trace_labels.has(str(idx)):
		return str(_trace_labels[str(idx)]).replace("\n", "\\n")
	var labels := _active_label_array()
	if idx >= 0 and idx < labels.size() and str(labels[idx]) != "":
		return str(labels[idx]).replace("\n", "\\n")
	var use_bpe := _explicit_bpe or LanguageAdapter.is_language(self) or not trace.is_empty() or value_cache.size() >= 256
	var src := _current_dataset_name if _current_dataset_name != "" else str(cfg.get("vocab_source", "bpe_8192"))
	if use_bpe and src in ["bpe_8192", "auto"]:
		if is_instance_valid(language_models) and language_models.backend != null:
			if language_models.backend.has_method("vocab_piece"):
				return str(language_models.backend.vocab_piece(idx)).replace("\n", "\\n")
			if language_models.backend.has_method("piece"):
				return str(language_models.backend.piece(idx)).replace("\n", "\\n")
	return "%s %d" % [_localized("Class", "Класс", "Класс"), idx]


func _refresh_display() -> void:
	if units.is_empty():
		return
	push_values(value_cache, per)


func push_values(values: Array, percent: bool = false) -> void:
	value_cache = values.duplicate()
	per = percent
	if units.is_empty():
		return
	if values.is_empty():
		other_mass = 0.0
		for i in len(units):
			units[i].get_node("Label").text = _default_slot_label(i)
			unit_set(i, 0.0, "0%" if percent else "0.0")
		_update_other_label(false)
		return

	var count := values.size()
	var indices: Array[int] = []
	indices.resize(count)
	for i in count:
		indices[i] = i
	indices.sort_custom(func(a: int, b: int) -> bool:
		var va := float(values[a])
		var vb := float(values[b])
		if va == vb:
			return a < b
		return va > vb
	)

	var k := mini(len(units), count)
	if percent:
		var top_sum := 0.0
		for r in k:
			var idx := indices[r]
			var prob := clampf(float(values[idx]), 0.0, 1.0)
			top_sum += prob
			units[r].get_node("Label").text = _resolve_label(idx)
			var pct := prob * 100.0
			var pct_text := "%.1f%%" % pct if (pct > 0.0 and pct < 1.0) else "%d%%" % roundi(pct)
			unit_set(r, prob, pct_text)
		for r in range(k, len(units)):
			units[r].get_node("Label").text = "—"
			unit_set(r, 0.0, "0%")
		other_mass = clampf(1.0 - top_sum, 0.0, 1.0)
		_update_other_label(true)
	else:
		var minimal := float(values.min())
		var maximal := float(values.max())
		for r in k:
			var idx := indices[r]
			var raw_val := float(values[idx])
			var weight := clampf(raw_val, 0.0, 1.0)
			if not is_equal_approx(maximal - minimal, 0.0):
				weight = clampf((raw_val - minimal) / (maximal - minimal), 0.0, 1.0)
			units[r].get_node("Label").text = _resolve_label(idx)
			unit_set(r, weight, str(glob.cap(raw_val, 2)))
		for r in range(k, len(units)):
			units[r].get_node("Label").text = "—"
			unit_set(r, 0.0, "0.0")
		other_mass = 0.0
		_update_other_label(false)


func _update_other_label(active: bool) -> void:
	if not is_instance_valid(other_label):
		other_label = get_node_or_null("input/OtherLabel")
	if not is_instance_valid(other_label):
		return
	var prefix := _localized("Other:", "Остальные:", "Қалғаны:")
	if active:
		other_label.text = "%s\n%.1f%%" % [prefix, other_mass * 100.0]
	else:
		other_label.text = "%s\n0.0%%" % prefix


func _localized(en: String, ru: String, kz: String) -> String:
	if is_instance_valid(glob) and glob.has_method("get_lang"):
		match str(glob.get_lang()):
			"ru":
				return ru
			"kz":
				return kz
	return en


func _on_language_changed() -> void:
	_refresh_display()


func get_language_op() -> StringName:
	return &"token_labels"


func get_language_config() -> Dictionary:
	return cfg.duplicate(true)


func apply_language_trace(value: Dictionary) -> void:
	trace = value.duplicate(true)
	var preview: Dictionary = value.get("preview", {}) if value.get("preview", {}) is Dictionary else {}
	_trace_labels = preview.get("labels", {}) if preview.get("labels", {}) is Dictionary else {}
	_selected_id = int(preview.get("selected_id", -1))
	_sync_unit_count(clampi(int(cfg.get("top_n", 5)), 1, 20), true)
	var scores: Array = preview.get("scores", []) if preview.get("scores", []) is Array else []
	if preview.has("candidates"):
		_trace_labels={}
		for candidate in preview.candidates:
			_trace_labels[str(scores.size())]=str(candidate.piece)
			scores.append(float(candidate.probability))
	push_values(scores, true)
	hold_for_frame()


func clear_language_trace() -> void:
	trace = {}
	_trace_labels = {}
	_selected_id = -1
	push_values([], true)
	hold_for_frame()


func _just_disconnected(who: Connection, from: Connection) -> void:
	super(who, from)


func _just_deattached(other_conn: Connection, my_conn: Connection) -> void:
	super(other_conn, my_conn)


func _source_controller() -> Node:
	for node in LanguageAdapter.component(self):
		if node.get_meta("created_with", "") == "text_input":
			return node.get("controller")
	return null


func _on_color_rect_2_pressed() -> void:
	pass


func _on_color_rect_2_released() -> void:
	if is_instance_valid(add_button) and add_button.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		return
	await open_vocabulary_splash()


func open_vocabulary_splash() -> Dictionary:
	if not is_instance_valid(ui):
		return {}
	var chains := _get_complete_training_chains()
	var mode := "chains_only" if chains.size() >= 2 else "all_datasets"

	if is_instance_valid(add_button):
		add_button.block_input()

	var current_source := _current_dataset_name if _current_dataset_name != "" else str(cfg.get("vocab_source", "bpe_8192"))
	var chain_items: Array = []
	for c in chains:
		chain_items.append({
			"dataset_name": c.get("dataset_name", ""),
			"label_names": c.get("label_names", []),
		})

	var result = await ui.splash_and_get_result("select_vocabulary", add_button, null, false, {
		"mode": mode,
		"chains": chain_items,
		"vocab_source": current_source,
		"with_who": "preset:" + current_source,
	})
	_hold_multiframe(3)
	if result is Dictionary and not result.is_empty():
		apply_vocabulary_selection(result)
	await get_tree().process_frame
	_hold_multiframe(5)
	while is_instance_valid(glob) and glob.mouse_pressed:
		await get_tree().process_frame
	if is_instance_valid(add_button):
		add_button.unblock_input()
	return result if result is Dictionary else {}


func apply_vocabulary_selection(selection: Dictionary) -> void:
	var ds_name := str(selection.get("dataset_name", selection.get("preset", "")))
	var labels: Array = selection.get("label_names", []) if selection.get("label_names", []) is Array else []
	if ds_name != "":
		_pinned_dataset_name = ds_name
		_current_dataset_name = ds_name
		_explicit_bpe = (ds_name == "bpe_8192")
		open_undo_redo(true)
		update_config({
			"vocab_source": ds_name,
			"label_names": labels.duplicate(),
		})
		close_undo_redo()
		_refresh_display()
		_hold_multiframe(5)
