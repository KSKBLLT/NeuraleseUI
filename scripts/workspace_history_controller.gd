class_name WorkspaceHistoryController
extends RefCounted

var _graph_history: Object
var _simulation_editor: Object


func _init(graph_history: Object, simulation_editor: Object = null) -> void:
	_graph_history = graph_history
	_simulation_editor = simulation_editor


func set_simulation_editor(editor: Object) -> void:
	_simulation_editor = editor


func can_undo(window_name: String) -> bool:
	if window_name == "graph":
		return _graph_history != null and _graph_history.has_method("has_undo") and _graph_history.has_undo()
	if window_name == "env":
		return _simulation_editor != null and _simulation_editor.has_method("can_undo") and _simulation_editor.can_undo()
	return false


func can_redo(window_name: String) -> bool:
	if window_name == "graph":
		return _graph_history != null and _graph_history.has_method("has_redo") and _graph_history.has_redo()
	if window_name == "env":
		return _simulation_editor != null and _simulation_editor.has_method("can_redo") and _simulation_editor.can_redo()
	return false


func undo(window_name: String) -> void:
	if not can_undo(window_name):
		return
	if window_name == "graph":
		_graph_history.undo()
	else:
		_simulation_editor.undo_last()


func redo(window_name: String) -> void:
	if not can_redo(window_name):
		return
	if window_name == "graph":
		_graph_history.redo()
	else:
		_simulation_editor.redo_last()
