extends SceneTree

const AuthSession = preload("res://scripts/auth/auth_session.gd")


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var api_root := OS.get_environment("NEURALESE_AUTH_TEST_API").strip_edges()
	if api_root == "":
		print("SKIP test_auth_live")
		quit(0)
		return

	var session = AuthSession.new()
	root.add_child(session)
	session.configure(api_root, "/api/auth/config?client=desktop_pkce")
	var loaded: Dictionary = await session.load_configuration(true)
	if not loaded.get("ok", false):
		push_error("live auth bootstrap failed: %s" % JSON.stringify(loaded))
		quit(1)
		return

	var auth: Dictionary = loaded.get("auth", {})
	var discovery: Dictionary = loaded.get("discovery", {})
	if str(auth.get("client_id", "")) == "":
		push_error("live auth config has no desktop client ID")
		quit(1)
		return
	if str(auth.get("flow", "")) != "authorization_code_pkce":
		push_error("live desktop auth does not use authorization-code PKCE")
		quit(1)
		return
	if str(auth.get("redirect_uri", "")) != "http://127.0.0.1:45871/auth/callback":
		push_error("live desktop auth has an unexpected loopback callback")
		quit(1)
		return
	if str(discovery.get("device_authorization_endpoint", "")) == "":
		push_error("live OIDC discovery has no device endpoint")
		quit(1)
		return
	if str(discovery.get("token_endpoint", "")) == "":
		push_error("live OIDC discovery has no token endpoint")
		quit(1)
		return

	session.queue_free()
	print("PASS test_auth_live")
	quit(0)
