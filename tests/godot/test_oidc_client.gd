extends SceneTree

const OIDCClient = preload("res://scripts/auth/oidc_client.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_pkce_rfc_vector()
	_test_authorization_code_request()
	_test_discovery_contract()
	_test_device_flow_states()
	_test_refresh_rotation()
	_test_jwt_claim_decode()

	if failures.is_empty():
		print("PASS test_oidc_client")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_pkce_rfc_vector() -> void:
	var verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	_expect_equal(
		OIDCClient.pkce_challenge(verifier),
		"E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM",
		"RFC 7636 challenge"
	)


func _test_authorization_code_request() -> void:
	var endpoint := "https://auth.example.test/oidc/auth"
	var redirect_uri := "http://127.0.0.1:45871/auth/callback"
	var url := OIDCClient.authorization_url(
		endpoint,
		"desktop-client",
		redirect_uri,
		["openid", "profile", "offline_access"],
		"https://api.example.test",
		"state-value",
		"challenge-value"
	)
	var query := _query_fields(url)
	_expect_equal(url.get_slice("?", 0), endpoint, "authorization endpoint")
	_expect_equal(query.get("client_id"), "desktop-client", "authorization client")
	_expect_equal(query.get("redirect_uri"), redirect_uri, "authorization redirect")
	_expect_equal(query.get("response_type"), "code", "authorization response type")
	_expect_equal(query.get("scope"), "openid profile offline_access", "authorization scopes")
	_expect_equal(query.get("resource"), "https://api.example.test", "authorization resource")
	_expect_equal(query.get("state"), "state-value", "authorization state")
	_expect_equal(query.get("code_challenge"), "challenge-value", "PKCE challenge")
	_expect_equal(query.get("code_challenge_method"), "S256", "PKCE method")
	_expect_equal(query.get("prompt"), "login", "browser session cannot skip login")
	_expect_equal(
		query.get("first_screen"),
		"identifier:sign_in",
		"Logto opens the identifier sign-in form"
	)
	_expect_equal(query.get("identifier"), "username", "Logto requests username sign-in")
	_expect_equal(query.has("client_secret"), false, "public client has no secret")

	var token_fields := OIDCClient.authorization_code_token_fields(
		"desktop-client",
		"authorization-code",
		redirect_uri,
		"verifier-value",
		"https://api.example.test"
	)
	_expect_equal(token_fields.get("grant_type"), "authorization_code", "code grant")
	_expect_equal(token_fields.get("code"), "authorization-code", "authorization code")
	_expect_equal(token_fields.get("code_verifier"), "verifier-value", "PKCE verifier")
	_expect_equal(token_fields.has("client_secret"), false, "token exchange has no secret")


func _test_discovery_contract() -> void:
	var issuer := "https://auth.example.test/oidc"
	var parsed := OIDCClient.parse_discovery({
		"issuer": issuer,
		"authorization_endpoint": issuer + "/auth",
		"token_endpoint": issuer + "/token",
		"device_authorization_endpoint": issuer + "/device/auth",
		"jwks_uri": issuer + "/jwks",
		"userinfo_endpoint": issuer + "/me",
	}, issuer)
	_expect_equal(parsed.get("token_endpoint"), issuer + "/token", "token endpoint")
	_expect_equal(parsed.get("userinfo_endpoint"), issuer + "/me", "userinfo endpoint")
	_expect_equal(
		parsed.get("device_authorization_endpoint"),
		issuer + "/device/auth",
		"device endpoint"
	)

	var mismatch := parsed.duplicate(true)
	mismatch["issuer"] = "https://attacker.example/oidc"
	_expect_equal(OIDCClient.parse_discovery(mismatch, issuer), {}, "issuer mismatch")


func _test_device_flow_states() -> void:
	_expect_equal(
		OIDCClient.classify_token_response(400, {"error": "authorization_pending"}),
		{"state": "pending", "retryable": true},
		"authorization pending"
	)
	_expect_equal(
		OIDCClient.classify_token_response(400, {"error": "slow_down"}),
		{"state": "slow_down", "retryable": true},
		"slow down"
	)
	_expect_equal(
		OIDCClient.classify_token_response(400, {"error": "access_denied"}),
		{"state": "access_denied", "retryable": false},
		"access denied"
	)
	_expect_equal(
		OIDCClient.classify_token_response(400, {"error": "expired_token"}),
		{"state": "expired", "retryable": false},
		"expired token"
	)
	_expect_equal(
		OIDCClient.classify_token_response(200, {
			"access_token": "access",
			"token_type": "Bearer",
			"expires_in": 3600,
		}).get("state"),
		"complete",
		"successful token"
	)


func _test_refresh_rotation() -> void:
	var current := {
		"access_token": "old-access",
		"refresh_token": "old-refresh",
		"expires_at_unix": 1,
	}
	var rotated := OIDCClient.merge_token_response(current, {
		"access_token": "new-access",
		"refresh_token": "new-refresh",
		"expires_in": 1800,
		"token_type": "Bearer",
	}, 100)
	_expect_equal(rotated.get("access_token"), "new-access", "new access token")
	_expect_equal(rotated.get("refresh_token"), "new-refresh", "rotated refresh token")
	_expect_equal(rotated.get("expires_at_unix"), 1900, "expiry")

	var retained := OIDCClient.merge_token_response(rotated, {
		"access_token": "third-access",
		"expires_in": 60,
		"token_type": "Bearer",
	}, 200)
	_expect_equal(retained.get("refresh_token"), "new-refresh", "retained refresh token")


func _test_jwt_claim_decode() -> void:
	var payload := Marshalls.utf8_to_base64(JSON.stringify({
		"sub": "user-1",
		"name": "Teacher",
		"email": "teacher@example.test",
	})).replace("+", "-").replace("/", "_").trim_suffix("=")
	var claims := OIDCClient.decode_jwt_claims("header.%s.signature" % payload)
	_expect_equal(claims.get("sub"), "user-1", "JWT subject")
	_expect_equal(claims.get("name"), "Teacher", "JWT name")


func _query_fields(url: String) -> Dictionary:
	var result := {}
	var query := url.get_slice("?", 1)
	for item in query.split("&", false):
		var key := item.get_slice("=", 0).uri_decode()
		var value := item.get_slice("=", 1).uri_decode()
		result[key] = value
	return result


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
