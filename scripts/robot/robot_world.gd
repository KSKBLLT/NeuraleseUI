class_name RobotWorld
extends Control
## The robot seen from above, facing right, with the camera tipped a little
## towards its right side so it reads as a solid object: the drawing of its kind
## of robot (EV3, SPIKE Prime; the hand-drawn micro:bit from straight above),
## rendered from the real parts (tools/robot_art/build_robot_art.py).
##
## The child drags distance sensors from the parts palette onto the free spots
## around the robot; a sensor faces outward from its spot and shows a live beam
## as long as what it measures. During the wheel check both wheels light up and
## the child presses the one that turned. While driving, the beams and the
## wheels' arrows show what the robot reads and does.
##
## Robot coordinates are centimetres, x forward (right on screen), y to the
## robot's left (up on screen), h up from the floor (see to_screen). Handles are
## drawn like the simulation's transform gizmo (simulation_transform_gizmo.gd).

signal changed                                   # sensors were put, moved or removed
signal wheel_picked(side: String)

const HANDLE_COLOR := Color("65d8dc")
const HANDLE_FILL := Color("111419")
const HANDLE_RADIUS := 7.0
const HANDLE_HIT_RADIUS := 13.0
## Brain Mapping status colours.
const OK_COLOR := Color("77dfa2")
const CLOSE_COLOR := Color("ef795f")
const NO_ECHO_MM := 2550
## Spots for sensors and the way a sensor on each one faces, in degrees (0 ahead,
## 90 to the left). Where a spot is depends on the drawing: see spot_pose.
const SPOTS := {
	"front": 0.0,
	"front_left": 45.0,
	"front_right": -45.0,
	"left": 90.0,
	"right": -90.0,
	"back_left": 135.0,
	"back_right": -135.0,
	"back": 180.0,
}
## Sensors are drawn smaller than life, so three in a row stay apart.
const SENSOR_SCALE := 0.55
## Room left between a sensor and what is next to it, in centimetres.
const SPOT_GAP_CM := 0.6

var platform := "ev3_direct"
var mode := "build":                # "build" | "wheels" | "drive"
	set(value):
		mode = value
		queue_redraw()
## port -> {"spot", "angle_deg", "x_cm", "y_cm"} (the IR's sensor pose plus its spot)
var sensors: Dictionary = {}
## side -> [motor ports] found by the wheel check
var wheels: Dictionary = {}:
	set(value):
		wheels = value
		queue_redraw()
var live: Dictionary = {}           # port -> millimetres
var reach_cm := 60.0                # how far a ray reaches (from the robot's length)
var drive_powers := [0.0, 0.0]      # left, right, -100..100
var drag_kind := ""                 # what the palette is dragging
## The wheel picked in the wheel check, lit until its direction is answered.
var picked_side := "":
	set(value):
		picked_side = value
		queue_redraw()
var selected := ""

var _dragging := ""                 # port being moved
var _drag_point := Vector2.ZERO
var _time := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	resized.connect(queue_redraw)


func _process(delta: float) -> void:
	_time += delta
	if mode != "build" or not drag_kind.is_empty() or not _dragging.is_empty():
		queue_redraw()


# -- geometry ----------------------------------------------------------------------------

func _base() -> Dictionary:
	return RobotArtData.base(platform)


func length_cm() -> float:
	return float(_base().get("length_cm", 14.0))


func width_cm() -> float:
	return float(_base().get("width_cm", 12.0))


## How far the camera is tipped towards the robot's right side, in radians: the
## drawing's own tilt (0 for a robot drawn only from above).
func _tilt() -> float:
	return deg_to_rad(RobotArtData.tilt_deg(platform))


## How high above the floor the sensors are drawn (where the camera is tilted).
func _sensor_height_cm() -> float:
	return 0.0 if is_zero_approx(_tilt()) else float(_base().get("sensor_height_cm", 0.0))


## Screen pixels per centimetre: the robot's picture fills most of the height,
## with room in front of it for the beams.
func _k() -> float:
	var view := RobotArtData.view_texture(platform)
	var picture := Vector2(view.get_size()) / RobotArtData.px_per_cm() if view != null else Vector2(length_cm(), width_cm())
	var by_height := size.y * 0.64 / maxf(picture.y, 1.0)
	var by_width := size.x * 0.42 / maxf(picture.x, 1.0)
	return maxf(minf(by_height, by_width), 1.0)


