class_name RobotLidarMap
extends RefCounted
## A floor plan of what the robot's distance sensors have seen while it drove:
## an occupancy grid (log-odds, 5 cm cells) filled from every reading and the
## robot's pose (wheel odometry), and straight walls found in it.
##
## The algorithm is the lidar mockup's (prototypes/lidar/mapper.js, every fix
## on), checked against it on the two recorded runs of the EV3 "KIRISIMA"
## (tests/godot/test_robot_lidar_map.gd):
##
## * a 1-2 frame "no echo" between echoes is a dropout, not "nothing there";
##   readings go through a median of three; a real "no echo" clears only 60 cm,
##   weakly;
## * a wall cell counts once it was seen from two places at least 15 cm apart;
## * an echo's weight goes to the part of its arc not already known to be free;
##   the main lobe (+-5 degrees) clears three times harder than the cone's edges;
## * where the robot's body went is free, and walls drawn there are cut;
## * a wall a sensor would have heard but did not (it sees through it) is cut;
## * walls keep their identity between rebuilds: cells stay wall with
##   hysteresis, walls are refit around their own centre, merged, and snapped to
##   the room's axes; gaps under 25 cm never seen free are drawn as wall.
##
## Units are metres and radians in the usual maths frame: x, y with y to the
## left of x, angles counter-clockwise from +x. Times are seconds.
##
## Speed: a reading only visits the cells inside its cone, and a rebuild only
## the cells an echo ever landed on, so the cost does not grow with the area.

const DEG := PI / 180.0
const CELL := 0.05
const BETA := 15.0 * DEG               # half the sonar's cone
const NO_ECHO_M := 2.5                 # a reading this far or further is "no echo"
const K_OCC := 0.9
const K_FREE := 0.3
const NO_ECHO_REACH := 0.6             # how far "no echo" clears, and how hard
const NO_ECHO_K := 0.1
const WALL_ON := 1.0                   # cell hysteresis
const WALL_OFF := 0.3
const CENTER_K := 3.0
const CUT_NO_ECHO := 1.5               # how far a beam with no echo sees through walls
const CUT_FACING := 40.0 * DEG         # walls turned further than this from the beam may send no echo back
const KNOWN_FREE := -0.4               # cells below this were seen free (drawn as known floor)
const BLOB_MIN := 0.8                  # an occupied cell no wall took (a leg, a box)
const HOUGH_ANGLES := 90
const HOUGH_STEP := 0.05               # metres per distance bin
const HOUGH_LINES := 8                 # new walls looked for per rebuild, at most
const HOUGH_VOTES := 8                 # cells a line needs


class Wall extends RefCounted:
	var id := 0
	var cx := 0.0
	var cy := 0.0
	var a := 0.0                       # direction, modulo pi
	var lo := 0.0                      # extent along the direction, from the centre
	var hi := 0.0
	var us := PackedFloat64Array()     # where its cells are along it, sorted
	var miss := 0                      # rebuilds in a row without points


class Piece extends RefCounted:
	var x1 := 0.0
	var y1 := 0.0
	var x2 := 0.0
	var y2 := 0.0
	var wall := 0

	func copy() -> Piece:
		var p := Piece.new()
		p.x1 = x1
		p.y1 = y1
		p.x2 = x2
		p.y2 = y2
		p.wall = wall
		return p


var gx0 := 0.0
var gy0 := 0.0
var nx := 0
var ny := 0
var log_odds := PackedFloat32Array()
var known := PackedByteArray()          # 255 where the floor was seen free; the view's texture
var known_changed := false
var pieces: Array[Piece] = []
## Where pieces were cut since the view last looked: [x, y, wall, half length].
var cuts: Array[PackedFloat64Array] = []
## Occupied cells no wall took, after the last rebuild.
var blobs := PackedInt32Array()
## The last filtered reading of each sensor: a distance, -1 for "no echo", NAN
## for a dropout that was ignored.
var readings := PackedFloat64Array()
var crossings := 0                      # times the robot drove through a drawn wall

