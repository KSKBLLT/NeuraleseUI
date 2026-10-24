class_name RobotLidarView
extends Control
## The room as the robot's sensors see it while it drives: a lidar seen from
## above and to one side, the camera slowly circling the robot (the lidar
## mockup's style B, prototypes/lidar). Range rings coloured by distance run
## along the floor up to the first wall and climb it as scan lines; the walls
## the map remembers stay as faint dotted lines, the floor it has seen as faint
## dots; the robot is an orange wireframe with its sensors' cones. In a corner,
## each sensor's reading as a bar.
##
## Two looks, by the graphics setting. Pretty (High, Medium): all of the above,
## 540 directions. Simple (Low, for slow computers): 180 directions, no faint
## floor dots, the robot without its glow.
##
## Built for slow computers either way: the map (RobotLidarMap) is updated from
## the run's telemetry on a worker thread, so a rebuild never holds up a frame;
## every point is a single vertex placed on the GPU from small data textures
## (shaders/robot_lidar_points.gdshader), and per frame the CPU only casts one
## ray per direction against the few walls near the robot.
##
## World units are metres and radians, counter-clockwise, z up; see start() and
## add_frame() for what the panel gives it.

const POINTS_SHADER := preload("res://shaders/robot_lidar_points.gdshader")
const WALLS_SHADER := preload("res://shaders/robot_lidar_walls.gdshader")
const FLOOR_SHADER := preload("res://shaders/robot_lidar_floor.gdshader")

const SCAN_R := 4.0                 # how far the rings reach, metres
const PRETTY_DIRECTIONS := 540
const SIMPLE_DIRECTIONS := 180
## Points per direction (robot_lidar_points.gdshader): 12 near rings, 14 far
## rings every other direction, 6 beams up a wall.
const POINTS_PER_DIRECTION := 12 + 7 + 6
const MAX_WALLS := 256
const MAX_SPARKS := 512
const MAX_TRAIL := 2048
const TRAIL_STEP := 0.03            # a trail point every 3 cm
const REBUILD_S := 0.6              # walls are rebuilt every 0.6 s of the run
const UPDATE_S := 1.0 / 30.0        # the scan and the walls' easing, at most 30 times a second
const KNOWN_UPLOAD_S := 0.2         # the seen floor goes to the GPU at most 5 times a second
const MAP_HALF := 10.0              # the map covers 20 x 20 m around the start
const NO_ECHO := RobotLidarMap.NO_ECHO_M
## Rounded like the app's panels (scenes/splash.tres).
const CORNER_RADIUS := 14.0
const ROBOT_COLOR := Color(1.0, 140.0 / 255.0, 40.0 / 255.0)
const CONE_COLOR := Color(1.0, 150.0 / 255.0, 60.0 / 255.0, 0.06)
const HUD_BACK := Color(0.0, 0.0, 0.0, 0.5)
const HUD_TITLE := Color(220.0 / 255.0, 230.0 / 255.0, 250.0 / 255.0, 0.8)
const HUD_LABEL := Color(160.0 / 255.0, 170.0 / 255.0, 195.0 / 255.0, 0.8)
const HUD_GLITCH := Color(150.0 / 255.0, 150.0 / 255.0, 170.0 / 255.0, 0.7)
const HUD_EMPTY := Color(1.0, 1.0, 1.0, 0.08)
## The rings' colours by distance (as robot_lidar.gdshaderinc).
const RAMP_D := [0.0, 0.5, 1.1, 1.8, 2.7, 4.0]
const RAMP_C := [Color8(255, 80, 30), Color8(255, 176, 20), Color8(140, 255, 60), Color8(30, 230, 190), Color8(30, 130, 255), Color8(70, 40, 255)]


## A piece of wall as drawn: it eases towards the map's piece of the same wall,
## grows out of its middle when new, and fades when the map drops it.
class Shown extends RefCounted:
	var x1 := 0.0
	var y1 := 0.0
	var x2 := 0.0
	var y2 := 0.0
	var wall := 0
	var alpha := 0.0
	var dying := false

	func copy() -> Shown:
		var s := Shown.new()
		s.x1 = x1
		s.y1 = y1
		s.x2 = x2
		s.y2 = y2
		s.wall = wall
		s.alpha = alpha
		s.dying = dying
		return s


var _floor: ColorRect
var _walls: MultiMeshInstance2D
var _points: MultiMeshInstance2D
var _overlay: Control
var _hud: Control
var _floor_material: ShaderMaterial
var _walls_material: ShaderMaterial
var _points_material: ShaderMaterial
var _pretty := true
var _az := PRETTY_DIRECTIONS
var _cos := PackedFloat64Array()
var _sin := PackedFloat64Array()

