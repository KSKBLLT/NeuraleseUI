extends SceneTree

const PilotOnboardingClient = preload("res://scripts/auth/pilot_onboarding_client.gd")

var failures: Array[String] = []


class FakeWeb:
	extends RefCounted
	var calls: Array[Dictionary] = []

	func JPOST(path: String, payload: Dictionary) -> Dictionary:
		calls.append({"path": path, "payload": payload.duplicate(true)})
		return {
			"ok": true,
			"access_token": "access-token",
			"refresh_token": "refresh-token",
			"token_type": "Bearer",
			"expires_in": 300,
			"refresh_expires_in": 600,
			"user": {"id": "pilot:device", "display_name": "Әлихан Нұрпейіс"},
			"profile": {
				"first_name": "Әлихан",
				"last_name": "Нұрпейіс",
				"certificate_name": "Әлихан Нұрпейіс",
				"type": "student",
				"onboarding_complete": true,
			},
		}


class FakeCookies:
	extends RefCounted
	var sessions: Array[Dictionary] = []

	func apply_pilot_session(payload: Dictionary) -> Dictionary:
		sessions.append(payload.duplicate(true))
		return {"ok": true, "session": {"auth_provider": "pilot"}}


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var web_api := FakeWeb.new()
	var cookies := FakeCookies.new()
	var client = PilotOnboardingClient.new(web_api, cookies)

	var result: Dictionary = await client.register(
		" student ",
		"  Әлихан ",
		" Нұрпейіс  ",
		"school-pilot",
		"runtime-enrollment-token",
		"installation_1234567890"
	)

	_expect_equal(result.get("ok"), true, "registration succeeds")
	_expect_equal(web_api.calls.size(), 1, "one registration request")
	_expect_equal(
		web_api.calls[0].get("path"),
		"api/pilot/onboarding/register",
		"canonical endpoint"
	)
	_expect_equal(web_api.calls[0].get("payload"), {
		"role": "student",
		"first_name": "Әлихан",
		"last_name": "Нұрпейіс",
		"enrollment_id": "school-pilot",
		"enrollment_token": "runtime-enrollment-token",
		"installation_id": "installation_1234567890",
	}, "normalized registration payload")
	_expect_equal(cookies.sessions.size(), 1, "session applied once")
	_expect_equal(
		result.get("profile", {}).get("certificate_name"),
		"Әлихан Нұрпейіс",
		"certificate profile returned"
	)

	var technical_web := FakeWeb.new()
	var technical_cookies := FakeCookies.new()
	var technical_client = PilotOnboardingClient.new(
		technical_web, technical_cookies
	)
	var technical: Dictionary = await technical_client.ensure_device_session(
		"student",
		"school-pilot",
		"runtime-enrollment-token",
		"installation_1234567890"
	)
	_expect_equal(technical.get("ok"), true, "device session succeeds")
	_expect_equal(
		technical_web.calls[0].get("payload", {}).get("first_name"),
		"Neuralese",
		"new device account does not use the student's name"
	)
	_expect_equal(
		technical_web.calls[0].get("payload", {}).get("last_name"),
		"Device",
		"new device account uses a neutral technical identity"
	)

	var legacy_web := FakeWeb.new()
	var legacy_client = PilotOnboardingClient.new(legacy_web, FakeCookies.new())
	await legacy_client.ensure_device_session(
		"student",
		"school-pilot",
		"runtime-enrollment-token",
		"installation_1234567890",
		{
			"pilot_enrollment_id": "school-pilot",
			"type": "teacher",
			"first_name": "Алия",
			"last_name": "Серикова",
		}
	)
	_expect_equal(legacy_web.calls[0].get("payload", {}).get("role"), "teacher", "existing pilot role is preserved")
	_expect_equal(legacy_web.calls[0].get("payload", {}).get("first_name"), "Алия", "existing pilot account remains compatible")

	var invalid: Dictionary = await client.register(
		"admin", "A", "B", "school-pilot", "token", "installation_1234567890"
	)
	_expect_equal(invalid.get("error"), "invalid_role", "invalid role rejected locally")
	_expect_equal(web_api.calls.size(), 1, "invalid request does not reach network")

	var installation_path := "user://pilot_onboarding_test_installation_id"
	if FileAccess.file_exists(installation_path):
		DirAccess.remove_absolute(installation_path)
	var first_id := PilotOnboardingClient.get_or_create_installation_id(
		installation_path
	)
	var repeated_id := PilotOnboardingClient.get_or_create_installation_id(
		installation_path
	)
	_expect_equal(first_id.length(), 48, "installation id uses 24 random bytes")
	_expect_equal(repeated_id, first_id, "installation id is stable")
	if FileAccess.file_exists(installation_path):
		DirAccess.remove_absolute(installation_path)

	if failures.is_empty():
		print("PASS test_pilot_onboarding_client")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