var _sensor_angle := PackedFloat64Array()
var _sensor_x := PackedFloat64Array()
var _sensor_y := PackedFloat64Array()
var _half_length := 0.12
var _half_width := 0.08
var _obs_x := PackedFloat32Array()
var _obs_y := PackedFloat32Array()
var _conf := PackedByteArray()
var _is_wall := PackedByteArray()
var _used := PackedByteArray()
var _candidate := PackedByteArray()
var _candidates := PackedInt32Array()   # cells an echo landed on that may be wall
var _hist: Array[PackedFloat64Array] = []
var _walls: Array[Wall] = []
var _axis := NAN
var _next_id := 1
var _recent_cross := {}                 # wall id -> when the robot last crossed it
var _now := 0.0
var _arc_k := PackedInt32Array()
var _arc_w := PackedFloat64Array()
## The Hough accumulator is kept between rebuilds: only cells that joined or
## left the free points vote again. Bins with enough votes for a line are listed.
var _acc := PackedInt32Array()
var _acc_cells := PackedInt32Array()   # the cells whose votes are in it, sorted
var _hot := {}                          # bin -> true, for bins with HOUGH_VOTES or more
var _cos_t := PackedFloat64Array()
var _sin_t := PackedFloat64Array()
var _rmax := 0.0
var _nr := 0


## The floor the map covers: from (x0, y0), width by height metres (plain
## floats: a Rect2 would round the grid's origin). sensors: one dictionary per
## sensor, {"angle": radians, "x": m, "y": m} on the robot (x ahead, y left).
## The robot's half length and half width, in metres, is what it clears as it drives.
func _init(x0: float, y0: float, width: float, height: float, sensors: Array, half_length: float = 0.12, half_width: float = 0.08) -> void:
	gx0 = x0
	gy0 = y0
	nx = ceili(width / CELL)
	ny = ceili(height / CELL)
	var n := nx * ny
	log_odds.resize(n)
	log_odds.fill(0.0)
	known.resize(n)
	known.fill(0)
	_obs_x.resize(n)
	_obs_x.fill(NAN)
	_obs_y.resize(n)
	_obs_y.fill(NAN)
	_conf.resize(n)
	_conf.fill(0)
	_is_wall.resize(n)
	_is_wall.fill(0)
	_used.resize(n)
	_used.fill(0)
	_candidate.resize(n)
	_candidate.fill(0)
	_half_length = half_length
	_half_width = half_width
	for sensor in sensors:
		_sensor_angle.append(float(sensor.get("angle", 0.0)))
		_sensor_x.append(float(sensor.get("x", 0.0)))
		_sensor_y.append(float(sensor.get("y", 0.0)))
		_hist.append(PackedFloat64Array())
	readings.resize(sensors.size())
	readings.fill(NAN)
	_rmax = sqrt(pow(maxf(absf(gx0), absf(gx0 + nx * CELL)), 2.0) + pow(maxf(absf(gy0), absf(gy0 + ny * CELL)), 2.0)) + 0.5
	_nr = ceili(2.0 * _rmax / HOUGH_STEP)
	for t in HOUGH_ANGLES:
		_cos_t.append(cos(t * PI / HOUGH_ANGLES))
		_sin_t.append(sin(t * PI / HOUGH_ANGLES))
	_acc.resize(HOUGH_ANGLES * _nr)
	_acc.fill(0)


func cell_of(x: float, y: float) -> int:
	var i := floori((x - gx0) / CELL)
	var j := floori((y - gy0) / CELL)
	return -1 if i < 0 or j < 0 or i >= nx or j >= ny else j * nx + i


func cell_x(k: int) -> float:
	return gx0 + ((k % nx) + 0.5) * CELL


func cell_y(k: int) -> float:
	return gy0 + ((k / nx) + 0.5) * CELL


func sensor_count() -> int:
	return _sensor_angle.size()


## Where a sensor is and which way it faces, for a robot at (x, y) heading a.
func sensor_pose(s: int, x: float, y: float, a: float) -> PackedFloat64Array:
	var ca := cos(a)
	var sa := sin(a)
	return PackedFloat64Array([x + ca * _sensor_x[s] - sa * _sensor_y[s], y + sa * _sensor_x[s] + ca * _sensor_y[s], a + _sensor_angle[s]])


## Cells an echo landed on that were seen from one place only, within a box
## around (x, y): echoes not confirmed yet.
func unconfirmed_near(x: float, y: float, reach: float) -> PackedInt32Array:
	var result := PackedInt32Array()
	for k in _candidates:
		if log_odds[k] < BLOB_MIN or _conf[k]:
			continue
		if absf(cell_x(k) - x) < reach and absf(cell_y(k) - y) < reach:
			result.append(k)
	return result


# -- one frame ---------------------------------------------------------------------------

