extends Node

# Where Neuralese's frame time goes, per case and per graphics level, in the
# real app (Car Track open). For every case it prints, as one RENDERBENCH line:
#   frame       wall time between frames, ms (median / p95)
#   gpu         root viewport GPU render time as Godot measures it, ms
#   cpu         root viewport CPU render time + frame setup, ms
#   calls       draw calls in the frame (median)
# and once, a CENSUS line: CanvasLayers whose items read the screen
# (hint_screen_texture), each of which costs one full-screen copy per frame
# (plus a Gaussian mip chain when the shader uses mipmaps), MSAA, and so on.
#
# User arguments:
#   --graphics=high|medium|low
#   --cases=graph_idle,graph_pan,graph_dialog,env_pan,ds_idle (default: all)
#   --frames=N            frames measured per case (default 120)
#   --msaa=off|2|4        override the level's 2D MSAA
#   --no-screen-copies    High with every screen-reading panel moved to the
#                         background-only shader (as Medium does), MSAA kept
#   --no-gauss            gaussian_mix 0 on every panel material (one lookup)
#   --opaque-root         root viewport without a transparent background
#   --swap-unused-screen  live-screen materials that only read the background
#                         (use_bg on) moved to the background-only shader
#   --layer-capture=N     prototype: the top bar reads a 1/8 bake of the objects
#                         layer drawn again at 1/N (proto/layer_capture_proto.gd)
#                         instead of the screen texture
#   --list-screen-items   every visible screen-reading item, once per case
#   --dump-capture=<png>  the prototype's bake (and capture) after the last case
#   --shot=<png>          the last frame of the last case

const GraphicsQualityConfigScript := preload("res://scripts/graphics_quality.gd")
const CAR_TRACK_PATH := "res://built_in_projects/Car Track.scn"
const SCREEN_SHADER := "res://shaders/block_screen.gdshader"
const BACKGROUND_SHADER := preload("res://shaders/block.gdshader")
const LayerCaptureProto := preload("res://.superpowers/low-perf-proxy/proto/layer_capture_proto.gd")
const ALL_CASES := ["graph_idle", "graph_pan", "graph_dialog", "env_pan", "ds_idle"]
const WARM_FRAMES := 30

var frames_per_case := 120
var level := 0
var _capture: Node = null


func _ready() -> void:
	_run.call_deferred()


