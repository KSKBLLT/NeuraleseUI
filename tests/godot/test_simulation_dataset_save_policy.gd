extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var policy = load("res://scripts/simulations/simulation_dataset_save_policy.gd")
	_expect(policy != null and policy.can_instantiate(), "dataset save policy must parse")
	if policy == null or not policy.can_instantiate():
		_finish()
		return
	var partial := {"arr": [[{"type": "float", "val": 0.5}]], "metadata": {"partial": true}}
	_expect(
		policy.requires_confirmation(partial, true),
		"cancelled non-empty partial datasets must require confirmation"
	)
	_expect(
		not policy.requires_confirmation({"arr": [], "metadata": {"partial": true}}, true),
		"empty partial datasets must not open a save confirmation"
	)
	_expect(
		not policy.requires_confirmation(partial, false),
		"normal generation completion must not ask about partial saving"
	)
	var spec: Dictionary = policy.confirmation_spec(42)
	_expect(spec.get("id") == "simulation_partial_dataset", "confirmation must have a stable dialog id")
	_expect(
		spec.get("buttons", []).map(func(button): return button.get("id")) == ["discard", "save"],
		"confirmation must offer explicit discard and save actions"
	)
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_dataset_save_policy")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_dataset_save_policy: %d failure(s)" % failures.size())
	quit(1)