## The robot at (x, y), heading a, at time t, and one range per sensor in
## metres (NO_ECHO_M or more: nothing heard).
func feed(t: float, x: float, y: float, a: float, ranges: PackedFloat64Array) -> void:
	_now = t
	_carve(x, y, a)
	var poses: Array[PackedFloat64Array] = []
	for s in _sensor_angle.size():
		var pose := sensor_pose(s, x, y, a)
		poses.append(pose)
		var reading := _filtered(s, ranges[s] if s < ranges.size() else NO_ECHO_M)
		readings[s] = reading
		if not is_nan(reading):
			_integrate(pose[0], pose[1], pose[2], reading)
	for s in _sensor_angle.size():
		if not is_nan(readings[s]):
			_beam_cut(poses[s][0], poses[s][1], poses[s][2], readings[s])
	_check_crossing(x, y)


## A distance, -1 for "no echo", or NAN for a dropout to ignore.
func _filtered(s: int, raw: float) -> float:
	var h := _hist[s]
	h.append(NAN if raw >= NO_ECHO_M else raw)
	if h.size() > 3:
		h.remove_at(0)
	_hist[s] = h
	if is_nan(h[h.size() - 1]):
		if h.size() == 3 and is_nan(h[0]) and is_nan(h[1]):
			return -1.0
		return NAN
	var echoes := PackedFloat64Array()
	for value in h:
		if not is_nan(value):
			echoes.append(value)
	echoes.sort()
	return maxf(0.04, echoes[echoes.size() / 2])   # median: a one-frame spike is dropped


func _set_odds(k: int, value: float) -> void:
	log_odds[k] = value
	var seen_free := 255 if log_odds[k] < KNOWN_FREE else 0
	if known[k] != seen_free:
		known[k] = seen_free
		known_changed = true


func _integrate(ox: float, oy: float, dir: float, reading: float) -> void:
	var echo := reading >= 0.0
	var d := reading
	var reach := d + 0.08 if echo else NO_ECHO_REACH
	var k_free := K_FREE if echo else NO_ECHO_K
	var i0 := maxi(0, floori((ox - reach - gx0) / CELL))
	var i1 := mini(nx - 1, floori((ox + reach - gx0) / CELL))
	var j0 := maxi(0, floori((oy - reach - gy0) / CELL))
	var j1 := mini(ny - 1, floori((oy + reach - gy0) / CELL))
	# The cone's two edges: in each row only the cells between them (and in reach)
	# are visited, with a cell's margin; the exact tests below decide.
	var ax := cos(dir - BETA)
	var ay := sin(dir - BETA)
	var bx := cos(dir + BETA)
	var by := sin(dir + BETA)
	var reach_m := reach + CELL
	_arc_k.clear()
	_arc_w.clear()
	for j in range(j0, j1 + 1):
		var py := gy0 + (j + 0.5) * CELL - oy
		if py * py > reach_m * reach_m:
			continue
		var half := sqrt(reach_m * reach_m - py * py)
		var lo := -half
		var hi := half
		if ay > 1e-9:
			hi = minf(hi, ax * py / ay + CELL)
		elif ay < -1e-9:
			lo = maxf(lo, ax * py / ay - CELL)
		if by > 1e-9:
			lo = maxf(lo, py * bx / by - CELL)
		elif by < -1e-9:
			hi = minf(hi, py * bx / by + CELL)
		if lo > hi:
			continue
		var i_lo := maxi(i0, ceili((ox + lo - gx0) / CELL - 0.5))
		var i_hi := mini(i1, floori((ox + hi - gx0) / CELL - 0.5))
		for i in range(i_lo, i_hi + 1):
			var px := gx0 + (i + 0.5) * CELL - ox
			var r := sqrt(px * px + py * py)
			if r > reach or r < 0.03:
				continue
			var da := atan2(py, px) - dir
			da = atan2(sin(da), cos(da))
			if absf(da) > BETA:
				continue
			var w := 1.0 - 0.5 * (da / BETA) * (da / BETA)
			var k := j * nx + i
			if echo and absf(r - d) < 0.06:
				_arc_k.append(k)
				_arc_w.append(w)
			elif r < (d - 0.06 if echo else reach):
				var centre := CENTER_K if echo and absf(da) < 5.0 * DEG else 1.0   # the main lobe: nothing there is surer
				_set_odds(k, maxf(-4.0, log_odds[k] - k_free * w * centre))
	if _arc_k.is_empty():
		return
	var sw := 0.0
	var swp := 0.0
	for n in _arc_k.size():
		sw += _arc_w[n]
		if log_odds[_arc_k[n]] >= -1.0:
			swp += _arc_w[n]
	# The whole arc seen free contradicts the echo: then the free belief is what is wrong.
	var narrow := swp > 0.2 * sw
	var scale := sw / swp if narrow else 1.0
	for n in _arc_k.size():
		var k := _arc_k[n]
		if narrow and log_odds[k] < -1.0:
			continue                    # seen free from elsewhere: the echo came from the rest of the arc
		_set_odds(k, minf(4.0, log_odds[k] + minf(1.5, K_OCC * _arc_w[n] * scale)))
		if not _candidate[k]:
			_candidate[k] = 1
			_candidates.append(k)
		if is_nan(_obs_x[k]):
			_obs_x[k] = ox
			_obs_y[k] = oy
		elif not _conf[k] and sqrt((ox - _obs_x[k]) * (ox - _obs_x[k]) + (oy - _obs_y[k]) * (oy - _obs_y[k])) >= 0.15:
			_conf[k] = 1


