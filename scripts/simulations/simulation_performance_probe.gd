class_name SimulationPerformanceProbe
extends Node

## Lightweight, opt-in profiler for the Simulations tab.
##
## Space starts a capture and Space again prints a copy/paste friendly report.
## F1-F10 create A/B segments by disabling one editor subsystem at a time.

static var _active: bool = false
static var _capture_started_usec: int = 0
static var _stage_totals: Dictionary = {}
static var _segments: Array[Dictionary] = []
static var _current_segment: Dictionary = {}
static var _feature_states: Dictionary = {
	"grid": true,
	"world": true,
	"palette": true,
	"runtime_bar": true,
	"ui": true,
	"drop_surface_input": true,
	"editor_input": true,
	"continuous_layout": true,
	"renderer_process": true,
	"gizmo": true,
}

var _editor: Node2D
var _grid: CanvasItem
var _world_root: CanvasItem
var _palette: CanvasItem
var _runtime_bar: CanvasItem
var _ui: CanvasLayer
var _drop_surface: Control
var _camera: Node
var _renderer: Node
var _gizmo: CanvasItem
var _baseline: Dictionary = {}
var _last_frame_usec: int = 0
var _pending_motion_usec: int = 0


func configure(editor: Node2D) -> void:
	_editor = editor
	_grid = editor.get_node_or_null("Grid") as CanvasItem
	_world_root = editor.get_node_or_null("WorldRoot") as CanvasItem
	_palette = editor.get_node_or_null("UI/Root/Palette") as CanvasItem
	_runtime_bar = editor.get_node_or_null("UI/Root/RuntimeBar") as CanvasItem
	_ui = editor.get_node_or_null("UI") as CanvasLayer
	_drop_surface = editor.get_node_or_null("UI/Root/DropSurface") as Control
	_camera = editor.get_node_or_null("Camera2D")
	_renderer = editor.get_node_or_null("WorldRoot/VirtualWorldRenderer")
	_gizmo = editor.get_node_or_null("TransformGizmo") as CanvasItem
	_capture_baseline()
	set_process(true)
	set_process_input(true)
	print("[SIM PERF] Ready. Space=start/stop report; F1-F10 toggle A/B subsystems.")


func _capture_baseline() -> void:
	_baseline = {
		"grid_visible": _grid.visible if is_instance_valid(_grid) else true,
		"world_visible": _world_root.visible if is_instance_valid(_world_root) else true,
		"palette_visible": _palette.visible if is_instance_valid(_palette) else true,
		"runtime_bar_visible": _runtime_bar.visible if is_instance_valid(_runtime_bar) else true,
		"ui_visible": _ui.visible if is_instance_valid(_ui) else true,
		"drop_surface_mouse_filter": _drop_surface.mouse_filter if is_instance_valid(_drop_surface) else Control.MOUSE_FILTER_PASS,
		"editor_unhandled_input": _editor.is_processing_unhandled_input() if is_instance_valid(_editor) else true,
		"camera_unhandled_input": _camera.is_processing_unhandled_input() if is_instance_valid(_camera) else true,
		"renderer_process": _renderer.is_processing() if is_instance_valid(_renderer) else true,
		"gizmo_visible": _gizmo.visible if is_instance_valid(_gizmo) else true,
		"gizmo_process": _gizmo.is_processing() if is_instance_valid(_gizmo) else true,
	}


static func is_active() -> bool:
	return _active


static func is_feature_enabled(feature_name: String) -> bool:
	return bool(_feature_states.get(feature_name, true))


static func begin_scope(_scope_name: StringName) -> int:
	if not _active:
		return 0
	return Time.get_ticks_usec()


static func end_scope(scope_name: StringName, started_usec: int) -> void:
	if not _active or started_usec <= 0:
		return
	var elapsed_usec: int = maxi(0, Time.get_ticks_usec() - started_usec)
	_accumulate_stage(_stage_totals, scope_name, elapsed_usec)
	if not _current_segment.is_empty():
		var segment_stages: Dictionary = _current_segment.get("stages", {})
		_accumulate_stage(segment_stages, scope_name, elapsed_usec)
		_current_segment["stages"] = segment_stages


static func _accumulate_stage(target: Dictionary, scope_name: StringName, elapsed_usec: int) -> void:
	var key: String = str(scope_name)
	var stats: Dictionary = target.get(key, {"calls": 0, "total_us": 0, "max_us": 0})
	stats["calls"] = int(stats.get("calls", 0)) + 1
	stats["total_us"] = int(stats.get("total_us", 0)) + elapsed_usec
	stats["max_us"] = maxi(int(stats.get("max_us", 0)), elapsed_usec)
	target[key] = stats


