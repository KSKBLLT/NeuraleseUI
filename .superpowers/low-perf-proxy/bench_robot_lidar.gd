extends Node

# The robot lidar view (scripts/robot/robot_lidar_view.gd) alone, at the size the
# Export window gives it, driven by the long recorded KIRISIMA run at the run's
# own speed. After a warm-up it prints, per frame (median / p95):
#   frame    time between frames (WSLg presents at 144 Hz: a multiple of 6.9 ms)
#   script   the view's own work in _process, timed around it
#   render   Godot's measured render time of the viewport, CPU and GPU (on
#            llvmpipe the GPU is the CPU too)
#
# User arguments: --graphics=<level>; --no-lidar (the scene without the view);
# --hide=Floor,Walls,Points,Robot,Sensors (layers not drawn); --no-feed (no frames
# after the first second); --only=camera,sync,scan,walls (only these parts of
# the view's frame run, the last three at 30 Hz).
#
# Run it with run-wsl-llvmpipe.sh's environment (llvmpipe, 4 CPUs, Mobile renderer):
#   bench_robot_lidar.tscn -- --graphics=low

const FIXTURE := "res://local_runtime/tests/fixtures/robot_drive/kirisima_lidar.json.gz"
const WARMUP_S := 4.0
const MEASURE_S := 30.0

var view: RobotLidarView = null
var frames: Array = []
var clock := 0.0
var next := 0
var only := ""
var no_feed := false
var frame_ms: Array[float] = []
var script_ms: Array[float] = []
var render_cpu_ms: Array[float] = []
var render_gpu_ms: Array[float] = []


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	var level := GraphicsQualityConfig.resolve(args)
	GraphicsQualityConfig.apply(level)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	no_feed = "--no-feed" in args
	for arg in args:
		if arg.begins_with("--only="):
			only = arg.trim_prefix("--only=")
	var data: Dictionary = JSON.parse_string(FileAccess.get_file_as_bytes(FIXTURE).decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	var run: Dictionary = data["runs"][1]
	frames = run["frames"]
	var back := ColorRect.new()
	back.color = Color(0.2, 0.1, 0.3)
	back.size = Vector2(1280, 720)
	add_child(back)
	if not "--no-lidar" in args:
		view = RobotLidarView.new()
		add_child(view)
		view.position = Vector2(216, 172)
		view.size = Vector2(848, 376)
		var sensors: Array = []
		var labels := ["4", "3", "2"]
		for n in run["sensor_angles_deg"].size():
			sensors.append({"angle": deg_to_rad(float(run["sensor_angles_deg"][n])), "x": 0.06, "y": 0.0, "label": labels[n]})
		view.start(sensors, 0.12, 0.08)
		# The bench runs the view's frame itself, to time it.
		view.set_process(false)
		for arg in args:
			if arg.begins_with("--hide="):
				for child_name in arg.trim_prefix("--hide=").split(","):
					view.get_node(child_name).visible = false
	print("LIDARBENCH start quality=%s lidar=%s args=%s" % [GraphicsQualityConfig.level_name(level), view != null, " ".join(args)])


func _process(delta: float) -> void:
	clock += delta
	while next < frames.size() and float(frames[next][0]) <= clock:
		var f: Array = frames[next]
		next += 1
		if view != null and not (no_feed and clock > 1.0):
			view.add_frame(f[0], f[1], f[2], f[3], PackedFloat64Array([f[4], f[5], f[6]]))
	var started := Time.get_ticks_usec()
	if view != null:
		if only.is_empty():
			view._process(delta)
		else:
			if "camera" in only:
				view._update_camera(delta)
			view._since_update += delta
			if view._since_update >= view.UPDATE_S:
				view._since_update = 0.0
				if "sync" in only:
					view._sync_shown(0.033)
				if "scan" in only:
					view._scan()
				if "walls" in only:
					view._upload_walls()
	var script := (Time.get_ticks_usec() - started) / 1000.0
	if clock > WARMUP_S:
		var rid := get_viewport().get_viewport_rid()
		frame_ms.append(delta * 1000.0)
		script_ms.append(script)
		render_cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu())
		render_gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
	if clock > WARMUP_S + MEASURE_S:
		print("LIDARBENCH frames=%d fps=%.1f frame %s script %s render_cpu %s render_gpu %s" % [
			frame_ms.size(), frame_ms.size() / MEASURE_S, _stats(frame_ms), _stats(script_ms), _stats(render_cpu_ms), _stats(render_gpu_ms)])
		if view != null:
			print("LIDARBENCH walls=%d trail=%d" % [view._shown.size(), view._trail_count])
		# --shot=<png path>: the last frame.
		for arg in OS.get_cmdline_user_args():
			if arg.begins_with("--shot="):
				get_viewport().get_texture().get_image().save_png(arg.trim_prefix("--shot="))
		get_tree().quit()


func _stats(values: Array[float]) -> String:
	var sorted := values.duplicate()
	sorted.sort()
	return "%.2f/%.2f" % [sorted[sorted.size() / 2], sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))]]
