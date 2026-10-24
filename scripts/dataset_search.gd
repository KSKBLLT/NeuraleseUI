class_name DatasetSearch
extends RefCounted


static func filter(entries: Dictionary, query: String) -> Dictionary:
	var normalized := query.strip_edges().to_lower()
	if normalized.is_empty():
		return entries.duplicate(true)

	var result := {}
	for dataset_id in entries:
		var entry: Variant = entries[dataset_id]
		var searchable := str(dataset_id)
		if entry is Dictionary:
			searchable += " " + JSON.stringify(entry.get("data", {}))
		if searchable.to_lower().contains(normalized):
			result[dataset_id] = entry
	return result
