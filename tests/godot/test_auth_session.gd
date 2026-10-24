extends SceneTree

const AuthSession = preload("res://scripts/auth/auth_session.gd")
const OIDCClient = preload("res://scripts/auth/oidc_client.gd")

var failures: Array[String] = []
var requests: Array[Dictionary] = []
var token_attempt := 0
var refresh_attempt := 0
var opened_urls: Array[String] = []
var authorization_state := ""


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var session = AuthSession.new()
	root.add_child(session)
	session.configure("https://api.example.test/", "/api/auth/config?client=desktop")
	session.set_transport(_fake_transport)

	var configured: Dictionary = await session.load_configuration()
	_expect_equal(configured.get("ok"), true, "configuration loaded")
	session.set_browser_opener(_fake_browser_opener)
	session.set_callback_receiver(_fake_callback_receiver)

	var logged_in: Dictionary = await session.login(true)
	_expect_equal(logged_in.get("ok"), true, "PKCE login succeeds")
	_expect_equal(opened_urls.size(), 1, "browser opened once")
	_expect_equal(
		opened_urls[0].get_slice("?", 0),
		"https://auth.example.test/oidc/auth",
		"browser opens authorization endpoint"
	)
	_expect_equal(
		_request_count("https://auth.example.test/oidc/device/auth"),
		0,
		"PKCE login skips device endpoint"
	)
	var exchange := _last_request_with_field("grant_type", "authorization_code")
	_expect_equal(exchange.get("fields", {}).get("code"), "browser-code", "code exchange")
	_expect_equal(
		exchange.get("fields", {}).get("redirect_uri"),
		"http://127.0.0.1:45871/auth/callback",
		"code exchange redirect"
	)
	_expect_equal(
		str(exchange.get("fields", {}).get("code_verifier", "")).length() >= 43,
		true,
		"code verifier supplied"
	)
	_expect_equal(session.has_session(), true, "PKCE session present")
	_expect_equal(session.get_user_info().get("username"), "Lyam", "userinfo username")
	var userinfo_request := _last_request_for_url("https://auth.example.test/oidc/me")
	_expect_equal(
		"Authorization: Bearer " + session.get_access_token() in userinfo_request.get("headers", []),
		true,
		"userinfo uses the access token"
	)
	session.clear_session()

	var started: Dictionary = await session.start_device_authorization()
	_expect_equal(started.get("user_code"), "ABCD-EFGH", "device code")
	_expect_equal(started.get("interval"), 5, "device interval")

	var pending: Dictionary = await session.poll_device_authorization_once(started)
	_expect_equal(pending.get("state"), "pending", "pending state")
	var slow_down: Dictionary = await session.poll_device_authorization_once(started)
	_expect_equal(slow_down.get("state"), "slow_down", "slow down state")
	var complete: Dictionary = await session.poll_device_authorization_once(started)
	_expect_equal(complete.get("state"), "complete", "complete state")
	_expect_equal(session.has_session(), true, "session present")
	_expect_equal(
		OIDCClient.decode_jwt_claims(session.get_access_token()).get("aud"),
		"https://api.example.test",
		"device flow exchanges opaque token for API audience"
	)
	_expect_equal(
		OIDCClient.decode_jwt_claims(session.get_access_token()).get("jti"),
		"api-access-1",
		"first API access token"
	)
	_expect_equal(session.get_user_info().get("sub"), "teacher-1", "ID token identity")

	session._tokens["expires_at_unix"] = 0
	var refreshed: Dictionary = await session.ensure_fresh()
	_expect_equal(refreshed.get("ok"), true, "refresh succeeds")
	_expect_equal(
		OIDCClient.decode_jwt_claims(session.get_access_token()).get("jti"),
		"api-access-2",
		"rotated API access token"
	)

	_assert_no_secret_fields()
	session.clear_session()
	_expect_equal(session.has_session(), false, "session cleared")
	session.queue_free()

	if failures.is_empty():
		print("PASS test_auth_session")
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
	if url == "https://api.example.test/api/auth/config?client=desktop":
		return {
			"ok": true,
			"http_code": 200,
			"json": {
				"ok": true,
				"auth": {
					"schema_version": 1,
					"provider_id": "self_hosted",
					"protocol": "oidc",
					"issuer": "https://auth.example.test/oidc",
					"audience": "https://api.example.test",
					"client_id": "desktop-client",
					"scopes": ["openid", "profile", "email", "offline_access"],
					"flow": "authorization_code_pkce",
					"fallback_flow": "device_authorization",
					"redirect_uri": "http://127.0.0.1:45871/auth/callback",
					"callback_timeout_seconds": 180,
					"discovery_url": "https://auth.example.test/oidc/.well-known/openid-configuration",
				},
			},
		}
	if url.ends_with("/.well-known/openid-configuration"):
		return {
			"ok": true,
			"http_code": 200,
			"json": {
				"issuer": "https://auth.example.test/oidc",
				"authorization_endpoint": "https://auth.example.test/oidc/auth",
				"token_endpoint": "https://auth.example.test/oidc/token",
				"device_authorization_endpoint": "https://auth.example.test/oidc/device/auth",
				"jwks_uri": "https://auth.example.test/oidc/jwks",
				"userinfo_endpoint": "https://auth.example.test/oidc/me",
			},
		}
	if url == "https://auth.example.test/oidc/me":
		return {
			"ok": true,
			"http_code": 200,
			"json": {
				"sub": "teacher-1",
				"username": "Lyam",
				"name": "Lyam",
			},
		}
	if url.ends_with("/device/auth"):
		return {
			"ok": true,
			"http_code": 200,
			"json": {
				"device_code": "device-secret",
				"user_code": "ABCD-EFGH",
				"verification_uri": "https://auth.example.test/device",
				"verification_uri_complete": "https://auth.example.test/device?user_code=ABCD-EFGH",
				"expires_in": 600,
				"interval": 5,
			},
		}
	if url.ends_with("/token") and fields.get("grant_type") == "refresh_token":
		refresh_attempt += 1
		return {
			"ok": true,
			"http_code": 200,
			"json": {
				"access_token": _access_token("api-access-%d" % refresh_attempt),
				"refresh_token": "refresh-2",
				"token_type": "Bearer",
				"expires_in": 3600,
			},
		}
	if url.ends_with("/token") and fields.get("grant_type") == "authorization_code":
		return {
			"ok": true,
			"http_code": 200,
			"json": {
				"access_token": _access_token("pkce-access"),
				"refresh_token": "pkce-refresh",
				"id_token": _id_token(),
				"token_type": "Bearer",
				"expires_in": 3600,
			},
		}
	if url.ends_with("/token"):
		token_attempt += 1
		if token_attempt == 1:
			return {
				"ok": false,
				"http_code": 400,
				"json": {"error": "authorization_pending"},
			}
		if token_attempt == 2:
			return {
				"ok": false,
				"http_code": 400,
				"json": {"error": "slow_down"},
			}
		return {
			"ok": true,
			"http_code": 200,
			"json": {
				"access_token": "opaque-device-token",
				"refresh_token": "refresh-1",
				"id_token": _id_token(),
				"token_type": "Bearer",
				"expires_in": 3600,
			},
		}
	return {"ok": false, "http_code": 404, "json": {"error": "not_found"}}