func _center() -> Vector2:
	return Vector2(size.x * 0.36, size.y * 0.53)


## A point of the robot on screen: x forward, y to its left, h up, in centimetres,
## seen from above with the camera tipped towards the robot's right side.
func to_screen(x_cm: float, y_cm: float, h_cm: float = 0.0) -> Vector2:
	var tilt := _tilt()
	return _center() + Vector2(x_cm, -y_cm * cos(tilt) - h_cm * sin(tilt)) * _k()


## A direction on the floor (degrees to the left of ahead) as it looks on screen.
func direction(angle_deg: float) -> Vector2:
	var a := deg_to_rad(angle_deg)
	return Vector2(cos(a), -sin(a) * cos(_tilt())).normalized()


## How long one centimetre on the floor in that direction looks, in centimetres.
func _floor_stretch(angle_deg: float) -> float:
	var a := deg_to_rad(angle_deg)
	return Vector2(cos(a), sin(a) * cos(_tilt())).length()


func spot_pose(spot: String) -> Dictionary:
	var at := _spot_cm(spot)
	return {
		"spot": spot,
		"angle_deg": float(SPOTS[spot]),
		"x_cm": snappedf(at.x, 0.1),
		"y_cm": snappedf(at.y, 0.1),
	}


## A sensor's size on the drawing, in centimetres: x along the way it faces.
func sensor_size_cm() -> Vector2:
	var texture := RobotArtData.sensor_texture(platform, false)
	if texture == null:
		return Vector2(2.7, 3.2)
	return texture.get_size() / RobotArtData.px_per_cm() * SENSOR_SCALE


## A wheel's rectangle on the drawing, in centimetres (x forward, y left).
func _wheel_cm(side: String) -> Rect2:
	var info: Dictionary = _base().get("wheels", {}).get(side, {})
	if info.is_empty():
		return Rect2()
	var ppc := RobotArtData.px_per_cm()
	var center_px: Array = info["center_px"]
	var size_px: Array = info["size_px"]
	var image_center: Array = _base().get("center_px", [0, 0])
	var middle := Vector2(float(center_px[0]) - float(image_center[0]), -(float(center_px[1]) - float(image_center[1]))) / ppc
	var extent := Vector2(float(size_px[0]), float(size_px[1])) / ppc
	return Rect2(middle - extent * 0.5, extent)


## Where a spot is, worked out from the drawing so no sensor covers a wheel or
## another sensor: in front, at the front corners, on the sides behind the
## wheels (beside the wheels when they leave no room), at the back corners and
## behind. Left and right mirror each other.
func _spot_cm(spot: String) -> Vector2:
	var half := length_cm() * 0.5
	var sensor := sensor_size_cm()
	var reach := sensor.length() * 0.5          # a turned sensor's half size
	var wheel := _wheel_cm("left")
	var has_wheel := wheel.size != Vector2.ZERO
	var wheel_front := wheel.end.x if has_wheel else 0.0
	var wheel_back := wheel.position.x if has_wheel else 0.0
	var wheel_inner := wheel.position.y if has_wheel else width_cm() * 0.4
	var corner_y := sensor.y + SPOT_GAP_CM * 2.0
	var side := 1.0 if spot.ends_with("left") else -1.0
	match spot:
		"front":
			return Vector2(half + sensor.x * 0.5 + SPOT_GAP_CM, 0.0)
		"back":
			return Vector2(-half - sensor.x * 0.5 - SPOT_GAP_CM, 0.0)
		"front_left", "front_right":
			return Vector2(maxf(half + sensor.x * 0.5, wheel_front + reach + SPOT_GAP_CM * 0.5), corner_y * side)
		"back_left", "back_right":
			return Vector2(-maxf(half + sensor.x * 0.5, -wheel_back + reach + SPOT_GAP_CM * 0.5), corner_y * side)
	# The sides: behind the wheel if there is room for a sensor there, else beside it.
	var room := wheel_back + half
	if not has_wheel or room >= sensor.y + SPOT_GAP_CM * 2.0:
		return Vector2((wheel_back - half) * 0.5, (wheel_inner + sensor.x * 0.5 + SPOT_GAP_CM * 0.3) * side)
	return Vector2(wheel.get_center().x, (wheel.end.y + sensor.x * 0.5 + SPOT_GAP_CM) * side)


