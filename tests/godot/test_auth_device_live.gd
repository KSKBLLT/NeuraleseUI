extends SceneTree

const AuthSession = preload("res://scripts/auth/auth_session.gd")
const OIDCClient = preload("res://scripts/auth/oidc_client.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var api_root := OS.get_environment("NEURALESE_AUTH_TEST_API").strip_edges()
	if api_root == "":
		print("SKIP test_auth_device_live")
		quit(0)
		return

	var session = AuthSession.new()
	root.add_child(session)
	session.configure(api_root, "/api/auth/config?client=desktop")
	var loaded: Dictionary = await session.load_configuration()
	if not loaded.get("ok", false):
		_fail("auth configuration failed: %s" % JSON.stringify(loaded))
		return
	var expected_audience := str(loaded.get("auth", {}).get("audience", ""))
	var started: Dictionary = await session.start_device_authorization()
	if str(started.get("device_code", "")) == "":
		_fail("device authorization failed: %s" % JSON.stringify(started))
		return

	print("AUTHORIZE %s" % str(started.get(
		"verification_uri_complete",
		started.get("verification_uri", "")
	)))
	var interval := int(started.get("interval", 5))
	var expires_at := int(started.get("expires_at_unix", 0))
	while int(Time.get_unix_time_from_system()) < expires_at:
		await create_timer(interval).timeout
		var polled: Dictionary = await session.poll_device_authorization_once(started)
		match str(polled.get("state", "")):
			"complete":
				var claims := OIDCClient.decode_jwt_claims(
					session.get_access_token()
				)
				var audience: Variant = claims.get("aud")
				if not _audience_contains(audience, expected_audience):
					_fail("device access token has the wrong audience")
					return
				session.clear_session()
				session.queue_free()
				print("PASS test_auth_device_live")
				quit(0)
				return
			"pending":
				continue
			"slow_down":
				interval += 5
				continue
			_:
				_fail("device token polling failed: %s" % JSON.stringify(polled))
				return

	_fail("device authorization expired")


func _audience_contains(audience: Variant, expected: String) -> bool:
	if typeof(audience) == TYPE_STRING:
		return str(audience) == expected
	if typeof(audience) == TYPE_ARRAY:
		return expected in audience
	return false


func _fail(message: String) -> void:
	push_error(message)
	quit(1)
