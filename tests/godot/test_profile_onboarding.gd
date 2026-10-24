extends SceneTree

const ProfileOnboarding = preload("res://scripts/startup/profile_onboarding.gd")

var failures: Array[String] = []


class FakeCookies:
	extends RefCounted
	var profile: Dictionary = {"onboarding_complete": false, "onboarding_version": 0}
	var user_info: Dictionary = {}
	var saved: Array[Dictionary] = []
	var local_saved: Array[Dictionary] = []
	var applied_languages: Array[String] = []
	var runtime_identities: Array[Dictionary] = []
	var session_present := true

	func get_neuralese_profile() -> Dictionary:
		return profile.duplicate(true)

	func get_pilot_account_profile() -> Dictionary:
		return profile.duplicate(true)

	func get_pilot_runtime_identity() -> Dictionary:
		return runtime_identities.back().duplicate(true) if not runtime_identities.is_empty() else {}

	func get_auth_user() -> Dictionary:
		return user_info.duplicate(true)

	func has_auth_session() -> bool:
		return session_present

	func has_pilot_session() -> bool:
		return session_present

	func get_preferred_language() -> String:
		return "en"

	func apply_preferred_language(language: String) -> void:
		applied_languages.append(language)

	func complete_onboarding(first_name: String, last_name: String, role: String) -> Dictionary:
		saved.append({"first_name": first_name, "last_name": last_name, "account_type": role})
		profile = {
			"first_name": first_name,
			"last_name": last_name,
			"certificate_name": "%s %s" % [first_name, last_name],
			"type": role,
			"onboarding_complete": true,
			"onboarding_version": 1,
		}
		return {"ok": true, "profile": profile.duplicate(true)}

	func complete_local_onboarding(first_name: String, last_name: String, role: String, language: String) -> Dictionary:
		local_saved.append({
			"first_name": first_name,
			"last_name": last_name,
			"account_type": role,
			"language": language,
		})
		profile = {
			"account_id": "local-account-1",
			"first_name": first_name,
			"last_name": last_name,
			"certificate_name": "%s %s" % [first_name, last_name],
			"type": role,
			"language": language,
			"onboarding_complete": true,
			"onboarding_version": 1,
		}
		return {"ok": true, "profile": profile.duplicate(true), "local": true}

	func set_pilot_runtime_identity(first_name: String, last_name: String) -> Dictionary:
		var identity := {
			"first_name": first_name,
			"last_name": last_name,
			"certificate_name": "%s %s" % [first_name, last_name],
		}
		runtime_identities.append(identity)
		var active := profile.duplicate(true)
		active.merge(identity, true)
		return {"ok": true, "profile": active, "runtime_identity": identity}


class FakeUi:
	extends RefCounted
	var results: Array[Dictionary] = []
	var specs: Array[Dictionary] = []
	var order: Array[String]

	func _init(record: Array[String] = []) -> void:
		order = record

	func show_dialog_and_get_result(spec: Dictionary) -> Dictionary:
		order.append("dialog")
		specs.append(spec.duplicate(true))
		return results.pop_front() if not results.is_empty() else {"action": "dismiss"}


class FakeGraphicsQuality:
	extends RefCounted
	var current := "medium"
	var applied: Array[String] = []

	func get_graphics_quality() -> String:
		return current

	func set_graphics_quality(value: String) -> void:
		current = value
		applied.append(value)


