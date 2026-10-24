extends SceneTree

func _init():
	var glob = preload("res://scripts/glob.gd").new()
	glob.load_datasets()

	# Try to wait a frame for async load if necessary (load_datasets is partly sync, but cache_rle is async)
	# But actually we don't need RLE for values
	var ds = glob.get_dataset_at("generated")
	if not ds or not ds.has("values"):
		var msg = "Dataset 'generated' not found or empty."
		print(msg)
		var file = FileAccess.open("res://scratch/dataset_stats.txt", FileAccess.WRITE)
		file.store_string(msg)
		file.close()
		quit()
		return

	var row_count = ds.get("row_count", 0)
	var col_count = ds.get("column_count", 0)
	var values: PackedFloat32Array = ds.get("values", PackedFloat32Array())
	var outputs_from = ds.get("outputs_from", 0)
	var col_names = ds.get("col_names", [])

	var out = "Dataset 'generated' loaded:\n"
	out += "- Rows: " + str(row_count) + "\n"
	out += "- Columns: " + str(col_count) + "\n"
	out += "- Inputs (outputs_from): " + str(outputs_from) + "\n"
	out += "- Col names: " + str(col_names) + "\n"
	out += "- Metadata: " + str(ds.get("metadata", {})) + "\n"
	out += "\n"

	var max_rows = min(row_count, 15)
	out += "First 15 rows:\n"
	for r in range(max_rows):
		var offset = r * col_count
		var row_str = ""
		for c in range(col_count):
			row_str += str(values[offset + c]) + " "
		out += row_str + "\n"

	out += "\nActions for first 1000 rows:\n"
	for r in range(min(row_count, 1000)):
		var offset = r * col_count
		var action = ""
		for c in range(outputs_from, col_count):
			action += str(values[offset + c]) + " "
		out += action + "\n"

	var file = FileAccess.open("res://scratch/dataset_stats.txt", FileAccess.WRITE)
	file.store_string(out)
	file.close()

	print("Parsed successfully!")
	quit()
