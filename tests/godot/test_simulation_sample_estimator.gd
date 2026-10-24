extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var estimator = load(
		"res://scripts/simulations/simulation_sample_estimator.gd"
	)
	_expect(estimator != null, "sample estimator must load")
	if estimator == null:
		_finish()
		return

	var simple_world := {
		"metadata": {},
		"objects": [{"type_id": "car"}, {"type_id": "finish"}],
	}
	var binding := {"input_width": 9, "output_width": 3}
	var simple: Dictionary = estimator.recommend(simple_world, binding)
	_expect(
		int(simple["sample_count"]) >= estimator.MIN_SAMPLES,
		"recommendation must keep a useful minimum dataset size"
	)
	_expect(
		int(simple["sample_count"]) % estimator.SAMPLE_BLOCK == 0,
		"recommendation must align work to deterministic sample blocks"
	)

	var varied_world: Dictionary = simple_world.duplicate(true)
	varied_world["objects"].append_array([
		{"type_id": "block"},
		{"type_id": "spikes"},
		{"type_id": "crate"},
	])
	varied_world["metadata"] = {
		"randomization": {
			"start_position": {
				"enabled": true,
				"jitter": Vector2(12.0, 4.0),
			},
			"surface_material": {"enabled": true},
		}
	}
	var varied: Dictionary = estimator.recommend(varied_world, binding)
	_expect(
		int(varied["sample_count"]) > int(simple["sample_count"]),
		"more geometry and active variation dimensions must increase coverage"
	)
	_expect(
		int(varied["variation_dimensions"]) == 3,
		"vector jitter must contribute two dimensions and a toggle one"
	)

	var huge_binding := {"input_width": 10000, "output_width": 1000}
	_expect(
		estimator.sample_count(varied_world, huge_binding) == estimator.MAX_SAMPLES,
		"recommendation must remain within a safe generation ceiling"
	)
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_sample_estimator")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_sample_estimator: %d failure(s)" % failures.size())
	quit(1)