func _input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key_event: InputEventKey = event as InputEventKey
		if key_event.pressed and not key_event.echo:
			if key_event.keycode == KEY_SPACE:
				if _active:
					_stop_capture()
				else:
					_start_capture()
				get_viewport().set_input_as_handled()
				return
			if _active:
				if key_event.keycode == KEY_F12:
					_finish_segment()
					_start_segment()
					print("[SIM PERF] New marker segment: %s" % _configuration_label())
					get_viewport().set_input_as_handled()
					return
				var feature_name: String = _feature_for_key(key_event.keycode)
				if not feature_name.is_empty():
					_toggle_feature(feature_name)
					get_viewport().set_input_as_handled()
					return
	if _active and event is InputEventMouseMotion:
		_current_segment["mouse_motion_events"] = int(_current_segment.get("mouse_motion_events", 0)) + 1
		var motion_event: InputEventMouseMotion = event as InputEventMouseMotion
		_current_segment["mouse_distance"] = float(_current_segment.get("mouse_distance", 0.0)) + motion_event.relative.length()
		if _pending_motion_usec == 0:
			_pending_motion_usec = Time.get_ticks_usec()
			_finish_motion_pipeline_sample.call_deferred()


func _process(_delta: float) -> void:
	if not _active:
		return
	var now_usec: int = Time.get_ticks_usec()
	if _last_frame_usec > 0:
		var frame_ms: float = float(now_usec - _last_frame_usec) / 1000.0
		_append_value(_current_segment, "frame_ms", frame_ms)
	_last_frame_usec = now_usec
	_append_value(_current_segment, "process_ms", float(Performance.get_monitor(Performance.TIME_PROCESS)) * 1000.0)
	_append_value(_current_segment, "physics_ms", float(Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0)
	_append_value(_current_segment, "draw_calls", float(Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)))
	_append_value(_current_segment, "render_objects", float(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME)))
	_current_segment["frames"] = int(_current_segment.get("frames", 0)) + 1


func _finish_motion_pipeline_sample() -> void:
	if _pending_motion_usec <= 0:
		return
	var started_usec: int = _pending_motion_usec
	_pending_motion_usec = 0
	if not _active:
		return
	var elapsed_usec: int = maxi(0, Time.get_ticks_usec() - started_usec)
	_accumulate_stage(_stage_totals, &"input.motion_to_deferred", elapsed_usec)
	var segment_stages: Dictionary = _current_segment.get("stages", {})
	_accumulate_stage(segment_stages, &"input.motion_to_deferred", elapsed_usec)
	_current_segment["stages"] = segment_stages


func _start_capture() -> void:
	_capture_baseline()
	for feature_name_variant: Variant in _feature_states.keys():
		_feature_states[str(feature_name_variant)] = true
	_stage_totals.clear()
	_segments.clear()
	_capture_started_usec = Time.get_ticks_usec()
	_active = true
	_pending_motion_usec = 0
	_start_segment()
	print("\n[SIM PERF] CAPTURE STARTED")
	print("[SIM PERF] Move the mouse / run the simulation, then use F1-F10 for A/B segments.")
	print("[SIM PERF] Space prints the final report.")
	_print_hotkeys()


func _stop_capture() -> void:
	if not _active:
		return
	_finish_segment()
	_active = false
	_pending_motion_usec = 0
	_print_report()
	_restore_all_features()


func _toggle_feature(feature_name: String) -> void:
	if _active:
		_finish_segment()
	var enabled: bool = not bool(_feature_states.get(feature_name, true))
	_feature_states[feature_name] = enabled
	_apply_feature(feature_name, enabled)
	print("[SIM PERF] %s = %s" % [feature_name, "ON" if enabled else "OFF"])
	if _active:
		_start_segment()


func _apply_feature(feature_name: String, enabled: bool) -> void:
	match feature_name:
		"grid":
			if is_instance_valid(_grid):
				_grid.visible = bool(_baseline.get("grid_visible", true)) if enabled else false
		"world":
			if is_instance_valid(_world_root):
				_world_root.visible = bool(_baseline.get("world_visible", true)) if enabled else false
		"palette":
			if is_instance_valid(_palette):
				_palette.visible = bool(_baseline.get("palette_visible", true)) if enabled else false
		"runtime_bar":
			if is_instance_valid(_runtime_bar):
				_runtime_bar.visible = bool(_baseline.get("runtime_bar_visible", true)) if enabled else false
		"ui":
			if is_instance_valid(_ui):
				_ui.visible = bool(_baseline.get("ui_visible", true)) if enabled else false
		"drop_surface_input":
			if is_instance_valid(_drop_surface):
				_drop_surface.mouse_filter = int(_baseline.get("drop_surface_mouse_filter", Control.MOUSE_FILTER_PASS)) if enabled else Control.MOUSE_FILTER_IGNORE
		"editor_input":
			if is_instance_valid(_editor):
				_editor.set_process_unhandled_input(bool(_baseline.get("editor_unhandled_input", true)) if enabled else false)
			if is_instance_valid(_camera):
				_camera.set_process_unhandled_input(bool(_baseline.get("camera_unhandled_input", true)) if enabled else false)
		"renderer_process":
			if is_instance_valid(_renderer):
				_renderer.set_process(bool(_baseline.get("renderer_process", true)) if enabled else false)
		"gizmo":
			if is_instance_valid(_gizmo):
				_gizmo.visible = bool(_baseline.get("gizmo_visible", true)) if enabled else false
				_gizmo.set_process(bool(_baseline.get("gizmo_process", true)) if enabled else false)


