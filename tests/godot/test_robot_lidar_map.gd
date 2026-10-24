extends SceneTree
## The lidar map (scripts/robot/robot_lidar_map.gd) replays the two recorded
## runs of the EV3 "KIRISIMA" and must draw the same walls as the mockup it was
## ported from (prototypes/lidar/mapper.js, metrics by run_metrics.js on the
## same frames): the robot never drives through a drawn wall, beams do not see
## through drawn walls, echoes land on drawn walls, and walls near the robot do
## not flicker. Also: the frames and rebuilds stay cheap enough for old computers.
##
## Run: godot --headless --path . -s tests/godot/test_robot_lidar_map.gd

const LidarMap = preload("res://scripts/robot/robot_lidar_map.gd")
const FIXTURE := "res://local_runtime/tests/fixtures/robot_drive/kirisima_lidar.json.gz"
const REBUILD_S := 0.6
## The mockup's numbers for these runs, every fix on (prototypes/lidar/metrics.json).
const REFERENCE := {
	"datalog_20261007_222935.jsonl": {"crossings": 0, "through": 0.2, "on_wall": 34.3, "gone": 14.1, "appeared": 17.7, "pieces": 12},
	"datalog_20261007_223501.jsonl": {"crossings": 0, "through": 2.7, "on_wall": 58.6, "gone": 23.3, "appeared": 36.1, "pieces": 112},
}

var failures: Array[String] = []


func _initialize() -> void:
	var packed := FileAccess.get_file_as_bytes(FIXTURE)
	var data: Variant = JSON.parse_string(packed.decompress_dynamic(-1, FileAccess.COMPRESSION_GZIP).get_string_from_utf8())
	_expect(data is Dictionary, "the fixture must load")
	if data is Dictionary:
		for run in data["runs"]:
			_check_run(run)
	_test_filter()
	_test_carve_and_crossing()
	if failures.is_empty():
		print("PASS test_robot_lidar_map")
	else:
		printerr("FAIL test_robot_lidar_map: %d failure(s)" % failures.size())
	quit(0 if failures.is_empty() else 1)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _close(value: float, reference: float, tolerance: float, what: String) -> void:
	_expect(absf(value - reference) <= tolerance, "%s: %.1f, the mockup has %.1f" % [what, value, reference])