## Where the robot's body is, the floor is free.
func _carve(x: float, y: float, a: float) -> void:
	var ca := cos(a)
	var sa := sin(a)
	var lx := -_half_length
	while lx <= _half_length:
		var ly := -_half_width
		while ly <= _half_width:
			var k := cell_of(x + lx * ca - ly * sa, y + lx * sa + ly * ca)
			if k >= 0:
				_set_odds(k, minf(log_odds[k], -3.0))
				_conf[k] = 0
				_is_wall[k] = 0
				_obs_x[k] = NAN
				_obs_y[k] = NAN
			ly += CELL / 2.0
		lx += CELL / 2.0


## A drawn wall across the beam, nearer than the echo, that the sonar would
## have heard (it faces the beam within 40 degrees): the sensor sees through
## it, so it is not there. Walls at a steeper angle can send no echo back and stay.
func _beam_cut(ox: float, oy: float, dir: float, reading: float) -> void:
	var reach := CUT_NO_ECHO if reading < 0.0 else reading - 0.12
	if reach < 0.1:
		return
	var dx := cos(dir)
	var dy := sin(dir)
	var keep: Array[Piece] = []
	var hit := false
	var facing_min := cos(CUT_FACING)
	for p in pieces:
		var ex := p.x2 - p.x1
		var ey := p.y2 - p.y1
		var length := sqrt(ex * ex + ey * ey)
		var den := dx * ey - dy * ex
		if length < 1e-6 or absf(den) < 1e-9:
			keep.append(p)
			continue
		var qx := p.x1 - ox
		var qy := p.y1 - oy
		var t := (qx * ey - qy * ex) / den
		var u := (qx * dy - qy * dx) / den
		var facing := absf(dx * ey - dy * ex) / length   # |cos| between the beam and the wall's normal
		if t < 0.05 or t > reach or u < 0.0 or u > 1.0 or facing < facing_min:
			keep.append(p)
			continue
		var x := ox + dx * t
		var y := oy + dy * t
		_cut(p, x, y, keep, 0.1)
		for j in range(-2, 3):
			for i in range(-2, 3):
				var k := cell_of(x + i * CELL, y + j * CELL)
				if k >= 0:
					_set_odds(k, minf(log_odds[k], -1.5))
					_is_wall[k] = 0
		hit = true
	if hit:
		pieces = keep


## A wall drawn where the robot's body now is.
func _check_crossing(x: float, y: float) -> void:
	var keep: Array[Piece] = []
	for p in pieces:
		if seg_dist(x, y, p) >= 0.08:
			keep.append(p)
			continue
		if not _recent_cross.has(p.wall) or _now - float(_recent_cross[p.wall]) > 1.0:
			crossings += 1
		_recent_cross[p.wall] = _now
		_cut(p, x, y, keep)
	pieces = keep


func _cut(p: Piece, x: float, y: float, keep: Array[Piece], half: float = 0.15) -> void:
	cuts.append(PackedFloat64Array([x, y, p.wall, half]))
	var length := sqrt((p.x2 - p.x1) * (p.x2 - p.x1) + (p.y2 - p.y1) * (p.y2 - p.y1))
	if length < 1e-6:
		return
	var ux := (p.x2 - p.x1) / length
	var uy := (p.y2 - p.y1) / length
	var s := (x - p.x1) * ux + (y - p.y1) * uy
	if s - half > 0.1:
		var before := p.copy()
		before.x2 = p.x1 + ux * (s - half)
		before.y2 = p.y1 + uy * (s - half)
		keep.append(before)
	if length - (s + half) > 0.1:
		var after := p.copy()
		after.x1 = p.x1 + ux * (s + half)
		after.y1 = p.y1 + uy * (s + half)
		keep.append(after)


# -- walls -------------------------------------------------------------------------------