func _arg(prefix: String, fallback: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return fallback


func _flag(name: String) -> bool:
	return name in OS.get_cmdline_user_args()


func _run() -> void:
	level = GraphicsQualityConfigScript.resolve(OS.get_cmdline_user_args())
	GraphicsQualityConfigScript.apply(level)
	DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
	frames_per_case = int(_arg("--frames=", "120"))
	RenderingServer.viewport_set_measure_render_time(get_viewport().get_viewport_rid(), true)
	# Startup dialogs (the profile's name) are dismissed, as the robot window harness does.
	for _step in 40:
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
	for _frame in 60:
		await get_tree().process_frame
	_apply_ablations()
	# True idle, as the app runs it (low-processor mode on): how many frames does
	# it still draw per second with nobody touching it?
	glob.go_window("graph")
	await get_tree().create_timer(2.0).timeout
	var drawn := Engine.get_frames_drawn()
	await get_tree().create_timer(5.0).timeout
	print("IDLE quality=%s frames_drawn_per_s=%.1f" % [GraphicsQualityConfigScript.level_name(level), (Engine.get_frames_drawn() - drawn) / 5.0])
	if _flag("--find-idle-redraw"):
		await _find_idle_redraw()
		get_tree().quit(0)
		return
	if not _arg("--record=", "").is_empty():
		OS.low_processor_usage_mode = false
		await _record(_arg("--record=", ""))
		print("RECORD PASS")
		get_tree().quit(0)
		return
	# The measured cases run uncapped (no low-processor sleep, no VSync): the
	# frame time is the work.
	OS.low_processor_usage_mode = false
	var cases := _arg("--cases=", ",".join(ALL_CASES)).split(",", false)
	print("RENDERBENCH start quality=%s renderer=%s/%s adapter=%s size=%s args=%s" % [
		GraphicsQualityConfigScript.level_name(level), ProjectSettings.get_setting("rendering/renderer/rendering_method"),
		RenderingServer.get_current_rendering_driver_name(), RenderingServer.get_video_adapter_name(),
		get_viewport().get_visible_rect().size, " ".join(OS.get_cmdline_user_args())])
	for case_name in cases:
		await _case(case_name)
	var shot := _arg("--shot=", "")
	if not shot.is_empty():
		get_viewport().get_texture().get_image().save_png(shot)
	var dump := _arg("--dump-capture=", "")
	if not dump.is_empty() and _capture != null:
		_capture.save_bake(dump)
	print("RENDERBENCH PASS")
	get_tree().quit(0)


func _apply_ablations() -> void:
	var msaa := _arg("--msaa=", "")
	match msaa:
		"off":
			get_tree().root.msaa_2d = Viewport.MSAA_DISABLED
		"2":
			get_tree().root.msaa_2d = Viewport.MSAA_2X
		"4":
			get_tree().root.msaa_2d = Viewport.MSAA_4X
	if _flag("--no-screen-copies"):
		GraphicsQualityConfigScript._swap_screen_materials_in(get_tree().root)
	if _flag("--no-gauss"):
		for item in _canvas_items(get_tree().root):
			var material := item.material as ShaderMaterial
			if material != null and material.shader != null and "gaussian_mix" in material.shader.code + _include_code(material.shader):
				material.set_shader_parameter("gaussian_mix", 0.0)
	if _flag("--opaque-root"):
		get_tree().root.transparent_bg = false
	if _flag("--swap-unused-screen"):
		_swap_unused_screen_materials()
	var capture_downscale := int(_arg("--layer-capture=", "0"))
	if capture_downscale > 0:
		if _capture == null:
			_capture = LayerCaptureProto.new()
			_capture.refresh_every = int(_arg("--capture-every=", "1"))
			add_child(_capture)
			_capture.install(get_tree().root, capture_downscale)
		else:
			_capture.attach_layers()
		print("LAYERCAPTURE panels swapped=%d" % _capture.swap_panels(get_tree().root))


## A live-screen material whose use_bg is on samples only the background, yet its
## shader still makes Godot copy the screen (and blur the copy into mipmaps): the
## background-only shader draws exactly the same pixels without the copy.
func _swap_unused_screen_materials() -> void:
	var swapped := []
	for item in _canvas_items(get_tree().root):
		var material := item.material as ShaderMaterial
		if material == null or material.shader == null or material.shader.resource_path != SCREEN_SHADER:
			continue
		if not bool(material.get_shader_parameter("use_bg")) and bool(material.get_shader_parameter("blurred_background")):
			continue
		var replacement := material.duplicate(true) as ShaderMaterial
		replacement.shader = BACKGROUND_SHADER
		item.material = replacement
		swapped.append(str(item.get_path()))
	print("SWAPUNUSED %s" % [swapped])


func _include_code(shader: Shader) -> String:
	return FileAccess.get_file_as_string("res://shaders/block_body.gdshaderinc") if "block_body" in shader.code else ""


## graph_layers: what each part of the graph screen costs, by switching it off
## for a block of panning frames between control blocks, all in one process
## (control, A, control, B, ..., control) so drift shows in the controls.
## Diagnostic removals only; none of them is a usable mode.
func _layers_case() -> void:
	glob.go_window("graph")
	for _frame in 20:
		await get_tree().process_frame
	_apply_ablations()
	var camera := glob.tree_windows["graph"].get("camera") as Camera2D
	var root := get_tree().root
	var layers := {}
	var world := []
	var bg_node: Node = null
	for node in _all_nodes(root):
		if node is CanvasLayer and (node as CanvasLayer).visible and node.get_viewport() == root:
			var layer := node as CanvasLayer
			var script: Script = layer.get_script()
			if script != null and script.resource_path == "res://scripts/bg.gd" and layer.get("register_global"):
				bg_node = layer
			var drawn := false
			for child in _all_nodes(layer):
				if child is CanvasItem and (child as CanvasItem).is_visible_in_tree() and child.get_viewport() == root:
					drawn = true
					break
			if drawn:
				layers["layer %d %s" % [layer.layer, layer.name]] = [layer]
		elif node is CanvasItem and (node as CanvasItem).visible and (node as CanvasItem).get_canvas_layer_node() == null \
				and not node.get_parent() is CanvasItem and node.get_viewport() == root:
			world.append(node)
	var targets := {"world canvas (graph, root controls)": world}
	targets.merge(layers)
	var blank := world.duplicate()
	for key in layers:
		blank.append_array(layers[key])
	targets["bg frozen (no sharp re-render)"] = []
	targets["blank (everything hidden, bg frozen)"] = blank
	var order := targets.keys()
	await _layers_block("control", camera, [], false)
	for key in order:
		await _layers_block(key, camera, targets[key], key.begins_with("bg frozen") or key.begins_with("blank"), bg_node)
		await _layers_block("control", camera, [], false)


func _layers_block(label: String, camera: Camera2D, hide: Array, freeze_bg: bool, bg_node: Node = null) -> void:
	var was := []
	for item in hide:
		was.append(item.visible)
		item.visible = false
	var froze := freeze_bg and bg_node != null and RenderingServer.frame_pre_draw.is_connected(bg_node._on_frame_pre_draw)
	if froze:
		RenderingServer.frame_pre_draw.disconnect(bg_node._on_frame_pre_draw)
	var start := camera.position
	var zoom := camera.zoom.x
	_breakdown_begin()
	var frame_ms: Array[float] = []
	var calls: Array[float] = []
	var last := Time.get_ticks_usec()
	for frame in 15 + 45:
		_move_camera(camera, zoom, start + Vector2(250.0 * sin(frame * 0.06), 0.0) / zoom)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		if frame >= 15:
			frame_ms.append((now - last) / 1000.0)
			calls.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
			_breakdown_sample(now)
		else:
			_breakdown_mark(now)
		last = now
	_move_camera(camera, zoom, start)
	print("LAYERS block=\"%s\" frame %.2f calls %d" % [label, _median(frame_ms), int(_median(calls))])
	_breakdown_print("layers:" + label)
	for i in hide.size():
		hide[i].visible = was[i]
	if froze:
		RenderingServer.frame_pre_draw.connect(bg_node._on_frame_pre_draw)
	for _frame in 10:
		await get_tree().process_frame


func _case(case_name: String) -> void:
	if case_name == "graph_layers":
		await _layers_case()
		return
	var camera: Camera2D = null
	var dialog: Node = null
	match case_name:
		"graph_idle", "graph_pan", "graph_dialog", "graph_zoom":
			glob.go_window("graph")
		"env_pan":
			glob.go_window("env")
		"ds_idle":
			glob.go_window("ds")
	for _frame in 20:
		await get_tree().process_frame
	var tab: Node = glob.tree_windows.get("env" if case_name == "env_pan" else "graph")
	if tab != null:
		camera = tab.get("camera") as Camera2D
	if case_name == "graph_dialog":
		# A top-level window over the moving workspace: the Export window.
		dialog = ui.splash("model_export", null, null, false, {"mode": "onnx"})
		for _frame in 90:
			await get_tree().process_frame
	# Tabs and dialogs create their panels when shown: the ablations apply to them too.
	_apply_ablations()
	_census(case_name)
	var frame_ms: Array[float] = []
	var gpu_ms: Array[float] = []
	var cpu_ms: Array[float] = []
	var calls: Array[float] = []
	var rid := get_viewport().get_viewport_rid()
	var last := Time.get_ticks_usec()
	var base_zoom := camera.zoom if camera != null else Vector2.ONE
	# --shot-frames=a,b,... with --shot-dir=<dir>: the frame on screen at those loop frames.
	var shot_frames := Array(_arg("--shot-frames=", "").split(",", false)).map(func(value: String) -> int: return int(value))
	if camera != null and _flag("--under-bar"):
		# The graph's upper nodes under the top bar, to compare what the bar blurs.
		_move_camera(camera, camera.zoom.x, camera.position + Vector2(0.0, 300.0 / camera.zoom.y))
	var start_position := camera.position if camera != null else Vector2.ZERO
	var breakdown := _flag("--breakdown")
	if breakdown:
		_breakdown_begin()
	for frame in WARM_FRAMES + frames_per_case:
		if frame in shot_frames:
			get_viewport().get_texture().get_image().save_png(_arg("--shot-dir=", "").path_join("%s_f%d.png" % [case_name, frame]))
		if camera != null and case_name == "graph_zoom":
			# A slow zoom in and out: every frame a new scale (and new glyph sizes for rasterized fonts).
			_move_camera(camera, base_zoom.x * (1.0 + 0.5 * sin(frame * 0.07)), start_position)
		elif camera != null:
			# Pan: back and forth, up to 15 screen px per frame, so the graph stays
			# on screen. Idle: the smallest change that still redraws the frame.
			var moving := case_name.ends_with("_pan") or case_name == "graph_dialog"
			var offset := Vector2(250.0 * sin(frame * 0.06), 0.0) if moving else Vector2(0.05 * (frame % 2), 0.0)
			_move_camera(camera, base_zoom.x, start_position + offset / base_zoom.x)
		await get_tree().process_frame
		var now := Time.get_ticks_usec()
		if frame >= WARM_FRAMES:
			frame_ms.append((now - last) / 1000.0)
			gpu_ms.append(RenderingServer.viewport_get_measured_render_time_gpu(rid))
			cpu_ms.append(RenderingServer.viewport_get_measured_render_time_cpu(rid) + RenderingServer.get_frame_setup_time_cpu())
			calls.append(RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TOTAL_DRAW_CALLS_IN_FRAME))
			if breakdown:
				_breakdown_sample(now)
		elif breakdown:
			_breakdown_mark(now)
		last = now
	if breakdown:
		_breakdown_print(case_name)
	if camera != null:
		_move_camera(camera, base_zoom.x, start_position)
	print("RENDERBENCH quality=%s case=%s frame %s gpu %s cpu %s calls %d vram_mb %.0f tex_mb %.0f" % [
		GraphicsQualityConfigScript.level_name(level), case_name, _stats(frame_ms), _stats(gpu_ms), _stats(cpu_ms),
		int(_median(calls)), RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_VIDEO_MEM_USED) / 1048576.0,
		RenderingServer.get_rendering_info(RenderingServer.RENDERING_INFO_TEXTURE_MEM_USED) / 1048576.0])
	if dialog != null and is_instance_valid(dialog) and dialog.has_method("go_away"):
		dialog.go_away()
	elif dialog != null and is_instance_valid(dialog):
		dialog.queue_free()
	for _frame in 30:
		await get_tree().process_frame


