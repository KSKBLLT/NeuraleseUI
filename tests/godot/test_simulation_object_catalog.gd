extends SceneTree

const Backend = preload("res://scripts/simulations/simulation_physics_backend.gd")
const Catalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const Compiler = preload("res://scripts/simulations/simulation_compiler.gd")
const VirtualObject = preload("res://scripts/simulations/simulation_virtual_object.gd")
const WorldState = preload("res://scripts/simulations/simulation_world_state.gd")

const EXPECTED_GROUPS := {
	"Geometry": [&"block", &"circle", &"slope"],
	"Materials": [&"ice", &"sand", &"trampoline", &"finish", &"water"],
	"Hazards": [&"spikes", &"lava"],
	"Dynamics": [&"crate", &"ball"],
	"Agents": [&"car", &"rover", &"flying_agent"],
}

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_catalog()
	_test_physics_backend()
	_test_material_application_skips_areas()
	_test_virtual_object_proxy()
	_finish()


func _test_catalog() -> void:
	_expect(Catalog.grouped_types() == EXPECTED_GROUPS, "catalog groups and ordering must match the approved palette")
	var visible: Array[StringName] = []
	for group_name in EXPECTED_GROUPS:
		for type_id in EXPECTED_GROUPS[group_name]:
			visible.append(type_id)
			var definition: Dictionary = Catalog.definition(type_id)
			_expect(not definition.is_empty(), "%s must have a definition" % type_id)
			for key in ["body_kind", "shape_kind", "default_size", "color", "dataset_role"]:
				_expect(definition.has(key), "%s must declare %s" % [type_id, key])
	_expect(Catalog.visible_types() == visible, "visible types must preserve palette order")
	var mutated := Catalog.definition(&"block")
	mutated["body_kind"] = "broken"
	_expect(Catalog.definition(&"block").get("body_kind") == "static", "catalog definitions must be deep copies")
	_expect(Catalog.definition(&"missing").is_empty(), "unknown object types must be rejected")
	_expect(float(Catalog.definition(&"ice").get("friction", 1.0)) <= 0.1, "ice must use low friction")
	_expect(float(Catalog.definition(&"sand").get("friction", 0.0)) >= 2.0, "sand must use high friction")
	_expect(Catalog.definition(&"car").get("agent_id") == &"side_view_car", "car must use the side-view agent")
	_expect(Catalog.definition(&"rover").get("agent_id") == &"top_down_rover", "rover must use the top-down agent")
	_expect(Catalog.definition(&"flying_agent").get("agent_id") == &"flying_agent", "flying agent must use flying physics")