func _restore_all_features() -> void:
	for feature_name_variant: Variant in _feature_states.keys():
		var feature_name: String = str(feature_name_variant)
		_feature_states[feature_name] = true
		_apply_feature(feature_name, true)


func _start_segment() -> void:
	_last_frame_usec = 0
	_current_segment = {
		"label": _configuration_label(),
		"started_us": Time.get_ticks_usec(),
		"frames": 0,
		"mouse_motion_events": 0,
		"mouse_distance": 0.0,
		"frame_ms": PackedFloat32Array(),
		"process_ms": PackedFloat32Array(),
		"physics_ms": PackedFloat32Array(),
		"draw_calls": PackedFloat32Array(),
		"render_objects": PackedFloat32Array(),
		"stages": {},
	}


func _finish_segment() -> void:
	if _current_segment.is_empty():
		return
	_current_segment["duration_us"] = maxi(0, Time.get_ticks_usec() - int(_current_segment.get("started_us", Time.get_ticks_usec())))
	_segments.append(_current_segment)
	_current_segment = {}
	_last_frame_usec = 0


func _configuration_label() -> String:
	var disabled: PackedStringArray = PackedStringArray()
	for feature_name_variant: Variant in _feature_states.keys():
		var feature_name: String = str(feature_name_variant)
		if not bool(_feature_states.get(feature_name, true)):
			disabled.append(feature_name)
	if disabled.is_empty():
		return "baseline(all_on)"
	return "off=" + ",".join(disabled)


func _feature_for_key(keycode: Key) -> String:
	match keycode:
		KEY_F1: return "grid"
		KEY_F2: return "world"
		KEY_F3: return "palette"
		KEY_F4: return "runtime_bar"
		KEY_F5: return "ui"
		KEY_F6: return "drop_surface_input"
		KEY_F7: return "editor_input"
		KEY_F8: return "continuous_layout"
		KEY_F9: return "renderer_process"
		KEY_F10: return "gizmo"
	return ""


func _print_hotkeys() -> void:
	print("[SIM PERF] F1 grid | F2 world | F3 palette | F4 runtime bar | F5 all UI")
	print("[SIM PERF] F6 drop-surface hit-test | F7 editor input | F8 continuous layout")
	print("[SIM PERF] F9 renderer process | F10 gizmo redraw | F12 new marker segment")


func _print_report() -> void:
	var capture_duration_ms: float = float(Time.get_ticks_usec() - _capture_started_usec) / 1000.0
	var lines: PackedStringArray = PackedStringArray()
	lines.append("")
	lines.append("========== SIMULATION PERFORMANCE REPORT ==========")
	lines.append("capture_ms=%.3f segments=%d godot=%s" % [capture_duration_ms, _segments.size(), Engine.get_version_info().get("string", "unknown")])
	lines.append("scope timings are elapsed wall time; nested scopes and input latency may overlap")
	lines.append("node_count=%d orphan_nodes=%d static_memory_mb=%.2f" % [
		int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)),
		int(Performance.get_monitor(Performance.OBJECT_ORPHAN_NODE_COUNT)),
		float(Performance.get_monitor(Performance.MEMORY_STATIC)) / 1048576.0,
	])
	lines.append("")
	for segment_index: int in _segments.size():
		_append_segment_report(lines, segment_index, _segments[segment_index])
	lines.append("GLOBAL RANKED SCOPES")
	_append_stage_report(lines, _stage_totals, capture_duration_ms, 0)
	lines.append("========== END SIMULATION PERFORMANCE REPORT ==========")
	print("\n".join(lines))


