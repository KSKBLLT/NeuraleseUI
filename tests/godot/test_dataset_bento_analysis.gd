extends SceneTree
## Dataset Bento analysis: alike rows form situations, rows that disagree with
## their alike rows are flagged, and car datasets get named situations.

const Analysis := preload("res://scripts/ui/dataset_bento_analysis.gd")

var _failures := 0


func _init() -> void:
	_test_car_situations_and_mistakes()
	_test_word_answers()
	_test_tiny_dataset()
	if _failures == 0:
		print("PASS test_dataset_bento_analysis")
	quit(1 if _failures else 0)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		_failures += 1
		push_error(message)


func _float(value: float) -> Dictionary:
	return {"type": "float", "val": value}


func _test_car_situations_and_mistakes() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var shapes := {
		"free": [[1, 1, 1, 1, 1, 1, 1], 0.0],
		"wall_right": [[1, 1, 0.9, 0.8, 0.5, 0.35, 0.3], -0.6],
		"wall_left": [[0.3, 0.35, 0.5, 0.8, 0.9, 1, 1], 0.6],
	}
	var rows: Array = []
	for i in 180:
		var shape: Array = shapes.values()[i % 3]
		var row: Array = []
		for ray in shape[0]:
			row.append(_float(clampf(ray + rng.randf_range(-0.05, 0.05), 0.05, 1.0)))
		row.append(_float(rng.randf_range(0.5, 0.9)))
		row.append(_float(shape[1] + rng.randf_range(-0.05, 0.05)))
		row.append(_float(0.9))
		rows.append(row)
	var planted := [5, 32, 98]  # «wall_left» rows (i % 3 == 2) turned the wrong way
	for row in planted:
		rows[row][8] = _float(-0.7)
	var names := ["Ray 1:float", "Ray 2:float", "Ray 3:float", "Ray 4:float", "Ray 5:float", "Ray 6:float", "Ray 7:float", "Speed:float", "Steering:float", "Throttle:float"]
	var result := Analysis.analyze({"col_names": names, "outputs_from": 8, "arr": rows})
	_expect(not result["car"].is_empty(), "rays, speed and steering make a car dataset")
	_expect(result["clusters"].size() >= 3, "three kinds of road give at least three situations: %d" % result["clusters"].size())
	var found := 0
	for row in planted:
		if result["errors"].has(row):
			found += 1
	_expect(found >= 2, "rows steering against their alike rows are flagged: %d of 3" % found)
	_expect(result["errors"].size() <= 6, "few honest rows are flagged: %d" % result["errors"].size())
	var keys: Array = result["clusters"].map(func(c): return c["label"].get("car", ""))
	for key in ["free", "wall_right", "wall_left"]:
		_expect(key in keys, "a situation is named %s: %s" % [key, keys])
	_expect(result["points"].size() == rows.size(), "every analysed row has a place on the map")


func _test_word_answers() -> void:
	var rows: Array = []
	for i in 80:
		var glass := i % 2 == 0
		rows.append([_float(0.5 + (0.3 if glass else -0.3) + i * 0.001), _float(0.9 if glass else 0.1), {"type": "text", "text": "Стекло" if glass else "Металл"}])
	rows[10][2] = {"type": "text", "text": "Металл"}  # a glass row labelled metal
	var result := Analysis.analyze({"col_names": ["вес:float", "прозрачность:float", "материал:text"], "outputs_from": 2, "arr": rows})
	_expect(result["errors"].has(10), "a row whose word disagrees with its alike rows is flagged")
	_expect(result["errors"].get(10, {}).get("expected", "") == "Стекло", "the flag names the alike rows' answer")
	var words: Array = result["clusters"].map(func(c): return c["action"].get("word", ""))
	_expect("Стекло" in words and "Металл" in words, "each situation answers its commonest word: %s" % [words])


func _test_tiny_dataset() -> void:
	var result := Analysis.analyze({"col_names": ["x:float", "y:float"], "outputs_from": 1, "arr": [[_float(1.0), _float(2.0)]]})
	_expect(result["clusters"].is_empty() and result["errors"].is_empty(), "one row gives no situations and no mistakes")
