extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	var path := "res://scripts/simulations/simulation_randomization_profile.gd"
	_expect(ResourceLoader.exists(path), "randomization profile must exist")
	if not ResourceLoader.exists(path):
		_finish()
		return
	var script = load(path)
	_expect(script != null and script.can_instantiate(), "randomization profile must parse")
	if script == null or not script.can_instantiate():
		_finish()
		return

	var raw := {
		"start_position": {"enabled": true, "jitter": Vector2(12.0, 4.0)},
		"goal_position": {"enabled": false, "jitter": Vector2(20.0, 10.0)},
		"initial_speed": true,
		"obstacle_position": true,
		"surface_material": false,
		"unknown": true,
	}
	var active: Dictionary = script.active_config(raw)
	_expect(
		active.keys() == ["start_position", "initial_speed", "obstacle_position"],
		"active profile must filter disabled and unknown variations in registry order"
	)
	_expect(
		script.active_labels(raw) == ["Start position", "Initial speed", "Obstacle position"],
		"UI labels must come from the same registry used by the generator"
	)
	_expect(
		script.vector_value(active, "start_position") == Vector2(12.0, 4.0),
		"profile must expose configured variation ranges"
	)
	_expect(
		script.vector_value(active, "initial_speed") == Vector2.ZERO,
		"boolean shorthand must use the registered default range"
	)

	_expect(script.validate(raw).get("valid", false), "well-formed randomization metadata must validate")
	var malformed := raw.duplicate(true)
	malformed["start_position"]["jitter"] = Vector2(-1.0, 2.0)
	_expect(
		not script.validate(malformed).get("valid", true),
		"negative position jitter must be rejected instead of silently changing the world"
	)
	_expect(
		not script.validate(["not", "a", "dictionary"]).get("valid", true),
		"randomization metadata must be an object"
	)
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_randomization_profile")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_randomization_profile: %d failure(s)" % failures.size())
	quit(1)
