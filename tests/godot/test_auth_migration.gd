extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_expect_file_without(
		"res://scripts/cookie_manager.gd",
		["clerk", "X-Neuralese-Auth-Provider"],
		"cookie compatibility facade is provider-neutral"
	)
	_expect_file_without(
		"res://scripts/web.gd",
		["has_clerk_session", "clerk_refresh_session"],
		"web retry is provider-neutral"
	)
	_expect_file_without(
		"res://scripts/glob.gd",
		["has_clerk_session", "restore_or_refresh_clerk_session", "clear_clerk_session"],
		"global login flow is provider-neutral"
	)

	var project_text := _read("res://project.godot")
	_expect_contains(
		project_text,
		"config_endpoint=\"/api/auth/config?client=desktop_pkce\"",
		"desktop bootstrap endpoint is project configuration"
	)

	var cookie_text := _read("res://scripts/cookie_manager.gd")
	_expect_contains(
		cookie_text,
		"AuthSessionService",
		"compatibility facade delegates to auth session"
	)
	_expect_not_contains(
		cookie_text,
		"set_cookie(AUTH_ACCESS",
		"access token is not persisted"
	)
	_expect_not_contains(
		cookie_text,
		"set_cookie(AUTH_REFRESH",
		"refresh token is not persisted"
	)

	if failures.is_empty():
		print("PASS test_auth_migration")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _read(path: String) -> String:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		failures.append("could not read %s" % path)
		return ""
	var text := file.get_as_text()
	file.close()
	return text


func _expect_file_without(path: String, needles: Array[String], label: String) -> void:
	var text := _read(path).to_lower()
	for needle in needles:
		if text.find(needle.to_lower()) != -1:
			failures.append("%s: found %s in %s" % [label, needle, path])


func _expect_contains(text: String, needle: String, label: String) -> void:
	if text.find(needle) == -1:
		failures.append("%s: missing %s" % [label, needle])


func _expect_not_contains(text: String, needle: String, label: String) -> void:
	if text.find(needle) != -1:
		failures.append("%s: found %s" % [label, needle])
