extends RefCounted
class_name StartupMainMenu

const StartupDialogStyleCore := preload("res://scripts/startup/startup_dialog_style.gd")
const ROUTES := {
	"tutorials": "builtin_projects",
	"continue": "workslist",
	"create": "project_create",
}

var _ui: Variant


func _init(ui: Variant = null) -> void:
	_ui = ui


static func dialog_spec(profile: Dictionary, hide_node_palette: bool = true, but=null) -> Dictionary:
	var name := str(profile.get("certificate_name", "")).strip_edges()
	if name.is_empty():
		name = str(profile.get("first_name", profile.get("display_name", ""))).strip_edges()
	var title := {
		"en": "Hello%s! What would you like to do?" % (", %s" % name if not name.is_empty() else ""),
		"ru": "Привет%s! Чем займёмся?" % (", %s" % name if not name.is_empty() else ""),
		"kz": "Сәлем%s! Не істейміз?" % (", %s" % name if not name.is_empty() else ""),
	}
	var spec := {
		"id": "startup_main_menu",
		"inner": but == null,
		"title": title,
		"body": {
			"en": "",
			"ru": "",
			"kz": "",
		},
		"format": "plain",
		"size": StartupDialogStyleCore.FORM_SIZE.duplicate(true),
		"surface": "transparent",
		"action_layout": "vertical",
		"appearance": StartupDialogStyleCore.appearance({
			"show_icon": false,
			"button_text_alignment": "left",
			"button_text_padding": 22,
			"hide_node_palette": hide_node_palette,
		}),
		"dismiss_on_escape": true,
		"dismiss_on_outside_click": true,
		"buttons": [
			{
				"id": "tutorials",
				"text": {
					"en": "Explore ready-made AI models",
					"ru": "Посмотреть готовые ИИ-модели",
					"kz": "Дайын ЖИ модельдерін көру",
				},
				"style": "primary",
				"can_go": false,
			},
			{
				"id": "continue",
				"text": {
					"en": "Continue one of my models",
					"ru": "Открыть модель, над которой я работал",
					"kz": "Өзім жұмыс істеген модельді ашу",
				},
				"style": "primary",
				"can_go": false,
			},
			{
				"id": "create",
				"text": {
					"en": "Create a new AI model",
					"ru": "Создать новую ИИ-модель",
					"kz": "Жаңа ЖИ моделін жасау",
				},
				"style": "primary",
				"can_go": false,
			},
		],
	}
	# The top-panel folder button uses the normal dialog API, but it still needs
	# the legacy splash source semantics while this menu is open.
	if is_instance_valid(but):
		spec["splashed_from"] = but
	return spec


func show(profile: Dictionary, open_route: bool = true, but=null) -> Dictionary:
	if _ui == null:
		return {"ok": false, "error": "startup_main_menu_unavailable"}
	var result: Dictionary
	if _pixel_home_available():
		result = await _ui.splash_and_get_result("home", but)
	else:
		result = await _ui.show_dialog_and_get_result(
			dialog_spec(profile, not open_route, but),
			true
		)
	if open_route:
		open_action(str(result.get("action", "")))
	return result


## Pixel design: the SPIKE-style home (scenes/home.tscn) replaces this menu and
## returns the same actions. Looked up at run time: script-mode tests load
## this file without autoloads.
func _pixel_home_available() -> bool:
	var tree := Engine.get_main_loop() as SceneTree
	var design_ui: Node = tree.root.get_node_or_null(^"design") if tree else null
	return design_ui != null and design_ui.pixel and _ui is Node and _ui.splash_menus.has("home")


func open_action(action: String) -> void:
	if _ui != null and ROUTES.has(action):
		_ui.splash(ROUTES[action], null, null, true)
