extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var runtime_path := "res://scripts/simulations/simulation_runtime.gd"
	_expect(ResourceLoader.exists(runtime_path), "simulation runtime script must exist")
	if not ResourceLoader.exists(runtime_path):
		_finish()
		return

	var runtime_script = load(runtime_path)
	_expect(runtime_script != null and runtime_script.can_instantiate(), "runtime script must parse")
	if runtime_script == null or not runtime_script.can_instantiate():
		_finish()
		return

	var world := SimulationWorldState.new()
	var block_id := world.add_object(
		&"block",
		Transform2D(0.0, Vector2(80.0, 220.0)),
		{"id": "block-1"}
	)
	var crate_id := world.add_object(
		&"crate",
		Transform2D(0.0, Vector2(120.0, 80.0)),
		{"id": "crate-1"}
	)
	_expect(block_id == "block-1" and crate_id == "crate-1", "runtime fixtures must keep stable ids")
	var renderer := SimulationWorldRenderer.new()
	get_root().add_child(renderer)
	renderer.configure(world)

	var runtime = runtime_script.new()
	get_root().add_child(runtime)
	runtime.configure(world, renderer)
	var emitted_states: Array[StringName] = []
	runtime.runtime_state_changed.connect(func(state: StringName): emitted_states.append(state))

	var original_tree_pause := paused
	runtime.play()
	_expect(runtime.current_state() == &"running", "play must enter running state")
	_expect(runtime.kernel() != null, "play must compile the data-oriented world into a physics kernel")
	_expect(runtime.is_physics_processing(), "play must enable the runtime physics loop")
	_expect(paused == original_tree_pause, "simulation runtime must not pause the Neuralese SceneTree")
	var id_to_index: Dictionary = runtime.kernel().blueprint().get("id_to_index", {})
	var block_index := int(id_to_index.get(block_id, -1))
	var crate_index := int(id_to_index.get(crate_id, -1))
	_expect(block_index >= 0 and crate_index >= 0, "compiled kernel must index every document object")
	world.update_object(block_id, {"position": Vector2(96.0, 204.0)})
	_expect(
		runtime.kernel().position_for(block_index) == Vector2(96.0, 204.0),
		"document transforms must update the live kernel"
	)
	_expect(
		not runtime.commit_live_edit(null),
		"the removed wrapper-node live-edit path must stay disabled"
	)

	runtime.kernel()._set_position(crate_index, Vector2(24.0, 12.0))
	var extra_id := world.add_object(
		&"circle",
		Transform2D(0.0, Vector2(220.0, 160.0)),
		{"id": "circle-live"}
	)
	id_to_index = runtime.kernel().blueprint().get("id_to_index", {})
	crate_index = int(id_to_index.get(crate_id, -1))
	_expect(extra_id == "circle-live" and id_to_index.has(extra_id), "live structure edits must rebuild the kernel")
	_expect(
		runtime.kernel().position_for(crate_index) == Vector2(24.0, 12.0),
		"kernel rebuilds must preserve dynamic body state"
	)
	var extra_index := int(id_to_index.get(extra_id, -1))
	var extra_body: RID = runtime.kernel()._physics.body_rid(extra_index)
	var extra_shape: RID = PhysicsServer2D.body_get_shape(extra_body, 0)
	world.update_object(extra_id, {"size": Vector2(160.0, 120.0), "scale": Vector2(1.5, 0.5)})
	_expect(
		is_equal_approx(float(PhysicsServer2D.shape_get_data(extra_shape)), 30.0),
		"live resize must update the collision shape without restarting the simulation"
	)
	var paused_position: Vector2 = runtime.kernel().position_for(crate_index)
	runtime.pause()
	_expect(runtime.current_state() == &"paused", "pause must enter paused state")
	_expect(not runtime.is_physics_processing(), "pause must suspend the runtime physics loop")
	_expect(runtime.kernel().position_for(crate_index) == paused_position, "pause must preserve body transforms")

	runtime.play()
	_expect(runtime.is_physics_processing(), "play after pause must resume the runtime physics loop")
	runtime.stop()
	await process_frame
	_expect(runtime.current_state() == &"stopped", "stop must enter stopped state")
	_expect(runtime.kernel() == null, "stop must destroy the compiled physics kernel")
	_expect(
		world.position_at(world.index_of(block_id)) == Vector2(96.0, 204.0),
		"stop must preserve authored live edits in the document"
	)
	_expect(
		world.position_at(world.index_of(crate_id)) == Vector2(120.0, 80.0),
		"runtime-only dynamic transforms must not overwrite the authored document"
	)
	_expect(
		emitted_states == [&"running", &"paused", &"running", &"stopped"],
		"runtime must emit deterministic state transitions"
	)

	runtime.free()
	renderer.free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_runtime")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_runtime: %d failure(s)" % failures.size())
	quit(1)
