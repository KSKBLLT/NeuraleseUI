extends SceneTree

const UpdatePromptSpec = preload("res://scripts/update_prompt_spec.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var optional: Dictionary = UpdatePromptSpec.build({
		"version": "1.0.8",
		"notes_markdown": {"en": "Fixes", "ru": "Исправления"}
	})
	_expect_equal(optional["id"], "update_available", "stable dialog id")
	_expect_equal(optional["format"], "markdown", "Markdown body")
	_expect_equal(optional["icon_path"], "res://game_assets/icons/download.png", "existing download icon")
	_expect_equal(optional["dismiss_on_escape"], true, "optional Escape")
	_expect_equal(optional["dismiss_on_outside_click"], false, "no accidental outside dismissal")
	_expect_equal(optional["buttons"].size(), 1, "optional buttons")
	_expect_equal(optional["buttons"][0]["id"], "continue", "optional continue action")
	_expect_equal(optional["progress"]["visible"], true, "download progress visible")
	_expect_contains(optional["body"]["ru"], "**1.0.8**", "version in localized body")
	_expect_contains(optional["body"]["ru"], "Исправления", "localized release notes")

	var mandatory: Dictionary = UpdatePromptSpec.build({"version": "2.0.0", "mandatory": true})
	_expect_equal(mandatory["dismiss_on_escape"], false, "mandatory Escape")
	_expect_equal(mandatory["buttons"].size(), 0, "mandatory action count")

	if failures.is_empty():
		print("PASS test_update_dialog_spec: optional and mandatory")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])


func _expect_contains(value: String, part: String, label: String) -> void:
	if not value.contains(part):
		failures.append("%s: expected %s in %s" % [label, part, value])