func _spot_point(spot: String) -> Vector2:
	var pose := spot_pose(spot)
	return to_screen(pose["x_cm"], pose["y_cm"], _sensor_height_cm())


func _spot_taken(spot: String, except_port: String = "") -> bool:
	for port in sensors:
		if port != except_port and str(sensors[port].get("spot", "")) == spot:
			return true
	return false


## The free spot nearest to a point; none if every spot is farther than ``limit``
## pixels (a sensor dragged away from the robot is taken off).
func _nearest_free_spot(point: Vector2, port: String, limit: float = 60.0) -> String:
	var best := ""
	var best_distance := limit
	for spot in SPOTS:
		if _spot_taken(spot, port):
			continue
		var distance := point.distance_to(_spot_point(spot))
		if distance < best_distance:
			best = spot
			best_distance = distance
	return best


## The wheel on screen: everything it covers, from the floor to its top.
func _wheel_rect(side: String) -> Rect2:
	var wheel := _wheel_cm(side)
	if wheel.size == Vector2.ZERO:
		return Rect2()
	var height := float(_base().get("wheel_diameter_cm", 5.6))
	var box := Rect2(to_screen(wheel.position.x, wheel.position.y), Vector2.ZERO)
	for x in [wheel.position.x, wheel.end.x]:
		for y in [wheel.position.y, wheel.end.y]:
			for h in [0.0, height]:
				box = box.expand(to_screen(x, y, h))
	return box


## A wheel is pressed anywhere on it, or a little around it (then the nearer
## one: on a small drawing the margins of the two wheels overlap).
func _wheel_at(point: Vector2) -> String:
	var nearest := ""
	var nearest_distance := INF
	for side in ["left", "right"]:
		var rect := _wheel_rect(side)
		if rect.size == Vector2.ZERO:
			continue
		if rect.has_point(point):
			return side
		var distance := point.distance_to(rect.get_center())
		if rect.grow(10.0).has_point(point) and distance < nearest_distance:
			nearest = side
			nearest_distance = distance
	return nearest


# -- the drawing as data -----------------------------------------------------------------

func load_geometry(geometry: Dictionary) -> void:
	sensors = {}
	var saved: Variant = geometry.get("sensors")
	if saved is Dictionary:
		for port in saved:
			var pose: Dictionary = saved[port]
			var spot := str(pose.get("spot", ""))
			if not SPOTS.has(spot):
				spot = _spot_for_angle(float(pose.get("angle_deg", 0.0)))
			if not spot.is_empty() and not _spot_taken(spot):
				sensors[str(port)] = spot_pose(spot)
	queue_redraw()


func _spot_for_angle(angle: float) -> String:
	var best := ""
	var best_difference := 30.0
	for spot in SPOTS:
		var difference := absf(wrapf(angle - float(SPOTS[spot]), -180.0, 180.0))
		if difference < best_difference:
			best = spot
			best_difference = difference
	return best


func sensors_geometry() -> Dictionary:
	var result := {}
	for port in sensors:
		result[port] = sensors[port].duplicate()
	return result


func put_sensor(port: String, spot: String) -> void:
	if spot.is_empty():
		remove_sensor(port)
		return
	sensors[port] = spot_pose(spot)
	selected = port
	changed.emit()
	queue_redraw()


## A sensor put without a place (a click in the palette): the first free spot, front first.
func put_sensor_default(port: String) -> void:
	for spot in ["front", "front_left", "front_right", "left", "right", "back_left", "back_right", "back"]:
		if not _spot_taken(spot, port):
			put_sensor(port, spot)
			return


func remove_sensor(port: String) -> void:
	if sensors.erase(port):
		if selected == port:
			selected = ""
		changed.emit()
		queue_redraw()


# -- dragging from the palette ---------------------------------------------------------------

func _can_drop_data(at_position: Vector2, data: Variant) -> bool:
	if not data is Dictionary or not data.has("robot_part"):
		return false
	drag_kind = str(data["robot_part"].get("kind", ""))
	_drag_point = at_position
	return drag_kind == "sensor"