# The map lives on the worker while a task runs; the view only reads what the
# task wrote into _result once it is done.
var _map: RobotLidarMap = null
var _pending: Array = []
var _task := -1
var _result := {}
var _next_rebuild := 0.0

var _sensors: Array = []            # [{"angle", "x", "y", "label"}] in the order of a frame's ranges
var _half_length := 0.12
var _half_width := 0.08
var _pieces := PackedFloat64Array() # the map's pieces: x1, y1, x2, y2, wall
var _cuts: Array[PackedFloat64Array] = []
var _blobs := PackedFloat64Array()  # x, y of each blob cell
var _shown: Array[Shown] = []
var _raw := PackedFloat64Array()    # the last ranges, metres
var _filtered := PackedFloat64Array()   # the map's readings: a distance, -1 no echo, NAN ignored
var _cone := PackedFloat64Array()   # how long each sensor's cone is drawn
var _target := PackedFloat64Array([0.0, 0.0, 0.0])   # the last pose
var _robot := PackedFloat64Array([0.0, 0.0, 0.0])    # the pose drawn, gliding to it
var _have_pose := false
var _trail_count := 0
var _trail_last := Vector2(INF, INF)
var _cam_target := Vector2.ZERO
var _clock := 0.0
var _since_update := INF
var _known_due := 0.0
var _known_bytes := PackedByteArray()   # the newest seen floor, not uploaded yet

## Per direction: distance, kind (0 none, 1 wall, 3 blob), how grown, 0; the
## scan texture's data as it is, and what each scan starts from.
var _scan_data := PackedFloat32Array()
var _scan_blank := PackedFloat32Array()
var _scan_image: Image
var _scan_texture: ImageTexture
var _wall_image: Image
var _wall_texture: ImageTexture
var _spark_image: Image
var _spark_texture: ImageTexture
var _trail_image: Image
var _trail_texture: ImageTexture
var _known_image: Image
var _known_texture: ImageTexture

# The camera of this frame (see _update_camera), for drawing the robot.
var _cam_pos := Vector3.ZERO
var _cam_f := Vector3.FORWARD
var _cam_r := Vector3.RIGHT
var _cam_u := Vector3.UP
var _focal := 400.0


func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_floor = ColorRect.new()
	_floor.name = "Floor"
	_floor.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_floor_material = ShaderMaterial.new()
	_floor_material.shader = FLOOR_SHADER
	_floor.material = _floor_material
	add_child(_floor)
	_walls = MultiMeshInstance2D.new()
	_walls.name = "Walls"
	_walls_material = ShaderMaterial.new()
	_walls_material.shader = WALLS_SHADER
	_walls.material = _walls_material
	add_child(_walls)
	_points = MultiMeshInstance2D.new()
	_points.name = "Points"
	_points_material = ShaderMaterial.new()
	_points_material.shader = POINTS_SHADER
	_points.material = _points_material
	add_child(_points)
	# The robot and its cones add light, as the points do (tutorial_radial_highlight.gd).
	_overlay = Control.new()
	_overlay.name = "Robot"
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_overlay.material = additive
	_overlay.draw.connect(_draw_robot)
	add_child(_overlay)
	_hud = Control.new()
	_hud.name = "Sensors"
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.draw.connect(_draw_hud)
	add_child(_hud)
	resized.connect(_layout)
	_setup_points()
	_layout()


func _layout() -> void:
	for child in [_floor, _overlay, _hud]:
		child.position = Vector2.ZERO
		child.size = size


func _exit_tree() -> void:
	finish()


# -- the run ----------------------------------------------------------------------------

