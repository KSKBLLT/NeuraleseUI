extends Node

# Rebuilt from the recorded yernar perfbench protocol.  It deliberately runs
# the actual project scene instead of a synthetic shader card.
const GraphicsQualityConfigScript := preload("res://scripts/graphics_quality.gd")
const CAR_TRACK_PATH := "res://built_in_projects/Car Track.scn"
const WARMUP_FRAMES := 60
const SETTLE_FRAMES := 20
const SAMPLE_FRAMES := 45
const DISCARD_SAMPLES := 10
const STRESS_DEFAULT_SECONDS := 180.0
const STRESS_SAMPLE_SECONDS := 5.0
const STRESS_COOLDOWN_SECONDS := 20.0
const STRESS_MAX_LIVE_NODES := 24
const STRESS_NODE_TYPES: Array[StringName] = [&"layer", &"dropout", &"neuron"]

var project_root: Node2D
var camera: Camera2D


func _ready() -> void:
	call_deferred("_run")


func _run() -> void:
	# The root of bench_project.tscn is an instance of project.tscn, so the
	# benchmark node's parent is the real project root.
	project_root = get_parent() as Node2D
	if project_root == null:
		push_error("PERFBENCH failed: project root is unavailable")
		get_tree().quit(1)
		return
	var requested_quality := _argument_value("--graphics=")
	var level := GraphicsQualityConfigScript.resolve(PackedStringArray(["--graphics=" + requested_quality]))
	GraphicsQualityConfigScript.apply(level)
	if not await _wait_for_workspace():
		get_tree().quit(1)
		return
	if not await _load_car_track():
		get_tree().quit(1)
		return
	if "--connection-probe" in OS.get_cmdline_user_args():
		await _run_connection_probe()
		print("PERFBENCH PASS")
		get_tree().quit(0)
		return
	if "--connection-repro" in OS.get_cmdline_user_args():
		var passed := await _run_connection_repro()
		print("CONNECTION_REPRO result=%s" % ["PASS" if passed else "FAIL"])
		get_tree().quit(0 if passed else 2)
		return
	for _frame in WARMUP_FRAMES:
		await get_tree().process_frame
	_print_render_state(level)
	if "--stress" in OS.get_cmdline_user_args():
		await _run_workspace_stress(level)
		print("PERFBENCH PASS")
		get_tree().quit(0)
		return

	for tab in _tabs_to_measure():
		glob.go_window(tab)
		for _frame in SETTLE_FRAMES:
			await get_tree().process_frame
		while glob.tree_windows.get(tab) == null:
			await get_tree().process_frame
		camera = _tab_camera(tab)
		for scenario in ["forced_redraw", "hover", "sweep", "camera_pan"]:
			var ms := await _measure(scenario)
			print("PERFBENCH quality=%s tab=%s scenario=%s median_ms=%.3f p95_ms=%.3f mean_ms=%.3f" % [
				GraphicsQualityConfigScript.level_name(level), tab, scenario, ms.median, ms.p95, ms.mean
			])
	print("PERFBENCH PASS")
	get_tree().quit(0)


