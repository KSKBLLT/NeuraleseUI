extends SceneTree

const AxonContextGate = preload("res://scripts/axon_context_gate.gd")
const AI_HELP_SCENE := "res://scenes/ai_help.tscn"

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var gate = AxonContextGate.new()
	_expect(gate.consume({"request_id": "a"}), "first request accepted")
	_expect(not gate.consume({"request_id": "a"}), "duplicate request rejected")
	_expect(gate.consume({"request_id": "b"}), "different request accepted")
	_expect(not gate.consume({"request_id": ""}), "empty request ID rejected")

	var presentation: Dictionary = AxonContextGate.presentation({
		"question": "What does RunModel do?",
		"source_label": "From RunModel info",
	})
	_expect_equal(presentation.get("api_text"), "What does RunModel do?", "API text excludes source")
	var message: Dictionary = presentation.get("message", {})
	_expect_equal(message.get("text"), "What does RunModel do?", "visible question")
	_expect_equal(message.get("source_label"), "From RunModel info", "visual source metadata")

	var packed: PackedScene = load(AI_HELP_SCENE)
	_expect(packed != null, "Axon scene loads")
	if packed != null:
		var menu = packed.instantiate()
		_expect(menu.has_method("queue_context_request"), "Axon accepts context requests")
		var source = menu.get_node_or_null(
			"ColorRect/ScrollContainer/MarginContainer2/MarginContainer/VBoxContainer/HBoxContainer/Content/source"
		)
		_expect(source != null, "user message has source label")
		if source != null:
			_expect(not source.visible, "ordinary messages hide source label")
		menu.free()

	if failures.is_empty():
		print("PASS test_axon_context")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
