extends RefCounted
class_name StartupTutorialPrompt

const StartupDialogStyleCore := preload("res://scripts/startup/startup_dialog_style.gd")

var _ui: Variant


func _init(ui: Variant = null) -> void:
	_ui = ui


static func dialog_spec() -> Dictionary:
	var compact_size := StartupDialogStyleCore.FORM_SIZE.duplicate(true)
	compact_size["height"] = 220
	return {
		"id": "startup_tutorial_prompt",
		"title": {
			"en": "Take a quick tour?",
			"ru": "Пройти короткое знакомство?",
			"kz": "Қысқаша танысуды бастаймыз ба?",
		},
		"inner": true,
		"format": "plain",
		"size": compact_size,
		"surface": "transparent",
		"action_layout": "vertical",
		"appearance": StartupDialogStyleCore.appearance({
			"show_icon": false,
			"hide_node_palette": true,
		}),
		"dismiss_on_escape": false,
		"dismiss_on_outside_click": false,
		"buttons": [
			{
				"id": "start",
				"text": {"en": "Start tour", "ru": "Начать знакомство", "kz": "Танысуды бастау"},
				"style": "primary",
				"can_go": true,
			},
			{
				"id": "later",
				"text": {"en": "Not now", "ru": "Не сейчас", "kz": "Қазір емес"},
				"style": "primary",
				"can_go": false,
				"close_mode": "handoff",
			},
		],
	}


func ask() -> Dictionary:
	if _ui == null:
		return {"ok": false, "error": "tutorial_prompt_unavailable"}
	var result: Dictionary = await _ui.show_dialog_and_get_result(dialog_spec(), true)
	var action := str(result.get("action", ""))
	if action not in ["start", "later"]:
		return {"ok": false, "error": "tutorial_prompt_required"}
	return {"ok": true, "start": action == "start", "action": action}