## Walls from the cells: every 0.6 s of the run is often enough.
func rebuild() -> void:
	_candidates.sort()
	var pts := PackedInt32Array()
	var still := PackedInt32Array()
	for k in _candidates:
		if _is_wall[k]:
			if log_odds[k] < WALL_OFF or not _conf[k]:
				_is_wall[k] = 0
		elif log_odds[k] > WALL_ON and _conf[k]:
			_is_wall[k] = 1
		if _is_wall[k]:
			pts.append(k)
		# A cell drops out until an echo lands on it again once it can be
		# neither wall, nor blob, nor unconfirmed echo.
		if _is_wall[k] or log_odds[k] >= BLOB_MIN:
			still.append(k)
		else:
			_candidate[k] = 0
	_candidates = still
	var count := pts.size()
	var xs := PackedFloat64Array()
	var ys := PackedFloat64Array()
	var ws := PackedFloat64Array()
	xs.resize(count)
	ys.resize(count)
	ws.resize(count)
	for n in count:
		xs[n] = cell_x(pts[n])
		ys[n] = cell_y(pts[n])
		ws[n] = maxf(0.3, log_odds[pts[n]])
	var taken := PackedByteArray()
	taken.resize(count)
	taken.fill(0)
	_used.fill(0)
	_refit_walls(pts, xs, ys, ws, taken)
	_new_walls(pts, taken)
	_merge_walls()
	_find_axis()
	var out: Array[Piece] = []
	for w in _walls:
		var dx := cos(w.a)
		var dy := sin(w.a)
		if w.us.size() < 2:
			if w.hi - w.lo >= 0.12:
				out.append_array(_pieces_along(w.cx, w.cy, dx, dy, PackedFloat64Array([w.lo, w.hi]), w.id))
			continue
		out.append_array(_pieces_along(w.cx, w.cy, dx, dy, w.us, w.id))
	pieces = out
	blobs = PackedInt32Array()
	for k in _candidates:
		if log_odds[k] > BLOB_MIN and _conf[k] and not _used[k]:
			blobs.append(k)


## 1. Existing walls, longest first, take the points near them and are refit
## around their own centre.
func _refit_walls(pts: PackedInt32Array, xs: PackedFloat64Array, ys: PackedFloat64Array, ws: PackedFloat64Array, taken: PackedByteArray) -> void:
	var order: Array = []
	for n in _walls.size():
		order.append([_walls[n].hi - _walls[n].lo, n, _walls[n]])
	order.sort_custom(func(p, q): return p[0] > q[0] or (p[0] == q[0] and p[1] < q[1]))
	_walls.clear()
	for item in order:
		_walls.append(item[2])
	for w in _walls:
		var dx := cos(w.a)
		var dy := sin(w.a)
		# The points of the band along the wall, in the order of pts: the rows
		# of the band's bounding box, each found in the sorted cells by bisection.
		var idx := PackedInt32Array()
		var box := _band_box(w.cx, w.cy, dx, dy, w.lo - 0.3, w.hi + 0.3, 0.07)
		for j in range(box[1], box[3] + 1):
			var first := pts.bsearch(j * nx + box[0])
			var after := pts.bsearch(j * nx + box[2] + 1)
			for n in range(first, after):
				if taken[n]:
					continue
				var rx := xs[n] - w.cx
				var ry := ys[n] - w.cy
				var u := rx * dx + ry * dy
				if absf(-rx * dy + ry * dx) < 0.07 and u > w.lo - 0.3 and u < w.hi + 0.3:
					idx.append(n)
		if idx.size() < 4:
			w.miss += 1
			w.us = PackedFloat64Array()
			continue
		w.miss = 0
		var fx := PackedFloat64Array()
		var fy := PackedFloat64Array()
		var fw := PackedFloat64Array()
		for n in idx:
			taken[n] = 1
			_used[pts[n]] = 1
			fx.append(xs[n])
			fy.append(ys[n])
			fw.append(ws[n])
		var fit := _fit_line(fx, fy, fw)
		var target := _snap(fit[0], idx.size())
		var e1x := w.cx + dx * w.lo
		var e1y := w.cy + dy * w.lo
		var e2x := w.cx + dx * w.hi
		var e2y := w.cy + dy * w.hi
		w.a = _mod_pi(w.a + _half_ang_diff(target, w.a) * 0.3)
		dx = cos(w.a)
		dy = sin(w.a)
		var mx := fit[1] - w.cx
		var my := fit[2] - w.cy
		var dn := -mx * dy + my * dx
		var du := mx * dx + my * dy
		w.cx += -dy * dn * 0.3 + dx * du
		w.cy += dx * dn * 0.3 + dy * du
		var us := PackedFloat64Array()
		for n in idx:
			us.append((xs[n] - w.cx) * dx + (ys[n] - w.cy) * dy)
		us.sort()
		w.us = us
		w.lo = minf((e1x - w.cx) * dx + (e1y - w.cy) * dy, us[0])
		w.hi = maxf((e2x - w.cx) * dx + (e2y - w.cy) * dy, us[us.size() - 1])
		# The ends shrink only where the floor along the wall is seen free.
		var first := us[0]
		var last := us[us.size() - 1]
		if first > w.lo + 0.1 and not _unknown_between(w.cx + dx * w.lo, w.cy + dy * w.lo, w.cx + dx * (first - CELL), w.cy + dy * (first - CELL)):
			w.lo = first
		if last < w.hi - 0.1 and not _unknown_between(w.cx + dx * (last + CELL), w.cy + dy * (last + CELL), w.cx + dx * w.hi, w.cy + dy * w.hi):
			w.hi = last
	var kept: Array[Wall] = []
	for w in _walls:
		if w.miss < 3:
			kept.append(w)
	_walls = kept


