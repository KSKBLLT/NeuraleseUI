extends RefCounted
## Dataset Bento analysis. Groups alike rows into situations (k-means, k picked
## by silhouette), finds rows whose answer disagrees with their nearest alike
## rows, and lays rows out on a 2-D map (PCA) where alike rows sit close.
## Pure data with no scene access, so it runs on a worker thread.

## Rows analysed; a larger dataset is sampled evenly.
const MAX_ROWS := 1500
const NEIGHBOURS := 8
## Situations smaller than this are not checked for mistakes.
const MIN_GROUP := 12
## Nearest neighbours are looked for among at most this many rows of a group.
const MAX_REFERENCE := 400
const Situations := preload("res://scripts/ui/dataset_bento_situations.gd")
const PALETTE: Array[Color] = [
	Color("#5598F9"), Color("#FC9252"), Color("#F47DB9"), Color("#89D7F9"), Color("#8294A7"), Color("#5F6275"),
]


static func analyze(ds: Dictionary) -> Dictionary:
	var names: Array = ds.get("col_names", [])
	var split: int = clampi(int(ds.get("outputs_from", names.size())), 0, names.size())
	var rows: Array = ds.get("arr", [])
	var columns: Array[String] = []
	var dtypes: Array[String] = []
	for column in names:
		columns.append(str(column).get_slice(":", 0))
		dtypes.append(str(column).get_slice(":", 1) if ":" in str(column) else "text")
	var inputs := range(split)
	var outputs := range(split, names.size())
	var image := inputs.any(func(c): return dtypes[c] == "image")
	var result := {
		"kind": "image" if image else "table",
		"rows": rows.size(),
		"inputs": inputs.map(func(c): return columns[c]),
		"outputs": outputs.map(func(c): return columns[c]),
		"car": Situations.car_columns(columns, inputs, outputs, rows),
		"clusters": [],
		"errors": {},
		"points": PackedVector2Array(),
		"point_rows": PackedInt32Array(),
		"point_cluster": PackedInt32Array(),
		"sampled": rows.size() > MAX_ROWS,
	}
	var picks := PackedInt32Array()
	var step := maxf(1.0, float(rows.size()) / MAX_ROWS)
	var at := 0.0
	while int(at) < rows.size() and picks.size() < MAX_ROWS:
		if rows[int(at)] is Array and rows[int(at)].size() >= names.size():
			picks.append(int(at))
		at += step
	var n := picks.size()
	if n < 2 or inputs.is_empty():
		return result
	var dims := 36 if image else inputs.size()
	var points := _image_features(rows, picks, inputs[0]) if image else _table_features(rows, picks, inputs)
	var answers := _answers(rows, picks, outputs)
	# Situations: k from 2 to 6, the clearest split wins.
	var assign := PackedInt32Array()
	assign.resize(n)
	var k := 1
	if n >= 8:
		var best := -2.0
		for candidate in range(2, mini(6, n - 1) + 1):
			var trial := _kmeans(points, n, dims, candidate, 7 + candidate)
			var score := _silhouette(points, n, dims, trial, candidate)
			if score > best:
				best = score
				assign = trial
				k = candidate
	var errors := _mistakes(points, n, dims, assign, k, answers)
	for sample in errors:
		result["errors"][picks[sample]] = errors[sample]
	# Groups without their mistakes, the largest first.
	var groups: Array = []
	for c in k:
		var members := PackedInt32Array()
		for i in n:
			if assign[i] == c and not errors.has(i):
				members.append(i)
		if not members.is_empty():
			groups.append(members)
	groups.sort_custom(func(a, b): return a.size() > b.size())
	var mapped := _pca_2d(points, n, dims)
	var cluster_of := PackedInt32Array()
	cluster_of.resize(n)
	cluster_of.fill(-1)
	for g in groups.size():
		var members: PackedInt32Array = groups[g]
		var rows_of := PackedInt32Array()
		var centre := Vector2.ZERO
		for i in members:
			cluster_of[i] = g
			rows_of.append(picks[i])
			centre += mapped[i]
		result["clusters"].append({
			"color": PALETTE[g % PALETTE.size()],
			"members": rows_of,
			"profile": Situations.profile(points, dims, members, result["car"], rows, picks, image),
			"label": Situations.label(points, n, dims, members, result, rows, picks),
			"action": Situations.action(members, answers, result["car"], rows, picks),
			"centre": centre / members.size(),
		})
	result["points"] = mapped
	result["point_rows"] = picks
	result["point_cluster"] = cluster_of
	return result


## Inputs scaled to 0..1 per column; words become evenly spaced codes.
static func _table_features(rows: Array, picks: PackedInt32Array, inputs: Array) -> PackedFloat32Array:
	var dims := inputs.size()
	var n := picks.size()
	var points := PackedFloat32Array()
	points.resize(n * dims)
	var is_word := PackedByteArray()
	is_word.resize(n)
	for d in dims:
		var words := {}
		var low := INF
		var high := -INF
		for i in n:
			var cell: Variant = rows[picks[i]][inputs[d]]
			var value := Situations.cell_number(cell)
			is_word[i] = 1 if is_nan(value) else 0
			if is_nan(value):
				var word := Situations.cell_text(cell)
				if not words.has(word):
					words[word] = words.size()
				value = words[word]
			else:
				low = minf(low, value)
				high = maxf(high, value)
			points[i * dims + d] = value
		for i in n:
			var value := points[i * dims + d]
			if is_word[i]:
				points[i * dims + d] = value / maxf(1.0, words.size() - 1.0)
			else:
				points[i * dims + d] = (value - low) / (high - low) if high > low else 0.5
	return points