func _check_run(run: Dictionary) -> void:
	var frames: Array = run["frames"]
	var x0 := INF
	var x1 := -INF
	var y0 := INF
	var y1 := -INF
	for f in frames:
		x0 = minf(x0, f[1])
		x1 = maxf(x1, f[1])
		y0 = minf(y0, f[2])
		y1 = maxf(y1, f[2])
	var sensors: Array = []
	for angle in run["sensor_angles_deg"]:
		sensors.append({"angle": float(angle) * LidarMap.DEG, "x": 0.06, "y": 0.0})
	# The mockup's grid: the run's extent and 3 m around it.
	var map: RobotLidarMap = LidarMap.new(x0 - 3.0, y0 - 3.0, x1 - x0 + 6.0, y1 - y0 + 6.0, sensors)
	var hist: Array = [[], [], []]
	var next := 0.0
	var echoes := 0
	var hit := 0
	var beams := 0
	var through := 0
	var drawn := {}
	var gone := 0
	var appeared := 0
	var feed_us: Array[int] = []
	var rebuild_us: Array[int] = []
	for n in frames.size():
		var f: Array = frames[n]
		var t := float(f[0])
		var started := Time.get_ticks_usec()
		map.feed(t, f[1], f[2], f[3], PackedFloat64Array([f[4], f[5], f[6]]))
		feed_us.append(Time.get_ticks_usec() - started)
		if t >= next:
			started = Time.get_ticks_usec()
			map.rebuild()
			rebuild_us.append(Time.get_ticks_usec() - started)
			next = t + REBUILD_S
			var now_drawn := _raster(map)
			if t > 10.0:
				gone += _unmatched(map, drawn, now_drawn, f[1], f[2])
				appeared += _unmatched(map, now_drawn, drawn, f[1], f[2])
			drawn = now_drawn
		# The same reference reading for every check: the median of the last three echoes.
		for s in 3:
			hist[s].append(float(f[4 + s]))
			if hist[s].size() > 3:
				hist[s].pop_front()
		if n % 2 or t < 10.0:
			continue
		var ox := float(f[1]) + cos(f[3]) * 0.06
		var oy := float(f[2]) + sin(f[3]) * 0.06
		var near: Array = map.pieces.filter(func(p): return RobotLidarMap.seg_dist(ox, oy, p) < 1.7)
		for s in 3:
			var e: Array = hist[s].filter(func(v): return v < 2.5)
			e.sort()
			if e.size() < 2:
				continue
			var d: float = e[e.size() / 2]
			var dir := float(f[3]) + float(run["sensor_angles_deg"][s]) * LidarMap.DEG
			if d < 1.5:
				echoes += 1
				if _explained(near, ox, oy, dir, d):
					hit += 1
			# A wall drawn closer than the echo, across the middle of the beam: the sensor sees through it.
			beams += 1
			var bx := ox + cos(dir) * (d - 0.15)
			var by := oy + sin(dir) * (d - 0.15)
			for p in near:
				if _crosses(ox, oy, bx, by, p):
					through += 1
					break
	map.rebuild()
	var duration := float(frames[frames.size() - 1][0]) - float(frames[0][0])
	var minutes := maxf(1e-6, (duration - 10.0) / 60.0)
	var result := {
		"crossings": map.crossings,
		"through": snappedf(100.0 * through / maxf(1, beams), 0.1),
		"on_wall": snappedf(100.0 * hit / maxf(1, echoes), 0.1),
		"gone": snappedf(gone * LidarMap.CELL / minutes, 0.1),
		"appeared": snappedf(appeared * LidarMap.CELL / minutes, 0.1),
		"pieces": map.pieces.size(),
	}
	var name := str(run["name"])
	var reference: Dictionary = REFERENCE[name]
	print("%s: %d frames; %s; mockup %s" % [name, frames.size(), result, reference])
	print("  feed: mean %.0f us, p99 %d us, max %d us; rebuild: mean %.0f us, max %d us" % [
		_mean(feed_us), _percentile(feed_us, 0.99), feed_us.max(), _mean(rebuild_us), rebuild_us.max()])
	_expect(result["crossings"] == 0, "%s: the robot drove through a drawn wall %d times" % [name, result["crossings"]])
	_close(result["through"], reference["through"], 1.0, name + " beams seeing through walls, %")
	_close(result["on_wall"], reference["on_wall"], 3.0, name + " echoes on drawn walls, %")
	_close(result["gone"], reference["gone"], maxf(3.0, reference["gone"] * 0.15), name + " walls gone near the robot, m/min")
	_close(result["appeared"], reference["appeared"], maxf(3.0, reference["appeared"] * 0.15), name + " walls appeared near the robot, m/min")
	_close(result["pieces"], reference["pieces"], maxf(2.0, reference["pieces"] * 0.1), name + " pieces of wall")


## Does a drawn wall explain this echo: some point of the echo's arc lies on a piece.
func _explained(pieces: Array, ox: float, oy: float, dir: float, d: float) -> bool:
	for da in range(-15, 16, 5):
		var x := ox + cos(dir + da * LidarMap.DEG) * d
		var y := oy + sin(dir + da * LidarMap.DEG) * d
		for p in pieces:
			if RobotLidarMap.seg_dist(x, y, p) < 0.1:
				return true
	return false


func _crosses(x1: float, y1: float, x2: float, y2: float, p: RobotLidarMap.Piece) -> bool:
	var d := (x2 - x1) * (p.y2 - p.y1) - (y2 - y1) * (p.x2 - p.x1)
	if absf(d) < 1e-9:
		return false
	var t := ((p.x1 - x1) * (p.y2 - p.y1) - (p.y1 - y1) * (p.x2 - p.x1)) / d
	var u := ((p.x1 - x1) * (y2 - y1) - (p.y1 - y1) * (x2 - x1)) / d
	return t > 0.0 and t < 1.0 and u > 0.0 and u < 1.0