func _drop_data(at_position: Vector2, data: Variant) -> void:
	var port := str(data["robot_part"]["port"])
	drag_kind = ""
	put_sensor(port, _nearest_free_spot(at_position, port, INF))


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		drag_kind = ""
		queue_redraw()
	elif what == NOTIFICATION_MOUSE_EXIT and not drag_kind.is_empty():
		_drag_point = Vector2(-1e5, -1e5)
		queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_press(event.position)
		elif not _dragging.is_empty():
			var port := _dragging
			_dragging = ""
			put_sensor(port, _nearest_free_spot(event.position, port))
		accept_event()
	elif event is InputEventMouseMotion and not _dragging.is_empty():
		_drag_point = event.position
		queue_redraw()
		accept_event()


func _press(point: Vector2) -> void:
	if mode == "wheels":
		var side := _wheel_at(point)
		if not side.is_empty() and picked_side.is_empty():
			wheel_picked.emit(side)
		return
	if mode != "build":
		return
	for port in sensors:
		var pose: Dictionary = sensors[port]
		var at := to_screen(pose["x_cm"], pose["y_cm"], _sensor_height_cm())
		var badge := _badge_point(at, float(pose["angle_deg"]), _port_label(port))
		if point.distance_to(at) <= HANDLE_HIT_RADIUS + 6.0 or point.distance_to(badge) <= HANDLE_HIT_RADIUS:
			selected = port
			_dragging = port
			_drag_point = point
			queue_redraw()
			return
	selected = ""
	queue_redraw()


# -- drawing -------------------------------------------------------------------------------------

func _draw() -> void:
	var tint := RobotArtData.tint()
	_draw_anchored(RobotArtData.view_texture(platform), RobotArtData.view_origin_px(platform), to_screen(0.0, 0.0), tint)
	var carrying := mode == "build" and (drag_kind == "sensor" or not _dragging.is_empty())
	var target := ""
	if carrying:
		target = _nearest_free_spot(_drag_point, _dragging, 60.0 if not _dragging.is_empty() else INF)
		# Where a sensor can go: a faint sensor on every free spot, a clear one
		# on the spot it would land on.
		for spot in SPOTS:
			if not _spot_taken(spot, _dragging):
				_draw_sensor_shape(_spot_point(spot), float(SPOTS[spot]), Color(tint, 0.6 if spot == target else 0.16))
	for port in sensors:
		if port != _dragging:
			_draw_sensor(port, tint)
	if not _dragging.is_empty():
		var angle := float(SPOTS[target]) if not target.is_empty() else float(sensors[_dragging]["angle_deg"])
		_draw_sensor_shape(_drag_point, angle, Color(tint, 0.9))
		_draw_badge(_badge_point(_drag_point, angle, _port_label(_dragging)), _port_label(_dragging), true)
	_draw_wheels()


func _draw_texture_at(texture: Texture2D, at: Vector2, angle: float, tint: Color, scale_k: float = 1.0) -> void:
	if texture == null:
		return
	var scale := _k() / RobotArtData.px_per_cm() * scale_k
	draw_set_transform(at, angle, Vector2(scale, scale))
	draw_texture(texture, -texture.get_size() * 0.5, tint)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## A picture whose given pixel lands on a point of the screen, at the drawing's scale.
func _draw_anchored(texture: Texture2D, anchor_px: Vector2, at: Vector2, tint: Color, scale_k: float = 1.0) -> void:
	if texture == null:
		return
	var scale := _k() / RobotArtData.px_per_cm() * scale_k
	draw_set_transform(at - anchor_px * scale, 0.0, Vector2(scale, scale))
	draw_texture(texture, Vector2.ZERO, tint)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


## A placed sensor: its picture facing out, its beam along the floor from its
## front (as long as the reading, up to how far the network's rays reach), and
## its port number on the beam just in front of it, clear of the picture.
func _draw_sensor(port: String, tint: Color) -> void:
	var pose: Dictionary = sensors[port]
	var angle := float(pose["angle_deg"])
	var height := _sensor_height_cm()
	var way := Vector2.RIGHT.rotated(deg_to_rad(angle))          # on the floor, y to the left
	var ground := Vector2(pose["x_cm"], pose["y_cm"])
	var front_cm := ground + way * sensor_size_cm().x * 0.5
	var at := to_screen(ground.x, ground.y, height)
	var front := to_screen(front_cm.x, front_cm.y, height)
	var far := ground + way * maxf(reach_cm, sensor_size_cm().x * 0.5)
	draw_line(front, to_screen(far.x, far.y, height), Color(HANDLE_COLOR, 0.18), 1.0, true)
	if live.has(port):
		var millimetres := float(live[port])
		if millimetres < NO_ECHO_MM:
			var hit := front_cm + way * minf(millimetres / 10.0, reach_cm)
			var end := to_screen(hit.x, hit.y, height)
			var close := millimetres / 10.0 < reach_cm * 0.3
			draw_line(front, end, Color(CLOSE_COLOR if close else HANDLE_COLOR, 0.9), 2.5, true)
			draw_circle(end, 3.0, CLOSE_COLOR if close else HANDLE_COLOR)
	_draw_sensor_shape(at, angle, tint)
	_draw_badge(_badge_point(at, angle, _port_label(port)), _port_label(port), port == selected)


