extends Node
class_name Cookies

const AuthSessionService = preload("res://scripts/auth/auth_session.gd")
const AuthFlowPolicy = preload("res://scripts/auth/auth_flow_policy.gd")
const LegacyCredentialCleanup = preload("res://scripts/auth/legacy_credential_cleanup.gd")
const ProfileOnboardingService = preload("res://scripts/startup/profile_onboarding.gd")

const cookie_file = "user://cookies.json"
const NEURALESE_PROFILE_COOKIE = "neuralese_profile"
const PILOT_RUNTIME_IDENTITY_COOKIE = "pilot_runtime_identity"

signal auth_login_started(payload: Dictionary)
signal auth_login_completed(session: Dictionary)
signal auth_login_failed(error: Dictionary)
signal user_profile_updated(profile: Dictionary)

var _cookies: Dictionary = {}
var _auth_session: Node
var _configured_api_root := ""
var _configured_endpoint := ""

func _ready() -> void:
	_load_cookies()
	if LegacyCredentialCleanup.remove_from(_cookies):
		_save_cookies()
	_ensure_auth_session()
	
	#test tab: dont remove.
	#await glob.wait(0.9)
	#glob.go_window("net")

func _ensure_auth_session() -> Node:
	if not is_instance_valid(_auth_session):
		_auth_session = AuthSessionService.new()
		add_child(_auth_session)
		_auth_session.login_started.connect(_on_auth_login_started)
	var root_url: String = str(glob.get_root_http()).trim_suffix("/")
	var endpoint := str(ProjectSettings.get_setting("auth/config_endpoint", "")).strip_edges()
	if root_url != _configured_api_root or endpoint != _configured_endpoint:
		_auth_session.configure(root_url, endpoint)
		_configured_api_root = root_url
		_configured_endpoint = endpoint
	return _auth_session

func _on_auth_login_started(payload: Dictionary) -> void:
	auth_login_started.emit(payload)

func get_bearer_auth_header() -> Dictionary:
	return _auth_session.get_auth_headers() if has_auth_session() else {}

func refreshed_auth_headers(headers: Dictionary) -> Dictionary:
	var out := headers.duplicate(true)
	if has_auth_session() and out.has("Authorization"):
		out["Authorization"] = "Bearer %s" % _auth_session.get_access_token()
	return out

func get_legacy_auth_pair() -> Dictionary:
	return {
		"user": user(),
		"pass": pwd(),
	}

func set_profile(field: String, val):
	var cfg = glob.remote_config if typeof(glob.remote_config) == TYPE_DICTIONARY else {}
	cfg[field] = val
	glob.set_remote_config(cfg)

	var neuralese_profile = get_neuralese_profile()
	if has_auth_session() or bool(neuralese_profile.get("local_profile", false)):
		if typeof(neuralese_profile) != TYPE_DICTIONARY:
			neuralese_profile = {}
		neuralese_profile[field] = val
		set_cookie(NEURALESE_PROFILE_COOKIE, JSON.stringify(neuralese_profile))
		if typeof(glob._logged_in) == TYPE_DICTIONARY and glob._logged_in.has("auth_provider"):
			var session_profile = glob._logged_in.get("profile", {})
			if typeof(session_profile) != TYPE_DICTIONARY:
				session_profile = {}
			session_profile[field] = val
			glob._logged_in["profile"] = session_profile
			glob.set_var("credentials", glob._logged_in)

func profile(field: String):
	#if field == "my_classroom": return "111111"
	var neuralese_profile = get_neuralese_profile()
	if has_auth_session() or bool(neuralese_profile.get("local_profile", false)):
		if field == "teacher":
			return str(neuralese_profile.get("type", "")).strip_edges().to_lower() == "teacher"
		if neuralese_profile.has(field):
			return neuralese_profile.get(field)
	return glob.remote_config.get(field)

var downloads_dir = OS.get_system_dir(OS.SYSTEM_DIR_DOWNLOADS)

func get_username() -> String:
	if has_auth_session():
		return get_display_identity()
	return glob._logged_in.get("user", "")