## A new run. sensors: one dictionary per sensor in the order add_frame's
## ranges come in, {"angle": radians to the left of ahead, "x", "y": metres
## from the robot's middle (x ahead, y left), "label": its port}. The robot's
## half length and half width, in metres.
func start(sensors: Array, half_length: float, half_width: float) -> void:
	finish()
	_pretty = GraphicsQualityConfig.current_level() != GraphicsQualityConfig.Level.Low
	var az := PRETTY_DIRECTIONS if _pretty else SIMPLE_DIRECTIONS
	if az != _az:
		_az = az
		_setup_points()
	_floor_material.set_shader_parameter("floor_dots", _pretty)
	# A third of the points, each with about three times the light.
	_points_material.set_shader_parameter("point_scale", 1.0 if _pretty else 1.7)
	_sensors = sensors
	_half_length = half_length
	_half_width = half_width
	_map = RobotLidarMap.new(-MAP_HALF, -MAP_HALF, MAP_HALF * 2.0, MAP_HALF * 2.0, sensors, half_length, half_width)
	_next_rebuild = 0.0
	_result = {}
	_pieces = PackedFloat64Array()
	_cuts.clear()
	_blobs = PackedFloat64Array()
	_shown.clear()
	_raw.resize(sensors.size())
	_raw.fill(NO_ECHO)
	_filtered.resize(sensors.size())
	_filtered.fill(NAN)
	_cone.resize(sensors.size())
	_cone.fill(NO_ECHO)
	_target = PackedFloat64Array([0.0, 0.0, 0.0])
	_robot = PackedFloat64Array([0.0, 0.0, 0.0])
	_have_pose = false
	_trail_count = 0
	_trail_last = Vector2(INF, INF)
	_cam_target = Vector2.ZERO
	_clock = 0.0
	_since_update = INF
	_known_due = 0.0
	_known_bytes = PackedByteArray()
	_known_image = Image.create_from_data(_map.nx, _map.ny, false, Image.FORMAT_R8, _map.known)
	_known_texture = ImageTexture.create_from_image(_known_image)
	var grid := Vector4(_map.gx0, _map.gy0, _map.nx, _map.ny)
	for material in [_floor_material, _points_material]:
		material.set_shader_parameter("known_tex", _known_texture)
		material.set_shader_parameter("grid", grid)
	_walls_material.set_shader_parameter("wall_count", 0)
	_points_material.set_shader_parameter("spark_count", 0)
	_points_material.set_shader_parameter("trail_count", 0)
	_hud.queue_redraw()


## One telemetry frame: the run's time in seconds, where the robot is (metres)
## and which way it faces (radians, counter-clockwise), and one range per
## sensor in metres (NO_ECHO or more: nothing heard).
func add_frame(t: float, x: float, y: float, a: float, ranges: PackedFloat64Array) -> void:
	if _map == null:
		return
	_pending.append([t, x, y, a, ranges])
	_target = PackedFloat64Array([x, y, a])
	if not _have_pose:
		_robot = _target.duplicate()
		_cam_target = Vector2(x, y)
		_have_pose = true
	_raw = ranges
	_hud.queue_redraw()
	if Vector2(x, y).distance_to(_trail_last) > TRAIL_STEP and _trail_count < MAX_TRAIL:
		_trail_last = Vector2(x, y)
		_trail_image.set_pixel(_trail_count, 0, Color(x, y, 0.0, 0.0))
		_trail_count += 1
		_trail_texture.update(_trail_image)
		_points_material.set_shader_parameter("trail_count", _trail_count)


## The run is over: the worker is waited for and the map let go.
func finish() -> void:
	if _task >= 0:
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
	_pending.clear()
	_map = null


# -- the map, on a worker ---------------------------------------------------------------

## On the worker: the frames into the map, the walls rebuilt every REBUILD_S of
## the run, and what the view needs copied out.
func _work(map: RobotLidarMap, frames: Array) -> void:
	var rebuilt := false
	for f in frames:
		map.feed(f[0], f[1], f[2], f[3], f[4])
		if f[0] >= _next_rebuild:
			map.rebuild()
			_next_rebuild = f[0] + REBUILD_S
			rebuilt = true
	var result := {}
	var pieces := PackedFloat64Array()
	for p in map.pieces:
		pieces.append_array(PackedFloat64Array([p.x1, p.y1, p.x2, p.y2, p.wall]))
	result["pieces"] = pieces
	result["cuts"] = map.cuts.duplicate()
	map.cuts.clear()
	if rebuilt:
		var blobs := PackedFloat64Array()
		for k in map.blobs:
			blobs.append_array(PackedFloat64Array([map.cell_x(k), map.cell_y(k)]))
		result["blobs"] = blobs
	if map.known_changed:
		map.known_changed = false
		result["known"] = map.known.duplicate()
	var last: Array = frames[frames.size() - 1]
	var sparks := PackedFloat32Array()
	for k in map.unconfirmed_near(last[1], last[2], SCAN_R):
		if sparks.size() >= MAX_SPARKS * 4:
			break
		# A height and a flicker of its own, the same for a cell every time.
		sparks.append_array(PackedFloat32Array([map.cell_x(k), map.cell_y(k), 0.04 + 0.08 * fmod(k * 0.618, 1.0), fmod(k * 1.7, TAU)]))
	result["sparks"] = sparks
	result["readings"] = map.readings.duplicate()
	_result = result