func _run_workspace_stress(level: int) -> void:
	var duration := _argument_float("--stress-seconds=", STRESS_DEFAULT_SECONDS)
	var random := RandomNumberGenerator.new()
	random.seed = 20260922 # Same operation order on every run.
	var spawned: Array[Graph] = []
	var frame_samples: Array[float] = []
	var start_usec := Time.get_ticks_usec()
	var last_sample_usec := start_usec
	var next_spawn_usec := start_usec
	var next_rebuild_usec := start_usec + 30_000_000
	var operation := 0
	print("STRESS_BEGIN quality=%s seconds=%.1f seed=%d" % [
		GraphicsQualityConfigScript.level_name(level), duration, random.seed
	])
	while float(Time.get_ticks_usec() - start_usec) / 1_000_000.0 < duration:
		var now_usec := Time.get_ticks_usec()
		if now_usec >= next_spawn_usec:
			_spawn_stress_node(spawned, random)
			next_spawn_usec = now_usec + 300_000 # New scene roughly 3.3 times/sec.
		if now_usec >= next_rebuild_usec:
			_rebuild_stress_wave(spawned)
			next_rebuild_usec = now_usec + 30_000_000
		if not spawned.is_empty():
			_mutate_stress_node(spawned[operation % spawned.size()], operation, random)
			operation += 1
		_apply_stress_input(operation)
		var frame_start_usec := Time.get_ticks_usec()
		await get_tree().process_frame
		frame_samples.append(float(Time.get_ticks_usec() - frame_start_usec) / 1000.0)
		if Time.get_ticks_usec() - last_sample_usec >= int(STRESS_SAMPLE_SECONDS * 1_000_000.0):
			_print_stress_sample(
				float(Time.get_ticks_usec() - start_usec) / 1_000_000.0,
				frame_samples,
				spawned,
				operation
			)
			frame_samples.clear()
			last_sample_usec = Time.get_ticks_usec()
	_rebuild_stress_wave(spawned)
	frame_samples.clear()
	var cooldown_start_usec := Time.get_ticks_usec()
	while float(Time.get_ticks_usec() - cooldown_start_usec) / 1_000_000.0 < STRESS_COOLDOWN_SECONDS:
		var frame_start_usec := Time.get_ticks_usec()
		await get_tree().process_frame
		frame_samples.append(float(Time.get_ticks_usec() - frame_start_usec) / 1000.0)
	_print_stress_sample(duration + STRESS_COOLDOWN_SECONDS, frame_samples, spawned, operation, true)
	print("STRESS_END quality=%s operations=%d" % [GraphicsQualityConfigScript.level_name(level), operation])


func _run_connection_probe() -> void:
	var dense := graphs.get_graph(&"layer", Graph.Flags.NEW) as Graph
	var labels := graphs.get_graph(&"classifier", Graph.Flags.NEW) as Graph
	if dense == null or labels == null:
		push_error("CONNECTION_PROBE failed to instantiate layer/classifier")
		return
	for _frame in 3:
		await get_tree().process_frame
	var dense_output := _find_port(dense, Connection.OUTPUT, &"layer_out")
	var labels_input := _find_port(labels, Connection.INPUT, &"layer_in")
	if dense_output == null or labels_input == null:
		push_error("CONNECTION_PROBE ports are unavailable")
		return
	print("CONNECTION_PROBE clean source=%s target=%s dtype=%s suitable=%s source_outputs=%d target_inputs=%d" % [
		dense_output._accepted_datatypes,
		labels_input._accepted_datatypes,
		dense_output.dtype(labels_input),
		dense_output.is_suitable(labels_input),
		dense_output.outputs.size(),
		labels_input.inputs.size(),
	])
	var attached := dense_output.connect_to(labels_input)
	print("CONNECTION_PROBE attach=%s source_outputs=%d target_inputs=%d" % [
		attached, dense_output.outputs.size(), labels_input.inputs.size()
	])
	dense_output.disconnect_from(labels_input, true)
	for _frame in 2:
		await get_tree().process_frame
	dense.allow_deletion()
	labels.allow_deletion()
	dense.delete()
	labels.delete()