func get_pass() -> String:
	return glob._logged_in.get("pass", "")

func user() -> String:
	if has_auth_session():
		return get_display_identity()
	return glob._logged_in.get("user", "") if glob._logged_in else ""

func pwd() -> String:
	return glob._logged_in.get("pass", "") if glob._logged_in else ""

func has_auth_session() -> bool:
	return _ensure_auth_session().has_session()

func has_pilot_session() -> bool:
	return (
		has_auth_session()
		and str(_auth_session.get_session().get("auth_provider", "")) == "pilot"
	)

func get_auth_user() -> Dictionary:
	return _ensure_auth_session().get_user_info()

func get_auth_display_name() -> String:
	return resolve_display_identity({}, get_auth_user())

func get_neuralese_profile() -> Dictionary:
	var profile := get_pilot_account_profile()
	if has_pilot_session():
		return AuthFlowPolicy.merge_pilot_runtime_identity(
			profile,
			get_pilot_runtime_identity()
		)
	return profile


func get_pilot_account_profile() -> Dictionary:
	var raw = str(_cookies.get(NEURALESE_PROFILE_COOKIE, ""))
	if raw == "":
		return {}
	var parsed = JSON.parse_string(raw)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func get_pilot_runtime_identity() -> Dictionary:
	var raw := str(_cookies.get(PILOT_RUNTIME_IDENTITY_COOKIE, ""))
	if raw.is_empty():
		return {}
	var parsed: Variant = JSON.parse_string(raw)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


func set_pilot_runtime_identity(first_name: String, last_name: String) -> Dictionary:
	var normalized_first := first_name.strip_edges()
	var normalized_last := last_name.strip_edges()
	if normalized_first.is_empty():
		return {"ok": false, "error": "invalid_first_name"}
	if normalized_last.is_empty():
		return {"ok": false, "error": "invalid_last_name"}
	var identity := {
		"first_name": normalized_first,
		"last_name": normalized_last,
		"certificate_name": "%s %s" % [normalized_first, normalized_last],
	}
	set_cookie(PILOT_RUNTIME_IDENTITY_COOKIE, JSON.stringify(identity))
	var active_profile := AuthFlowPolicy.merge_pilot_runtime_identity(
		get_pilot_account_profile(), identity
	)
	if typeof(glob._logged_in) == TYPE_DICTIONARY:
		glob._logged_in["profile"] = active_profile
		glob._logged_in["user"] = str(identity["certificate_name"])
		glob.set_var("credentials", glob._logged_in)
	user_profile_updated.emit(active_profile.duplicate(true))
	return {
		"ok": true,
		"profile": active_profile,
		"runtime_identity": identity,
	}


func get_preferred_language() -> String:
	return str(glob.get_lang())


func apply_preferred_language(language: String) -> void:
	glob.change_lang(language)

func get_profile_username() -> String:
	return _identity_text(get_neuralese_profile().get("username"))

func get_display_identity() -> String:
	return resolve_display_identity(get_neuralese_profile(), get_auth_user())


static func resolve_display_identity(profile: Dictionary, user_info: Dictionary) -> String:
	return AuthFlowPolicy.resolve_display_identity(profile, user_info)


static func login_result_with_profile_sync(
	login_result: Dictionary,
	profile_sync_result: Dictionary
) -> Dictionary:
	return AuthFlowPolicy.login_result_with_profile_sync(
		login_result,
		profile_sync_result
	)


static func _identity_text(value: Variant) -> String:
	return AuthFlowPolicy.identity_text(value)

func restore_or_refresh_session(_saved: Dictionary = {}) -> bool:
	if not has_auth_session():
		return false
	var fresh: Dictionary = await _auth_session.ensure_fresh()
	if fresh.get("ok", false):
		_apply_auth_session(_auth_session.get_session(), true)
		var profile_result: Dictionary = await get_user_profile()
		if profile_result.get("ok", false):
			return true
		return true
	if _should_clear_auth_session_for_error(fresh):
		clear_auth_session(false)
	return false