class FakePilotClient:
	extends RefCounted
	var registrations: Array[Dictionary] = []
	var device_sessions: Array[Dictionary] = []
	var cookies: FakeCookies
	var order: Array[String]

	func _init(cookie_service: FakeCookies = null, record: Array[String] = []) -> void:
		cookies = cookie_service
		order = record

	func ensure_device_session(role: String, enrollment_id: String, enrollment_token: String, installation_id: String, persisted_profile: Dictionary = {}) -> Dictionary:
		order.append("device_session")
		device_sessions.append({
			"role": role,
			"enrollment_id": enrollment_id,
			"enrollment_token": enrollment_token,
			"installation_id": installation_id,
			"persisted_profile": persisted_profile.duplicate(true),
		})
		if cookies != null:
			cookies.session_present = true
			cookies.profile = {
				"account_id": "pilot-device-account",
				"pilot_enrollment_id": enrollment_id,
				"type": role,
				"first_name": "Neuralese",
				"last_name": "Device",
				"onboarding_complete": true,
				"onboarding_version": 1,
			}
		return {"ok": true, "profile": cookies.profile.duplicate(true) if cookies != null else {}}

	func register(role: String, first_name: String, last_name: String, enrollment_id: String, enrollment_token: String, installation_id: String) -> Dictionary:
		registrations.append({
			"role": role,
			"first_name": first_name,
			"last_name": last_name,
			"enrollment_id": enrollment_id,
			"enrollment_token": enrollment_token,
			"installation_id": installation_id,
		})
		return {"ok": true, "profile": {"onboarding_complete": true, "onboarding_version": 1}}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_dialog_contract_and_prefill()
	await _test_normal_onboarding()
	await _test_local_onboarding_without_browser_auth()
	await _test_local_profile_handoff_after_browser_login()
	await _test_completed_profile_is_asked_again()
	await _test_pilot_registration_path()
	await _test_pilot_mode_asks_names_before_creating_device_session_every_launch()

	if failures.is_empty():
		print("PASS test_profile_onboarding")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_dialog_contract_and_prefill() -> void:
	var spec := ProfileOnboarding.dialog_spec(
		{"first_name": "", "last_name": "", "type": "student"},
		{"given_name": "Алия", "family_name": "Серикова"}
	)
	_expect_equal(spec.get("surface"), "transparent", "Neuralese transparent surface")
	_expect_equal(spec.get("action_layout"), "vertical", "single vertical action")
	_expect_equal(spec.get("dismiss_on_escape"), false, "required onboarding cannot be skipped")
	_expect_equal(spec.get("fields", []).map(func(field): return field.get("id")), ["first_name", "last_name", "role", "language", "graphics_quality"], "local profile includes graphics quality")
	_expect_equal(spec.get("appearance", {}).get("field_columns"), 2, "profile fields use a compact two-column layout")
	_expect_equal(spec.get("appearance", {}).get("button_width"), 500, "continue button fills the compact form")
	_expect_equal(spec.get("appearance", {}).get("title_font_size"), 32, "profile heading matches the main menu")
	_expect_equal(spec.get("appearance", {}).get("field_height"), 44, "profile controls use readable Neuralese sizing")
	_expect_equal(spec.get("appearance", {}).get("hide_node_palette"), true, "profile form hides the node palette")
	_expect_equal(spec.get("body"), {"en": "", "ru": "", "kz": ""}, "profile form avoids a tall explanatory block")
	_expect_equal(spec["fields"][0].get("value"), "Алия", "OIDC first-name prefill")
	_expect_equal(spec["fields"][1].get("value"), "Серикова", "OIDC last-name prefill")
	_expect_equal(spec["fields"][3].get("value"), "ru", "Russian is the default language")
	if spec.get("fields", []).size() > 4:
		_expect_equal(spec["fields"][4].get("value"), "medium", "onboarding defaults to Medium graphics")
		_expect_equal(spec["fields"][4].get("label", {}).get("ru"), "Качество графики", "graphics quality label is localized")
		_expect_equal(spec["fields"][4].get("options", [])[0].get("text", {}).get("ru"), "Высокое", "graphics quality options are localized")
	var pilot_spec := ProfileOnboarding.pilot_dialog_spec({})
	_expect_equal(pilot_spec.get("appearance", {}).get("hide_node_palette"), true, "pilot name form hides the node palette")
	_expect_equal(pilot_spec.get("language"), "ru", "pilot form defaults to Russian")
	_expect_equal(pilot_spec.get("fields", []).map(func(field): return field.get("id")), ["first_name", "last_name", "language", "graphics_quality"], "pilot form includes language and graphics quality selection")
	_expect_equal(pilot_spec["fields"][2].get("live_language"), true, "pilot language selection updates the open form")


