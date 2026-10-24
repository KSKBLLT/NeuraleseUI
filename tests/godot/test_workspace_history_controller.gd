extends SceneTree

var failures: Array[String] = []


class FakeHistory:
	extends RefCounted
	var undo_available := false
	var redo_available := false
	var undo_calls := 0
	var redo_calls := 0

	func has_undo() -> bool:
		return undo_available

	func has_redo() -> bool:
		return redo_available

	func undo() -> void:
		undo_calls += 1

	func redo() -> void:
		redo_calls += 1


class FakeSimulationEditor:
	extends Node
	var undo_available := false
	var redo_available := false
	var undo_calls := 0
	var redo_calls := 0

	func can_undo() -> bool:
		return undo_available

	func can_redo() -> bool:
		return redo_available

	func undo_last() -> void:
		undo_calls += 1

	func redo_last() -> void:
		redo_calls += 1


func _initialize() -> void:
	var top_bar_scene := load("res://scenes/fg.tscn") as PackedScene
	_expect(top_bar_scene != null, "top bar scene must load")
	if top_bar_scene != null:
		var top_bar = top_bar_scene.instantiate()
		_expect(top_bar.get_node_or_null("ColorRect/HistoryControls/Undo") != null, "graph and simulation tabs must expose an undo button")
		_expect(top_bar.get_node_or_null("ColorRect/HistoryControls/Redo") != null, "graph and simulation tabs must expose a redo button")
		top_bar.free()
	var controller_script = load("res://scripts/workspace_history_controller.gd")
	_expect(controller_script != null, "workspace history controller must exist")
	if controller_script == null:
		_finish()
		return
	var graph_history := FakeHistory.new()
	var simulation := FakeSimulationEditor.new()
	var controller = controller_script.new(graph_history, simulation)

	graph_history.undo_available = true
	controller.undo("graph")
	_expect(graph_history.undo_calls == 1, "graph undo button must use the graph history")
	_expect(controller.can_undo("graph"), "graph undo availability must reflect graph history")

	simulation.redo_available = true
	controller.redo("env")
	_expect(simulation.redo_calls == 1, "simulation redo button must use simulation history")
	_expect(controller.can_redo("env"), "simulation redo availability must reflect simulation history")
	controller.undo("ds")
	_expect(graph_history.undo_calls == 1 and simulation.undo_calls == 0, "non-editing tabs must not mutate either history")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_workspace_history_controller")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
