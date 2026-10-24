extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var search = load("res://scripts/dataset_search.gd")
	var entries := {
		"flowers": {"data": {"name": "Iris flowers", "outputs": ["species"]}},
		"cars": {"data": {"name": "Driving examples", "outputs": ["steer"]}},
	}
	var by_id: Dictionary = search.filter(entries, "flower")
	_expect(by_id.keys() == ["flowers"], "search filters by dataset id")
	var by_metadata: Dictionary = search.filter(entries, "driving")
	_expect(by_metadata.keys() == ["cars"], "search filters by dataset metadata")
	_expect(search.filter(entries, "").size() == 2, "empty search restores every dataset")
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_dataset_search")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
