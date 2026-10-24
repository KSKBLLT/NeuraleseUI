class_name RobotField
extends Control
## The training world, shrunk to the robot's size: where to put the robot and
## where the goal is in the room.
##
## Shown only when the network sees its place in the world or a goal. The world
## comes from the dataset (SimulationCompiler.training_world). One simulation
## unit is ``cm_per_unit`` centimetres, the rover's length over the robot's.
## The child may drag the start and the goal to fit the room; while the robot
## drives, its estimated position is drawn as a trail.

signal changed

const HANDLE_COLOR := Color("65d8dc")
const HANDLE_FILL := Color("111419")
const GOAL_COLOR := Color("76d49b")         # registry accent of the goal sensors
const FLAG := preload("res://game_assets/icons/flag.png")

var world: Dictionary = {}                  # bounds, agent_start, goal (units)
var cm_per_unit := 0.25
var platform := "ev3_direct"
var start := Vector3.ZERO                   # x, y (units), heading (radians)
var goal := Vector2.ZERO
var has_goal := false
var trail := PackedVector2Array()           # estimated positions while driving (units)
var editable := true

var _dragging := ""


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	resized.connect(queue_redraw)


func load_world(new_world: Dictionary, scale_cm_per_unit: float, saved: Dictionary = {}) -> void:
	world = new_world
	cm_per_unit = scale_cm_per_unit
	var s: Variant = saved.get("start", world.get("agent_start"))
	start = Vector3(float(s[0]), float(s[1]), float(s[2])) if s is Array and s.size() >= 3 else Vector3.ZERO
	var g: Variant = saved.get("goal", world.get("goal"))
	has_goal = g is Array and g.size() >= 2
	goal = Vector2(float(g[0]), float(g[1])) if has_goal else Vector2.ZERO
	trail = PackedVector2Array()
	queue_redraw()


func bounds() -> Rect2:
	var b: Variant = world.get("bounds", [-480, -260, 960, 520])
	return Rect2(float(b[0]), float(b[1]), float(b[2]), float(b[3]))


## Size of the field in the room, in metres.
func size_m() -> Vector2:
	return bounds().size * cm_per_unit / 100.0


## The goal from the start, in the robot's terms: metres ahead and to the right.
func goal_from_start_m() -> Vector2:
	var delta := (goal - Vector2(start.x, start.y)).rotated(-start.z)
	return delta * cm_per_unit / 100.0


func to_saved() -> Dictionary:
	var result := {"start": [start.x, start.y, start.z]}
	if has_goal:
		result["goal"] = [goal.x, goal.y]
	return result


func _transform() -> Array:
	var rect := bounds()
	var margin := 18.0
	var k := minf((size.x - margin * 2.0) / rect.size.x, (size.y - margin * 2.0 - 22.0) / rect.size.y)
	var origin := Vector2((size.x - rect.size.x * k) * 0.5, margin) - rect.position * k
	return [k, origin]


func _to_screen(point: Vector2) -> Vector2:
	var t := _transform()
	return t[1] + point * float(t[0])


func _from_screen(point: Vector2) -> Vector2:
	var t := _transform()
	return (point - t[1]) / float(t[0])


func _gui_input(event: InputEvent) -> void:
	if not editable:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			if has_goal and event.position.distance_to(_to_screen(goal)) < 22.0:
				_dragging = "goal"
			elif event.position.distance_to(_to_screen(Vector2(start.x, start.y))) < 26.0:
				_dragging = "start"
		elif not _dragging.is_empty():
			_dragging = ""
			changed.emit()
		accept_event()
	elif event is InputEventMouseMotion and not _dragging.is_empty():
		var rect := bounds()
		var point := _from_screen(event.position)
		point = Vector2(clampf(point.x, rect.position.x, rect.end.x), clampf(point.y, rect.position.y, rect.end.y))
		if _dragging == "goal":
			goal = point
		else:
			start = Vector3(point.x, point.y, start.z)
		queue_redraw()
		accept_event()


func _draw() -> void:
	var rect := bounds()
	var top_left := _to_screen(rect.position)
	var bottom_right := _to_screen(rect.end)
	var field := Rect2(top_left, bottom_right - top_left)
	draw_rect(field, Color(1.0, 1.0, 1.0, 0.04))
	draw_rect(field, Color(HANDLE_COLOR, 0.5), false, 1.5)
	# A line every 50 cm, so distances in the room can be read off.
	var step_units := 50.0 / maxf(cm_per_unit, 0.001)
	var x := rect.position.x + step_units
	while x < rect.end.x:
		draw_line(_to_screen(Vector2(x, rect.position.y)), _to_screen(Vector2(x, rect.end.y)), Color(1, 1, 1, 0.06), 1.0)
		x += step_units
	var y := rect.position.y + step_units
	while y < rect.end.y:
		draw_line(_to_screen(Vector2(rect.position.x, y)), _to_screen(Vector2(rect.end.x, y)), Color(1, 1, 1, 0.06), 1.0)
		y += step_units
	var font := get_theme_default_font()
	var metres := size_m()
	var caption := "%s × %s" % [RobotPanel.decimal(metres.x), RobotPanel.metres(metres.y)]
	draw_string(font, Vector2(field.position.x, field.end.y + 18.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color(0.72, 0.74, 0.79))
	if trail.size() > 1:
		var points := PackedVector2Array()
		for p in trail:
			points.append(_to_screen(p))
		draw_polyline(points, Color(HANDLE_COLOR, 0.8), 2.0, true)
	if has_goal:
		var at := _to_screen(goal)
		draw_circle(at, 12.0, HANDLE_FILL)
		draw_circle(at, 12.0, GOAL_COLOR, false, 2.0, true)
		draw_texture_rect(FLAG, Rect2(at - Vector2(8, 8), Vector2(16, 16)), false, GOAL_COLOR)
	# The robot at its start, as long as it is in the room.
	var base := RobotArtData.base(platform)
	var texture := RobotArtData.texture(str(base.get("image", "ev3_base_top.png")))
	var k := float(_transform()[0])
	var robot_px := float(base.get("length_cm", 14.0)) / maxf(cm_per_unit, 0.001) * k
	var scale := maxf(robot_px, 18.0) / maxf(texture.get_size().x, 1.0)
	var at_start := _to_screen(Vector2(start.x, start.y))
	draw_set_transform(at_start, start.z, Vector2(scale, scale))
	draw_texture(texture, -texture.get_size() * 0.5, RobotArtData.tint())
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	if editable:
		draw_circle(at_start, 24.0, Color(HANDLE_COLOR, 0.55), false, 1.5, true)
