extends SceneTree

var failures: Array[String] = []
var stop_emitted := false


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var view_path := "res://scripts/simulations/simulation_dataset_view.gd"
	var dashboard_path := "res://scripts/simulations/simulation_dataset_dashboard.gd"
	_expect(ResourceLoader.exists(view_path), "dataset environment view must exist")
	_expect(ResourceLoader.exists(dashboard_path), "dataset dashboard must exist")
	if not ResourceLoader.exists(view_path) or not ResourceLoader.exists(dashboard_path):
		_finish()
		return

	var view_script = load(view_path)
	var dashboard_script = load(dashboard_path)
	_expect(view_script != null and view_script.can_instantiate(), "dataset view must parse")
	_expect(dashboard_script != null and dashboard_script.can_instantiate(), "dataset dashboard must parse")
	if view_script == null or dashboard_script == null:
		_finish()
		return

	var view: Control = view_script.new()
	view.size = Vector2(900.0, 650.0)
	get_root().add_child(view)
	_expect(view.environment_count() == 1, "dataset view must expose only the live environment being simulated")
	view.configure_world({
		"metadata": {"generation_bounds": [-300.0, -180.0, 300.0, 180.0]},
		"objects": [
			{
				"id": "ground",
				"type_id": "block",
				"position": Vector2(0.0, 120.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(600.0, 32.0),
				"properties": {},
			},
			{
				"id": "agent",
				"type_id": "rover",
				"position": Vector2(-180.0, 40.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(72.0, 48.0),
				"properties": {},
			},
			{
				"id": "goal",
				"type_id": "finish",
				"position": Vector2(220.0, 40.0),
				"rotation": 0.0,
				"scale": Vector2.ONE,
				"size": Vector2(72.0, 112.0),
				"properties": {},
			},
		],
	})
	_expect(
		view.displayed_type_ids() == [&"block", &"rover", &"finish"],
		"dataset preview must be generated from the active SimulationWorld instead of a fixed demo track"
	)
	var preview := {
		"normalized_position": Vector2(0.35, 0.5),
		"normalized_goal": Vector2(0.9, 0.5),
		"world_position": Vector2(-90.0, 30.0),
		"goal_world_position": Vector2(220.0, 40.0),
		"agent_type_id": "rover",
		"rotation": 0.1,
		"ray_values": [0.2, 0.4, 0.6, 0.8, 1.0, 0.8, 0.6, 0.4],
		"terminal_reason": "",
	}
	view.update_environment(0, preview)
	_expect(view.preview_for(0) == preview, "dataset view must retain the latest real physics preview")

	var dashboard: Control = dashboard_script.new()
	dashboard.size = Vector2(390.0, 650.0)
	get_root().add_child(dashboard)
	dashboard.stop_requested.connect(_on_stop_requested)
	dashboard.reset("maze_pilot_train_v1", 1000, 9, 3, {})
	_expect(
		str((dashboard.find_child("StatusIndicator", true, false) as Label).text) == char(0x25CF),
		"dataset status must use a real indicator glyph instead of a letter"
	)
	_expect(
		dashboard.active_variations().is_empty(),
		"dashboard must not claim that unconfigured environment variations are active"
	)
	dashboard.reset("maze_pilot_train_v1", 1000, 9, 3, {
		"start_position": {"enabled": true, "jitter": Vector2(10.0, 3.0)},
		"initial_speed": {"enabled": true, "range": Vector2(0.0, 20.0)},
	})
	_expect(
		dashboard.active_variations() == ["Start position", "Initial speed"],
		"dashboard variations must come from the generator configuration"
	)
	var metrics := {
		"completed_samples": 736,
		"total_samples": 1000,
		"completed_episodes": 9,
		"success_rate": 0.71,
		"collisions": 84,
		"stuck": 2,
		"timeouts": 3,
		"discarded_rows": 0,
	}
	dashboard.update_metrics(metrics, "maze_pilot_train_v1", 9, 3)
	_expect(dashboard.displayed_metrics() == metrics, "dashboard must display the latest generator metrics")
	_expect(dashboard.find_child("RewardChart", true, false) == null, "dashboard must not show an undefined reward chart")
	_expect(
		str((dashboard.find_child("RunningLabel", true, false) as Label).text).contains("1"),
		"dashboard must report the single real environment in every locale"
	)
	dashboard.request_stop()
	_expect(stop_emitted, "dashboard stop action must be wired through a signal")

	view.free()
	dashboard.free()
	_finish()


func _on_stop_requested() -> void:
	stop_emitted = true


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_dataset_ui")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_dataset_ui: %d failure(s)" % failures.size())
	quit(1)
