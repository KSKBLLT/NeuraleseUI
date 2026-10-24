extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var connection_script = load("res://scripts/connection.gd")
	_expect(connection_script != null, "connection script must load")
	if connection_script != null:
		var message: String = connection_script.incompatible_nodes_message("Плотн", "Ввод1D", "ru")
		_expect(
			message == "Тип узла «Плотн» несовместим с типом узла «Ввод1D».",
			"incompatible connection must explain both node types"
		)
		_expect(
			connection_script.incompatible_nodes_message("Dense", "Input1D", "en")
			== "Node type “Dense” is incompatible with node type “Input1D”.",
			"connection feedback must support the English interface"
		)
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_connection_feedback")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
