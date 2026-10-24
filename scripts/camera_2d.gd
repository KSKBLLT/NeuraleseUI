extends Camera2D
class_name GraphViewport

const PlatformInput = preload("res://scripts/platform_input.gd")
const MIN_ZOOM: float = 0.4
const MAX_ZOOM: float = 4.0

@export var main: bool = false
@export var zoom_speed: float = 300.0
@export var drag_button: int = 1
@export var drag_speed: float = 1.0
@export var pan_gesture_speed: float = 20.0
@export var zoom_interpolation_speed: float = 10.0
@export var edge_pan_rate: float = 0.6
@export var reference_size: float = 746496

# Programmatic camera emphasis (go_camera) smoothing
@export var go_duration_default: float = 0.55

var paused = false
var dragging = false
# Keep script initialization independent from native Camera2D property order.
var target_zoom: float = 1.0
var target_position = Vector2()
var acc = false
var move_intensity = 1.0
var zoom_move_vec = Vector2()
var drag_move_vec = Vector2()

var _last_disp = Vector2.ZERO

# --- go_camera state (ONLY affects programmatic emphasis moves) ---
var _go_active: bool = false
var _go_t: float = 0.0
var _go_duration: float = 0.55
var _go_from_pos: Vector2 = Vector2.ZERO
var _go_to_pos: Vector2 = Vector2.ZERO
var _go_from_zoom: float = 1.0
var _go_to_zoom: float = 1.0


func _enter_tree() -> void:
	if main:
		glob.main_cam = self
		glob.cam = self
		glob.viewport = get_viewport()


func _ready() -> void:
	IdleCamera.apply(self)
	var initial_zoom := _valid_zoom(zoom.x)
	zoom = Vector2.ONE * initial_zoom
	target_zoom = initial_zoom
	# The graph selector is global UI. SimulationCamera inherits this class, but
	# must not receive graph selector signals while its tab is hidden.
	if main and is_instance_valid(glob.selector_box) and not glob.selector_box.request_pan.is_connected(_on_selector_pan):
		glob.selector_box.request_pan.connect(_on_selector_pan)
	_last_disp = glob.get_display_mouse_position()


func _valid_zoom(value: float, fallback: float = 1.0) -> float:
	if is_nan(value) or is_inf(value) or is_zero_approx(value):
		value = fallback
	return clampf(absf(value), MIN_ZOOM, MAX_ZOOM)


func restore_view(saved_zoom: float, saved_position: Vector2) -> void:
	target_zoom = _valid_zoom(saved_zoom)
	target_position = saved_position
	zoom = Vector2.ONE * target_zoom
	position = target_position


func reset() -> void:
	target_position = position
	target_zoom = _valid_zoom(zoom.x)
	dragging = false
	acc = false
	zoom_move_vec = Vector2()
	drag_move_vec = Vector2()
	move_intensity = 1.0
	_go_active = false


func stop() -> void:
	paused = true
	drag_move_vec = Vector2()


func resume() -> void:
	paused = false


func _cancel_go_camera() -> void:
	_go_active = false


func _smoothstep(t: float) -> float:
	# 0..1 -> 0..1 (soft ease-in/out)
	return t * t * (3.0 - 2.0 * t)


func go_camera(new_zoom: float, new_center: Vector2, duration: float = -1.0) -> void:
	# Smooth programmatic emphasis move.
	# DOES NOT change how user-driven camera movement feels.
	if duration <= 0.0:
		duration = go_duration_default

	_go_active = true
	_go_t = 0.0
	_go_duration = max(0.01, duration)

	_go_from_pos = target_position
	_go_from_zoom = target_zoom

	_go_to_pos = new_center
	_go_to_zoom = _valid_zoom(new_zoom)


func change_cam(new_zoom: float, center: Vector2) -> void:
	# Wrapper used by your code; this is the programmatic emphasis.
	go_camera(new_zoom, center)


func _on_selector_pan(direction: Vector2) -> void:
	if paused or ui.active_splashed() or get_viewport().get_camera_2d() != self:
		return
	pan_for_selection_edge(direction)


func pan_for_selection_edge(direction: Vector2) -> void:
	# Selection is allowed to edge-pan even when ordinary mouse navigation is
	# temporarily disabled to keep the resize gesture from moving the camera.
	if ui.active_splashed():
		return

	# User-driven intent -> cancel emphasis move
	_cancel_go_camera()

	var dt = get_process_delta_time()

	var vp_size = get_viewport_rect().size
	var short_side_px = min(vp_size.x, vp_size.y)
	var pixels_this_frame = edge_pan_rate * short_side_px * dt * clamp(get_viewport_rect().get_area() / (reference_size) * 0.5, 0, 5)

	var px_delta = direction * pixels_this_frame

	var CT = get_viewport().get_canvas_transform()
	var center_screen = CT * (target_position)
	center_screen += px_delta
	target_position = CT.affine_inverse() * (center_screen)