## The cells (first column, first row, last column, last row) around a band
## from u0 to u1 along a line through (cx, cy) with direction (dx, dy), and
## half a width either side of it; a cell's margin all round.
func _band_box(cx: float, cy: float, dx: float, dy: float, u0: float, u1: float, half: float) -> PackedInt32Array:
	var x_lo := INF
	var x_hi := -INF
	var y_lo := INF
	var y_hi := -INF
	for u in [u0, u1]:
		for side in [-half, half]:
			var x: float = cx + dx * u - dy * side
			var y: float = cy + dy * u + dx * side
			x_lo = minf(x_lo, x)
			x_hi = maxf(x_hi, x)
			y_lo = minf(y_lo, y)
			y_hi = maxf(y_hi, y)
	return PackedInt32Array([
		maxi(0, floori((x_lo - gx0) / CELL) - 1), maxi(0, floori((y_lo - gy0) / CELL) - 1),
		mini(nx - 1, floori((x_hi - gx0) / CELL) + 1), mini(ny - 1, floori((y_hi - gy0) / CELL) + 1),
	])


## 2. New walls only from points no wall took, one per run of cells along a
## Hough line.
func _new_walls(pts: PackedInt32Array, taken: PackedByteArray) -> void:
	var free := PackedInt32Array()
	for n in pts.size():
		if not taken[n]:
			free.append(pts[n])
	for line in _hough(free):
		var c := cos(line[0])
		var s := sin(line[0])
		var inliers: PackedInt32Array = line[2]
		var cells: Array = []
		for n in inliers.size():
			cells.append([-cell_x(inliers[n]) * s + cell_y(inliers[n]) * c, n, inliers[n]])
		cells.sort_custom(func(p, q): return p[0] < q[0] or (p[0] == q[0] and p[1] < q[1]))
		var run: Array = [cells[0]]
		for n in range(1, cells.size()):
			if cells[n][0] - cells[n - 1][0] > 0.3:
				_wall_from_run(run)
				run = []
			run.append(cells[n])
		_wall_from_run(run)


func _wall_from_run(run: Array) -> void:
	if run.size() < 6 or run[run.size() - 1][0] - run[0][0] < 0.15:
		return
	var fx := PackedFloat64Array()
	var fy := PackedFloat64Array()
	var fw := PackedFloat64Array()
	for item in run:
		var k: int = item[2]
		fx.append(cell_x(k))
		fy.append(cell_y(k))
		fw.append(maxf(0.3, log_odds[k]))
	var fit := _fit_line(fx, fy, fw)
	var dx := cos(fit[0])
	var dy := sin(fit[0])
	var us := PackedFloat64Array()
	for n in fx.size():
		us.append((fx[n] - fit[1]) * dx + (fy[n] - fit[2]) * dy)
	us.sort()
	for item in run:
		_used[item[2]] = 1
	var w := Wall.new()
	w.id = _next_id
	_next_id += 1
	w.cx = fit[1]
	w.cy = fit[2]
	w.a = fit[0]
	w.lo = us[0]
	w.hi = us[us.size() - 1]
	w.us = us
	_walls.append(w)