func _run_connection_repro() -> bool:
	if not await _run_school_topology_repro():
		return false
	var target_graph := graphs.get_graph(&"classifier", Graph.Flags.NEW) as Graph
	var sources: Array[Graph] = []
	for _i in 3:
		sources.append(graphs.get_graph(&"layer", Graph.Flags.NEW) as Graph)
	for _frame in 3:
		await get_tree().process_frame
	var target := _find_port(target_graph, Connection.INPUT, &"layer_in")
	var outputs: Array[Connection] = []
	for source in sources:
		outputs.append(_find_port(source, Connection.OUTPUT, &"layer_out"))
	if target == null or outputs.has(null):
		push_error("CONNECTION_REPRO missing graph port")
		return false
	print("CONNECTION_REPRO begin target=%d sources=%s" % [target.conn_id, [outputs[0].conn_id, outputs[1].conn_id, outputs[2].conn_id]])
	for iteration in 120:
		var source: Connection = outputs[iteration % outputs.size()]
		var phase := iteration % 3
		if not source.is_suitable(target) or not source.connect_to(target):
			_connection_repro_snapshot("refused_before_attach", iteration, source, target)
			return false
		if phase == 0:
			var spline: Spline = target.inputs.keys()[0]
			target.detatch_spline(spline)
			if not source.active_outputs.is_empty():
				source.end_spline(source.active_outputs.keys()[0])
		elif phase == 1:
			source.disconnect_from(target, false, true)
		else:
			source.disconnect_from(target)
			if not source.active_outputs.is_empty():
				var slot: int = source.active_outputs.keys()[0]
				if not source.is_suitable(target):
					_connection_repro_snapshot("refused_while_reconnecting", iteration, source, target)
					return false
				source.attach_spline(slot, target)
			source.disconnect_from(target, false, true)
		if not target.inputs.is_empty() or not target.connected.is_empty() or not source.outputs.is_empty():
			_connection_repro_snapshot("phantom_after_disconnect", iteration, source, target)
			return false
		if iteration % 20 == 0:
			print("CONNECTION_REPRO progress=%d" % iteration)
		await get_tree().process_frame
	for iteration in 12:
		var removed_source := graphs.get_graph(&"layer", Graph.Flags.NEW) as Graph
		for _frame in 2:
			await get_tree().process_frame
		var removed_output := _find_port(removed_source, Connection.OUTPUT, &"layer_out")
		if removed_output == null or not removed_output.connect_to(target):
			print("CONNECTION_REPRO deletion_setup_failed iteration=%d" % iteration)
			return false
		removed_source.allow_deletion()
		removed_source.delete()
		for _frame in 2:
			await get_tree().process_frame
		if not target.inputs.is_empty() or not target.connected.is_empty():
			print("CONNECTION_REPRO phantom_after_source_delete iteration=%d inputs=%d connected=%d" % [
				iteration, target.inputs.size(), target.connected.size()
			])
			return false
	print("CONNECTION_REPRO source_deletion_cycles=12 clean=true")
	# Reproduce a rejected release after the target becomes free during a drag.
	# The current UI caches suitability by target identity, not graph state.
	var occupant: Connection = outputs[0]
	var dragging: Connection = outputs[1]
	occupant.parent_graph.show()
	dragging.parent_graph.show()
	target.parent_graph.show()
	dragging.show()
	target.show()
	if not occupant.connect_to(target):
		_connection_repro_snapshot("setup_failed", 120, occupant, target)
		return false
	var drag_slot := dragging.add_spline()
	dragging.start_spline(drag_slot)
	graphs._ensure_conn_space(&"hover")["next_chosen"] = target
	glob.mouse_pressed = true
	dragging._process(0.016)
	var was_rejected := not dragging._last_suit
	occupant.disconnect_from(target, false, true)
	var fresh_suitable := dragging.is_suitable(target)
	var input_is_empty := target.inputs.is_empty() and target.connected.is_empty()
	dragging._process(0.016)
	var cache_still_rejects := not dragging._last_suit
	print("CONNECTION_REPRO stale_cache before_rejected=%s target_empty=%s fresh_suitable=%s cached_rejects=%s" % [
		was_rejected, input_is_empty, fresh_suitable, cache_still_rejects
	])
	glob.mouse_pressed = false
	var toasts_before := get_tree().get_nodes_in_group("ui_error_toast").size()
	dragging._process(0.016)
	var no_new_toast := get_tree().get_nodes_in_group("ui_error_toast").size() == toasts_before
	var fixed := was_rejected and input_is_empty and fresh_suitable and cache_still_rejects \
		and dragging.outputs.size() == 1 and target.inputs.size() == 1 and no_new_toast
	print("CONNECTION_REPRO stale_cache release_attached=%s no_new_toast=%s source_visible=%s outputs=%d active=%d inputs=%d" % [
		fixed, no_new_toast, dragging.parent_graph.visible, dragging.outputs.size(), dragging.active_outputs.size(), target.inputs.size()
	])
	graphs._ensure_conn_space(&"hover")["next_chosen"] = null
	if not dragging.active_outputs.is_empty():
		dragging.end_spline(dragging.active_outputs.keys()[0])
	for source_graph in sources:
		source_graph.allow_deletion()
		source_graph.delete()
	target_graph.allow_deletion()
	target_graph.delete()
	var active_delete_graph := graphs.get_graph(&"layer", Graph.Flags.NEW) as Graph
	for _frame in 2:
		await get_tree().process_frame
	var active_delete_output := _find_port(active_delete_graph, Connection.OUTPUT, &"layer_out")
	var active_delete_slot := active_delete_output.add_spline()
	active_delete_output.start_spline(active_delete_slot)
	active_delete_graph.allow_deletion()
	active_delete_graph.delete()
	for _frame in 2:
		await get_tree().process_frame
	var active_delete_clean := graphs.conns_active.is_empty()
	print("CONNECTION_REPRO delete_during_drag clean=%s active_registry=%d" % [active_delete_clean, graphs.conns_active.size()])
	var quota_source_graph := graphs.get_graph(&"layer", Graph.Flags.NEW) as Graph
	var quota_first_graph := graphs.get_graph(&"classifier", Graph.Flags.NEW) as Graph
	var quota_second_graph := graphs.get_graph(&"classifier", Graph.Flags.NEW) as Graph
	for _frame in 2:
		await get_tree().process_frame
	var quota_source := _find_port(quota_source_graph, Connection.OUTPUT, &"layer_out")
	var quota_first := _find_port(quota_first_graph, Connection.INPUT, &"layer_in")
	var quota_second := _find_port(quota_second_graph, Connection.INPUT, &"layer_in")
	var first_attached := quota_source.connect_to(quota_first)
	var quota_blocks_empty_input: bool = first_attached and quota_second.inputs.is_empty() and quota_source.dtype(quota_second) \
		and not quota_source.is_suitable(quota_second)
	quota_source_graph.show()
	quota_source.show()
	quota_second_graph.show()
	quota_second.show()
	var quota_drag_slot := quota_source.add_spline()
	quota_source.start_spline(quota_drag_slot)
	graphs._ensure_conn_space(&"hover")["next_chosen"] = quota_second
	glob.mouse_pressed = false
	quota_source._process(0.016)
	graphs._ensure_conn_space(&"hover")["next_chosen"] = null
	quota_source.disconnect_from(quota_first, false, true)
	var usable_after_detach := quota_source.is_suitable(quota_second)
	print("CONNECTION_REPRO classifier_quota blocks_empty_input=%s usable_after_detach=%s" % [
		quota_blocks_empty_input, usable_after_detach
	])
	for quota_graph in [quota_source_graph, quota_first_graph, quota_second_graph]:
		quota_graph.allow_deletion()
		quota_graph.delete()
	return fixed and active_delete_clean and quota_blocks_empty_input and usable_after_detach


