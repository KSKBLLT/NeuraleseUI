extends SceneTree

const AuthFlowPolicy = preload("res://scripts/auth/auth_flow_policy.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_identity_prefers_oidc_username()
	_test_identity_ignores_null_values()
	_test_profile_sync_failure_is_non_fatal()
	_test_pilot_runtime_identity_overlays_device_profile()
	_test_login_success_copy()
	_test_successful_login_does_not_open_settings()
	_test_pilot_session_counts_as_signed_in()

	if failures.is_empty():
		print("PASS test_auth_ui_identity")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_identity_prefers_oidc_username() -> void:
	_expect_equal(
		AuthFlowPolicy.resolve_display_identity(
			{"username": null},
			{"sub": "opaque-subject", "username": "Lyam"}
		),
		"Lyam",
		"OIDC username is used when the backend profile has no username"
	)


func _test_identity_ignores_null_values() -> void:
	_expect_equal(
		AuthFlowPolicy.resolve_display_identity(
			{
				"username": null,
				"first_name": "Алим",
				"last_name": "Бупешев",
			},
			{"name": null, "email": null, "sub": "opaque-subject"}
		),
		"Алим Бупешев",
		"null values never become visible text"
	)


func _test_profile_sync_failure_is_non_fatal() -> void:
	var result := AuthFlowPolicy.login_result_with_profile_sync(
		{"ok": true, "session": {"auth_provider": "self_hosted"}},
		{"ok": false, "error": "http 404"}
	)
	_expect_equal(result.get("ok"), true, "profile sync cannot cancel a valid login")
	_expect_equal(
		result.get("profile_sync_error", {}).get("error"),
		"http 404",
		"profile sync error remains observable"
	)


func _test_pilot_runtime_identity_overlays_device_profile() -> void:
	var merged := AuthFlowPolicy.merge_pilot_runtime_identity(
		{
			"account_id": "pilot-device-account",
			"first_name": "Neuralese",
			"last_name": "Device",
			"type": "student",
		},
		{
			"first_name": "Lyam",
			"last_name": "Student",
			"certificate_name": "Lyam Student",
		}
	)
	_expect_equal(merged.get("account_id"), "pilot-device-account", "runtime identity keeps the technical account")
	_expect_equal(merged.get("type"), "student", "runtime identity cannot change account permissions")
	_expect_equal(merged.get("first_name"), "Lyam", "runtime first name is visible in the app")
	_expect_equal(merged.get("certificate_name"), "Lyam Student", "runtime certificate name is visible in the app")


func _test_login_success_copy() -> void:
	_expect_equal(
		AuthFlowPolicy.login_success_text("ru"),
		"Вход выполнен",
		"Russian login success text"
	)


func _test_successful_login_does_not_open_settings() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/top_panel.gd")
	var function_start := source.find("func _on_login_released()")
	var function_end := source.find("\n@onready var savebut", function_start)
	var function_source := source.substr(function_start, function_end - function_start)
	var unauthenticated_start := function_source.find("if !glob.logged_in():")
	var authenticated_else := function_source.find("\n\telse:", unauthenticated_start)
	var unauthenticated_source := function_source.substr(
		unauthenticated_start,
		authenticated_else - unauthenticated_start
	)
	_expect_equal(
		unauthenticated_source.find("ui.splash(\"settings\", login_btn)"),
		-1,
		"fresh login closes instead of replacing itself with settings"
	)


func _test_pilot_session_counts_as_signed_in() -> void:
	_expect(
		AuthFlowPolicy.is_signed_in({}, true),
		"a stored pilot/OIDC session counts as signed in before a run opens the login dialog"
	)
	_expect(
		not AuthFlowPolicy.is_signed_in({}, false),
		"an empty legacy state without an auth session remains signed out"
	)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