func _handle_mouse_wrap(pos: Vector2) -> void:
	var begin = glob.space_begin
	var end = glob.space_end
	var new_pos = pos
	var wrapped = false

	if pos.x <= begin.x:
		new_pos.x = end.x - 2
		wrapped = true
	elif pos.x >= end.x - 1:
		new_pos.x = begin.x + 1
		wrapped = true

	if pos.y <= begin.y:
		new_pos.y = end.y - 2
		wrapped = true
	elif pos.y >= end.y - 1:
		new_pos.y = begin.y + 1
		wrapped = true

	if wrapped:
		get_viewport().warp_mouse(new_pos)
		_last_disp = new_pos


func _can_user_navigate() -> bool:
	return (
		not ui.active_splashed()
		and not ui.topr_inside
		and not paused
		and not glob.is_occupied(self, &"scroll")
		and glob.is_scroll_possible()
	)


func _can_user_drag_camera(event: InputEvent = null) -> bool:
	if ui.active_splashed() or ui.topr_inside or paused:
		return false
	if glob.is_occupied(self, &"scroll"):
		return false
	if glob.is_scroll_possible():
		return true
	var world_mouse := get_global_mouse_position() if is_inside_tree() else Vector2.ZERO
	var screen_mouse := get_viewport().get_mouse_position() if is_inside_tree() else Vector2.ZERO
	if event is InputEventMouse:
		screen_mouse = event.global_position
		if not is_inside_tree():
			world_mouse = screen_mouse
	for blocker in glob.scroll_imp:
		if is_instance_valid(blocker):
			if not blocker.is_inside_tree() or blocker.is_visible_in_tree():
				var rect: Rect2 = blocker.get_global_rect()
				if rect.has_point(world_mouse) or rect.has_point(screen_mouse):
					if blocker.get_meta("allow_camera_drag", false):
						return true
	return false


func _set_user_zoom(new_zoom: float) -> void:
	var previous_zoom := target_zoom
	target_zoom = clampf(new_zoom, MIN_ZOOM, MAX_ZOOM)
	if not is_equal_approx(target_zoom, previous_zoom):
		_cancel_go_camera()
		move_intensity = 1.0
		glob.hide_all_menus()


func apply_trackpad_pan(gesture_delta: Vector2) -> void:
	target_position += PlatformInput.trackpad_pan_offset(
		gesture_delta,
		target_zoom,
		pan_gesture_speed
	)


func _input(event: InputEvent) -> void:
	if event is InputEventPanGesture:
		if _can_user_navigate():
			_cancel_go_camera()
			apply_trackpad_pan(event.delta)
			glob.hide_all_menus()
			get_viewport().set_input_as_handled()
		return

	if event is InputEventMagnifyGesture:
		if _can_user_navigate():
			_set_user_zoom(target_zoom * maxf(event.factor, 0.01))
			get_viewport().set_input_as_handled()
		return

	if event is InputEventMouseButton:
		if event.button_index == drag_button:
			if not event.pressed:
				dragging = false
			elif _can_user_drag_camera(event):
				dragging = true
				acc = glob.get_display_mouse_position().x < glob.space_end.x
				_last_disp = glob.get_display_mouse_position()
				_cancel_go_camera()
			else:
				dragging = false
		elif _can_user_navigate() and event.pressed:
			var factor = zoom_speed * event.factor * zoom.x
			match event.button_index:
				MOUSE_BUTTON_WHEEL_DOWN:
					_set_user_zoom(zoom.x - factor)
				MOUSE_BUTTON_WHEEL_UP:
					_set_user_zoom(zoom.x + factor)


func _toroidal_delta(prev: Vector2, curr: Vector2) -> Vector2:
	var begin = glob.space_begin
	var end = glob.space_end
	var size = Vector2(end.x - begin.x, end.y - begin.y)

	var d = curr - prev
	if d.x > 0.5 * size.x:
		d.x -= size.x
	elif d.x < -0.5 * size.x:
		d.x += size.x

	if d.y > 0.5 * size.y:
		d.y -= size.y
	elif d.y < -0.5 * size.y:
		d.y += size.y

	return d


func mouse_range(pos: float, edge_start: float, edge_end: float, axis: int):
	var edge_min: float = -edge_start
	var edge_max: float = -edge_end
	match axis:
		glob.UP:
			edge_min = glob.space_begin.y - edge_min
			edge_max = glob.space_begin.y - edge_max
		glob.LEFT:
			edge_min = glob.space_begin.x - edge_min
			edge_max = glob.space_begin.x - edge_max
		glob.DOWN:
			edge_min += glob.space_end.y
			edge_max += glob.space_end.y
		glob.RIGHT:
			edge_min += glob.space_end.x
			edge_max += glob.space_end.x
	var t = inverse_lerp(edge_min, edge_max, pos)
	return clamp(t, 0.0, 1.0)


