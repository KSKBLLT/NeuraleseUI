@tool
extends EditorScript

func _run() -> void:
	var glob = preload("res://scripts/glob.gd").new()
	var path = "user://datasets/" + glob.sha1("generated") + ".ds"

	if not FileAccess.file_exists(path):
		print("Dataset not found at: ", path)
		return

	var file = FileAccess.open(path, FileAccess.READ)
	var length = file.get_var()
	var compressed = file.get_var()
	file.close()

	var decompressed = compressed.decompress(length, FileAccess.COMPRESSION_ZSTD)
	var ds = bytes_to_var_with_objects(decompressed)

	if ds == null:
		print("Failed to decode dataset!")
		return

	var row_count = ds.get("row_count", 0)
	var col_count = ds.get("column_count", 0)
	var values: PackedFloat32Array = ds.get("values", PackedFloat32Array())
	var outputs_from = ds.get("outputs_from", 0)
	var col_names = ds.get("col_names", [])

	print("--- DATASET STATS ---")
	print("Rows: ", row_count)
	print("Cols: ", col_count)
	print("Outputs from index: ", outputs_from)
	print("Col Names: ", col_names)
	print("Metadata: ", ds.get("metadata", {}))

	print("\n--- FIRST 20 ROWS ---")
	for r in range(min(row_count, 20)):
		var offset = r * col_count
		var row_str = ""
		for c in range(col_count):
			row_str += "%.3f" % values[offset + c] + "\t"
		print(row_str)

	print("\n--- ACTION STATS (First 5000 rows) ---")
	var action_stats = {}
	for r in range(min(row_count, 5000)):
		var offset = r * col_count
		var action = ""
		for c in range(outputs_from, col_count):
			action += "%.3f" % values[offset + c] + ","
		if not action_stats.has(action):
			action_stats[action] = 0
		action_stats[action] += 1

	for act in action_stats:
		print("Action [", act, "]: ", action_stats[act])

	print("--- END ---")