## Images as 6×6 grey thumbnails.
static func _image_features(rows: Array, picks: PackedInt32Array, column: int) -> PackedFloat32Array:
	var points := PackedFloat32Array()
	points.resize(picks.size() * 36)
	for i in picks.size():
		var source := Situations.cell_image(rows[picks[i]][column])
		if source == null or source.is_empty():
			continue
		var small := source.duplicate() as Image
		if small.is_compressed():
			small.decompress()
		small.convert(Image.FORMAT_L8)
		small.resize(6, 6, Image.INTERPOLATE_BILINEAR)
		var data := small.get_data()
		for p in mini(36, data.size()):
			points[i * 36 + p] = data[p] / 255.0
	return points


## Each sampled row's answer: numbers when every output is a number, else words.
static func _answers(rows: Array, picks: PackedInt32Array, outputs: Array) -> Dictionary:
	var numbers: Array[PackedFloat32Array] = []
	var words := PackedStringArray()
	var numeric := not outputs.is_empty()
	for row_index in picks:
		var row: Array = rows[row_index]
		var values := PackedFloat32Array()
		var parts := PackedStringArray()
		for c in outputs:
			var value := Situations.cell_number(row[c])
			numeric = numeric and not is_nan(value)
			values.append(value)
			parts.append(Situations.cell_text(row[c]))
		numbers.append(values)
		words.append(", ".join(parts))
	var spans := PackedFloat32Array()
	if numeric:
		for o in outputs.size():
			var low := INF
			var high := -INF
			for values in numbers:
				low = minf(low, values[o])
				high = maxf(high, values[o])
			spans.append(high - low)
	return {"numeric": numeric, "numbers": numbers, "words": words, "spans": spans}


static func _d2(points: PackedFloat32Array, a: int, b: int, dims: int) -> float:
	var total := 0.0
	for d in dims:
		var q := points[a * dims + d] - points[b * dims + d]
		total += q * q
	return total


static func _kmeans(points: PackedFloat32Array, n: int, dims: int, k: int, seed: int) -> PackedInt32Array:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	# k-means++ start: each next centre far from the ones chosen.
	var centres := PackedFloat32Array()
	var first := rng.randi_range(0, n - 1)
	centres.append_array(points.slice(first * dims, first * dims + dims))
	var nearest := PackedFloat32Array()
	nearest.resize(n)
	while centres.size() < k * dims:
		var total := 0.0
		for i in n:
			var best := INF
			for c in centres.size() / dims:
				best = minf(best, _centre_d2(points, i, centres, c, dims))
			nearest[i] = best
			total += best
		var target := rng.randf() * total
		var chosen := n - 1
		for i in n:
			target -= nearest[i]
			if target <= 0.0:
				chosen = i
				break
		centres.append_array(points.slice(chosen * dims, chosen * dims + dims))
	var assign := PackedInt32Array()
	assign.resize(n)
	for iteration in 15:
		var moved := false
		for i in n:
			var best := 0
			var best_d := INF
			for c in k:
				var d := _centre_d2(points, i, centres, c, dims)
				if d < best_d:
					best_d = d
					best = c
			if assign[i] != best:
				moved = true
			assign[i] = best
		if not moved and iteration > 0:
			break
		var counts := PackedInt32Array()
		counts.resize(k)
		centres.fill(0.0)
		for i in n:
			counts[assign[i]] += 1
			for d in dims:
				centres[assign[i] * dims + d] += points[i * dims + d]
		for c in k:
			for d in dims:
				centres[c * dims + d] /= maxf(1.0, counts[c])
	return assign


static func _centre_d2(points: PackedFloat32Array, i: int, centres: PackedFloat32Array, c: int, dims: int) -> float:
	var total := 0.0
	for d in dims:
		var q := points[i * dims + d] - centres[c * dims + d]
		total += q * q
	return total


## Mean silhouette over an even subsample: how much closer rows sit to their
## own group than to the next one.
static func _silhouette(points: PackedFloat32Array, n: int, dims: int, assign: PackedInt32Array, k: int) -> float:
	var picks := PackedInt32Array()
	var step := maxf(1.0, n / 250.0)
	var at := 0.0
	while int(at) < n:
		picks.append(int(at))
		at += step
	var total := 0.0
	for i in picks:
		var sums := PackedFloat32Array()
		sums.resize(k)
		var counts := PackedInt32Array()
		counts.resize(k)
		for j in picks:
			if j != i:
				sums[assign[j]] += sqrt(_d2(points, i, j, dims))
				counts[assign[j]] += 1
		var own := sums[assign[i]] / maxf(1.0, counts[assign[i]])
		var other := INF
		for c in k:
			if c != assign[i] and counts[c] > 0:
				other = minf(other, sums[c] / counts[c])
		if counts[assign[i]] > 0 and other < INF:
			total += (other - own) / maxf(maxf(own, other), 0.000001)
	return total / maxf(1.0, picks.size())


