extends Node

# The robot window in the real app (Car Track open, Export window in robot
# mode), measured on three screens at the graphics level given by --graphics=:
#   build   the robot drawing and the checklist
#   drive   the drive screen as it was: the drawing with live beams
#   lidar   the drive screen with the lidar, fed the long KIRISIMA run at its own speed
# No robot is connected (the session's Python does not run here); the screens
# are put up directly, the KIRISIMA sensors on the drawing.
#
# Run it with run-wsl-llvmpipe.sh's environment (llvmpipe, 4 CPUs, Mobile renderer):
#   bench_robot_lidar_app.tscn -- --graphics=medium

const GraphicsQualityConfigScript := preload("res://scripts/graphics_quality.gd")
const CAR_TRACK_PATH := "res://built_in_projects/Car Track.scn"
const FIXTURE := "res://local_runtime/tests/fixtures/robot_drive/kirisima_lidar.json.gz"
const SETTLE_S := 3.0
const MEASURE_S := 20.0
const KIRISIMA := {
	"in4": {"angle_deg": 45.0, "x_cm": 6.4, "y_cm": 2.5, "spot": "front_left"},
	"in3": {"angle_deg": 0.0, "x_cm": 7.0, "y_cm": 0.0, "spot": "front"},
	"in2": {"angle_deg": -45.0, "x_cm": 6.4, "y_cm": -2.5, "spot": "front_right"},
}

var panel: RobotPanel = null
var frames: Array = []
var feeding := false
var clock := 0.0
var next := 0


func _ready() -> void:
	_run.call_deferred()


func _process(delta: float) -> void:
	if not feeding:
		return
	clock += delta
	while next < frames.size() and float(frames[next][0]) <= clock:
		var f: Array = frames[next]
		next += 1
		panel._lidar.add_frame(f[0], f[1], f[2], f[3], PackedFloat64Array([f[4], f[5], f[6]]))


func _run() -> void:
	var level := GraphicsQualityConfigScript.resolve(OS.get_cmdline_user_args())
	GraphicsQualityConfigScript.apply(level)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	# Startup dialogs (the profile's name) are dismissed, as the robot window harness does.
	for _step in 30:
		for dialog in ui.active_dialogs.values():
			if is_instance_valid(dialog) and dialog.has_method("dismiss_with_splash_animation"):
				dialog.dismiss_with_splash_animation()
		await get_tree().create_timer(0.5).timeout
		if ui.active_dialogs.is_empty() and not ui.active_splashed() and is_instance_valid(glob.tree_windows.get("graph")):
			break
	var raw: Variant = FileAccess.open(CAR_TRACK_PATH, FileAccess.READ).get_var()
	await glob._apply_project_payload("perfbench-car-track", "Car Track", bytes_to_var(raw), {
		"stop_lesson": false, "set_project_id": false, "project_id": -1, "emit_project_opened": false,
	})
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_bytes(FIXTURE).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	frames = data["runs"][1]["frames"]
	ui.splash("model_export", null, null, false, {"mode": "robot"})
	for _frame in 120:
		panel = get_tree().root.find_child("RobotPanel", true, false) as RobotPanel
		if panel != null:
			break
		await get_tree().process_frame
	await get_tree().create_timer(2.0).timeout
	panel.robot = {"platform": "ev3_direct", "ports": []}
	panel.geometry = {"sensors": KIRISIMA.duplicate(true)}
	panel._world.platform = "ev3_direct"
	panel._world.load_geometry(panel.geometry)
	panel._show(RobotPanel.Screen.BUILD)
	print("LIDARAPP quality=%s" % GraphicsQualityConfigScript.level_name(level))
	await _measure("build")
	panel._show(RobotPanel.Screen.DRIVE)
	panel._set_bar("drive")
	panel._lidar.visible = false
	panel._world.visible = true
	await _measure("drive")
	panel._world.visible = false
	panel._lidar.visible = true
	panel._start_lidar()
	feeding = true
	await _measure("lidar")
	print("LIDARAPP walls=%d trail=%d" % [panel._lidar._shown.size(), panel._lidar._trail_count])
	# --shot=<png path>: what the lidar screen looked like at the end.
	for arg in OS.get_cmdline_user_args():
		if arg.begins_with("--shot="):
			get_viewport().get_texture().get_image().save_png(arg.trim_prefix("--shot="))
	get_tree().quit()


func _measure(screen: String) -> void:
	await get_tree().create_timer(SETTLE_S).timeout
	var samples: Array[float] = []
	var started := Time.get_ticks_msec()
	var last := Time.get_ticks_usec()
	while Time.get_ticks_msec() - started < MEASURE_S * 1000.0:
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		samples.append((now - last) / 1000.0)
		last = now
	samples.sort()
	print("LIDARAPP screen=%s frames=%d fps=%.1f frame_ms median=%.1f p95=%.1f max=%.1f" % [
		screen, samples.size(), samples.size() / MEASURE_S, samples[samples.size() / 2],
		samples[mini(samples.size() - 1, int(samples.size() * 0.95))], samples[samples.size() - 1]])