func _run_school_topology_repro() -> bool:
	# The reported five-node scene: Input1D -> Dense -> Dense -> OutputAnswer,
	# with an activation feeding the first Dense. No saved project is needed.
	var input_graph := graphs.get_graph(&"input_1d", Graph.Flags.NEW) as Graph
	var activation_graph := graphs.get_graph(&"neuron", Graph.Flags.NEW) as Graph
	var first_dense := graphs.get_graph(&"layer", Graph.Flags.NEW) as Graph
	var second_dense := graphs.get_graph(&"layer", Graph.Flags.NEW) as Graph
	var answer_graph := graphs.get_graph(&"classifier", Graph.Flags.NEW) as Graph
	var created: Array[Graph] = [input_graph, activation_graph, first_dense, second_dense, answer_graph]
	for _frame in 3:
		await get_tree().process_frame
	var input_out := _find_port(input_graph, Connection.OUTPUT, &"input_out")
	var activ_out := _find_port(activation_graph, Connection.OUTPUT, &"activ_out")
	var first_in := _find_port(first_dense, Connection.INPUT, &"layer_in")
	var first_activ := _find_port(first_dense, Connection.INPUT, &"activ_in")
	var first_out := _find_port(first_dense, Connection.OUTPUT, &"layer_out")
	var second_in := _find_port(second_dense, Connection.INPUT, &"layer_in")
	var second_out := _find_port(second_dense, Connection.OUTPUT, &"layer_out")
	var answer_in := _find_port(answer_graph, Connection.INPUT, &"layer_in")
	var wired := input_out.connect_to(first_in) and activ_out.connect_to(first_activ) \
		and first_out.connect_to(second_in)
	var clean_suitable := wired and answer_in.inputs.is_empty() and second_out.is_suitable(answer_in)
	# Create one ordinary user-visible reason for an initial refusal: the other
	# Dense is connected to the answer. Then free the answer and retry without
	# changing the hovered port. The old cache retained the first "false".
	var first_attached := clean_suitable and first_out.connect_to(answer_in)
	var first_drag := second_out.add_spline()
	second_out.start_spline(first_drag)
	graphs._ensure_conn_space(&"hover")["next_chosen"] = answer_in
	glob.mouse_pressed = false
	second_out._process(0.016)
	var first_rejected := not second_out._last_suit and second_out.active_outputs.is_empty()
	first_out.disconnect_from(answer_in, false, true)
	var empty_and_compatible: bool = answer_in.inputs.is_empty() and answer_in.connected.is_empty() \
		and second_out.dtype(answer_in) and second_out.is_suitable(answer_in)
	var legacy_cached_reject := empty_and_compatible and second_out._last_hovered_conn == answer_in \
		and not second_out._last_suit
	# One idle process tick models the mouse moving back to the Dense output.
	# The previous implementation did not invalidate _last_hovered_conn here.
	second_out._process(0.016)
	var retry_drag := second_out.add_spline()
	second_out.start_spline(retry_drag)
	glob.mouse_pressed = true
	second_out._process(0.016)
	glob.mouse_pressed = false
	second_out._process(0.016)
	var retry_attached := answer_in.inputs.size() == 1 and second_out.outputs.size() == 1
	print("CONNECTION_REPRO school_topology wired=%s clean_suitable=%s initial_reject=%s empty_and_compatible=%s legacy_cached_reject=%s retry_attached=%s" % [
		wired, clean_suitable, first_rejected, empty_and_compatible, legacy_cached_reject, retry_attached
	])
	graphs._ensure_conn_space(&"hover")["next_chosen"] = null
	for graph in created:
		graph.allow_deletion()
		graph.delete()
	return wired and clean_suitable and first_attached and first_rejected and empty_and_compatible \
		and legacy_cached_reject and retry_attached