## 3. Walls on one line with a small gap become one.
func _merge_walls() -> void:
	# Directions do not change while merging; twice the angle tells quickly
	# which pairs are far from parallel (the exact test still decides).
	var cs := PackedFloat64Array()
	var sn := PackedFloat64Array()
	var c2 := PackedFloat64Array()
	var s2 := PackedFloat64Array()
	for w in _walls:
		cs.append(cos(w.a))
		sn.append(sin(w.a))
		c2.append(cos(2.0 * w.a))
		s2.append(sin(2.0 * w.a))
	var far := cos(12.0 * DEG) - 1e-6
	var i := 0
	while i < _walls.size():
		var j := _walls.size() - 1
		while j > i:
			var a := _walls[i]
			var b := _walls[j]
			var bj := j
			j -= 1
			if c2[i] * c2[bj] + s2[i] * s2[bj] < far or absf(_half_ang_diff(a.a, b.a)) > 6.0 * DEG:
				continue
			var dx := cs[i]
			var dy := sn[i]
			var bx := cs[bj]
			var by := sn[bj]
			if absf(-(b.cx - a.cx) * dy + (b.cy - a.cy) * dx) > 0.06 or absf(-(a.cx - b.cx) * by + (a.cy - b.cy) * bx) > 0.06:
				continue
			var p_lo := (b.cx + bx * b.lo - a.cx) * dx + (b.cy + by * b.lo - a.cy) * dy
			var p_hi := (b.cx + bx * b.hi - a.cx) * dx + (b.cy + by * b.hi - a.cy) * dy
			var b1 := minf(p_lo, p_hi)
			var b2 := maxf(p_lo, p_hi)
			if maxf(b1 - a.hi, a.lo - b2) > 0.25:
				continue
			a.lo = minf(a.lo, b1)
			a.hi = maxf(a.hi, b2)
			var us := a.us.duplicate()
			for u in b.us:
				us.append((b.cx + bx * u - a.cx) * dx + (b.cy + by * u - a.cy) * dy)
			us.sort()
			a.us = us
			_walls.remove_at(bj)
			cs.remove_at(bj)
			sn.remove_at(bj)
			c2.remove_at(bj)
			s2.remove_at(bj)
		i += 1


## 4. The room's axes, from the long walls.
func _find_axis() -> void:
	var sx := 0.0
	var sy := 0.0
	var total := 0.0
	for w in _walls:
		var length := w.hi - w.lo
		if length < 0.4:
			continue
		sx += length * cos(4.0 * w.a)
		sy += length * sin(4.0 * w.a)
		total += length
	_axis = atan2(sy, sx) / 4.0 if total > 1.0 and sqrt(sx * sx + sy * sy) > 0.5 * total else NAN


## A direction within 7 degrees of the room's axes is taken as on them.
func _snap(a: float, support: int) -> float:
	if is_nan(_axis) or support < 6:
		return a
	var d := a - _axis
	d = d - _round_half_up(d / (PI / 2.0)) * (PI / 2.0)
	return _mod_pi(a - d) if absf(d) < 7.0 * DEG else a


## Lines through the points (sorted cells), the best first; each takes its
## points away. Returns [angle, distance from the origin, inlier cells] per line.
func _hough(points: PackedInt32Array) -> Array:
	_vote_to(points)
	var remaining := points
	var lines: Array = []
	for line in HOUGH_LINES:
		if remaining.size() < HOUGH_VOTES:
			break
		# The first bin with the most votes, as a scan of the whole accumulator
		# would find; a bin under HOUGH_VOTES could not make a line anyway.
		var best := 0
		var best_i := 0
		for i in _hot:
			var votes := _acc[i]
			if votes > best or (votes == best and i < best_i):
				best = votes
				best_i = i
		if best < HOUGH_VOTES:
			break
		var tb := best_i / _nr
		var rho := (best_i % _nr + 0.5) * HOUGH_STEP - _rmax
		var c := _cos_t[tb]
		var s := _sin_t[tb]
		var inliers := PackedInt32Array()
		var rest := PackedInt32Array()
		for k in remaining:
			if absf(cell_x(k) * c + cell_y(k) * s - rho) < 0.06:
				inliers.append(k)
			else:
				rest.append(k)
		_vote(inliers, -1)
		remaining = rest
		if inliers.size() >= HOUGH_VOTES:
			lines.append([tb * PI / HOUGH_ANGLES, rho, inliers])
	_acc_cells = remaining
	return lines


## Brings the accumulator to the votes of exactly these cells (sorted): the
## cells that left take theirs back, the cells that came vote.
func _vote_to(cells: PackedInt32Array) -> void:
	var gone := PackedInt32Array()
	var came := PackedInt32Array()
	var a := 0
	var b := 0
	while a < _acc_cells.size() or b < cells.size():
		if b >= cells.size() or (a < _acc_cells.size() and _acc_cells[a] < cells[b]):
			gone.append(_acc_cells[a])
			a += 1
		elif a >= _acc_cells.size() or cells[b] < _acc_cells[a]:
			came.append(cells[b])
			b += 1
		else:
			a += 1
			b += 1
	_vote(gone, -1)
	_vote(came, 1)
	_acc_cells = cells


