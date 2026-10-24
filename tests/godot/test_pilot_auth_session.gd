extends SceneTree

const AuthSession = preload("res://scripts/auth/auth_session.gd")

var failures: Array[String] = []
var requests: Array[Dictionary] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var session = AuthSession.new()
	root.add_child(session)
	session.configure("https://api.example.test/", "/api/auth/config?client=desktop")
	session.set_transport(_fake_transport)

	var applied: Dictionary = session.apply_internal_token_pair({
		"access_token": _access_token("pilot-access-1"),
		"refresh_token": "pilot-refresh-1",
		"token_type": "Bearer",
		"expires_in": 300,
		"user": {
			"id": "pilot:device_1",
			"display_name": "Иван Иванов",
		},
	}, "pilot")
	_expect_equal(applied.get("ok"), true, "pilot session applied")
	_expect_equal(
		session.get_session().get("auth_provider"), "pilot", "pilot provider"
	)
	_expect_equal(
		session.get_user_info().get("display_name"),
		"Иван Иванов",
		"pilot display identity"
	)

	session._tokens["expires_at_unix"] = 0
	var refreshed: Dictionary = await session.ensure_fresh()
	_expect_equal(refreshed.get("ok"), true, "pilot refresh succeeds")
	_expect_equal(requests.size(), 1, "one pilot refresh request")
	_expect_equal(
		requests[0].get("url"),
		"https://api.example.test/api/auth/refresh",
		"refresh uses Neuralese API"
	)
	_expect_equal(
		requests[0].get("fields", {}).get("refresh_token"),
		"pilot-refresh-1",
		"refresh token forwarded"
	)
	_expect_equal(
		"Content-Type: application/json" in requests[0].get("headers", []),
		true,
		"refresh uses backend JSON contract"
	)
	_expect_equal(
		session.get_user_info().get("display_name"),
		"Иван Иванов",
		"refresh keeps pilot identity"
	)

	session.queue_free()
	if failures.is_empty():
		print("PASS test_pilot_auth_session")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _fake_transport(
	method: int,
	url: String,
	fields: Dictionary,
	headers: PackedStringArray
) -> Dictionary:
	requests.append({
		"method": method,
		"url": url,
		"fields": fields.duplicate(true),
		"headers": headers.duplicate(),
	})
	return {
		"ok": true,
		"http_code": 200,
		"json": {
			"ok": true,
			"access_token": _access_token("pilot-access-2"),
			"refresh_token": "pilot-refresh-2",
			"token_type": "Bearer",
			"expires_in": 300,
		},
	}


func _access_token(token_id: String) -> String:
	var payload := Marshalls.utf8_to_base64(JSON.stringify({
		"iss": "https://api.example.test",
		"aud": "neuralese-client",
		"sub": "pilot:device_1",
		"jti": token_id,
	})).replace("+", "-").replace("/", "_").trim_suffix("=")
	return "header.%s.signature" % payload


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
