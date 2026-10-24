extends RefCounted
class_name AccountTypeOnboarding

const ACCOUNT_TYPES := ["student", "teacher"]

var _cookies: Variant
var _ui: Variant


func _init(cookies: Variant = null, ui: Variant = null) -> void:
	_cookies = cookies
	_ui = ui


static func normalize_role(value: Variant) -> String:
	var normalized := str(value).strip_edges().to_lower()
	return normalized if normalized in ACCOUNT_TYPES else ""


static func dialog_spec() -> Dictionary:
	return {
		"id": "account_type",
		"title": {
			"en": "How will you use Neuralese?",
			"ru": "Как вы будете использовать Neuralese?",
			"kz": "Neuralese-ті қалай қолданасыз?",
		},
		"body": {
			"en": "Choose the option that describes you. You can still build projects in either mode.",
			"ru": "Выберите подходящий вариант. Создавать проекты можно в любом режиме.",
			"kz": "Өзіңізге сәйкес нұсқаны таңдаңыз. Екі режимде де жобалар жасауға болады.",
		},
		"format": "plain",
		"icon_path": "res://game_assets/icons/account.png",
		"size": {"width": 520, "height": 260},
		"dismiss_on_escape": false,
		"dismiss_on_outside_click": false,
		"buttons": [
			{
				"id": "student",
				"text": {"en": "Student", "ru": "Ученик", "kz": "Оқушы"},
				"style": "primary",
			},
			{
				"id": "teacher",
				"text": {"en": "Teacher", "ru": "Учитель", "kz": "Мұғалім"},
				"style": "secondary",
			},
		],
	}


func ensure_selected() -> Dictionary:
	if _cookies == null or _ui == null:
		return {"ok": false, "error": "account_type_flow_unavailable"}
	if not _cookies.needs_account_type():
		return {
			"ok": true,
			"profile": _cookies.get_neuralese_profile(),
			"unchanged": true,
		}

	var choice: Dictionary = await _ui.show_dialog_and_get_result(dialog_spec())
	var selected := normalize_role(choice.get("action", ""))
	if selected.is_empty():
		return {"ok": false, "error": "account_type_required"}

	var saved: Dictionary = await _cookies.select_account_type(selected)
	if not saved.get("ok", false):
		return saved
	return {
		"ok": true,
		"profile": saved.get("profile", {}),
	}
