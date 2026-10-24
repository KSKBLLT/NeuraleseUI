class_name PackedNumericDataset
extends RefCounted

## Columnar row-major float storage used by generated simulation datasets.


static func is_packed(dataset: Dictionary) -> bool:
	return str(dataset.get("storage", "")) == "packed_float32" and dataset.get("values") is PackedFloat32Array


static func row_count(dataset: Dictionary) -> int:
	if is_packed(dataset):
		return int(dataset.get("row_count", 0))
	var rows: Variant = dataset.get("arr", [])
	return rows.size() if rows is Array else 0


static func column_count(dataset: Dictionary) -> int:
	if is_packed(dataset):
		return int(dataset.get("column_count", 0))
	var rows: Variant = dataset.get("arr", [])
	return rows[0].size() if rows is Array and not rows.is_empty() else 0


static func value(dataset: Dictionary, row: int, column: int) -> float:
	if not is_packed(dataset):
		return 0.0
	var columns := column_count(dataset)
	var values: PackedFloat32Array = dataset["values"]
	var offset := row * columns + column
	return values[offset] if row >= 0 and row < row_count(dataset) and column >= 0 and column < columns and offset >= 0 and offset < values.size() else 0.0


static func materialize_legacy_rows(dataset: Dictionary) -> Array:
	var existing: Variant = dataset.get("arr", [])
	if existing is Array and not existing.is_empty():
		return existing
	if not is_packed(dataset):
		return []
	var rows: Array = []
	var count := row_count(dataset)
	var columns := column_count(dataset)
	var values: PackedFloat32Array = dataset["values"]
	var column_types: PackedStringArray = _column_types(dataset, columns)
	rows.resize(count)
	for row_index in count:
		var row: Array[Dictionary] = []
		row.resize(columns)
		var offset := row_index * columns
		for column_index in columns:
			var number: float = values[offset + column_index]
			row[column_index] = {"type": "float", "val": number} if column_types[column_index] == "float" else {"type": "num", "num": number}
		rows[row_index] = row
	dataset["arr"] = rows
	return rows


static func _column_types(dataset: Dictionary, columns: int) -> PackedStringArray:
	var result: PackedStringArray = PackedStringArray()
	result.resize(columns)
	var column_names: Variant = dataset.get("col_names", [])
	for column_index in columns:
		var column_name: String = str(column_names[column_index]) if column_names is Array and column_index < column_names.size() else ""
		var parts: PackedStringArray = column_name.rsplit(":", true, 1)
		result[column_index] = parts[1] if parts.size() > 1 else "num"
	return result


static func make_editable(dataset: Dictionary) -> Array:
	var rows: Array = materialize_legacy_rows(dataset)
	if is_packed(dataset):
		# The dataset editor mutates legacy row dictionaries. Once opened there,
		# those rows must become the canonical storage or later training/saving
		# would continue reading the stale packed snapshot.
		dataset["storage"] = "legacy_rows"
		dataset.erase("values")
		dataset.erase("row_count")
		dataset.erase("column_count")
	return rows
