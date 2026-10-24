extends SceneTree

const StartupMainMenu = preload("res://scripts/startup/startup_main_menu.gd")

var failures: Array[String] = []


class FakeUi:
	extends RefCounted
	var results: Array[Dictionary] = []
	var specs: Array[Dictionary] = []
	var opened: Array[String] = []
	var wait_for_close_requests: Array[bool] = []

	func show_dialog_and_get_result(spec: Dictionary, wait_until_closed: bool = false) -> Dictionary:
		specs.append(spec.duplicate(true))
		wait_for_close_requests.append(wait_until_closed)
		return results.pop_front() if not results.is_empty() else {"action": "dismiss"}

	func splash(menu: String, _from = null, _emitter = null, _inner = false, _data = null) -> Variant:
		opened.append(menu)
		return null


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_menu_contract()
	await _test_routes_to_existing_windows()

	if failures.is_empty():
		print("PASS test_startup_main_menu")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_menu_contract() -> void:
	var spec := StartupMainMenu.dialog_spec({"certificate_name": "Иван Иванов"}, true)
	_expect_equal(spec.get("surface"), "transparent", "main menu uses Neuralese transparent surface")
	_expect_equal(spec.get("action_layout"), "vertical", "main menu actions are vertical")
	_expect_equal(spec.get("title", {}).get("ru"), "Привет, Иван Иванов! Чем займёмся?", "personal greeting")
	_expect_equal(spec.get("body", {}).get("ru"), "", "main menu has no form-like body panel")
	_expect_equal(spec.get("appearance", {}).get("show_icon"), false, "main menu hides the small dialog icon")
	_expect_equal(spec.get("appearance", {}).get("title_font_size"), 32, "main menu matches onboarding heading scale")
	_expect_equal(spec.get("appearance", {}).get("button_height"), 50, "main menu matches onboarding action scale")
	_expect_equal(spec.get("appearance", {}).get("button_width"), 500, "main menu uses the onboarding action width")
	_expect_equal(spec.get("size", {}).get("width"), 560, "main menu uses the onboarding dialog width")
	_expect_equal(spec.get("appearance", {}).get("button_text_alignment"), "left", "main menu action labels align left")
	_expect_equal(spec.get("appearance", {}).get("button_text_padding"), 22, "main menu action labels share a left inset")
	_expect_equal(spec.get("appearance", {}).get("hide_node_palette"), true, "main menu hides the graph node palette")
	_expect_equal(
		StartupMainMenu.dialog_spec({"certificate_name": "Иван Иванов"}, false).get("appearance", {}).get("hide_node_palette"),
		false,
		"subsequent folder menu leaves the graph node palette visible"
	)
	_expect_equal(spec.get("buttons", []).map(func(button): return button.get("id")), ["tutorials", "continue", "create"], "three clear startup actions")


func _test_routes_to_existing_windows() -> void:
	var cases := {
		"tutorials": "builtin_projects",
		"continue": "workslist",
		"create": "project_create",
	}
	for action in cases:
		var ui := FakeUi.new()
		ui.results.append({"action": action})
		var result: Dictionary = await StartupMainMenu.new(ui).show({"first_name": "Ada"})
		_expect_equal(result.get("action"), action, "%s result" % action)
		_expect_equal(ui.wait_for_close_requests, [true], "%s waits for the menu to close before routing" % action)
		_expect_equal(ui.opened, [cases[action]], "%s route" % action)
		_expect_equal(ui.specs[0].get("appearance", {}).get("hide_node_palette"), false, "%s subsequent menu preserves the palette" % action)

	var dismissed_ui := FakeUi.new()
	await StartupMainMenu.new(dismissed_ui).show({})
	_expect_equal(dismissed_ui.opened.is_empty(), true, "dismiss does not open a window")

	var deferred_ui := FakeUi.new()
	deferred_ui.results.append({"action": "create"})
	var deferred_menu = StartupMainMenu.new(deferred_ui)
	await deferred_menu.show({}, false)
	_expect_equal(deferred_ui.opened.is_empty(), true, "startup coordinator can defer destination window")
	_expect_equal(deferred_ui.specs[0].get("appearance", {}).get("hide_node_palette"), true, "first startup menu hides the palette")
	deferred_menu.open_action("create")
	_expect_equal(deferred_ui.opened, ["project_create"], "deferred destination opens explicitly")


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