func _test_physics_backend() -> void:
	var world := WorldState.new()
	var cases := [
		{"type_id": &"block", "mode": PhysicsServer2D.BODY_MODE_STATIC},
		{"type_id": &"slope", "mode": PhysicsServer2D.BODY_MODE_STATIC},
		{"type_id": &"crate", "mode": PhysicsServer2D.BODY_MODE_RIGID},
		{"type_id": &"car", "mode": PhysicsServer2D.BODY_MODE_RIGID},
		{"type_id": &"rover", "mode": PhysicsServer2D.BODY_MODE_RIGID},
		{"type_id": &"flying_agent", "mode": PhysicsServer2D.BODY_MODE_RIGID_LINEAR},
	]
	for case_index in cases.size():
		world.add_object(cases[case_index]["type_id"], Transform2D(0.0, Vector2(case_index * 180.0, 0.0)))
	var blueprint: Dictionary = Compiler.compile(world.to_dictionary())
	var backend := Backend.new()
	_expect(backend.create(blueprint, false), "compiled world must create an isolated PhysicsServer2D backend")
	for index in cases.size():
		var body: RID = backend.body_rid(index)
		_expect(body.is_valid(), "%s must create a native physics RID" % cases[index]["type_id"])
		if not body.is_valid():
			continue
		_expect(PhysicsServer2D.body_get_mode(body) == cases[index]["mode"], "%s must use the expected native body mode" % cases[index]["type_id"])
		_expect(PhysicsServer2D.body_get_shape_count(body) == 1, "%s must have one native collision shape" % cases[index]["type_id"])
	var slope_body := backend.body_rid(1)
	if slope_body.is_valid() and PhysicsServer2D.body_get_shape_count(slope_body) == 1:
		var slope_shape: RID = PhysicsServer2D.body_get_shape(slope_body, 0)
		_expect(PhysicsServer2D.shape_get_type(slope_shape) == PhysicsServer2D.SHAPE_CONVEX_POLYGON, "slope must use a convex polygon shape")
	var car_index := 3
	backend.set_body_state(car_index, Vector2.ZERO, 0.0, Vector2.ZERO)
	backend.apply_agent_controls(car_index, &"ground_rigid", {"jump": 1.0, "grounded": false})
	_expect(
		backend.velocity(car_index).is_zero_approx(),
		"an airborne jump command must not apply an impulse"
	)
	backend.apply_agent_controls(car_index, &"ground_rigid", {"jump": 0.0, "grounded": true})
	backend.apply_agent_controls(car_index, &"ground_rigid", {"jump": 1.0, "grounded": true})
	var first_jump_velocity := backend.velocity(car_index)
	_expect(first_jump_velocity.y < -0.001, "a grounded jump edge must apply an upward impulse")
	backend.set_body_state(car_index, Vector2.ZERO, 0.0, Vector2.ZERO)
	backend.apply_agent_controls(car_index, &"ground_rigid", {"jump": 1.0, "grounded": true})
	_expect(
		backend.velocity(car_index).is_zero_approx(),
		"holding jump must not apply repeated impulses"
	)
	backend.apply_agent_controls(car_index, &"ground_rigid", {"jump": 0.0, "grounded": true})
	backend.apply_agent_controls(car_index, &"ground_rigid", {"jump": 1.0, "grounded": true})
	_expect(backend.velocity(car_index).y < -0.001, "releasing jump must arm the next grounded impulse")
	backend.destroy()


func _test_material_application_skips_areas() -> void:
	var world := WorldState.new()
	world.add_object(&"block", Transform2D.IDENTITY)
	world.add_object(&"finish", Transform2D(0.0, Vector2(120.0, 0.0)))
	var blueprint: Dictionary = Compiler.compile(world.to_dictionary())
	var backend := Backend.new()
	_expect(backend.create(blueprint, false), "material fixture must create a physics backend")
	_expect(backend.call("set_material", 0, Catalog.definition(&"ice")) == true, "surface material must apply to a physics body")
	_expect(backend.call("set_material", 1, Catalog.definition(&"ice")) == false, "surface material must skip an area RID")
	backend.destroy()


func _test_virtual_object_proxy() -> void:
	var world := WorldState.new()
	var object_id := world.add_object(&"block", Transform2D(0.25, Vector2(1.5, 0.75), 0.0, Vector2(120.0, 64.0)), {
		"id": "object-7",
		"scale": Vector2(1.5, 0.75),
		"size": Vector2(160.0, 32.0),
	})
	_expect(object_id == "object-7", "world state must preserve a supplied stable id")
	var proxy := VirtualObject.new()
	get_root().add_child(proxy)
	_expect(proxy.bind_document_object(world, object_id), "editor proxy must bind to data-oriented world state")
	_expect(proxy.position == Vector2(120.0, 64.0), "proxy must expose document position")
	_expect(is_equal_approx(proxy.rotation, 0.25), "proxy must expose document rotation")
	_expect(proxy.scale == Vector2(1.5, 0.75), "proxy must expose document scale")
	var snapshot: Dictionary = proxy.serialize()
	_expect(snapshot.get("id") == "object-7", "proxy serialization must preserve stable id")
	_expect(snapshot.get("type_id") == "block", "proxy serialization must preserve catalog type")
	world.update_object(object_id, {"position": Vector2(10.0, 20.0), "rotation": 0.5})
	_expect(proxy.sync_from_document(), "proxy must resync after document edits")
	_expect(proxy.position == Vector2(10.0, 20.0), "proxy must expose the updated position")
	_expect(is_equal_approx(proxy.rotation, 0.5), "proxy must expose the updated rotation")
	proxy.free()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_object_catalog")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_object_catalog: %d failure(s)" % failures.size())
	quit(1)