## --breakdown: where one frame's wall time goes, from the engine's own frame
## signals (main loop order: physics, process_frame, the nodes' _process,
## frame_pre_draw, drawing, frame_post_draw; post_draw comes after present):
##   process  process_frame -> frame_pre_draw: scene processing, scripts, tweens
##   render   frame_pre_draw -> frame_post_draw: RenderingServer setup, command
##            recording per viewport, llvmpipe raster waits, final blit, present
##   other    frame_post_draw -> next process_frame: physics, input, the loop
## plus, per viewport, the CPU (command recording) and GPU (llvmpipe raster)
## time Godot measures with viewport timestamps only (no --gpu-profile, whose
## per-canvas timestamps make lavapipe flush and distort the numbers).
var _bd_pre := 0
var _bd_post := 0
var _bd_prev := 0
var _bd := {}
var _bd_viewports := {}


func _breakdown_begin() -> void:
	_bd = {"process": [], "render": [], "other": [], "setup": []}
	_bd_viewports = {"root": get_tree().root.get_viewport_rid()}
	for node in _all_nodes(get_tree().root):
		if node is SubViewport:
			var path := str(node.get_path()).split("/")
			_bd_viewports["/".join(path.slice(maxi(path.size() - 3, 0)))] = (node as SubViewport).get_viewport_rid()
	for name in _bd_viewports:
		RenderingServer.viewport_set_measure_render_time(_bd_viewports[name], true)
		_bd["cpu " + name] = []
		_bd["gpu " + name] = []
	if not RenderingServer.frame_pre_draw.is_connected(_on_bd_pre):
		RenderingServer.frame_pre_draw.connect(_on_bd_pre)
		RenderingServer.frame_post_draw.connect(_on_bd_post)