## Rows whose answer differs from what their nearest alike rows answer.
static func _mistakes(points: PackedFloat32Array, n: int, dims: int, assign: PackedInt32Array, k: int, answers: Dictionary) -> Dictionary:
	var found := {}
	var numeric: bool = answers["numeric"]
	var spans: PackedFloat32Array = answers["spans"]
	for c in k:
		var members := PackedInt32Array()
		for i in n:
			if assign[i] == c:
				members.append(i)
		if members.size() < MIN_GROUP:
			continue
		var reference := members
		if members.size() > MAX_REFERENCE:
			reference = PackedInt32Array()
			for r in MAX_REFERENCE:
				reference.append(members[r * members.size() / MAX_REFERENCE])
		for i in members:
			var near := _nearest(points, dims, i, reference)
			if numeric:
				var expected := PackedFloat32Array()
				var off := false
				var own: PackedFloat32Array = answers["numbers"][i]
				for o in own.size():
					var values := PackedFloat32Array()
					for j in near:
						values.append(answers["numbers"][j][o])
					values.sort()
					var middle := (values[(values.size() - 1) / 2] + values[values.size() / 2]) * 0.5
					expected.append(middle)
					off = off or (spans[o] > 0.0 and absf(own[o] - middle) > spans[o] * 0.3)
				if off:
					found[i] = {"expected": expected}
			else:
				var votes := {}
				for j in near:
					var word: String = answers["words"][j]
					votes[word] = votes.get(word, 0) + 1
				for word in votes:
					if votes[word] >= 6 and word != answers["words"][i]:
						found[i] = {"expected": word}
	return found


static func _nearest(points: PackedFloat32Array, dims: int, i: int, reference: PackedInt32Array) -> PackedInt32Array:
	var best_rows := PackedInt32Array()
	var best_d := PackedFloat32Array()
	for j in reference:
		if j == i:
			continue
		var d := _d2(points, i, j, dims)
		if best_rows.size() < NEIGHBOURS:
			best_rows.append(j)
			best_d.append(d)
		elif d < best_d[best_d.size() - 1]:
			best_rows[best_rows.size() - 1] = j
			best_d[best_d.size() - 1] = d
		else:
			continue
		# Keep the list sorted, nearest first.
		var at := best_d.size() - 1
		while at > 0 and best_d[at] < best_d[at - 1]:
			var dd := best_d[at]
			best_d[at] = best_d[at - 1]
			best_d[at - 1] = dd
			var rr := best_rows[at]
			best_rows[at] = best_rows[at - 1]
			best_rows[at - 1] = rr
			at -= 1
	return best_rows


## The two directions rows differ most along, scaled into the map's square.
static func _pca_2d(points: PackedFloat32Array, n: int, dims: int) -> PackedVector2Array:
	var mean := PackedFloat32Array()
	mean.resize(dims)
	for i in n:
		for d in dims:
			mean[d] += points[i * dims + d] / n
	var cov := PackedFloat32Array()
	cov.resize(dims * dims)
	for i in n:
		for a in dims:
			var qa := points[i * dims + a] - mean[a]
			for b in range(a, dims):
				cov[a * dims + b] += qa * (points[i * dims + b] - mean[b]) / n
	for a in dims:
		for b in a:
			cov[a * dims + b] = cov[b * dims + a]
	var axes: Array[PackedFloat32Array] = []
	for axis in 2:
		var v := PackedFloat32Array()
		v.resize(dims)
		for d in dims:
			v[d] = 1.0 / (d + 1.0 + axis)
		for iteration in 40:
			var next := PackedFloat32Array()
			next.resize(dims)
			for a in dims:
				for b in dims:
					next[a] += cov[a * dims + b] * v[b]
			for previous in axes:
				var dot := 0.0
				for d in dims:
					dot += next[d] * previous[d]
				for d in dims:
					next[d] -= dot * previous[d]
			var length := 0.0
			for d in dims:
				length += next[d] * next[d]
			length = sqrt(length)
			if length < 0.0000001:
				break
			for d in dims:
				v[d] = next[d] / length
		axes.append(v)
	var mapped := PackedVector2Array()
	mapped.resize(n)
	var low := Vector2(INF, INF)
	var high := Vector2(-INF, -INF)
	for i in n:
		var p := Vector2.ZERO
		for d in dims:
			var q := points[i * dims + d] - mean[d]
			p.x += q * axes[0][d]
			p.y += q * axes[1][d]
		mapped[i] = p
		low = low.min(p)
		high = high.max(p)
	var span := (high - low).max(Vector2(0.000001, 0.000001))
	for i in n:
		mapped[i] = Vector2(0.06, 0.06) + (mapped[i] - low) / span * 0.88
	return mapped
