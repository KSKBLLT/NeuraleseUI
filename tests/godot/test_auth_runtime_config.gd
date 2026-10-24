extends SceneTree

const AuthRuntimeConfig = preload("res://scripts/auth/auth_runtime_config.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_valid_contract()
	_test_rejects_unknown_and_secret_fields()
	_test_rejects_mismatched_discovery()
	_test_loopback_http_policy()
	_test_pkce_redirect_contract()

	if failures.is_empty():
		print("PASS test_auth_runtime_config")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _valid_payload() -> Dictionary:
	return {
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
	}


func _test_valid_contract() -> void:
	var parsed := AuthRuntimeConfig.parse(_valid_payload())
	_expect_equal(parsed.get("client_id"), "desktop-client", "client id")
	_expect_equal(parsed.get("audience"), "https://api.example.test", "audience")
	_expect_equal(parsed.get("scopes", []).size(), 4, "scope count")
	_expect_equal(parsed.get("fallback_flow"), "device_authorization", "fallback flow")
	_expect_equal(
		parsed.get("redirect_uri"),
		"http://127.0.0.1:45871/auth/callback",
		"PKCE redirect URI"
	)
	_expect_equal(parsed.get("callback_timeout_seconds"), 180, "callback timeout")


func _test_rejects_unknown_and_secret_fields() -> void:
	var unknown := _valid_payload()
	unknown["auth"]["unexpected"] = "value"
	_expect_empty(AuthRuntimeConfig.parse(unknown), "unknown auth field")

	var secret := _valid_payload()
	secret["auth"]["client_secret"] = "must-never-be-public"
	_expect_empty(AuthRuntimeConfig.parse(secret), "client secret")

	var extra_envelope := _valid_payload()
	extra_envelope["debug"] = true
	_expect_empty(AuthRuntimeConfig.parse(extra_envelope), "unknown envelope field")


func _test_rejects_mismatched_discovery() -> void:
	var payload := _valid_payload()
	payload["auth"]["discovery_url"] = "https://attacker.example/.well-known/openid-configuration"
	_expect_empty(AuthRuntimeConfig.parse(payload), "mismatched discovery URL")


func _test_loopback_http_policy() -> void:
	var loopback := _valid_payload()
	loopback["auth"]["issuer"] = "http://127.0.0.1:3001/oidc"
	loopback["auth"]["discovery_url"] = "http://127.0.0.1:3001/oidc/.well-known/openid-configuration"
	_expect_equal(
		AuthRuntimeConfig.parse(loopback).get("issuer"),
		"http://127.0.0.1:3001/oidc",
		"loopback HTTP"
	)

	var insecure := _valid_payload()
	insecure["auth"]["issuer"] = "http://auth.example.test/oidc"
	insecure["auth"]["discovery_url"] = "http://auth.example.test/oidc/.well-known/openid-configuration"
	_expect_empty(AuthRuntimeConfig.parse(insecure), "remote HTTP")


func _test_pkce_redirect_contract() -> void:
	var missing := _valid_payload()
	missing["auth"].erase("redirect_uri")
	_expect_empty(AuthRuntimeConfig.parse(missing), "PKCE redirect is required")

	var remote_http := _valid_payload()
	remote_http["auth"]["redirect_uri"] = "http://example.test/auth/callback"
	_expect_empty(AuthRuntimeConfig.parse(remote_http), "remote HTTP redirect")

	var wrong_host := _valid_payload()
	wrong_host["auth"]["redirect_uri"] = "http://localhost:45871/auth/callback"
	_expect_empty(AuthRuntimeConfig.parse(wrong_host), "redirect must bind 127.0.0.1")

	var wrong_path := _valid_payload()
	wrong_path["auth"]["redirect_uri"] = "http://127.0.0.1:45871/other"
	_expect_empty(AuthRuntimeConfig.parse(wrong_path), "redirect callback path")

	var device := _valid_payload()
	device["auth"]["flow"] = "device_authorization"
	device["auth"].erase("fallback_flow")
	device["auth"].erase("redirect_uri")
	device["auth"].erase("callback_timeout_seconds")
	_expect_equal(
		AuthRuntimeConfig.parse(device).get("flow"),
		"device_authorization",
		"device flow does not require redirect"
	)


func _expect_empty(actual: Dictionary, label: String) -> void:
	_expect_equal(actual, {}, label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