func login_cached_or_browser(open_browser: bool = true) -> Dictionary:
	var profile_before_login := get_neuralese_profile()
	if await restore_or_refresh_session():
		var restored_handoff: Dictionary = await ProfileOnboardingService.new(
			self
		).sync_local_profile_after_login(profile_before_login)
		var session: Dictionary = _auth_session.get_session()
		auth_login_completed.emit(session)
		return login_result_with_profile_sync({
			"ok": true,
			"cached": true,
			"session": session,
		}, restored_handoff)
	var result: Dictionary = await _auth_session.login(open_browser)
	if not result.get("ok", false):
		auth_login_failed.emit(result)
		return result
	var session: Dictionary = result.get("session", {})
	_apply_auth_session(session, true)
	await get_user_profile()
	var handoff: Dictionary = await ProfileOnboardingService.new(
		self
	).sync_local_profile_after_login(profile_before_login)
	auth_login_completed.emit(session)
	return login_result_with_profile_sync(result, handoff)

func clear_auth_session(reset_glob: bool = true) -> void:
	_ensure_auth_session().clear_session()
	delete_cookie(NEURALESE_PROFILE_COOKIE)
	var cfg = glob.remote_config if typeof(glob.remote_config) == TYPE_DICTIONARY else {}
	cfg["teacher"] = false
	cfg["my_classroom"] = ""
	glob.set_remote_config(cfg)
	if reset_glob:
		glob._logged_in = {}
		glob.set_var("credentials", {})

func refresh_session() -> Dictionary:
	var result: Dictionary = await _ensure_auth_session().refresh()
	if result.get("ok", false):
		_apply_auth_session(_auth_session.get_session(), true)
	else:
		auth_login_failed.emit(result)
	return result

func apply_pilot_session(payload: Dictionary) -> Dictionary:
	var profile: Variant = payload.get("profile", {})
	var user: Variant = payload.get("user", {})
	if typeof(profile) != TYPE_DICTIONARY or profile.is_empty():
		return {"ok": false, "error": "invalid_pilot_profile"}
	if typeof(user) != TYPE_DICTIONARY:
		user = {}

	var applied: Dictionary = _ensure_auth_session().apply_internal_token_pair(
		payload,
		"pilot"
	)
	if not applied.get("ok", false):
		return applied
	var session: Dictionary = applied.get("session", {}).duplicate(true)
	session["profile"] = profile.duplicate(true)
	session["user"] = str(user.get("display_name", profile.get(
		"certificate_name", ""
	)))
	_apply_auth_session(session, true)
	auth_login_completed.emit(session)
	return {
		"ok": true,
		"session": session,
		"profile": profile.duplicate(true),
	}

func _should_clear_auth_session_for_error(result: Dictionary) -> bool:
	var http_code = int(result.get("http_code", 0))
	if http_code == 401 or http_code == 403:
		return true
	var error_text = str(result.get("error", result.get("message", ""))).to_lower()
	return (
		error_text.find("invalid token") != -1
		or error_text.find("signature") != -1
		or error_text.find("expired") != -1
		or error_text.find("revoked") != -1
		or error_text.find("refresh") != -1 and error_text.find("invalid") != -1
	)

func get_user_profile() -> Dictionary:
	if not has_auth_session():
		return {"ok": false, "error": "missing session"}
	var result = await _auth_json_request(
		"GET",
		"/api/users/me",
		{},
		get_bearer_auth_header()
	)
	if result.get("ok", false):
		_apply_user_profile(result.get("profile", {}), true)
	return result

func needs_username() -> bool:
	var profile = get_neuralese_profile()
	if profile.is_empty():
		return true
	if profile.has("needs_username"):
		return bool(profile.get("needs_username"))
	return (
		str(profile.get("username", "")) == ""
		and not bool(profile.get("onboarding_complete", false))
	)

func needs_account_type() -> bool:
	var profile = get_neuralese_profile()
	if profile.is_empty():
		return true
	if profile.has("needs_account_type"):
		return bool(profile.get("needs_account_type"))
	return not bool(profile.get("account_type_selected", false))