## A sensor facing angle_deg, its centre at a point: seen by the drawing's
## camera where the robot is tilted, else its top view turned that way.
func _draw_sensor_shape(at: Vector2, angle_deg: float, tint: Color) -> void:
	var view := RobotArtData.sensor_view(platform, angle_deg)
	if view.is_empty():
		_draw_texture_at(RobotArtData.sensor_texture(platform, false), at, direction(angle_deg).angle(), tint, SENSOR_SCALE)
	else:
		_draw_anchored(view["texture"], view["anchor"], at, tint, SENSOR_SCALE)


## A sensor's port number sits just in front of it, on its beam.
func _badge_point(at: Vector2, angle_deg: float, text: String) -> Vector2:
	var gap := sensor_size_cm().x * 0.5 * _k() * _floor_stretch(angle_deg) + _badge_radius(text) + 3.0
	return at + direction(angle_deg) * gap


func _draw_wheels() -> void:
	for side in ["left", "right"]:
		var rect := _wheel_rect(side)
		if rect.size == Vector2.ZERO:
			continue
		if mode == "wheels":
			# Both wheels pulse until one is picked; then only that one, steady.
			if picked_side.is_empty():
				var pulse := 0.55 + 0.45 * sin(_time * 5.0)
				draw_rect(rect.grow(5.0), Color(HANDLE_COLOR, pulse), false, 2.5)
			elif picked_side == side:
				draw_rect(rect.grow(5.0), OK_COLOR, false, 3.0)
		var ports: Array = wheels.get(side, [])
		if not ports.is_empty() and mode != "wheels":
			var labels := ports.map(func(p): return _port_label(str(p)))
			var outward := -1.0 if side == "left" else 1.0
			_draw_badge(Vector2(rect.get_center().x, (rect.position.y if side == "left" else rect.end.y) + outward * 14.0 * _badge_scale()), "".join(labels))
		if mode == "drive":
			var power := float(drive_powers[0 if side == "left" else 1]) / 100.0
			if absf(power) > 0.02:
				var middle := rect.get_center()
				var tip := middle + Vector2.RIGHT * rect.size.x * 0.6 * clampf(power, -1.0, 1.0)
				draw_line(middle, tip, OK_COLOR, 3.0, true)
				var back := (middle - tip).normalized() * 7.0
				draw_line(tip, tip + back.rotated(0.5), OK_COLOR, 3.0, true)
				draw_line(tip, tip + back.rotated(-0.5), OK_COLOR, 3.0, true)


## Port badges shrink with the drawing, so a small window does not bury the robot under them.
func _badge_scale() -> float:
	return clampf(_k() / 9.0, 0.6, 1.0)


func _badge_radius(text: String) -> float:
	return maxf(10.0, 5.0 + 4.0 * text.length()) * _badge_scale()


func _draw_badge(at: Vector2, text: String, strong: bool = false) -> void:
	var k := _badge_scale()
	var radius := _badge_radius(text)
	draw_circle(at, radius, HANDLE_FILL)
	draw_circle(at, radius, HANDLE_COLOR, false, 2.5 if strong else 1.5, true)
	var font := get_theme_default_font()
	var font_size := int(round(13.0 * k))
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x
	draw_string(font, at + Vector2(-width * 0.5, font_size * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color.WHITE)


## "in2" -> "2", "outB" -> "B": the names printed next to the ports on the brick.
static func _port_label(port: String) -> String:
	if port.begins_with("in"):
		return port.substr(2)
	if port.begins_with("out"):
		return port.substr(3)
	return port