## The cells the drawn walls cover.
func _raster(map: RobotLidarMap) -> Dictionary:
	var cells := {}
	for p in map.pieces:
		var length := sqrt((p.x2 - p.x1) * (p.x2 - p.x1) + (p.y2 - p.y1) * (p.y2 - p.y1))
		var n := maxi(1, ceili(length / (LidarMap.CELL / 2.0)))
		for i in n + 1:
			var k := map.cell_of(p.x1 + (p.x2 - p.x1) * i / n, p.y1 + (p.y2 - p.y1) * i / n)
			if k >= 0:
				cells[k] = true
	return cells


## Cells of a near the robot with no cell of b next to them (a one-cell shift is not a change).
func _unmatched(map: RobotLidarMap, a: Dictionary, b: Dictionary, rx: float, ry: float) -> int:
	var count := 0
	for k in a:
		if Vector2(map.cell_x(k) - rx, map.cell_y(k) - ry).length() > LidarMap.NO_ECHO_M:
			continue
		var near := false
		for dj in range(-1, 2):
			for di in range(-1, 2):
				if b.has(k + dj * map.nx + di):
					near = true
		if not near:
			count += 1
	return count


## A lone "no echo" between echoes is ignored, three in a row are "no echo",
## and a one-frame spike is dropped by the median.
func _test_filter() -> void:
	var map: RobotLidarMap = LidarMap.new(-2.0, -2.0, 4.0, 4.0, [{"angle": 0.0, "x": 0.0, "y": 0.0}])
	var seen: Array = []
	for value in [1.0, 2.55, 1.0, 0.3, 1.02, 2.55, 2.55, 2.55]:
		map.feed(0.0, 0.0, 0.0, 0.0, PackedFloat64Array([value]))
		seen.append(map.readings[0])
	_expect(is_nan(seen[1]), "one 'no echo' between echoes is a dropout")
	_expect(is_equal_approx(seen[3], 1.0), "a one-frame spike is dropped by the median")
	_expect(is_nan(seen[5]) and is_nan(seen[6]), "two 'no echo' frames are still dropouts")
	_expect(seen[7] == -1.0, "three 'no echo' frames in a row are 'no echo'")


## A wall seen ahead from two places is drawn; driving through it counts once
## and cuts it where the robot went.
func _test_carve_and_crossing() -> void:
	var map: RobotLidarMap = LidarMap.new(-3.0, -3.0, 6.0, 6.0, [{"angle": 0.0, "x": 0.0, "y": 0.0}])
	var t := 0.0
	for step in 40:
		var y := -0.3 + step * 0.015
		map.feed(t, 0.0, y, 0.0, PackedFloat64Array([1.0]))
		t += 0.05
	map.rebuild()
	var across := false
	for p in map.pieces:
		across = across or (absf((p.x1 + p.x2) * 0.5 - 1.0) < 0.12 and absf(p.x2 - p.x1) < absf(p.y2 - p.y1))
	_expect(across, "a wall seen ahead from two places is drawn")
	# Up to the wall and through it, hearing it until the sensor is past it.
	for step in 65:
		var x := step * 0.02
		map.feed(t, x, 0.0, 0.0, PackedFloat64Array([1.0 - x if x < 0.96 else 2.55]))
		t += 0.05
	_expect(map.crossings == 1, "driving through a wall counts once, not %d times" % map.crossings)
	for p in map.pieces:
		_expect(RobotLidarMap.seg_dist(1.0, 0.0, p) > 0.1, "the wall is cut where the robot drove through it")


func _mean(values: Array[int]) -> float:
	var total := 0
	for v in values:
		total += v
	return float(total) / maxf(1, values.size())


func _percentile(values: Array[int], q: float) -> int:
	var sorted := values.duplicate()
	sorted.sort()
	return sorted[mini(sorted.size() - 1, int(sorted.size() * q))]