func _bbox_of(nodes) -> Rect2:
	var any = true
	var r = Rect2()
	for g in nodes:
		var gr = g.rect.get_global_rect() if g is Graph else graphs._graphs[g].rect.get_global_rect()
		if any:
			r = gr
			any = false
		else:
			r = r.merge(gr)
	return r


func emp_node(nodes) -> void:
	var bbox = _bbox_of(nodes)
	var center = bbox.position + bbox.size / 2.0
	var span = max(bbox.size.x, bbox.size.y)
	var z = clamp(800.0 / max(span, 100.0), 0.4, 4)
	change_cam(z, center)


var rise_mult = 0.0
var _last_view_scale := NAN
func _process(delta: float) -> void:
	# Keep every downstream transform and division inside the camera contract,
	# including malformed legacy project data and unusually long frames.
	target_zoom = _valid_zoom(target_zoom)
	if glob.mouse_middle_just_pressed and not paused:
		acc = glob.get_display_mouse_position().x < glob.space_end.x

	var mouse = get_global_mouse_position()

	if ui.active_splashed():
		# Splash owns this global while visible. Republish our value once it closes.
		_last_view_scale = NAN
	else:
		var view_scale := pow(zoom.x, 0.25)
		if view_scale != _last_view_scale:
			_last_view_scale = view_scale
			RenderingServer.global_shader_parameter_set("_view_scale", view_scale)

	# --- go_camera drives targets softly (only when active) ---
	if _go_active:
		_go_t += delta
		var u = clamp(_go_t / _go_duration, 0.0, 1.0)
		u = _smoothstep(u)
		target_position = _go_from_pos.lerp(_go_to_pos, u)
		target_zoom = lerp(_go_from_zoom, _go_to_zoom, u)
		if _go_t >= _go_duration:
			_go_active = false

	# Existing zoom smoothing (unchanged feel)
	var zoom_weight := clampf(delta * zoom_interpolation_speed, 0.0, 1.0) if glob.animations_enabled() else 1.0
	var next_zoom := _valid_zoom(lerp(zoom.x, target_zoom, zoom_weight), target_zoom)
	if absf(next_zoom - target_zoom) < 1e-5:
		next_zoom = target_zoom
	if next_zoom != zoom.x or zoom.x != zoom.y:
		zoom = Vector2.ONE * next_zoom
	move_intensity = lerp(move_intensity, 0.0, minf(1.0, delta * zoom_interpolation_speed)) if glob.animations_enabled() else 0.0

	if glob.mouse_scroll and not ui.active_splashed():
		zoom_move_vec = (mouse - get_global_mouse_position())

	if not paused:
		var display_mouse = glob.get_display_mouse_position()

		if dragging:
			glob.hide_all_menus.call_deferred()

		if dragging and not glob.mouse_pressed and acc and not ui.active_splashed():
			var d = _toroidal_delta(_last_disp, display_mouse)
			if d != Vector2.ZERO:
				var pixel_to_world = 1.0 / zoom.x
				target_position -= d * pixel_to_world * drag_speed
			_handle_mouse_wrap(display_mouse)
			_last_disp = glob.get_display_mouse_position()
		else:
			_last_disp = display_mouse

		rise_mult = min(
			mouse_range(display_mouse.x, 110, 50, glob.RIGHT) +
			mouse_range(display_mouse.x, 110, 50, glob.LEFT) +
			mouse_range(display_mouse.y, 30, -30, glob.UP) +
			mouse_range(display_mouse.y, 30, -30, glob.DOWN),
			1.0
		) if not glob.is_occupied(self, &"scroll") else 0.0

		if (graphs.dragged or graphs.conning()) and glob.mouse_pressed and rise_mult and not ui.topr_inside:
			var dir = glob.window_middle.direction_to(display_mouse)
			var target_drag = 1000 * delta * dir * rise_mult / min(1.5, zoom.x * 1.5)
			drag_move_vec = drag_move_vec.lerp(
				target_drag,
				delta * 10.0
			) if glob.animations_enabled() else target_drag
			glob.hide_all_menus.call_deferred()
		else:
			drag_move_vec = drag_move_vec.lerp(Vector2(), minf(1.0, delta * 10.0)) if glob.animations_enabled() else Vector2()

		target_position += drag_move_vec

	target_position += zoom_move_vec * move_intensity

	# Existing position smoothing (unchanged feel)
	var pos_weight = minf(1.0, 20.0 * delta) if glob.animations_enabled() else 1.0
	var next_position := position.lerp(target_position, pos_weight)
	if next_position.distance_squared_to(target_position) < 1e-8:
		next_position = target_position
	if next_position != position:
		position = next_position
