extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var record_path := "res://scripts/simulations/simulation_episode_record.gd"
	_expect(ResourceLoader.exists(record_path), "simulation episode record must exist")
	if not ResourceLoader.exists(record_path):
		_finish()
		return

	var record_script = load(record_path)
	_expect(record_script != null and record_script.can_instantiate(), "episode record must parse")
	if record_script == null or not record_script.can_instantiate():
		_finish()
		return

	var record = record_script.new(42, "side_view_car", "binding-1")
	var accepted: bool = record.append_step(
		PackedFloat32Array([0.1, 0.2]),
		PackedFloat32Array([0.5]),
		{"position": Vector2(10.0, 20.0)},
		{"position": Vector2(12.0, 20.0)},
		0.1
	)
	_expect(accepted, "finite episode steps must be accepted")
	_expect(not record.append_step(
		PackedFloat32Array([NAN]),
		PackedFloat32Array([0.0]),
		{},
		{},
		0.1
	), "non-finite episode values must be rejected")

	record.finish(&"success", {"goal_id": "finish-1"})
	var payload: Dictionary = record.to_dictionary()
	_expect(payload.get("version") == 1, "episode payload must be versioned")
	_expect(payload.get("seed") == 42, "episode payload must preserve the seed")
	_expect(payload.get("terminal_reason") == &"success", "episode payload must preserve terminal reason")
	_expect(payload.get("steps", []).size() == 1, "rejected steps must not enter the record")
	_expect(record_script.validate(payload).get("valid") == true, "serialized valid episode must pass validation")

	var malformed := payload.duplicate(true)
	malformed["terminal_reason"] = &"unknown"
	_expect(not record_script.validate(malformed).get("valid", true), "unknown terminal reasons must be rejected")
	var limited: RefCounted = record_script.new(43, "side_view_car", "binding-1")
	limited.append_step(
		PackedFloat32Array([0.1, 0.2]),
		PackedFloat32Array([0.5]),
		{},
		{},
		0.1
	)
	_expect(limited.finish(&"sample_limit"), "reaching the requested sample limit must be a valid terminal reason")
	_expect(
		record_script.validate(limited.to_dictionary()).get("valid") == true,
		"sample-limited episode records must pass validation"
	)
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_episode_record")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_episode_record: %d failure(s)" % failures.size())
	quit(1)
