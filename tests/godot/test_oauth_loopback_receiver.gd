extends SceneTree

const OAuthLoopbackReceiver = preload("res://scripts/auth/oauth_loopback_receiver.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_redirect_uri_contract()
	_test_callback_request_parser()

	if failures.is_empty():
		print("PASS test_oauth_loopback_receiver")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_redirect_uri_contract() -> void:
	_expect_equal(
		OAuthLoopbackReceiver.parse_redirect_uri(
			"http://127.0.0.1:45871/auth/callback"
		),
		{"host": "127.0.0.1", "port": 45871, "path": "/auth/callback"},
		"valid loopback redirect"
	)
	_expect_equal(
		OAuthLoopbackReceiver.parse_redirect_uri(
			"http://localhost:45871/auth/callback"
		),
		{},
		"localhost alias is rejected"
	)
	_expect_equal(
		OAuthLoopbackReceiver.parse_redirect_uri(
			"http://127.0.0.1:80/auth/callback"
		),
		{},
		"privileged port is rejected"
	)


func _test_callback_request_parser() -> void:
	var request := (
		"GET /auth/callback?code=abc%2F123&state=state-value HTTP/1.1\r\n"
		+ "Host: 127.0.0.1:45871\r\n\r\n"
	)
	_expect_equal(
		OAuthLoopbackReceiver.parse_http_request(request, "/auth/callback"),
		{"ok": true, "code": "abc/123", "state": "state-value"},
		"authorization callback"
	)
	_expect_equal(
		OAuthLoopbackReceiver.parse_http_request(
			"GET /other?code=abc&state=state-value HTTP/1.1\r\n\r\n",
			"/auth/callback"
		).get("error"),
		"invalid_callback_path",
		"callback path is exact"
	)
	_expect_equal(
		OAuthLoopbackReceiver.parse_http_request(
			"POST /auth/callback HTTP/1.1\r\n\r\n",
			"/auth/callback"
		).get("error"),
		"invalid_callback_method",
		"callback only accepts GET"
	)
	_expect_equal(
		OAuthLoopbackReceiver.parse_http_request(
			"GET /auth/callback?error=access_denied&state=s HTTP/1.1\r\n\r\n",
			"/auth/callback"
		),
		{"ok": false, "error": "access_denied", "state": "s"},
		"OIDC error callback"
	)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