func _fake_browser_opener(url: String) -> int:
	opened_urls.append(url)
	authorization_state = _query_fields(url).get("state", "")
	return OK


func _fake_callback_receiver(_redirect_uri: String, _timeout_seconds: int) -> Dictionary:
	await process_frame
	return {
		"ok": true,
		"code": "browser-code",
		"state": authorization_state,
	}


func _request_count(url: String) -> int:
	var count := 0
	for request in requests:
		if request.get("url") == url:
			count += 1
	return count


func _last_request_with_field(field: String, value: String) -> Dictionary:
	for index in range(requests.size() - 1, -1, -1):
		var request: Dictionary = requests[index]
		if str(request.get("fields", {}).get(field, "")) == value:
			return request
	return {}


func _last_request_for_url(url: String) -> Dictionary:
	for index in range(requests.size() - 1, -1, -1):
		var request: Dictionary = requests[index]
		if str(request.get("url", "")) == url:
			return request
	return {}


func _query_fields(url: String) -> Dictionary:
	var result := {}
	for item in url.get_slice("?", 1).split("&", false):
		result[item.get_slice("=", 0).uri_decode()] = item.get_slice("=", 1).uri_decode()
	return result


func _id_token() -> String:
	var payload := Marshalls.utf8_to_base64(JSON.stringify({
		"sub": "teacher-1",
		"name": "Teacher",
		"email": "teacher@example.test",
	})).replace("+", "-").replace("/", "_").trim_suffix("=")
	return "header.%s.signature" % payload


func _access_token(token_id: String) -> String:
	var payload := Marshalls.utf8_to_base64(JSON.stringify({
		"iss": "https://auth.example.test/oidc",
		"aud": "https://api.example.test",
		"sub": "teacher-1",
		"jti": token_id,
	})).replace("+", "-").replace("/", "_").trim_suffix("=")
	return "header.%s.signature" % payload


func _assert_no_secret_fields() -> void:
	for request in requests:
		var fields: Dictionary = request.get("fields", {})
		if fields.has("client_secret"):
			failures.append("request unexpectedly contained client_secret")
		if request.get("url") == "https://api.example.test/api/auth/config?client=desktop":
			_expect_equal(fields, {}, "bootstrap request has no credentials")


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
