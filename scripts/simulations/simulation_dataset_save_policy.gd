class_name SimulationDatasetSavePolicy
extends RefCounted


static func requires_confirmation(dataset: Dictionary, cancel_requested: bool) -> bool:
	return (
		cancel_requested
		and dataset.get("metadata", {}).get("partial", false) == true
		and PackedNumericDataset.row_count(dataset) > 0
	)


static func confirmation_spec(row_count: int) -> Dictionary:
	return {
		"id": "simulation_partial_dataset",
		"title": {
			"en": "Save partial dataset?",
			"ru": "Сохранить неполный датасет?",
			"kz": "Сохранить неполный датасет?",

		},
		"body": {
			"en": "Generation stopped after **%d valid rows**. Save them as a partial dataset or discard them." % row_count,
			"ru": "Генерация остановлена после **%d корректных строк**. Сохранить их как неполный датасет или удалить?" % row_count,
			"kz": "Генерация остановлена после **%d корректных строк**. Сохранить их как неполный датасет или удалить?" % row_count,

		},
		"format": "markdown",
		"size": {"width": 480, "height": 260},
		"dismiss_on_escape": true,
		"dismiss_on_outside_click": false,
		"buttons": [
			{"id": "discard", "text": {"en": "Discard", "ru": "Удалить"}, "style": "secondary"},
			{"id": "save", "text": {"en": "Save partial", "ru": "Сохранить"}, "style": "primary"},
		],
	}
