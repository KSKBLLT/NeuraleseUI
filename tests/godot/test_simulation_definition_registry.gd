extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var registry_path := "res://scripts/simulations/simulation_definition_registry.gd"
	_expect(ResourceLoader.exists(registry_path), "simulation definition registry must exist")
	if not ResourceLoader.exists(registry_path):
		_finish()
		return

	var registry = load(registry_path)
	_expect(registry != null and registry.can_instantiate(), "definition registry must parse")
	if registry == null or not registry.can_instantiate():
		_finish()
		return

	var car: Dictionary = registry.agent(&"side_view_car")
	_expect(car.get("physics_kind") == &"ground_rigid", "car must declare native ground physics")
	_expect(car.get("sensors", []).has(&"ray_distance"), "car must declare compatible sensors")
	_expect(car.get("actuators", []).has(&"steering"), "car must declare compatible actuators")

	var rover: Dictionary = registry.agent(&"top_down_rover")
	_expect(rover.get("physics_kind") == &"top_down_rigid", "rover must declare top-down physics")
	var flyer: Dictionary = registry.agent(&"flying_agent")
	_expect(flyer.get("physics_kind") == &"flying_rigid", "flying agent must declare flying physics")

	var ray: Dictionary = registry.sensor(&"ray_distance")
	_expect(ray.get("dimension_kind") == &"range", "ray sensor width must be configurable")
	_expect(registry.sensor_accepts_width(&"ray_distance", 8), "ray sensor must accept an eight-channel range")
	_expect(not registry.sensor_accepts_width(&"ray_distance", 0), "ray sensor must reject empty ranges")
	_expect(not registry.sensor_accepts_width(&"speed", 2), "scalar sensors must reject multi-channel ranges")

	var steering: Dictionary = registry.actuator(&"steering")
	_expect(steering.get("channels") == 1, "steering must consume one model output")
	_expect(registry.agent_supports_sensor(&"side_view_car", &"speed"), "agent compatibility must come from the registry")
	_expect(not registry.agent_supports_actuator(&"flying_agent", &"brake"), "incompatible actuators must be rejected")

	var mutated: Dictionary = registry.sensor(&"speed")
	mutated["label"] = "Broken"
	_expect(registry.sensor(&"speed").get("label") == "Speed", "registry callers must receive deep copies")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_definition_registry")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_definition_registry: %d failure(s)" % failures.size())
	quit(1)
