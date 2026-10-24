extends SceneTree

const ProfileOnboarding = preload("res://scripts/startup/profile_onboarding.gd")
const StartupTutorialPrompt = preload("res://scripts/startup/startup_tutorial_prompt.gd")

var failures: Array[String] = []


class FakeUi:
	extends RefCounted
	var result := {"action": "start"}
	var specs: Array[Dictionary] = []
	func show_dialog_and_get_result(spec: Dictionary, _wait_until_closed: bool = false, but=null) -> Dictionary:
		specs.append(spec.duplicate(true))
		return result.duplicate(true)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var profile_spec := ProfileOnboarding.dialog_spec({}, {}, "ru")
	var prompt_spec := StartupTutorialPrompt.dialog_spec()
	_expect_equal(prompt_spec.get("surface"), "transparent", "tutorial choice has no panel background")
	_expect_equal(prompt_spec.has("body"), false, "tutorial choice has no oversized body panel")
	_expect_equal(prompt_spec.get("title", {}).get("ru"), "Пройти короткое знакомство?", "tutorial choice uses a compact title")
	_expect_equal(prompt_spec.get("size", {}).get("height"), 220, "tutorial choice uses a compact height")
	_expect_equal(
		prompt_spec.get("buttons", [])[1].get("close_mode"),
		"handoff",
		"declining the tutorial hands off directly to the greeting"
	)
	_expect_equal(prompt_spec.get("appearance", {}).get("hide_node_palette"), true, "tutorial choice hides the node palette")
	_expect_equal(
		prompt_spec.get("buttons", [])[0].has("close_mode"),
		false,
		"starting the tutorial keeps the normal blur-releasing close animation"
	)
	for key in ["title_font_size", "button_height", "button_width", "button_font_scale", "action_separation"]:
		_expect_equal(
			prompt_spec.get("appearance", {}).get(key),
			profile_spec.get("appearance", {}).get(key),
			"tutorial choice shares onboarding %s" % key
		)
	_expect_equal(prompt_spec.get("buttons", []).map(func(button): return button.get("id")), ["start", "later"], "tutorial choice has explicit start and skip actions")
	_expect_equal(prompt_spec.get("buttons", []).map(func(button): return button.get("style")), ["primary", "primary"], "tutorial choice actions share the onboarding button style")

	var ui := FakeUi.new()
	var accepted: Dictionary = await StartupTutorialPrompt.new(ui).ask()
	_expect_equal(accepted.get("start"), true, "start action accepts the tutorial")
	ui.result = {"action": "later"}
	var declined: Dictionary = await StartupTutorialPrompt.new(ui).ask()
	_expect_equal(declined.get("start"), false, "later action declines the tutorial")

	if failures.is_empty():
		print("PASS test_startup_tutorial_prompt")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