func select_account_type(account_type: String) -> Dictionary:
	if not has_auth_session():
		return {"ok": false, "error": "missing session"}
	var normalized := str(account_type).strip_edges().to_lower()
	if normalized not in ["student", "teacher"]:
		return {"ok": false, "error": "invalid_account_type"}
	var result = await _auth_json_request(
		"POST",
		"/api/users/account-type",
		{"account_type": normalized},
		get_bearer_auth_header()
	)
	if result.get("ok", false):
		_apply_user_profile(result.get("profile", {}), true)
	return result

func complete_onboarding(first_name: String, last_name: String, account_type: String) -> Dictionary:
	if not has_auth_session():
		return {"ok": false, "error": "missing session"}
	var result = await _auth_json_request(
		"POST",
		"/api/users/onboarding",
		{
			"first_name": first_name.strip_edges(),
			"last_name": last_name.strip_edges(),
			"account_type": account_type.strip_edges().to_lower(),
		},
		get_bearer_auth_header()
	)
	if result.get("ok", false):
		_apply_user_profile(result.get("profile", {}), true)
	return result


func complete_local_onboarding(first_name: String, last_name: String, account_type: String, language: String) -> Dictionary:
	var normalized_first := first_name.strip_edges()
	var normalized_last := last_name.strip_edges()
	var normalized_type := account_type.strip_edges().to_lower()
	var normalized_language := language.strip_edges().to_lower()
	if normalized_first.is_empty() or normalized_last.is_empty():
		return {"ok": false, "error": "invalid_local_profile_name"}
	if normalized_type not in ["student", "teacher"]:
		return {"ok": false, "error": "invalid_account_type"}
	if normalized_language not in ["en", "ru", "kz"]:
		return {"ok": false, "error": "invalid_language"}

	var profile := get_neuralese_profile()
	var account_id := str(profile.get("account_id", "")).strip_edges()
	if account_id.is_empty():
		account_id = "local_%s" % Crypto.new().generate_random_bytes(16).hex_encode()
	profile.merge({
		"account_id": account_id,
		"first_name": normalized_first,
		"last_name": normalized_last,
		"certificate_name": "%s %s" % [normalized_first, normalized_last],
		"type": normalized_type,
		"account_type_selected": true,
		"language": normalized_language,
		"local_profile": true,
		"onboarding_complete": true,
		"onboarding_version": 1,
		"needs_username": false,
		"needs_account_type": false,
	}, true)
	set_cookie(NEURALESE_PROFILE_COOKIE, JSON.stringify(profile))
	user_profile_updated.emit(profile.duplicate(true))
	return {"ok": true, "profile": profile.duplicate(true), "local": true}

func check_username_available(username: String) -> Dictionary:
	if not has_auth_session():
		return {"ok": false, "error": "missing session"}
	return await _auth_json_request(
		"GET",
		"/api/users/username-available?username=%s" % username.uri_encode(),
		{},
		get_bearer_auth_header()
	)

func claim_username(username: String) -> Dictionary:
	if not has_auth_session():
		return {"ok": false, "error": "missing session"}
	var result = await _auth_json_request(
		"POST",
		"/api/users/claim-username",
		{"username": username},
		get_bearer_auth_header()
	)
	if result.get("ok", false):
		_apply_user_profile(result.get("profile", {}), true)
	return result

func open_or_create(path: String, path_from: String = "user://") -> FileAccess:
	if not path_from.ends_with("/"):
		path_from += "/"
	var full_path = path_from + path
	var dir_path = full_path.get_base_dir()
	#(full_path)

	var dir := DirAccess.open(path_from)
	if dir and not dir.dir_exists(dir_path):
		var err = dir.make_dir_recursive(dir_path)
		if err != OK:
			push_error("Failed to create directory: %s" % dir_path)
			return null
	var file = FileAccess.open(full_path, FileAccess.READ_WRITE)
	if file:
		return file
	file = FileAccess.open(full_path, FileAccess.WRITE_READ)
	if not file:
		push_error("Failed to open or create file: %s" % full_path)
		return null
	return file

