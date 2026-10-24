extends RefCounted
## Dataset Bento: reading cells and describing situations — where a car's
## walls are, what its rows answer, and the bars that sketch each situation.
## Pure data, used by dataset_bento_analysis.gd on a worker thread.

static func cell_number(cell: Variant) -> float:
	if cell is Dictionary:
		match str(cell.get("type", "")):
			"num":
				return float(cell.get("num", 0))
			"float":
				return float(cell.get("val", 0.0))
			"text":
				var text := str(cell.get("text", "")).strip_edges()
				return text.to_float() if text.is_valid_float() else NAN
		return NAN
	if cell is float or cell is int:
		return float(cell)
	return NAN


static func cell_text(cell: Variant) -> String:
	if cell is Dictionary:
		match str(cell.get("type", "")):
			"num":
				return str(cell.get("num", 0))
			"float":
				return String.num(float(cell.get("val", 0.0)), 2)
			"text":
				return str(cell.get("text", ""))
			"image":
				return "▦"
	return str(cell)


static func cell_image(cell: Variant) -> Image:
	if cell is Dictionary and cell.get("img") is Image:
		return cell["img"]
	return null


## Simulation datasets: rays, speed, steering and throttle by column name.
static func car_columns(columns: Array[String], inputs: Array, outputs: Array, rows: Array) -> Dictionary:
	var rays: Array[int] = []
	var car := {"rays": rays, "speed": -1, "steer": -1, "throttle": -1, "ray_max": 1.0, "speed_max": 1.0}
	for c in inputs:
		if columns[c].begins_with("Ray "):
			rays.append(c)
		elif columns[c] == "Speed":
			car["speed"] = c
	for c in outputs:
		if columns[c] == "Steering":
			car["steer"] = c
		elif columns[c] == "Throttle":
			car["throttle"] = c
	if rays.size() < 3 or car["steer"] < 0:
		return {}
	for row in rows:
		if row is Array and row.size() > rays.max():
			for c in rays:
				car["ray_max"] = maxf(car["ray_max"], absf(finite(cell_number(row[c]))))
			if car["speed"] >= 0:
				car["speed_max"] = maxf(car["speed_max"], absf(finite(cell_number(row[car["speed"]]))))
	return car


## Bar heights for a situation: its rays and speed, or its mean inputs.
static func profile(points: PackedFloat32Array, dims: int, members: PackedInt32Array, car: Dictionary, rows: Array, picks: PackedInt32Array, image: bool) -> PackedFloat32Array:
	var profile := PackedFloat32Array()
	if image:
		return profile
	if not car.is_empty():
		var columns: Array = car["rays"].duplicate()
		if car["speed"] >= 0:
			columns.append(car["speed"])
		for c in columns:
			var scale: float = car["speed_max"] if c == car["speed"] else car["ray_max"]
			var total := 0.0
			for i in members:
				total += absf(finite(cell_number(rows[picks[i]][c]))) / maxf(scale, 0.000001)
			profile.append(total / members.size())
		return profile
	for d in mini(dims, 12):
		var total := 0.0
		for i in members:
			total += points[i * dims + d]
		profile.append(total / members.size())
	return profile


## What a situation is about. Cars: where the walls are. Otherwise the inputs
## that stand out most from the whole dataset, up or down.
static func label(points: PackedFloat32Array, n: int, dims: int, members: PackedInt32Array, result: Dictionary, rows: Array, picks: PackedInt32Array) -> Dictionary:
	var car: Dictionary = result["car"]
	if not car.is_empty():
		var rays: Array = car["rays"]
		var m := PackedFloat32Array()
		for c in rays:
			var total := 0.0
			for i in members:
				total += finite(cell_number(rows[picks[i]][c])) / maxf(car["ray_max"], 0.000001)
			m.append(total / members.size())
		var speed := 1.0
		if car["speed"] >= 0:
			var total := 0.0
			for i in members:
				total += absf(finite(cell_number(rows[picks[i]][car["speed"]]))) / maxf(car["speed_max"], 0.000001)
			speed = total / members.size()
		return {"car": car_key(m, speed)}
	if result["kind"] == "image" or dims == 0:
		return {"features": []}
	var standouts: Array = []
	for d in dims:
		var overall := 0.0
		var spread := 0.0
		for i in n:
			overall += points[i * dims + d] / n
		for i in n:
			spread += pow(points[i * dims + d] - overall, 2) / n
		var own := 0.0
		for i in members:
			own += points[i * dims + d] / members.size()
		var z := (own - overall) / maxf(sqrt(spread), 0.000001)
		if absf(z) > 0.4:
			standouts.append([result["inputs"][d], z])
	standouts.sort_custom(func(a, b): return absf(a[1]) > absf(b[1]))
	return {"features": standouts.slice(0, 2).map(func(s): return [s[0], s[1] > 0.0])}


## What a situation's rows answer: the car's action, the commonest word or the mean.
static func action(members: PackedInt32Array, answers: Dictionary, car: Dictionary, rows: Array, picks: PackedInt32Array) -> Dictionary:
	if not car.is_empty():
		var steer := 0.0
		var gas := 1.0
		for i in members:
			steer += finite(cell_number(rows[picks[i]][car["steer"]])) / members.size()
		if car["throttle"] >= 0:
			gas = 0.0
			for i in members:
				gas += finite(cell_number(rows[picks[i]][car["throttle"]])) / members.size()
		return {"car": car_action(steer, gas)}
	if answers["numeric"]:
		var means := PackedFloat32Array()
		for i in members:
			var values: PackedFloat32Array = answers["numbers"][i]
			if means.is_empty():
				means.resize(values.size())
			for o in values.size():
				means[o] += values[o] / members.size()
		return {"values": Array(means).map(func(v): return String.num(v, 2))}
	var votes := {}
	for i in members:
		var word: String = answers["words"][i]
		votes[word] = votes.get(word, 0) + 1
	var best := ""
	for word in votes:
		if best == "" or votes[word] > votes[best]:
			best = word
	return {"word": best}


## Where the walls are around a car, from its rays (0..1, far is 1) and speed (0..1).
static func car_key(rays: PackedFloat32Array, speed: float) -> String:
	if rays.is_empty():
		return "mixed"
	var third := maxi(1, rays.size() / 3)
	var left := mean(rays.slice(0, third))
	var right := mean(rays.slice(rays.size() - third))
	var centre := mean(rays.slice(third, rays.size() - third)) if rays.size() > third * 2 else (left + right) * 0.5
	var lowest := 1.0
	for value in rays:
		lowest = minf(lowest, value)
	if lowest > 0.8:
		return "start" if speed < 0.35 else "free"
	if centre < 0.5 and left > centre + 0.2 and right > centre + 0.2:
		return "obstacle"
	if right < left - 0.2:
		return "wall_right"
	if left < right - 0.2:
		return "wall_left"
	if left < 0.65 and right < 0.65:
		return "corridor"
	return "mixed"


static func car_action(steer: float, gas: float) -> String:
	if gas < 0.4:
		return "brake"
	if steer < -0.25:
		return "left"
	if steer > 0.25:
		return "right"
	return "straight"


static func mean(values: PackedFloat32Array) -> float:
	var total := 0.0
	for value in values:
		total += value
	return total / maxf(1.0, values.size())


static func finite(value: float) -> float:
	return 0.0 if is_nan(value) or is_inf(value) else value
