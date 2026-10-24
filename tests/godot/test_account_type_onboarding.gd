extends SceneTree

const AccountTypeOnboarding = preload("res://scripts/auth/account_type_onboarding.gd")

var failures: Array[String] = []


class FakeCookies:
	extends RefCounted
	var profile: Dictionary = {"needs_account_type": true}
	var selected: Array[String] = []

	func get_neuralese_profile() -> Dictionary:
		return profile.duplicate(true)

	func needs_account_type() -> bool:
		return bool(profile.get("needs_account_type", false))

	func select_account_type(account_type: String) -> Dictionary:
		selected.append(account_type)
		profile = {
			"type": account_type,
			"account_type_selected": true,
			"needs_account_type": false,
		}
		return {"ok": true, "profile": profile.duplicate(true)}


class FakeUi:
	extends RefCounted
	var results: Array[Dictionary] = []
	var specs: Array[Dictionary] = []

	func show_dialog_and_get_result(spec: Dictionary) -> Dictionary:
		specs.append(spec.duplicate(true))
		if results.is_empty():
			return {"action": "dismiss"}
		return results.pop_front()


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_role_contract()
	await _test_selection_flow()

	if failures.is_empty():
		print("PASS test_account_type_onboarding")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_role_contract() -> void:
	_expect_equal(AccountTypeOnboarding.normalize_role(" teacher "), "teacher", "teacher normalization")
	_expect_equal(AccountTypeOnboarding.normalize_role("student"), "student", "student normalization")
	_expect_equal(AccountTypeOnboarding.normalize_role("admin"), "", "privileged role rejection")

	var spec: Dictionary = AccountTypeOnboarding.dialog_spec()
	_expect_equal(spec.get("dismiss_on_escape"), false, "role dialog cannot be skipped with Escape")
	_expect_equal(spec.get("dismiss_on_outside_click"), false, "role dialog cannot be skipped outside")
	_expect_equal(spec.get("buttons", []).map(func(button): return button.get("id")), ["student", "teacher"], "canonical role actions")


func _test_selection_flow() -> void:
	var cookies := FakeCookies.new()
	var ui := FakeUi.new()
	ui.results.append({"action": "teacher"})
	var onboarding = AccountTypeOnboarding.new(cookies, ui)

	var result: Dictionary = await onboarding.ensure_selected()
	_expect_equal(result.get("ok"), true, "selection succeeds")
	_expect_equal(cookies.selected, ["teacher"], "one canonical server update")
	_expect_equal(cookies.profile.get("type"), "teacher", "saved server profile is applied")
	_expect_equal(ui.specs.size(), 1, "one role dialog")

	var repeated: Dictionary = await onboarding.ensure_selected()
	_expect_equal(repeated.get("ok"), true, "completed selection is reusable")
	_expect_equal(cookies.selected.size(), 1, "completed selection does not write again")
	_expect_equal(ui.specs.size(), 1, "completed selection does not reopen dialog")

	var invalid_cookies := FakeCookies.new()
	var invalid_ui := FakeUi.new()
	invalid_ui.results.append({"action": "admin"})
	var invalid = await AccountTypeOnboarding.new(invalid_cookies, invalid_ui).ensure_selected()
	_expect_equal(invalid.get("error"), "account_type_required", "invalid UI action is rejected")
	_expect_equal(invalid_cookies.selected.is_empty(), true, "invalid action never reaches server")


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