func _take_result() -> void:
	var result := _result
	_result = {}
	_pieces = result.get("pieces", _pieces)
	_cuts.append_array(result.get("cuts", []))
	if result.has("blobs"):
		_blobs = result["blobs"]
	if result.has("known"):
		_known_bytes = result["known"]
	var sparks: PackedFloat32Array = result.get("sparks", PackedFloat32Array())
	var count := sparks.size() / 4
	sparks.resize(MAX_SPARKS * 4)
	_spark_image.set_data(MAX_SPARKS, 1, false, Image.FORMAT_RGBAF, sparks.to_byte_array())
	_spark_texture.update(_spark_image)
	_points_material.set_shader_parameter("spark_count", count)
	_filtered = result.get("readings", _filtered)
	for s in mini(_filtered.size(), _cone.size()):
		if not is_nan(_filtered[s]):
			_cone[s] = NO_ECHO if _filtered[s] < 0.0 else minf(NO_ECHO, _filtered[s])
	_hud.queue_redraw()


# -- every frame --------------------------------------------------------------------------

func _process(delta: float) -> void:
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		_take_result()
	if _task < 0 and _map != null and not _pending.is_empty():
		var frames := _pending
		_pending = []
		_task = WorkerThreadPool.add_task(_work.bind(_map, frames), false, "Robot lidar map")
	if not is_visible_in_tree():
		return
	_clock += delta
	# The robot glides to its last pose between the telemetry's frames.
	var k := 1.0 - exp(-delta * 15.0)
	_robot[0] += (_target[0] - _robot[0]) * k
	_robot[1] += (_target[1] - _robot[1]) * k
	_robot[2] += wrapf(_target[2] - _robot[2], -PI, PI) * k
	_since_update += delta
	if _since_update >= UPDATE_S:
		_fade_cuts()
		_sync_shown(minf(_since_update, 0.1))
		_scan()
		_upload_walls()
		_since_update = 0.0
	_known_due -= delta
	if _known_due <= 0.0 and not _known_bytes.is_empty() and _map != null:
		_known_image.set_data(_map.nx, _map.ny, false, Image.FORMAT_R8, _known_bytes)
		_known_texture.update(_known_image)
		_known_bytes = PackedByteArray()
		_known_due = KNOWN_UPLOAD_S
	_update_camera(delta)
	_overlay.queue_redraw()


## Pieces the map cut (the robot drove there, or a beam saw through them): the
## cut part fades, its ends stay.
func _fade_cuts() -> void:
	for c in _cuts:
		var next: Array[Shown] = []
		for sp in _shown:
			var length := Vector2(sp.x2 - sp.x1, sp.y2 - sp.y1).length()
			if sp.dying or sp.wall != int(c[2]) or length < 1e-6 or _seg_dist(c[0], c[1], sp) > 0.12:
				next.append(sp)
				continue
			var ux := (sp.x2 - sp.x1) / length
			var uy := (sp.y2 - sp.y1) / length
			var s := (c[0] - sp.x1) * ux + (c[1] - sp.y1) * uy
			var a := maxf(0.0, s - c[3])
			var b := minf(length, s + c[3])
			if a > 0.05:
				var before := sp.copy()
				before.x2 = sp.x1 + ux * a
				before.y2 = sp.y1 + uy * a
				next.append(before)
			if length - b > 0.05:
				var after := sp.copy()
				after.x1 = sp.x1 + ux * b
				after.y1 = sp.y1 + uy * b
				next.append(after)
			var gone := sp.copy()
			gone.x1 = sp.x1 + ux * a
			gone.y1 = sp.y1 + uy * a
			gone.x2 = sp.x1 + ux * b
			gone.y2 = sp.y1 + uy * b
			gone.dying = true
			next.append(gone)
		_shown = next
	_cuts.clear()


