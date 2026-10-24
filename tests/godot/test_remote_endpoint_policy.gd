extends SceneTree

const EndpointPolicy = preload("res://scripts/auth/remote_endpoint_policy.gd")
const SessionGate = preload("res://scripts/auth/remote_session_gate.gd")

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_expect_equal(
		EndpointPolicy.canonical_rest("ask_once"),
		"api/axon/ask-once",
		"Axon alias is canonical"
	)
	_expect_equal(
		EndpointPolicy.rest_access("classroom/join"),
		EndpointPolicy.Access.AUTH_REQUIRED,
		"classroom join is protected"
	)
	_expect_equal(
		EndpointPolicy.rest_access("health"),
		EndpointPolicy.Access.PUBLIC,
		"health is public"
	)
	_expect_equal(
		EndpointPolicy.rest_access("https://updates.example/file.bin"),
		EndpointPolicy.Access.EXTERNAL_PUBLIC,
		"absolute URL is external public"
	)
	_expect_equal(
		EndpointPolicy.rest_access("api/new-unclassified-route"),
		EndpointPolicy.Access.UNKNOWN,
		"unknown internal route fails closed"
	)
	_expect_equal(
		EndpointPolicy.rest_access("/api/users/me"),
		EndpointPolicy.Access.AUTH_REQUIRED,
		"profile adapter route is protected"
	)
	_expect_equal(
		EndpointPolicy.canonical_websocket("ws/talk"),
		"ws/axon/talk",
		"Axon socket alias is canonical"
	)
	_expect_equal(
		EndpointPolicy.websocket_access("ws/infer"),
		EndpointPolicy.Access.AUTH_REQUIRED,
		"inference socket is protected"
	)
	_expect(SessionGate.has_bearer({"Authorization": "Bearer token"}), "bearer accepted")
	_expect(not SessionGate.has_bearer({"Authorization": "Basic token"}), "basic rejected")
	_expect(not SessionGate.has_bearer({"user": "local child"}), "local identity rejected")
	var denied := SessionGate.prepare_headers(
		EndpointPolicy.Access.AUTH_REQUIRED,
		{"user": "local child"},
		{}
	)
	_expect(not denied.get("ok", true), "protected request without bearer is denied")
	var authorized := SessionGate.prepare_headers(
		EndpointPolicy.Access.AUTH_REQUIRED,
		{"Authorization": "Basic stale", "X-Test": "yes"},
		{"Authorization": "Bearer fresh"}
	)
	_expect(authorized.get("ok", false), "protected request with bearer is accepted")
	_expect_equal(
		authorized.get("headers", {}).get("Authorization", ""),
		"Bearer fresh",
		"trusted bearer replaces caller authorization"
	)
	var external := SessionGate.prepare_headers(
		EndpointPolicy.Access.EXTERNAL_PUBLIC,
		{"Authorization": "Bearer must-not-leak", "Range": "bytes=1-"},
		{}
	)
	_expect(external.get("ok", false), "external public request is accepted")
	_expect(
		not external.get("headers", {}).has("Authorization"),
		"external public request strips authorization"
	)
	_expect_equal(
		external.get("headers", {}).get("Range", ""),
		"bytes=1-",
		"external public request preserves non-secret headers"
	)
	var ui_errors: Array[String] = []
	_expect(
		not SessionGate.require_ready(
			{},
			"ru",
			true,
			func(message: String) -> void: ui_errors.append(message)
		),
		"interactive action is denied without bearer"
	)
	_expect_equal(ui_errors.size(), 1, "interactive denial reports exactly one error")
	ui_errors.clear()
	_expect(
		not SessionGate.require_ready(
			{},
			"ru",
			false,
			func(message: String) -> void: ui_errors.append(message)
		),
		"background action is denied without bearer"
	)
	_expect(ui_errors.is_empty(), "background denial stays silent")
	_expect(
		SessionGate.inference_ready(true, true, false),
		"local inference uses the local model without remote auth"
	)
	_expect(
		not SessionGate.inference_ready(true, false, true),
		"local inference still requires a local model"
	)
	_expect(
		SessionGate.inference_ready(false, false, true),
		"remote inference uses bearer readiness"
	)
	_expect(
		not SessionGate.inference_ready(false, true, false),
		"local identity or model cannot authorize remote inference"
	)
	_expect(not SessionGate.error_text("ru").is_empty(), "Russian error copy")
	_expect(not SessionGate.error_text("en").is_empty(), "English error copy")
	_expect(not SessionGate.error_text("kz").is_empty(), "Kazakh error copy")
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [message, str(expected), str(actual)])


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_remote_endpoint_policy")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