func _connection_repro_snapshot(stage: String, iteration: int, source: Connection, target: Connection) -> void:
	print("CONNECTION_REPRO anomaly=%s iteration=%d dtype=%s suitable=%s source_outputs=%d active=%d classifier_count=%s target_inputs=%d target_connected=%d cycle_ok=%s source_input=%s target_input=%s" % [
		stage, iteration, source.dtype(target), source.is_suitable(target),
		source.outputs.size(), source.active_outputs.size(),
		source.conn_counts.get(&"classifier", [0])[0], target.inputs.size(), target.connected.size(),
		graphs.validate_acyclic_edge(source, target),
		graphs._reach_input(source.parent_graph), graphs._reach_input(target.parent_graph),
	])


func _find_port(graph: Graph, direction: int, name: StringName) -> Connection:
	var ports: Array[Connection] = graph.outputs if direction == Connection.OUTPUT else graph._inputs
	for port in ports:
		if port.server_name == name:
			return port
	return null


func _spawn_stress_node(spawned: Array[Graph], random: RandomNumberGenerator) -> void:
	if spawned.size() >= STRESS_MAX_LIVE_NODES:
		var retired: Graph = spawned.pop_front()
		if is_instance_valid(retired):
			retired.allow_deletion()
			retired.delete()
	var type_id: StringName = STRESS_NODE_TYPES[random.randi_range(0, STRESS_NODE_TYPES.size() - 1)]
	var node: Graph = graphs.get_graph(type_id, Graph.Flags.NEW) as Graph
	if node == null:
		push_error("STRESS failed to instantiate %s" % type_id)
		return
	node.global_position = Vector2(
		random.randf_range(-800.0, 800.0),
		random.randf_range(-450.0, 450.0)
	)
	spawned.append(node)