## Every piece of the map is matched to the drawn piece of the same wall nearest
## to it, which eases towards it; new pieces grow out of their middle, pieces
## the map dropped fade.
func _sync_shown(delta: float) -> void:
	var by_wall := {}
	for s in _shown:
		if not s.dying:
			if not by_wall.has(s.wall):
				by_wall[s.wall] = []
			by_wall[s.wall].append(s)
	var used := {}
	var next: Array[Shown] = []
	var ease := 1.0 - exp(-delta * 8.0)
	for n in _pieces.size() / 5:
		var tx1 := _pieces[n * 5]
		var ty1 := _pieces[n * 5 + 1]
		var tx2 := _pieces[n * 5 + 2]
		var ty2 := _pieces[n * 5 + 3]
		var wall := int(_pieces[n * 5 + 4])
		var mx := (tx1 + tx2) * 0.5
		var my := (ty1 + ty2) * 0.5
		var best: Shown = null
		var best_d := INF
		for item in by_wall.get(wall, []):
			var s: Shown = item
			if used.has(s):
				continue
			var sx := (s.x1 + s.x2) * 0.5
			var sy := (s.y1 + s.y2) * 0.5
			if _seg_dist_xy(sx, sy, tx1, ty1, tx2, ty2) > 0.1 and _seg_dist(mx, my, s) > 0.1:
				continue
			var d := Vector2(sx - mx, sy - my).length()
			if d < best_d:
				best_d = d
				best = s
		if best == null:
			best = Shown.new()
			best.x1 = mx
			best.y1 = my
			best.x2 = mx
			best.y2 = my
			best.wall = wall
		else:
			# Keep the drawn ends in the same order as the map's.
			if Vector2(best.x1 - tx1, best.y1 - ty1).length() > Vector2(best.x1 - tx2, best.y1 - ty2).length():
				var x := best.x1
				var y := best.y1
				best.x1 = best.x2
				best.y1 = best.y2
				best.x2 = x
				best.y2 = y
			best.x1 += (tx1 - best.x1) * ease
			best.y1 += (ty1 - best.y1) * ease
			best.x2 += (tx2 - best.x2) * ease
			best.y2 += (ty2 - best.y2) * ease
			best.alpha = minf(1.0, best.alpha + delta * 2.5)
		used[best] = true
		next.append(best)
	for s in _shown:
		if not used.has(s):
			s.dying = true
			s.alpha -= delta * 2.0
			if s.alpha > 0.0:
				next.append(s)
	_shown = next


## The lidar's returns: per direction, the first wall or blob within SCAN_R.
## Each wall is cast only over the directions it covers.
func _scan() -> void:
	_scan_data = _scan_blank.duplicate()
	var rx := _robot[0]
	var ry := _robot[1]
	for s in _shown:
		if s.alpha <= 0.02 or _seg_dist(rx, ry, s) > SCAN_R:
			continue
		var ex := s.x2 - s.x1
		var ey := s.y2 - s.y1
		var qx := s.x1 - rx
		var qy := s.y1 - ry
		var a1 := atan2(qy, qx)
		var span := wrapf(atan2(s.y2 - ry, s.x2 - rx) - a1, -PI, PI)
		var first := floori(minf(a1, a1 + span) / TAU * _az) - 1
		for n in ceili(absf(span) / TAU * _az) + 3:
			var i := posmod(first + n, _az)
			var dx := _cos[i]
			var dy := _sin[i]
			var den := dx * ey - dy * ex
			if absf(den) < 1e-9:
				continue
			var t := (qx * ey - qy * ex) / den
			var u := (qx * dy - qy * dx) / den
			if t > 0.05 and t < _scan_data[i * 4] and u >= 0.0 and u <= 1.0:
				_scan_data[i * 4] = t
				_scan_data[i * 4 + 1] = 1.0
				_scan_data[i * 4 + 2] = s.alpha
	# Blobs: the first step of a march from 12 cm in 3 cm steps that lands in the cell.
	var half_cell := RobotLidarMap.CELL * 0.5
	for n in _blobs.size() / 2:
		var cx := _blobs[n * 2]
		var cy := _blobs[n * 2 + 1]
		var dist := Vector2(cx - rx, cy - ry).length()
		if dist > SCAN_R + 0.1 or dist < 0.05:
			continue
		var half := asin(minf(1.0, half_cell * 1.5 / dist))
		var mid := atan2(cy - ry, cx - rx)
		var first := floori((mid - half) / TAU * _az) - 1
		for m in ceili(2.0 * half / TAU * _az) + 3:
			var i := posmod(first + m, _az)
			var t_in := -INF
			var t_out := INF
			for axis in 2:
				var d := _cos[i] if axis == 0 else _sin[i]
				var o := (rx if axis == 0 else ry)
				var c := (cx if axis == 0 else cy)
				if absf(d) < 1e-12:
					if absf(o - c) > half_cell:
						t_in = INF
					continue
				var t1 := (c - half_cell - o) / d
				var t2 := (c + half_cell - o) / d
				t_in = maxf(t_in, minf(t1, t2))
				t_out = minf(t_out, maxf(t1, t2))
			if t_out < t_in or t_out < 0.12:
				continue
			var step := 0.12 + ceilf(maxf(t_in - 0.12, 0.0) / 0.03) * 0.03
			if step <= t_out and step < _scan_data[i * 4]:
				_scan_data[i * 4] = step
				_scan_data[i * 4 + 1] = 3.0
				_scan_data[i * 4 + 2] = 1.0
	_scan_image.set_data(_az, 1, false, Image.FORMAT_RGBAF, _scan_data.to_byte_array())
	_scan_texture.update(_scan_image)
	_points_material.set_shader_parameter("scan_origin", Vector2(rx, ry))