func _on_bd_pre() -> void:
	_bd_pre = Time.get_ticks_usec()


func _on_bd_post() -> void:
	_bd_post = Time.get_ticks_usec()


func _breakdown_mark(now: int) -> void:
	_bd_prev = now


func _breakdown_sample(now: int) -> void:
	if _bd_prev > 0 and _bd_prev < _bd_pre and _bd_pre <= _bd_post and _bd_post <= now:
		_bd["process"].append((_bd_pre - _bd_prev) / 1000.0)
		_bd["render"].append((_bd_post - _bd_pre) / 1000.0)
		_bd["other"].append((now - _bd_post) / 1000.0)
		_bd["setup"].append(RenderingServer.get_frame_setup_time_cpu())
		for name in _bd_viewports:
			_bd["cpu " + name].append(RenderingServer.viewport_get_measured_render_time_cpu(_bd_viewports[name]))
			_bd["gpu " + name].append(RenderingServer.viewport_get_measured_render_time_gpu(_bd_viewports[name]))
	_bd_prev = now


func _breakdown_print(case_name: String) -> void:
	var line := "BREAKDOWN quality=%s case=%s frames=%d process %.2f render %.2f other %.2f (setup %.2f)" % [
		GraphicsQualityConfigScript.level_name(level), case_name, _bd["process"].size(),
		_bd_median(_bd["process"]), _bd_median(_bd["render"]), _bd_median(_bd["other"]), _bd_median(_bd["setup"])]
	var rows := []
	for name in _bd_viewports:
		var gpu := _bd_median(_bd["gpu " + name])
		var cpu := _bd_median(_bd["cpu " + name])
		if gpu > 0.02 or cpu > 0.02:
			rows.append([gpu, "%s cpu %.2f gpu %.2f" % [name, cpu, gpu]])
	rows.sort_custom(func(a: Array, b: Array) -> bool: return a[0] > b[0])
	print(line)
	for row in rows:
		print("BREAKDOWN   viewport %s" % row[1])