signal sandbox_projects_page_started(payload: Dictionary)
signal sandbox_projects_page_loaded(payload: Dictionary)
signal sandbox_projects_page_failed(error: Dictionary)

var _sandbox_projects_cursor: int = 0
var _sandbox_projects_total: int = 0
var _sandbox_projects_loading: bool = false
var _sandbox_projects_source_mode: String = "generated"

func reset_sandbox_projects_feed(total_count: int = 1000, source_mode: String = "generated") -> void:
	_sandbox_projects_cursor = 0
	_sandbox_projects_total = max(0, total_count)
	_sandbox_projects_loading = false
	_sandbox_projects_source_mode = source_mode


func has_more_sandbox_projects() -> bool:
	return _sandbox_projects_cursor < _sandbox_projects_total


func is_sandbox_projects_loading() -> bool:
	return _sandbox_projects_loading


func request_sandbox_projects_page(page_size: int = 24, cursor: String = "", simulated_delay_seconds: float = 0.12, filters: Dictionary = {}) -> Dictionary:
	if _sandbox_projects_loading:
		var busy_error = {
			"ok": false,
			"error": "sandbox projects request already in progress",
			"busy": true,
		}
		sandbox_projects_page_failed.emit(busy_error)
		return busy_error

	var safe_page_size = max(1, page_size)
	var resolved_cursor = _resolve_sandbox_projects_cursor(cursor)

	if resolved_cursor >= _sandbox_projects_total:
		var empty_payload = {
			"ok": true,
			"items": [],
			"cursor": str(resolved_cursor),
			"next_cursor": str(resolved_cursor),
			"has_more": false,
			"total": _sandbox_projects_total,
			"count": 0,
			"filters": filters,
			"source": _sandbox_projects_source_mode,
		}
		sandbox_projects_page_loaded.emit(empty_payload)
		return empty_payload

	_sandbox_projects_loading = true

	sandbox_projects_page_started.emit({
		"cursor": str(resolved_cursor),
		"requested_count": safe_page_size,
		"filters": filters,
		"source": _sandbox_projects_source_mode,
	})

	var result = await _download_sandbox_projects_page(
		resolved_cursor,
		safe_page_size,
		simulated_delay_seconds,
		filters
	)

	_sandbox_projects_loading = false

	if not result.get("ok", false):
		sandbox_projects_page_failed.emit(result)
		return result

	_sandbox_projects_cursor = int(result.get("next_cursor", _sandbox_projects_cursor))
	sandbox_projects_page_loaded.emit(result)

	return result


func _resolve_sandbox_projects_cursor(cursor: String) -> int:
	var clean_cursor = cursor.strip_edges()

	if clean_cursor == "":
		return _sandbox_projects_cursor

	if not clean_cursor.is_valid_int():
		return _sandbox_projects_cursor

	return clamp(int(clean_cursor), 0, _sandbox_projects_total)


func _download_sandbox_projects_page(start_cursor: int, page_size: int, simulated_delay_seconds: float, filters: Dictionary) -> Dictionary:
	# Later replace this function body with a real web._request().
	# Keep request_sandbox_projects_page() and its payload format unchanged.

	if simulated_delay_seconds > 0.0:
		await get_tree().create_timer(simulated_delay_seconds).timeout

	var end_cursor = min(start_cursor + page_size, _sandbox_projects_total)
	var items: Array = []

	for i in range(start_cursor, end_cursor):
		items.append(_generate_sandbox_project(i, filters))

	return {
		"ok": true,
		"items": items,
		"cursor": str(start_cursor),
		"next_cursor": str(end_cursor),
		"has_more": end_cursor < _sandbox_projects_total,
		"total": _sandbox_projects_total,
		"count": items.size(),
		"filters": filters,
		"source": _sandbox_projects_source_mode,
	}