## The walls the map remembers, drawn dotted at their foot and top.
func _upload_walls() -> void:
	var count := mini(_shown.size(), MAX_WALLS)
	var data := PackedFloat32Array()
	data.resize(MAX_WALLS * 2 * 4)
	for n in count:
		var s := _shown[n]
		data[n * 4] = s.x1
		data[n * 4 + 1] = s.y1
		data[n * 4 + 2] = s.x2
		data[n * 4 + 3] = s.y2
		data[(MAX_WALLS + n) * 4] = s.alpha
		data[(MAX_WALLS + n) * 4 + 1] = maxf(2.0, roundf(Vector2(s.x2 - s.x1, s.y2 - s.y1).length() / 0.04))
	_wall_image.set_data(MAX_WALLS, 2, false, Image.FORMAT_RGBAF, data.to_byte_array())
	_wall_texture.update(_wall_image)
	_walls_material.set_shader_parameter("wall_count", count)


## The camera looks at the robot from 3.3 m away and 2.7 m up, circling it
## slowly, and follows it lazily.
func _update_camera(delta: float) -> void:
	_cam_target += (Vector2(_robot[0], _robot[1]) - _cam_target) * (1.0 - pow(0.97, delta * 60.0))
	var orbit := _clock * 0.05 + 2.2
	_cam_pos = Vector3(_cam_target.x + cos(orbit) * 3.3, _cam_target.y + sin(orbit) * 3.3, 2.7)
	_cam_f = (Vector3(_cam_target.x, _cam_target.y, 0.0) - _cam_pos).normalized()
	_cam_r = _cam_f.cross(Vector3(0.0, 0.0, 1.0)).normalized()
	_cam_u = _cam_r.cross(_cam_f)
	# As tall as the view; a low, wide strip (a small window) zooms in by its
	# width instead, so the robot and what is around it stay readable.
	_focal = maxf(size.y, size.x / 3.0) * 1.2
	var sweep := fmod(_clock * TAU * 0.8, TAU)
	for material in [_floor_material, _walls_material, _points_material]:
		material.set_shader_parameter("cam_pos", _cam_pos)
		material.set_shader_parameter("cam_f", _cam_f)
		material.set_shader_parameter("cam_r", _cam_r)
		material.set_shader_parameter("cam_u", _cam_u)
		material.set_shader_parameter("focal", _focal)
		material.set_shader_parameter("center", size * 0.5)
		material.set_shader_parameter("view_size", size)
		material.set_shader_parameter("corner_radius", CORNER_RADIUS)
	_floor_material.set_shader_parameter("robot", Vector2(_robot[0], _robot[1]))
	_points_material.set_shader_parameter("sweep", sweep)
	_points_material.set_shader_parameter("flicker", fmod(_clock * 1000.0 / 160.0, TAU))


func _project(p: Vector3) -> Vector3:
	var d := p - _cam_pos
	var zc := d.dot(_cam_f)
	return Vector3(size.x * 0.5 + _focal * d.dot(_cam_r) / zc, size.y * 0.5 - _focal * d.dot(_cam_u) / zc, zc)


# -- drawing ---------------------------------------------------------------------------------