func _bd_median(values: Array) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return float(sorted[sorted.size() / 2]) if not sorted.is_empty() else 0.0


## Frame sequences for judging a change in motion (flicker, sparkle, lag, stale or
## white frames), which single screenshots cannot show. Run with --fixed-fps 60
## so every frame advances the app's animations by the same 1/60 s and two runs
## (the app as is, and a variant) stay frame for frame comparable. Every frame of
## each segment is saved as <dir>/<segment>_<frame>.png; analyze with
## .superpowers/low-perf-proxy/flicker_check.py.
func _record(dir: String) -> void:
	DirAccess.make_dir_recursive_absolute(dir)
	var segments := _arg("--segments=", "pan,zoom,dialog,tabs").split(",", false)
	glob.go_window("graph")
	for _frame in 30:
		await get_tree().process_frame
	_apply_ablations()
	var camera := glob.tree_windows["graph"].get("camera") as Camera2D
	var home_zoom := camera.zoom.x
	var home := camera.position + Vector2(0.0, 300.0 / camera.zoom.y)
	for segment in segments:
		_move_camera(camera, home_zoom, home)
		for _frame in 10:
			await get_tree().process_frame
		match segment:
			"pan":
				# Nodes slide under the top bar at 6 screen px per frame, then back slower.
				for frame in 160:
					var step := 6.0 if frame < 100 else -3.0
					_move_camera(camera, home_zoom, camera.position + Vector2(step, 0.0) / camera.zoom.x)
					await _record_frame(dir, segment, frame)
			"zoom":
				for frame in 160:
					_move_camera(camera, home_zoom * (1.0 + 0.4 * sin(frame * 0.06)), camera.position)
					await _record_frame(dir, segment, frame)
			"dialog":
				# A window opening and closing over a slowly moving workspace.
				var dialog: Node = null
				for frame in 150:
					if frame == 10:
						dialog = ui.splash("model_export", null, null, false, {"mode": "onnx"})
						_apply_ablations()
					if frame == 90 and is_instance_valid(dialog) and dialog.has_method("go_away"):
						dialog.go_away()
					_move_camera(camera, home_zoom, camera.position + Vector2(2.0, 0.0) / camera.zoom.x)
					await _record_frame(dir, segment, frame)
			"tabs":
				var order := ["env", "ds", "graph"]
				for frame in 180:
					if frame % 60 == 5:
						glob.go_window(order[frame / 60])
						_apply_ablations()
					await _record_frame(dir, segment, frame)


func _record_frame(dir: String, segment: String, frame: int) -> void:
	await get_tree().process_frame
	get_viewport().get_texture().get_image().save_png(dir.path_join("%s_%04d.png" % [segment, frame]))


## The app's camera (scripts/camera_2d.gd) eases toward its own targets every
## frame, so setting position or zoom alone is undone: restore_view snaps both.
func _move_camera(camera: Camera2D, zoom: float, position: Vector2) -> void:
	if camera.has_method("restore_view"):
		camera.restore_view(zoom, position)
	else:
		camera.zoom = Vector2.ONE * zoom
		camera.position = position