func _mutate_stress_node(node: Graph, operation: int, random: RandomNumberGenerator) -> void:
	if not is_instance_valid(node) or not node.is_node_ready():
		return
	match String(node.get_meta("created_with", "")):
		"layer":
			# Exercises the DenseLayer input path that previously correlated with
			# intermittent slowdowns, without typing through the OS keyboard queue.
			node.update_config({"neuron_count": 1 + (operation * 17) % 240})
		"dropout":
			# This calls Dropout.get_noise(), which creates an ImageTexture, so a
			# retained texture after node deletion will show up in the memory trace.
			node.update_config({"p": random.randf_range(0.0, 0.95)})
		"neuron":
			node.update_config({"activ": &"none" if operation % 2 == 0 else &"relu"})


func _rebuild_stress_wave(spawned: Array[Graph]) -> void:
	for node in spawned:
		if is_instance_valid(node):
			node.allow_deletion()
			node.delete()
	spawned.clear()


func _apply_stress_input(operation: int) -> void:
	if camera == null:
		camera = _tab_camera("graph")
	if camera != null:
		camera.position += Vector2(4.0 if operation % 2 == 0 else -3.0, 2.0)
	var event := InputEventMouseMotion.new()
	event.position = Vector2(80 + (operation * 47) % 1120, 90 + (operation * 31) % 560)
	event.relative = Vector2(4.0, 2.0)
	Input.parse_input_event(event)


func _print_stress_sample(
		elapsed_seconds: float,
		frame_samples: Array[float],
		spawned: Array[Graph],
		operation: int,
		final_sample: bool = false
	) -> void:
	if frame_samples.is_empty() and not final_sample:
		return
	var sorted: Array[float] = frame_samples.duplicate()
	sorted.sort()
	var sum := 0.0
	for sample in sorted:
		sum += sample
	var mean_ms: float = sum / sorted.size() if not sorted.is_empty() else 0.0
	var median_ms: float = float(sorted[sorted.size() / 2]) if not sorted.is_empty() else 0.0
	var p95_ms: float = float(sorted[mini(sorted.size() - 1, ceili(sorted.size() * 0.95) - 1)]) if not sorted.is_empty() else 0.0
	var alive := 0
	for node in spawned:
		if is_instance_valid(node):
			alive += 1
	print(
		"STRESS_SAMPLE t=%.1fs ops=%d alive=%d fps=%.1f frame_mean_ms=%.3f frame_median_ms=%.3f frame_p95_ms=%.3f static_mib=%.2f static_peak_mib=%.2f video_mib=%.2f texture_mib=%.2f objects=%d orphan_nodes=%d draw_calls=%d" % [
			elapsed_seconds,
			operation,
			alive,
			Performance.get_monitor(Performance.TIME_FPS),
			mean_ms,
			median_ms,
			p95_ms,
			Performance.get_monitor(Performance.MEMORY_STATIC) / 1048576.0,
			Performance.get_monitor(Performance.MEMORY_STATIC_MAX) / 1048576.0,
			Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
			Performance.get_monitor(Performance.RENDER_TEXTURE_MEM_USED) / 1048576.0,
			int(Performance.get_monitor(Performance.OBJECT_COUNT)),
			int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
			int(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)),
		]
	)


func _argument_float(prefix: String, fallback: float) -> float:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return maxf(1.0, argument.trim_prefix(prefix).to_float())
	return fallback


func _measure(scenario: String) -> Dictionary:
	var samples: Array[float] = []
	for frame in SAMPLE_FRAMES:
		_apply_scenario(scenario, frame)
		var started := Time.get_ticks_usec()
		# Changing the active Camera2D marks the full canvas dirty.  This avoids
		# measuring the idle sleep cap instead of the renderer's frame cost.
		await get_tree().process_frame
		var elapsed_ms := float(Time.get_ticks_usec() - started) / 1000.0
		if frame >= DISCARD_SAMPLES:
			samples.append(elapsed_ms)
	samples.sort()
	var total := 0.0
	for sample in samples:
		total += sample
	return {
		"median": samples[samples.size() / 2],
		"p95": samples[mini(samples.size() - 1, ceili(samples.size() * 0.95) - 1)],
		"mean": total / samples.size(),
	}