## The robot as an orange glowing wireframe box, and each sensor's cone as far
## as it hears.
func _draw_robot() -> void:
	if _map == null:
		return
	var x := _robot[0]
	var y := _robot[1]
	var a := _robot[2]
	var ca := cos(a)
	var sa := sin(a)
	for s in _sensors.size():
		var ox: float = x + ca * float(_sensors[s]["x"]) - sa * float(_sensors[s]["y"])
		var oy: float = y + sa * float(_sensors[s]["x"]) + ca * float(_sensors[s]["y"])
		var dir: float = a + float(_sensors[s]["angle"])
		var d := _cone[s]
		var points := PackedVector2Array()
		var at := _project(Vector3(ox, oy, 0.08))
		if at.z < 0.08:
			continue
		points.append(Vector2(at.x, at.y))
		for k in range(-6, 7):
			var side := dir + k / 6.0 * RobotLidarMap.BETA
			var p := _project(Vector3(ox + cos(side) * d, oy + sin(side) * d, 0.08))
			if p.z < 0.08:
				points.clear()
				break
			points.append(Vector2(p.x, p.y))
		if points.size() > 2:
			_overlay.draw_colored_polygon(points, CONE_COLOR)
	var corners: Array[Vector2] = []
	var height := _half_length * 1.25
	for z in [0.02, height]:
		for corner in [Vector2(-1, -1), Vector2(1, -1), Vector2(1, 1), Vector2(-1, 1)]:
			var lx: float = corner.x * _half_length
			var ly: float = corner.y * _half_width
			var p := _project(Vector3(x + lx * ca - ly * sa, y + lx * sa + ly * ca, z))
			if p.z < 0.08:
				return
			corners.append(Vector2(p.x, p.y))
	var lines := PackedVector2Array()
	for edge in [[0, 1], [1, 2], [2, 3], [3, 0], [4, 5], [5, 6], [6, 7], [7, 4], [0, 4], [1, 5], [2, 6], [3, 7]]:
		lines.append(corners[edge[0]])
		lines.append(corners[edge[1]])
	# Pretty: a glow, two wide faint passes under the line. Simple: the line.
	for pass_ in ([[7.0, 0.12], [3.0, 0.35], [1.4, 1.0]] if _pretty else [[1.4, 1.0]]):
		_overlay.draw_multiline(lines, Color(ROBOT_COLOR, pass_[1]), pass_[0], _pretty)


## Each sensor's last reading as a bar, left sensor first, in the bottom left
## corner: the fuller, the nearer. A reading the map ignored as a dropout is grey.
func _draw_hud() -> void:
	if _sensors.is_empty():
		return
	var order: Array = range(_sensors.size())
	order.sort_custom(func(p, q): return float(_sensors[p]["angle"]) > float(_sensors[q]["angle"]))
	var font := get_theme_default_font()
	var font_size := 13
	var title := RobotPanel.say(RobotPanel.STEP_TITLES["sensors"])   # the build screen's step of the same name
	var bar_w := 14.0
	var gap := 7.0
	# A low view keeps only the bars, as tall as there is room for.
	var words := size.y >= 150.0
	var margin := 16.0 if size.y >= 80.0 else 6.0
	var bar_h := 46.0 if words else clampf(size.y - margin * 2.0, 6.0, 46.0)
	var x0 := margin
	var y0 := size.y - margin
	var bars_w := order.size() * (bar_w + gap) - gap
	if words:
		var width := maxf(bars_w, font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x) + 16.0
		_hud.draw_rect(Rect2(x0 - 8.0, y0 - bar_h - 44.0, width, bar_h + 52.0), HUD_BACK)
		_hud.draw_string(font, Vector2(x0, y0 - bar_h - 26.0), title, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, HUD_TITLE)
	else:
		_hud.draw_rect(Rect2(x0 - 4.0, y0 - bar_h - 4.0, bars_w + 8.0, bar_h + 8.0), HUD_BACK)
	for n in order.size():
		var s: int = order[n]
		var bx := x0 + n * (bar_w + gap)
		if words:
			var label := str(_sensors[s].get("label", ""))
			var label_w := font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size - 1).x
			_hud.draw_string(font, Vector2(bx + (bar_w - label_w) * 0.5, y0 - bar_h - 6.0), label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size - 1, HUD_LABEL)
		var d := minf(NO_ECHO, _raw[s]) if s < _raw.size() else NO_ECHO
		var full := maxf(0.04, 1.0 - d / NO_ECHO)
		var glitch := s < _filtered.size() and is_nan(_filtered[s]) and _have_pose
		_hud.draw_rect(Rect2(bx, y0 - bar_h, bar_w, bar_h), HUD_EMPTY)
		_hud.draw_rect(Rect2(bx, y0 - bar_h * full, bar_w, bar_h * full), HUD_GLITCH if glitch else Color(_ramp(d * 1.4), 0.95))


static func _ramp(d: float) -> Color:
	var i := 0
	while i < RAMP_D.size() - 2 and d > RAMP_D[i + 1]:
		i += 1
	return RAMP_C[i].lerp(RAMP_C[i + 1], clampf((d - RAMP_D[i]) / (RAMP_D[i + 1] - RAMP_D[i]), 0.0, 1.0))