func _vote(cells: PackedInt32Array, delta: int) -> void:
	for k in cells:
		var x := cell_x(k)
		var y := cell_y(k)
		for t in HOUGH_ANGLES:
			var i := t * _nr + floori((x * _cos_t[t] + y * _sin_t[t] + _rmax) / HOUGH_STEP)
			var before := _acc[i]
			_acc[i] = before + delta
			if delta > 0 and before + delta == HOUGH_VOTES:
				_hot[i] = true
			elif delta < 0 and before == HOUGH_VOTES:
				_hot.erase(i)


## The floor between two points of a line was never seen free.
func _unknown_between(x1: float, y1: float, x2: float, y2: float) -> bool:
	var n := maxi(1, ceili(sqrt((x2 - x1) * (x2 - x1) + (y2 - y1) * (y2 - y1)) / CELL))
	for i in n + 1:
		var k := cell_of(x1 + (x2 - x1) * i / n, y1 + (y2 - y1) * i / n)
		if k >= 0 and log_odds[k] < -1.2:
			return false
	return true


## Pieces along a line through (ox, oy) with direction (dx, dy), from the sorted
## positions of its cells. A gap under 25 cm whose floor was never seen free
## is wall; a longer or seen gap splits the wall.
func _pieces_along(ox: float, oy: float, dx: float, dy: float, along: PackedFloat64Array, wall_id: int) -> Array[Piece]:
	var out: Array[Piece] = []
	var start := along[0]
	var prev := along[0]
	for n in range(1, along.size()):
		var u := along[n]
		var gap := u - prev
		if gap <= 2.5 * CELL:
			prev = u
			continue
		var open := not _unknown_between(ox + dx * (prev + CELL), oy + dy * (prev + CELL), ox + dx * (u - CELL), oy + dy * (u - CELL))
		if gap < 0.25 and not open:
			prev = u
			continue
		_flush_piece(out, ox, oy, dx, dy, start, prev, wall_id)
		start = u
		prev = u
	_flush_piece(out, ox, oy, dx, dy, start, prev, wall_id)
	return out


func _flush_piece(out: Array[Piece], ox: float, oy: float, dx: float, dy: float, a: float, b: float, wall_id: int) -> void:
	if b - a < 0.12:
		return
	var p := Piece.new()
	p.x1 = ox + dx * (a - CELL / 2.0)
	p.y1 = oy + dy * (a - CELL / 2.0)
	p.x2 = ox + dx * (b + CELL / 2.0)
	p.y2 = oy + dy * (b + CELL / 2.0)
	p.wall = wall_id
	out.append(p)


# -- geometry ----------------------------------------------------------------------------

static func seg_dist(x: float, y: float, p: Piece) -> float:
	var ex := p.x2 - p.x1
	var ey := p.y2 - p.y1
	var l2 := ex * ex + ey * ey
	var t := clampf(((x - p.x1) * ex + (y - p.y1) * ey) / l2, 0.0, 1.0) if l2 > 0.0 else 0.0
	var qx := x - (p.x1 + ex * t)
	var qy := y - (p.y1 + ey * t)
	return sqrt(qx * qx + qy * qy)


## The difference of two line directions (defined modulo pi).
static func _half_ang_diff(a: float, b: float) -> float:
	return 0.5 * atan2(sin(2.0 * (a - b)), cos(2.0 * (a - b)))


static func _mod_pi(a: float) -> float:
	var r := fmod(a, PI)
	return r + PI if r < 0.0 else r


## Math.round: halves go up.
static func _round_half_up(v: float) -> float:
	return floorf(v + 0.5)


## The weighted principal direction of points: [angle, mean x, mean y].
static func _fit_line(xs: PackedFloat64Array, ys: PackedFloat64Array, ws: PackedFloat64Array) -> PackedFloat64Array:
	var total := 0.0
	var mx := 0.0
	var my := 0.0
	for i in xs.size():
		total += ws[i]
		mx += ws[i] * xs[i]
		my += ws[i] * ys[i]
	mx /= total
	my /= total
	var sxx := 0.0
	var syy := 0.0
	var sxy := 0.0
	for i in xs.size():
		var dx := xs[i] - mx
		var dy := ys[i] - my
		sxx += ws[i] * dx * dx
		syy += ws[i] * dy * dy
		sxy += ws[i] * dx * dy
	return PackedFloat64Array([_mod_pi(0.5 * atan2(2.0 * sxy, sxx - syy)), mx, my])