func _append_segment_report(lines: PackedStringArray, segment_index: int, segment: Dictionary) -> void:
	var duration_ms: float = float(segment.get("duration_us", 0)) / 1000.0
	var duration_seconds: float = maxf(duration_ms / 1000.0, 0.000001)
	var motion_events: int = int(segment.get("mouse_motion_events", 0))
	var frame_stats: Dictionary = _value_stats(segment.get("frame_ms", PackedFloat32Array()))
	var process_stats: Dictionary = _value_stats(segment.get("process_ms", PackedFloat32Array()))
	var physics_stats: Dictionary = _value_stats(segment.get("physics_ms", PackedFloat32Array()))
	var draw_stats: Dictionary = _value_stats(segment.get("draw_calls", PackedFloat32Array()))
	var object_stats: Dictionary = _value_stats(segment.get("render_objects", PackedFloat32Array()))
	lines.append("SEGMENT %d: %s" % [segment_index + 1, str(segment.get("label", "unknown"))])
	lines.append("  duration_ms=%.3f frames=%d mouse_events=%d mouse_events_per_s=%.1f mouse_distance=%.1f" % [
		duration_ms,
		int(segment.get("frames", 0)),
		motion_events,
		float(motion_events) / duration_seconds,
		float(segment.get("mouse_distance", 0.0)),
	])
	lines.append("  frame_ms avg=%.3f p50=%.3f p95=%.3f p99=%.3f max=%.3f approx_fps=%.1f" % [
		float(frame_stats.get("avg", 0.0)),
		float(frame_stats.get("p50", 0.0)),
		float(frame_stats.get("p95", 0.0)),
		float(frame_stats.get("p99", 0.0)),
		float(frame_stats.get("max", 0.0)),
		1000.0 / maxf(float(frame_stats.get("avg", 0.0)), 0.000001),
	])
	lines.append("  godot_process_ms avg=%.3f p95=%.3f max=%.3f | physics_ms avg=%.3f p95=%.3f max=%.3f" % [
		float(process_stats.get("avg", 0.0)), float(process_stats.get("p95", 0.0)), float(process_stats.get("max", 0.0)),
		float(physics_stats.get("avg", 0.0)), float(physics_stats.get("p95", 0.0)), float(physics_stats.get("max", 0.0)),
	])
	lines.append("  draw_calls avg=%.1f max=%.1f | render_objects avg=%.1f max=%.1f" % [
		float(draw_stats.get("avg", 0.0)), float(draw_stats.get("max", 0.0)),
		float(object_stats.get("avg", 0.0)), float(object_stats.get("max", 0.0)),
	])
	_append_stage_report(lines, segment.get("stages", {}), duration_ms, 12)
	lines.append("")


func _append_stage_report(lines: PackedStringArray, stages: Dictionary, duration_ms: float, limit: int) -> void:
	var rows: Array[Dictionary] = []
	for stage_name_variant: Variant in stages.keys():
		var stage_name: String = str(stage_name_variant)
		var stats: Dictionary = stages.get(stage_name, {})
		rows.append({
			"name": stage_name,
			"calls": int(stats.get("calls", 0)),
			"total_us": int(stats.get("total_us", 0)),
			"max_us": int(stats.get("max_us", 0)),
		})
	rows.sort_custom(_stage_more_expensive)
	var row_count: int = rows.size() if limit <= 0 else mini(limit, rows.size())
	for row_index: int in row_count:
		var row: Dictionary = rows[row_index]
		var calls: int = maxi(1, int(row.get("calls", 0)))
		var total_ms: float = float(row.get("total_us", 0)) / 1000.0
		lines.append("  scope=%s calls=%d total_ms=%.3f avg_us=%.2f max_us=%d capture_pct=%.2f" % [
			str(row.get("name", "unknown")),
			int(row.get("calls", 0)),
			total_ms,
			float(row.get("total_us", 0)) / float(calls),
			int(row.get("max_us", 0)),
			100.0 * total_ms / maxf(duration_ms, 0.000001),
		])


static func _stage_more_expensive(left: Dictionary, right: Dictionary) -> bool:
	return int(left.get("total_us", 0)) > int(right.get("total_us", 0))


static func _append_value(target: Dictionary, key: String, value: float) -> void:
	var values: PackedFloat32Array = target.get(key, PackedFloat32Array())
	values.append(value)
	target[key] = values


static func _value_stats(values_variant: Variant) -> Dictionary:
	var values: PackedFloat32Array = values_variant if values_variant is PackedFloat32Array else PackedFloat32Array()
	if values.is_empty():
		return {"avg": 0.0, "p50": 0.0, "p95": 0.0, "p99": 0.0, "max": 0.0}
	var sorted_values: PackedFloat32Array = values.duplicate()
	sorted_values.sort()
	var total: float = 0.0
	for value: float in sorted_values:
		total += value
	return {
		"avg": total / float(sorted_values.size()),
		"p50": _percentile(sorted_values, 0.50),
		"p95": _percentile(sorted_values, 0.95),
		"p99": _percentile(sorted_values, 0.99),
		"max": sorted_values[sorted_values.size() - 1],
	}


static func _percentile(sorted_values: PackedFloat32Array, ratio: float) -> float:
	if sorted_values.is_empty():
		return 0.0
	var index: int = clampi(ceili(float(sorted_values.size()) * ratio) - 1, 0, sorted_values.size() - 1)
	return sorted_values[index]