func _test_normal_onboarding() -> void:
	var cookies := FakeCookies.new()
	cookies.user_info = {"name": "Ada Lovelace"}
	var ui := FakeUi.new()
	var quality := FakeGraphicsQuality.new()
	ui.results.append({
		"action": "continue",
		"values": {"first_name": " Ada ", "last_name": " Lovelace ", "role": "teacher", "language": "en", "graphics_quality": "low"},
	})
	var result: Dictionary = await ProfileOnboarding.new(cookies, ui, null, {}, quality).ensure_complete()

	_expect_equal(result.get("ok"), true, "normal onboarding succeeds")
	_expect_equal(cookies.saved, [{"first_name": "Ada", "last_name": "Lovelace", "account_type": "teacher"}], "one normalized server update")
	_expect_equal(ui.specs.size(), 1, "one onboarding dialog")
	_expect_equal(cookies.applied_languages, ["en"], "selected language is applied after onboarding")
	_expect_equal(quality.applied, ["low"], "selected graphics quality is applied after onboarding")


func _test_local_onboarding_without_browser_auth() -> void:
	var cookies := FakeCookies.new()
	cookies.session_present = false
	var ui := FakeUi.new()
	ui.results.append({
		"action": "continue",
		"values": {"first_name": "Иван", "last_name": "Иванов", "role": "student", "language": "ru"},
	})
	var result: Dictionary = await ProfileOnboarding.new(cookies, ui).ensure_complete()

	_expect_equal(result.get("ok"), true, "local onboarding succeeds without browser auth")
	_expect_equal(result.get("local"), true, "local onboarding is identified")
	_expect_equal(cookies.local_saved, [{
		"first_name": "Иван",
		"last_name": "Иванов",
		"account_type": "student",
		"language": "ru",
	}], "local identity is persisted once")
	_expect_equal(cookies.saved.is_empty(), true, "local onboarding does not call the authenticated profile endpoint")
	_expect_equal(cookies.applied_languages, ["ru"], "local profile language is applied immediately")


func _test_local_profile_handoff_after_browser_login() -> void:
	var cookies := FakeCookies.new()
	cookies.profile = {"onboarding_complete": false, "onboarding_version": 0}
	var ui := FakeUi.new()
	var local_profile := {
		"local_profile": true,
		"first_name": "Иван",
		"last_name": "Иванов",
		"type": "student",
		"language": "ru",
		"onboarding_complete": true,
		"onboarding_version": 1,
	}
	var onboarding = ProfileOnboarding.new(cookies, ui)
	if not onboarding.has_method("sync_local_profile_after_login"):
		failures.append("profile onboarding exposes the post-login handoff")
		return
	var result: Dictionary = await onboarding.sync_local_profile_after_login(local_profile)

	_expect_equal(result.get("ok"), true, "local profile handoff succeeds")
	_expect_equal(result.get("synced"), true, "local profile handoff is reported")
	_expect_equal(cookies.saved, [{
		"first_name": "Иван",
		"last_name": "Иванов",
		"account_type": "student",
	}], "saved local identity is copied to the authenticated profile")
	_expect_equal(ui.specs.is_empty(), true, "profile handoff does not open another dialog")
	_expect_equal(cookies.applied_languages, ["ru"], "profile handoff preserves the language")


