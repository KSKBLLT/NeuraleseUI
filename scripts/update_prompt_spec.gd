extends RefCounted
class_name UpdatePromptSpec

const DialogSpecCore := preload("res://scripts/dialog_spec.gd")
const LANGUAGES := ["en", "ru", "kz"]


static func build(state: Dictionary) -> Dictionary:
	var version := str(state.get("version", "")).strip_edges()
	var mandatory: bool = state.get("mandatory", false) == true
	var body := _localized_body(version, state.get("notes_markdown", ""))
	var buttons: Array[Dictionary] = []
	if not mandatory:
		buttons.append({
			"id": "continue",
			"text": {
				"en": "Continue without updating",
				"ru": "Продолжить без обновления",
				"kz": "Жаңартусыз жалғастыру",
			},
			"style": "secondary",
		})

	return {
		"id": "update_available",
		"title": {
			"en": "Update available",
			"ru": "Доступно обновление",
			"kz": "Жаңарту қолжетімді",
		},
		"body": body,
		"format": "markdown",
		"icon_path": "res://game_assets/icons/download.png",
		"size": {"width": 520, "height": 320},
		"dismiss_on_escape": not mandatory,
		"dismiss_on_outside_click": false,
		"progress": {
			"visible": true,
			"value": 0.0,
			"status": {
				"en": "Preparing update",
				"ru": "Подготовка обновления",
				"kz": "Жаңартуды дайындау",
			},
			"detail": "",
		},
		"buttons": buttons,
	}


static func _localized_body(version: String, notes: Variant) -> Dictionary:
	var templates := {
		"en": "Version **%s** is being downloaded.",
		"ru": "Скачивается версия **%s**.",
		"kz": "**%s** нұсқасы жүктелуде.",
	}
	var result := {}
	for language in LANGUAGES:
		var text: String = templates[language] % version
		var localized_notes := DialogSpecCore.localize(notes, language).strip_edges()
		if not localized_notes.is_empty():
			text += "\n\n" + localized_notes
		result[language] = text
	return result