## What keeps an untouched app redrawing: the nodes of one script at a time stop
## processing for three seconds, and the frames drawn meanwhile are counted.
func _find_idle_redraw() -> void:
	var by_script := {}
	for node in _all_nodes(get_tree().root):
		if node == self or not node.is_processing():
			continue
		var script: Script = node.get_script()
		var key := script.resource_path if script != null else node.get_class()
		if not by_script.has(key):
			by_script[key] = []
		by_script[key].append(node)
	var tweens := get_tree().get_processed_tweens().size()
	var animated := []
	for item in _canvas_items(get_tree().root):
		var material := item.material as ShaderMaterial
		if item.is_visible_in_tree() and material != null and material.shader != null and "TIME" in material.shader.code:
			animated.append(str(item.get_path()))
	print("IDLEFIND processing_scripts=%d tweens=%d visible_TIME_shaders=%s" % [by_script.size(), tweens, animated])
	for key in by_script:
		var nodes: Array = by_script[key]
		for node in nodes:
			node.set_process(false)
		await get_tree().create_timer(0.5).timeout
		var drawn := Engine.get_frames_drawn()
		await get_tree().create_timer(3.0).timeout
		var rate := (Engine.get_frames_drawn() - drawn) / 3.0
		for node in nodes:
			if is_instance_valid(node):
				node.set_process(true)
		print("IDLEFIND without=%s nodes=%d frames_drawn_per_s=%.1f" % [key, nodes.size(), rate])


## Which canvases (CanvasLayers) have visible items reading the screen, and how
## many panels use the blurred-background shader at all.
func _census(case_name: String) -> void:
	var screen_layers := {}
	var mip_layers := {}
	var screen_items := 0
	var blur_items := 0
	var processing := 0
	for item in _canvas_items(get_tree().root):
		if not item.is_visible_in_tree():
			continue
		var material := item.material as ShaderMaterial
		if material == null or material.shader == null:
			continue
		var code := material.shader.code
		if "block_body" in code:
			blur_items += 1
		if "hint_screen_texture" in code or "BLOCK_SAMPLE_SCREEN_TEXTURE" in code:
			screen_items += 1
			var layer := item.get_canvas_layer_node()
			var key := str(layer.get_instance_id()) + ":" + str(layer.layer) if layer != null else "root"
			screen_layers[key] = true
			if "mipmap" in code or "BLOCK_SAMPLE_SCREEN_TEXTURE" in code:
				mip_layers[key] = true
			if _flag("--list-screen-items"):
				var rect: Rect2 = (item as Control).get_global_rect() if item is Control else Rect2()
				print("SCREENITEM case=%s layer=%s use_bg=%s blurred_background=%s size=%s path=%s material=%s" % [
					case_name, key, material.get_shader_parameter("use_bg"), material.get_shader_parameter("blurred_background"),
					rect.size, item.get_path(), material.resource_path])
	var canvas_layers := {}
	for node in _all_nodes(get_tree().root):
		if node.is_processing():
			processing += 1
		# Each visible CanvasLayer with visible items is its own render pass (and MSAA resolve).
		if node is CanvasItem and (node as CanvasItem).is_visible_in_tree():
			var owner_layer := (node as CanvasItem).get_canvas_layer_node()
			canvas_layers[owner_layer.get_instance_id() if owner_layer != null else 0] = owner_layer.layer if owner_layer != null else 0
	print("CENSUS quality=%s case=%s canvas_layers_with_visible_items=%d layer_numbers=%s" % [
		GraphicsQualityConfigScript.level_name(level), case_name, canvas_layers.size(), canvas_layers.values()])
	print("CENSUS quality=%s case=%s screen_reading_layers=%d (with mip chain %d) screen_items=%d blur_panels=%d msaa_2d=%d processing_nodes=%d layers=%s" % [
		GraphicsQualityConfigScript.level_name(level), case_name, screen_layers.size(), mip_layers.size(), screen_items, blur_items,
		get_tree().root.msaa_2d, processing, ",".join(screen_layers.keys())])


func _canvas_items(node: Node) -> Array[CanvasItem]:
	var result: Array[CanvasItem] = []
	for child in _all_nodes(node):
		if child is CanvasItem:
			result.append(child)
	return result


func _all_nodes(node: Node) -> Array[Node]:
	var result: Array[Node] = [node]
	var index := 0
	while index < result.size():
		for child in result[index].get_children(true):
			result.append(child)
		index += 1
	return result


func _median(values: Array[float]) -> float:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[sorted.size() / 2] if not sorted.is_empty() else 0.0


func _stats(values: Array[float]) -> String:
	var sorted := values.duplicate()
	sorted.sort()
	if sorted.is_empty():
		return "-"
	return "%.2f/%.2f/max%.0f" % [sorted[sorted.size() / 2], sorted[mini(sorted.size() - 1, int(sorted.size() * 0.95))], sorted[sorted.size() - 1]]
