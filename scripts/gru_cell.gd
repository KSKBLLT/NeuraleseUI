extends BaseNeuronLayer


const MIN_HIDDEN_SIZE := 1
const MAX_HIDDEN_SIZE := 64

var _updating_control := false


func _after_ready() -> void:
	super()
	_apply_hidden_size(_hidden_size())


func _useful_properties() -> Dictionary:
	return {
		"config": {
			"type": "gru_cell",
			"hidden_size": _hidden_size(),
		},
		"cache_tag": str(graph_id),
	}


func _config_field(field: StringName, value: Variant) -> void:
	if field != &"hidden_size":
		return
	var normalized := clampi(int(value), MIN_HIDDEN_SIZE, MAX_HIDDEN_SIZE)
	cfg[&"hidden_size"] = normalized
	_apply_hidden_size(normalized)
	graphs.push_1d(normalized, self)


func _get_x() -> Variant:
	return _hidden_size()


func _just_connected(_who: Connection, _to: Connection) -> void:
	graphs.push_1d(_hidden_size(), self)


func re_upd() -> void:
	graphs.push_1d(_hidden_size(), self)


func _can_drag() -> bool:
	return not ui.is_focus($hidden_size_input)


func _hidden_size() -> int:
	return clampi(int(cfg.get(&"hidden_size", 16)), MIN_HIDDEN_SIZE, MAX_HIDDEN_SIZE)


func _apply_hidden_size(value: int) -> void:
	_updating_control = true
	$hidden_size_input.set_line(str(value))
	_updating_control = false


func _on_hidden_size_changed() -> void:
	if _updating_control or not $hidden_size_input.is_valid_input():
		return
	update_config({&"hidden_size": int($hidden_size_input.get_value())})


func _on_hidden_size_submitted(_new_text: String) -> void:
	if _updating_control:
		return
	open_undo_redo()
	update_config({&"hidden_size": int($hidden_size_input.get_value())})
	close_undo_redo()