func _generate_sandbox_project(index: int, filters: Dictionary = {}) -> Dictionary:
	var templates = [
		{
			"slug": "car_track_ai",
			"name": "Car Track AI",
			"short_description": "Train a tiny model to steer around a procedural racing track.",
			"tags": ["Cars", "Beginner", "Inference"],
		},
		{
			"slug": "mnist_lab",
			"name": "Digit Classifier Lab",
			"short_description": "Build and train a neural net to classify handwritten digits.",
			"tags": ["Vision", "Dataset", "Training"],
		},
		{
			"slug": "predator_prey_sim",
			"name": "Predator-Prey Sim",
			"short_description": "Experiment with agents, sensors, rewards, and survival behavior.",
			"tags": ["Agents", "RL", "Simulation"],
		},
		{
			"slug": "gesture_ai",
			"name": "Gesture AI",
			"short_description": "Classify simple hand gestures using a compact visual model.",
			"tags": ["Vision", "Classifier", "Interactive"],
		},
		{
			"slug": "maze_solver",
			"name": "Maze Solver",
			"short_description": "Teach a model to navigate mazes with limited sensor inputs.",
			"tags": ["Navigation", "Planning", "Sensors"],
		},
		{
			"slug": "sound_classifier",
			"name": "Sound Classifier",
			"short_description": "Build a small model that recognizes simple audio patterns.",
			"tags": ["Audio", "Signals", "Classifier"],
		},
	]

	var template: Dictionary = templates[index % templates.size()]
	var tags: Array = template.get("tags", []).duplicate(true)

	var feed = str(filters.get("feed", "community"))

	if feed == "featured":
		tags.append("Featured")
		tags.append("Neuralese Team")
	elif index % 7 == 0:
		tags.append("Featured")

	var owner = "Neuralese Team" if feed == "featured" or index % 5 == 0 else get_username()

	return {
		"id": "%s_%04d" % [str(template.get("slug", "sandbox")), index],
		"name": "%s #%d" % [str(template.get("name", "Sandbox")), index + 1],
		"short_description": str(template.get("short_description", "")),
		"tags": tags,
		"owner": owner,
		"feed": feed,
		"project_index": index,
	}





func dir_or_create(path: String) -> DirAccess:
	var full_path = "user://" + path
	
	var dir := DirAccess.open("user://")
	if dir == null:
		push_error("Cannot open user://")
		return null
	
	if not dir.dir_exists(path):
		var err = dir.make_dir_recursive(path)
		if err != OK:
			push_error("Failed to create directory: %s" % full_path)
			return null
	
	return DirAccess.open(full_path)


func _save_cookies() -> void:
	var f = FileAccess.open(cookie_file, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(_cookies, "", true, true))
		f.close()

func set_cookie(name: String, value: String) -> void:
	_cookies[name] = value
	_save_cookies()

func has_cookie(name: String) -> bool:
	return _cookies.has(name)

func delete_cookie(name: String) -> void:
	if _cookies.has(name):
		_cookies.erase(name)
		_save_cookies()

func _load_cookies() -> void:
	if not FileAccess.file_exists(cookie_file):
		return
	var f = FileAccess.open(cookie_file, FileAccess.READ)
	if f:
		var txt = f.get_as_text().strip_edges()
		f.close()
		if txt != "":
			var parsed = JSON.parse_string(txt)
			if typeof(parsed) == TYPE_DICTIONARY:
				_cookies = parsed

func update_from_headers(headers: PackedStringArray) -> void:
	for h in headers:
		var lower = h.to_lower()
		if lower.begins_with("set-cookie:"):
			var cookie_str = h.substr(12).strip_edges()
			_parse_cookie(cookie_str)
	_save_cookies()

func _parse_cookie(cookie_str: String) -> void:
	var parts = cookie_str.split(";")[0].split("=")
	if parts.size() == 2:
		var name = parts[0].strip_edges()
		var value = parts[1].strip_edges()
		_cookies[name] = value

func get_header() -> String:
	if _cookies.is_empty():
		return ""
	var list: Array[String] = []
	for n in _cookies.keys():
		list.append("%s=%s" % [n, _cookies[n]])
	return "Cookie: " + "; ".join(list)

func clear():
	_cookies.clear()
	if FileAccess.file_exists(cookie_file):
		DirAccess.open("user://").remove(cookie_file)