func _apply_scenario(scenario: String, frame: int) -> void:
	if camera == null:
		return
	match scenario:
		"camera_pan":
			camera.position += Vector2(12.0, 0.0)
		"sweep":
			var event := InputEventMouseMotion.new()
			event.position = Vector2(120 + (frame * 19) % 980, 340 + (frame * 7) % 240)
			event.relative = Vector2(19.0, 7.0)
			Input.parse_input_event(event)
			camera.position += Vector2(0.05, 0.0)
		"hover":
			var event := InputEventMouseMotion.new()
			event.position = Vector2(640, 44)
			Input.parse_input_event(event)
			camera.position += Vector2(0.05, 0.0)
		_:
			camera.position += Vector2(0.05, 0.0)


func _tab_camera(tab: String) -> Camera2D:
	var tab_node: Node = glob.tree_windows.get(tab)
	if tab_node != null:
		return tab_node.get("camera") as Camera2D
	return project_root.get_node_or_null("WIN_GRAPH/Camera2D") as Camera2D


func _argument_value(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return "high"


func _tabs_to_measure() -> Array[String]:
	var requested_tabs := _argument_value("--tabs=")
	if requested_tabs == "high":
		return _default_tabs()
	var result: Array[String] = []
	for tab in requested_tabs.split(",", false):
		if tab in ["graph", "env", "ds", "net"]:
			result.append(tab)
	return result if not result.is_empty() else _default_tabs()


func _default_tabs() -> Array[String]:
	var result: Array[String] = []
	result.append("graph")
	result.append("env")
	return result


func _wait_for_workspace() -> bool:
	for _frame in 240:
		if (
			not ui.active_splashed()
			and is_instance_valid(glob.tree_windows.get("graph"))
			and is_instance_valid(glob.tree_windows.get("env"))
		):
			return true
		await get_tree().process_frame
	push_error("PERFBENCH failed: graph and simulation windows did not initialize")
	return false


func _load_car_track() -> bool:
	var file := FileAccess.open(CAR_TRACK_PATH, FileAccess.READ)
	if file == null:
		push_error("PERFBENCH failed: could not read %s" % CAR_TRACK_PATH)
		return false
	var blob: Variant = file.get_var()
	file.close()
	if not blob is PackedByteArray:
		push_error("PERFBENCH failed: Car Track payload is not PackedByteArray")
		return false
	var project_data: Variant = bytes_to_var(blob)
	if not project_data is Dictionary:
		push_error("PERFBENCH failed: Car Track payload is not a project dictionary")
		return false
	var loaded: Variant = await glob._apply_project_payload("perfbench-car-track", "Car Track", project_data, {
		"stop_lesson": false,
		"set_project_id": false,
		"project_id": -1,
		"emit_project_opened": false,
	})
	if not bool(loaded):
		push_error("PERFBENCH failed: could not load Car Track")
		return false
	print("PERFBENCH_PROJECT name=Car Track graphs=%d" % graphs._graphs.size())
	return true


func _print_render_state(level: int) -> void:
	var blur_visible: bool = is_instance_valid(ui.blur) and bool(ui.blur.visible)
	var blur_alpha: float = float(ui.blur.self_modulate.a) if is_instance_valid(ui.blur) else -1.0
	var live_screen_materials: int = _count_live_screen_materials(get_tree().root, 0)
	print(
		"PERFBENCH_STATE quality=%s active_splash=%s blur_visible=%s blur_alpha=%.3f live_screen_materials=%d" % [
			GraphicsQualityConfigScript.level_name(level),
			ui.active_splashed(),
			blur_visible,
			blur_alpha,
			live_screen_materials,
		]
	)


func _count_live_screen_materials(node: Node, count: int) -> int:
	if node is CanvasItem:
		var material := (node as CanvasItem).material as ShaderMaterial
		if material != null and material.shader != null and material.shader.resource_path == "res://shaders/block_screen.gdshader":
			count += 1
	for child in node.get_children():
		count = _count_live_screen_materials(child, count)
	return count