func _test_completed_profile_is_asked_again() -> void:
	var cookies := FakeCookies.new()
	cookies.profile = {
		"first_name": "Cached",
		"last_name": "Student",
		"type": "student",
		"language": "ru",
		"onboarding_complete": true,
		"onboarding_version": 1,
	}
	var ui := FakeUi.new()
	ui.results.append({
		"action": "continue",
		"values": {"first_name": "Новый", "last_name": "Ученик", "role": "student", "language": "ru"},
	})
	var result: Dictionary = await ProfileOnboarding.new(cookies, ui).ensure_complete()

	_expect_equal(result.get("ok"), true, "completed profile can be updated for the current launch")
	_expect_equal(ui.specs.size(), 1, "name dialog reopens on every application launch")
	_expect_equal(ui.specs[0]["fields"][0].get("value"), "", "cached first name is not prefilled")
	_expect_equal(ui.specs[0]["fields"][1].get("value"), "", "cached last name is not prefilled")
	_expect_equal(cookies.saved[0].get("first_name"), "Новый", "current launch identity replaces the cached name")


func _test_pilot_registration_path() -> void:
	var cookies := FakeCookies.new()
	cookies.session_present = false
	var ui := FakeUi.new()
	ui.results.append({
		"action": "continue",
		"values": {"first_name": "Иван", "last_name": "Иванов", "role": "student", "language": "ru"},
	})
	var pilot := FakePilotClient.new(cookies)
	var flow = ProfileOnboarding.new(cookies, ui, pilot, {
		"enrollment_id": "pilot-school",
		"enrollment_token": "runtime-secret",
		"installation_id": "installation_1234567890",
	})
	var result: Dictionary = await flow.ensure_complete()

	_expect_equal(result.get("ok"), true, "pilot onboarding succeeds")
	_expect_equal(pilot.device_sessions.size(), 1, "pilot device session client used once")
	_expect_equal(pilot.device_sessions[0].get("enrollment_token"), "runtime-secret", "runtime pilot token forwarded")
	_expect_equal(cookies.saved.is_empty(), true, "pilot path does not call normal profile endpoint")


func _test_pilot_mode_asks_names_before_creating_device_session_every_launch() -> void:
	var cookies := FakeCookies.new()
	cookies.session_present = false
	cookies.profile = {
		"account_id": "pilot-device-account",
		"pilot_enrollment_id": "pilot-school",
		"type": "student",
		"first_name": "Neuralese",
		"last_name": "Device",
		"onboarding_complete": true,
		"onboarding_version": 1,
	}
	var order: Array[String] = []
	var ui := FakeUi.new(order)
	ui.results.append({
		"action": "continue",
		"values": {"first_name": " Максим ", "last_name": " Иванов ", "language": "ru"},
	})
	ui.results.append({
		"action": "continue",
		"values": {"first_name": " Алия ", "last_name": " Серикова ", "language": "kz"},
	})
	var pilot := FakePilotClient.new(cookies, order)
	var flow = ProfileOnboarding.new(cookies, ui, pilot, {
		"account_role": "student",
		"enrollment_id": "pilot-school",
		"enrollment_token": "runtime-secret",
		"installation_id": "installation_1234567890",
	})

	var first: Dictionary = await flow.ensure_complete()
	var second: Dictionary = await flow.ensure_complete()

	_expect_equal(first.get("ok"), true, "pilot launch profile succeeds")
	_expect_equal(second.get("ok"), true, "pilot profile is requested again on a new startup invocation")
	_expect_equal(pilot.device_sessions.size(), 1, "technical device account is created once")
	_expect_equal(order, ["dialog", "device_session", "dialog"], "pilot names are collected before token generation")
	_expect_equal(ui.specs.size(), 2, "pilot identity dialog is always shown")
	_expect_equal(ui.specs[0].get("fields", []).map(func(field): return field.get("id")), ["first_name", "last_name", "language", "graphics_quality"], "pilot asks for names, language, and graphics quality")
	_expect_equal(ui.specs[1]["fields"][0].get("value"), "", "pilot name is not restored from a previous process")
	_expect_equal(cookies.applied_languages, ["ru", "kz"], "pilot language is applied on every launch")
	_expect_equal(cookies.runtime_identities.map(func(identity): return identity.get("certificate_name")), ["Максим Иванов", "Алия Серикова"], "student identity stays local and can change between launches")
	_expect_equal(second.get("profile", {}).get("certificate_name"), "Алия Серикова", "active profile uses the current local student name")


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