func _apply_auth_session(session: Dictionary, persist: bool) -> void:
	var user_info = session.get("user_info", {})
	if typeof(user_info) != TYPE_DICTIONARY:
		user_info = {}
	var profile = session.get("profile", {})
	if typeof(profile) != TYPE_DICTIONARY:
		profile = {}
	var stored_profile: Dictionary = profile.duplicate(true)
	var auth_provider := str(session.get("auth_provider", ""))
	if auth_provider == "pilot":
		profile = AuthFlowPolicy.merge_pilot_runtime_identity(
			stored_profile,
			get_pilot_runtime_identity()
		)
	var compat_user := resolve_display_identity(profile, user_info)
	if compat_user == "":
		compat_user = _identity_text(session.get("user"))
	glob._logged_in = {
		"auth_provider": auth_provider,
		"user": compat_user,
		"pass": "",
		"user_info": user_info,
		"profile": profile,
	}
	_apply_profile_to_remote_config(stored_profile)
	if persist:
		if not stored_profile.is_empty():
			set_cookie(NEURALESE_PROFILE_COOKIE, JSON.stringify(stored_profile))
		# Only non-secret compatibility metadata is persisted. OIDC tokens stay in memory.
		glob.set_var("credentials", glob._logged_in)

func _apply_user_profile(profile, persist: bool) -> void:
	if typeof(profile) != TYPE_DICTIONARY:
		return
	_apply_profile_to_remote_config(profile)
	if persist:
		set_cookie(NEURALESE_PROFILE_COOKIE, JSON.stringify(profile))
	var user_info := get_auth_user()
	var display_identity := resolve_display_identity(profile, user_info)
	if glob._logged_in.is_empty():
		glob._logged_in = {
			"auth_provider": str(_auth_session.get_session().get("auth_provider", "")),
			"user": display_identity,
			"pass": "",
			"user_info": user_info,
			"profile": profile,
		}
	else:
		glob._logged_in["profile"] = profile
		glob._logged_in["user_info"] = user_info
		if display_identity != "" or _identity_text(glob._logged_in.get("user")) == "":
			glob._logged_in["user"] = display_identity
	glob.set_var("credentials", glob._logged_in)
	user_profile_updated.emit(profile)

func _apply_profile_to_remote_config(profile: Dictionary) -> void:
	if typeof(profile) != TYPE_DICTIONARY:
		return
	var cfg = glob.remote_config if typeof(glob.remote_config) == TYPE_DICTIONARY else {}
	cfg["teacher"] = str(profile.get("type", "")).strip_edges().to_lower() == "teacher"
	if profile.has("my_classroom"):
		cfg["my_classroom"] = profile.get("my_classroom")
	glob.set_remote_config(cfg)

func _auth_json_request(method: String, path: String, body: Dictionary = {}, headers: Dictionary = {}) -> Dictionary:
	var url = glob.get_root_http().trim_suffix("/") + path
	var http_method = HTTPClient.METHOD_GET if method == "GET" else HTTPClient.METHOD_POST
	var req = await web._request(
		url,
		{} if method == "GET" else body,
		http_method,
		false,
		false,
		false,
		headers,
		path
	)
	if typeof(req) != TYPE_DICTIONARY:
		return {"ok": false, "error": "invalid web response", "url": url}
	var result_code: int = int(req.get("result", OK))
	var response_code: int = int(req.get("code", 0))
	var response_body: PackedByteArray = req.get("body", PackedByteArray())
	var text = response_body.get_string_from_utf8()
	var parsed = JSON.parse_string(text)
	#print(response_body)
	if typeof(parsed) != TYPE_DICTIONARY:
		parsed = {"ok": false, "error": "invalid json", "raw": text}
	if result_code != HTTPRequest.RESULT_SUCCESS:
		parsed["ok"] = false
		parsed["error"] = parsed.get("error", "network error")
	if response_code < 200 or response_code >= 300:
		parsed["ok"] = false
		parsed["error"] = parsed.get("error", "http %s" % response_code)
	parsed["http_code"] = response_code
	parsed["url"] = url
	return parsed
