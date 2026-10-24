class_name SimulationCommandHistory
extends RefCounted

## Compact object-level undo/redo. A command stores only the affected object,
## never a deep copy of the complete world.

var _document: SimulationWorldState
var _undo: Array[Dictionary] = []
var _redo: Array[Dictionary] = []
var max_commands := 512


func configure(document: SimulationWorldState) -> void:
	_document = document
	clear()


func push_change(label: String, before: Dictionary, after: Dictionary, index: int = -1) -> void:
	if before == after:
		return
	_undo.append({
		"label": label,
		"before": before.duplicate(true),
		"after": after.duplicate(true),
		"index": index,
	})
	if _undo.size() > max_commands:
		_undo.pop_front()
	_redo.clear()


func push_batch_change(label: String, changes: Array[Dictionary]) -> void:
	var normalized: Array[Dictionary] = []
	for change in changes:
		var before: Dictionary = change.get("before", {})
		var after: Dictionary = change.get("after", {})
		if before == after:
			continue
		normalized.append({
			"before": before.duplicate(true),
			"after": after.duplicate(true),
			"index": int(change.get("index", -1)),
		})
	if normalized.is_empty():
		return
	_undo.append({"label": label, "batch": normalized})
	if _undo.size() > max_commands:
		_undo.pop_front()
	_redo.clear()


func can_undo() -> bool:
	return not _undo.is_empty()


func can_redo() -> bool:
	return not _redo.is_empty()


func undo() -> void:
	if _undo.is_empty() or _document == null:
		return
	var command: Dictionary = _undo.pop_back()
	_apply_command(command, false)
	_redo.append(command)


func redo() -> void:
	if _redo.is_empty() or _document == null:
		return
	var command: Dictionary = _redo.pop_back()
	_apply_command(command, true)
	_undo.append(command)


func clear() -> void:
	_undo.clear()
	_redo.clear()


func _apply(target: Dictionary, opposite: Dictionary, index: int) -> void:
	var object_id := str(target.get("id", opposite.get("id", "")))
	if target.is_empty():
		_document.remove_object(object_id)
	elif _document.has_object(object_id):
		_document.replace_object(target)
	else:
		_document.insert_object_data(target, index)


func _apply_command(command: Dictionary, redo: bool) -> void:
	if command.has("batch"):
		for change in command["batch"]:
			_apply(
				change["after"] if redo else change["before"],
				change["before"] if redo else change["after"],
				int(change["index"])
			)
		return
	_apply(
		command["after"] if redo else command["before"],
		command["before"] if redo else command["after"],
		int(command["index"])
	)