# -- setup -----------------------------------------------------------------------------------

## The points: one instance of a single-vertex point each; the walls: one unit
## quad per wall and height. All at the view's origin: the shaders place them,
## from the small textures made here.
func _setup_points() -> void:
	_cos.resize(_az)
	_sin.resize(_az)
	for i in _az:
		_cos[i] = cos(float(i) / _az * TAU)
		_sin[i] = sin(float(i) / _az * TAU)
	_scan_blank.resize(_az * 4)
	for i in _az:
		_scan_blank[i * 4] = SCAN_R
		_scan_blank[i * 4 + 1] = 0.0
		_scan_blank[i * 4 + 2] = 1.0
		_scan_blank[i * 4 + 3] = 0.0
	_scan_data = _scan_blank.duplicate()
	_points.multimesh = _placed_by_shader(_point_mesh(), _az * POINTS_PER_DIRECTION + MAX_SPARKS + MAX_TRAIL)
	_walls.multimesh = _placed_by_shader(_unit_quad(), 2 * MAX_WALLS)
	_scan_image = Image.create_empty(_az, 1, false, Image.FORMAT_RGBAF)
	_scan_texture = ImageTexture.create_from_image(_scan_image)
	_wall_image = Image.create_empty(MAX_WALLS, 2, false, Image.FORMAT_RGBAF)
	_wall_texture = ImageTexture.create_from_image(_wall_image)
	_spark_image = Image.create_empty(MAX_SPARKS, 1, false, Image.FORMAT_RGBAF)
	_spark_texture = ImageTexture.create_from_image(_spark_image)
	_trail_image = Image.create_empty(MAX_TRAIL, 1, false, Image.FORMAT_RGBAF)
	_trail_texture = ImageTexture.create_from_image(_trail_image)
	_points_material.set_shader_parameter("scan_tex", _scan_texture)
	_walls_material.set_shader_parameter("wall_tex", _wall_texture)
	_points_material.set_shader_parameter("spark_tex", _spark_texture)
	_points_material.set_shader_parameter("trail_tex", _trail_texture)
	_points_material.set_shader_parameter("az_count", _az)
	_points_material.set_shader_parameter("max_sparks", MAX_SPARKS)
	# Until a map comes, an empty one: every ring runs out to SCAN_R.
	var empty := Image.create_empty(1, 1, false, Image.FORMAT_R8)
	for material in [_floor_material, _points_material]:
		material.set_shader_parameter("known_tex", ImageTexture.create_from_image(empty))
		material.set_shader_parameter("grid", Vector4(0.0, 0.0, 0.0, 0.0))


## So many instances of a mesh, all at the view's origin (the shader places
## them) and never culled (only the shader knows where they are).
static func _placed_by_shader(mesh: Mesh, count: int) -> MultiMesh:
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_2D
	multimesh.mesh = mesh
	multimesh.instance_count = count
	var identity := PackedFloat32Array([1.0, 0.0, 0.0, 0.0, 0.0, 1.0, 0.0, 0.0])
	while identity.size() < count * 8:
		identity.append_array(identity)
	identity.resize(count * 8)
	multimesh.buffer = identity
	multimesh.custom_aabb = AABB(Vector3(-1e5, -1e5, -1.0), Vector3(2e5, 2e5, 2.0))
	return multimesh


## One vertex drawn as a point (its size is set by the shader).
static func _point_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2.ZERO])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_POINTS, arrays)
	return mesh


## LineDrawer2D's unit quad (scripts/linebatch.gd).
static func _unit_quad() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = PackedVector2Array([Vector2(-0.5, -0.5), Vector2(0.5, -0.5), Vector2(0.5, 0.5), Vector2(-0.5, 0.5)])
	arrays[Mesh.ARRAY_TEX_UV] = PackedVector2Array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	arrays[Mesh.ARRAY_INDEX] = PackedInt32Array([0, 1, 2, 0, 2, 3])
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh


static func _seg_dist(x: float, y: float, s: Shown) -> float:
	return _seg_dist_xy(x, y, s.x1, s.y1, s.x2, s.y2)


static func _seg_dist_xy(x: float, y: float, x1: float, y1: float, x2: float, y2: float) -> float:
	var ex := x2 - x1
	var ey := y2 - y1
	var l2 := ex * ex + ey * ey
	var t := clampf(((x - x1) * ex + (y - y1) * ey) / l2, 0.0, 1.0) if l2 > 0.0 else 0.0
	return Vector2(x - (x1 + ex * t), y - (y1 + ey * t)).length()
