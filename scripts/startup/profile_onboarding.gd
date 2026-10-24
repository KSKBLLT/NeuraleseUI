extends RefCounted
class_name ProfileOnboarding

const StartupDialogStyleCore := preload("res://scripts/startup/startup_dialog_style.gd")
const GraphicsQualityConfigScript := preload("res://scripts/graphics_quality.gd")
const CURRENT_VERSION := 1
const ACCOUNT_TYPES := ["student", "teacher"]
const LANGUAGES := ["en", "ru", "kz"]

var _cookies: Variant
var _ui: Variant
var _pilot_client: Variant
var _pilot_config: Dictionary
var _graphics_quality_service: Variant


func _init(
	cookies: Variant = null,
	ui: Variant = null,
	pilot_client: Variant = null,
	pilot_config: Dictionary = {},
	graphics_quality_service: Variant = null
) -> void:
	_cookies = cookies
	_ui = ui
	_pilot_client = pilot_client
	_pilot_config = pilot_config.duplicate(true)
	_graphics_quality_service = graphics_quality_service


static func dialog_spec(
	profile: Dictionary,
	user_info: Dictionary,
	current_language: String = "ru",
	current_graphics_quality: String = "medium"
) -> Dictionary:
	var names := _prefill_names(profile, user_info)
	var role := normalize_role(profile.get("type", "student"))
	if role.is_empty():
		role = "student"
	var language := normalize_language(profile.get("language", current_language))
	if language.is_empty():
		language = "ru"
	var graphics_quality := normalize_graphics_quality(current_graphics_quality)
	if graphics_quality.is_empty():
		graphics_quality = "medium"
	return {
		"id": "startup_profile_onboarding",
		"title": {
			"en": "Welcome to Neuralese",
			"ru": "Добро пожаловать в Neuralese",
			"kz": "Neuralese-ке қош келдіңіз",
		},
		"body": {
			"en": "",
			"ru": "",
			"kz": "",
		},
		"format": "plain",
		"icon_path": "res://game_assets/icons/account.png",
		"size": {"width": 560, "height": 380},
		"surface": "transparent",
		"action_layout": "vertical",
		"appearance": StartupDialogStyleCore.appearance({
			"hide_node_palette": true,
			"field_columns": 2,
		}),
		"dismiss_on_escape": false,
		"dismiss_on_outside_click": false,
		"fields": [
			{
				"id": "first_name",
				"type": "text",
				"label": {"en": "First name", "ru": "Имя", "kz": "Аты"},
				"placeholder": {"en": "Your first name", "ru": "Ваше имя", "kz": "Атыңыз"},
				"required": true,
				"value": names["first_name"],
			},
			{
				"id": "last_name",
				"type": "text",
				"label": {"en": "Last name", "ru": "Фамилия", "kz": "Тегі"},
				"placeholder": {"en": "Your last name", "ru": "Ваша фамилия", "kz": "Тегіңіз"},
				"required": true,
				"value": names["last_name"],
			},
			{
				"id": "role",
				"type": "choice",
				"label": {"en": "I am a", "ru": "Я", "kz": "Мен"},
				"required": true,
				"value": role,
				"options": [
					{"value": "student", "text": {"en": "Student", "ru": "Ученик", "kz": "Оқушы"}},
					{"value": "teacher", "text": {"en": "Teacher", "ru": "Учитель", "kz": "Мұғалім"}},
				],
			},
			{
				"id": "language",
				"type": "choice",
				"live_language": true,
				"label": {"en": "Language", "ru": "Язык", "kz": "Тіл"},
				"required": true,
				"value": language,
				"options": [
					{"value": "en", "text": "English"},
					{"value": "ru", "text": "Русский"},
					{"value": "kz", "text": "Қазақша"},
				],
			},
			_graphics_quality_field(graphics_quality),
		],
		"buttons": [{
			"id": "continue",
			"text": {"en": "Continue", "ru": "Продолжить", "kz": "Жалғастыру"},
			"style": "primary",
			"can_go": false,
		}],
	}


static func pilot_dialog_spec(
	runtime_identity: Dictionary,
	current_language: String = "ru",
	current_graphics_quality: String = "medium"
) -> Dictionary:
	var language := normalize_language(current_language)
	if language.is_empty():
		language = "ru"
	var graphics_quality := normalize_graphics_quality(current_graphics_quality)
	if graphics_quality.is_empty():
		graphics_quality = "medium"
	return {
		"id": "pilot_runtime_identity",
		"title": {
			"en": "Who is working now?",
			"ru": "Кто сейчас работает?",
			"kz": "Қазір кім жұмыс істейді?",
		},
		"body": {"en": "", "ru": "", "kz": ""},
		"format": "plain",
		"icon_path": "res://game_assets/icons/account.png",
		"size": {"width": 560, "height": 340},
		"surface": "transparent",
		"action_layout": "vertical",
		"appearance": StartupDialogStyleCore.appearance({
			"hide_node_palette": true,
			"field_columns": 2,
		}),
		"dismiss_on_escape": false,
		"dismiss_on_outside_click": false,
		"fields": [
			{
				"id": "first_name",
				"type": "text",
				"label": {"en": "First name", "ru": "Имя", "kz": "Аты"},
				"placeholder": {"en": "Your first name", "ru": "Ваше имя", "kz": "Атыңыз"},
				"required": true,
				"value": str(runtime_identity.get("first_name", "")).strip_edges(),
			},
			{
				"id": "last_name",
				"type": "text",
				"label": {"en": "Last name", "ru": "Фамилия", "kz": "Тегі"},
				"placeholder": {"en": "Your last name", "ru": "Ваша фамилия", "kz": "Тегіңіз"},
				"required": true,
				"value": str(runtime_identity.get("last_name", "")).strip_edges(),
			},
			{
				"id": "language",
				"type": "choice",
				"live_language": true,
				"label": {"en": "Language", "ru": "Язык", "kz": "Тіл"},
				"required": true,
				"value": language,
				"options": [
					{"value": "en", "text": "English"},
					{"value": "ru", "text": "Русский"},
					{"value": "kz", "text": "Қазақша"},
				],
			},
			_graphics_quality_field(graphics_quality),
		],
		"buttons": [{
			"id": "continue",
			"text": {"en": "Continue", "ru": "Продолжить", "kz": "Жалғастыру"},
			"style": "primary",
			"can_go": false,
		}],
		"language": language,
	}


static func normalize_role(value: Variant) -> String:
	var normalized := str(value).strip_edges().to_lower()
	return normalized if normalized in ACCOUNT_TYPES else ""


static func normalize_language(value: Variant) -> String:
	var normalized := str(value).strip_edges().to_lower()
	return normalized if normalized in LANGUAGES else ""


static func normalize_graphics_quality(value: Variant) -> String:
	return GraphicsQualityConfigScript.normalize_level_name(str(value))


static func _graphics_quality_field(value: String) -> Dictionary:
	return {
		"id": "graphics_quality",
		"type": "choice",
		"label": {
			"en": "Graphics quality",
			"ru": "Качество графики",
			"kz": "Графика сапасы",
		},
		"required": true,
		"value": value,
		"options": [
			{"value": "high", "text": {"en": "High", "ru": "Высокое", "kz": "Жоғары"}},
			{"value": "medium", "text": {"en": "Medium", "ru": "Среднее", "kz": "Орташа"}},
			{"value": "low", "text": {"en": "Low", "ru": "Низкое", "kz": "Төмен"}},
		],
	}


func ensure_complete() -> Dictionary:
	if _cookies == null or _ui == null:
		return {"ok": false, "error": "profile_onboarding_unavailable"}
	if _pilot_enabled():
		var identity_result: Dictionary = await collect_pilot_launch_identity()
		if not identity_result.get("ok", false):
			return identity_result
		var session_result: Dictionary = await ensure_pilot_session()
		if not session_result.get("ok", false):
			return session_result
		return _pilot_completion_result(identity_result, session_result)
	var profile: Dictionary = _cookies.get_neuralese_profile()
	var current_language := "ru"
	if _cookies.has_method("get_preferred_language"):
		current_language = str(_cookies.get_preferred_language())
	var launch_profile := {
		"type": profile.get("type", "student"),
		"language": profile.get("language", current_language),
	}
	var result: Dictionary = await _ui.show_dialog_and_get_result(
		dialog_spec(launch_profile, {}, current_language, _current_graphics_quality())
	)
	if result.get("action") != "continue":
		return {"ok": false, "error": "profile_onboarding_required"}
	var values: Dictionary = result.get("values", result.get("fields", {}))
	var first_name := str(values.get("first_name", "")).strip_edges()
	var last_name := str(values.get("last_name", "")).strip_edges()
	var role := normalize_role(values.get("role", ""))
	var language := normalize_language(values.get("language", ""))
	var graphics_quality := normalize_graphics_quality(
		values.get("graphics_quality", _current_graphics_quality())
	)
	if first_name.is_empty():
		return {"ok": false, "error": "invalid_first_name"}
	if last_name.is_empty():
		return {"ok": false, "error": "invalid_last_name"}
	if role.is_empty():
		return {"ok": false, "error": "invalid_account_type"}
	if language.is_empty():
		return {"ok": false, "error": "invalid_language"}
	if graphics_quality.is_empty():
		return {"ok": false, "error": "invalid_graphics_quality"}

	var onboarding_result: Dictionary
	if not _cookies.has_auth_session():
		if not _cookies.has_method("complete_local_onboarding"):
			return {"ok": false, "error": "local_profile_storage_unavailable"}
		onboarding_result = await _cookies.complete_local_onboarding(
			first_name, last_name, role, language
		)
	else:
		onboarding_result = await _cookies.complete_onboarding(first_name, last_name, role)
	if onboarding_result.get("ok", false) and _cookies.has_method("apply_preferred_language"):
		_cookies.apply_preferred_language(language)
	if onboarding_result.get("ok", false):
		_apply_graphics_quality(graphics_quality)
	return onboarding_result


func collect_pilot_launch_identity() -> Dictionary:
	if _cookies == null or _ui == null:
		return {"ok": false, "error": "profile_onboarding_unavailable"}
	var current_language := "ru"
	if _cookies.has_method("get_preferred_language"):
		current_language = str(_cookies.get_preferred_language())
	var result: Dictionary = await _ui.show_dialog_and_get_result(
		pilot_dialog_spec({}, current_language, _current_graphics_quality())
	)
	if result.get("action") != "continue":
		return {"ok": false, "error": "pilot_runtime_identity_required"}
	var values: Dictionary = result.get("values", result.get("fields", {}))
	var first_name := str(values.get("first_name", "")).strip_edges()
	var last_name := str(values.get("last_name", "")).strip_edges()
	var language := normalize_language(values.get("language", ""))
	var graphics_quality := normalize_graphics_quality(
		values.get("graphics_quality", _current_graphics_quality())
	)
	if first_name.is_empty():
		return {"ok": false, "error": "invalid_first_name"}
	if last_name.is_empty():
		return {"ok": false, "error": "invalid_last_name"}
	if language.is_empty():
		return {"ok": false, "error": "invalid_language"}
	if graphics_quality.is_empty():
		return {"ok": false, "error": "invalid_graphics_quality"}
	if not _cookies.has_method("set_pilot_runtime_identity"):
		return {"ok": false, "error": "pilot_runtime_identity_storage_unavailable"}
	var identity_result: Dictionary = _cookies.set_pilot_runtime_identity(first_name, last_name)
	if identity_result.get("ok", false) and _cookies.has_method("apply_preferred_language"):
		_cookies.apply_preferred_language(language)
	if identity_result.get("ok", false):
		_apply_graphics_quality(graphics_quality)
	return identity_result


func ensure_pilot_session() -> Dictionary:
	if _cookies == null or _pilot_client == null:
		return {"ok": false, "error": "pilot_device_session_unavailable"}
	var has_pilot_session: bool = (
		_cookies.has_pilot_session()
		if _cookies.has_method("has_pilot_session")
		else _cookies.has_auth_session()
	)
	if has_pilot_session:
		return {"ok": true, "session_reused": true}
	if not _pilot_client.has_method("ensure_device_session"):
		return {"ok": false, "error": "pilot_device_session_unavailable"}
	var persisted_profile: Dictionary = (
		_cookies.get_pilot_account_profile()
		if _cookies.has_method("get_pilot_account_profile")
		else {}
	)
	return await _pilot_client.ensure_device_session(
		str(_pilot_config.get("account_role", "student")),
		str(_pilot_config["enrollment_id"]),
		str(_pilot_config["enrollment_token"]),
		str(_pilot_config["installation_id"]),
		persisted_profile
	)


func _pilot_completion_result(
	identity_result: Dictionary,
	session_result: Dictionary
) -> Dictionary:
	var profile: Dictionary = (
		_cookies.get_neuralese_profile()
		if _cookies.has_method("get_neuralese_profile")
		else session_result.get("profile", {})
	)
	var runtime_identity: Dictionary = identity_result.get("runtime_identity", {})
	profile.merge(runtime_identity, true)
	var result := session_result.duplicate(true)
	result["ok"] = true
	result["profile"] = profile
	result["runtime_identity"] = runtime_identity.duplicate(true)
	return result


func sync_local_profile_after_login(local_profile: Dictionary) -> Dictionary:
	if _cookies == null:
		return {"ok": false, "error": "profile_onboarding_unavailable"}
	if not _cookies.has_auth_session():
		return {"ok": false, "error": "missing_session"}

	var server_profile: Dictionary = _cookies.get_neuralese_profile()
	if _is_complete(server_profile):
		return {
			"ok": true,
			"profile": server_profile,
			"synced": false,
			"unchanged": true,
		}
	if not bool(local_profile.get("local_profile", false)) or not _is_complete(local_profile):
		return {"ok": true, "profile": server_profile, "synced": false}

	var first_name := str(local_profile.get("first_name", "")).strip_edges()
	var last_name := str(local_profile.get("last_name", "")).strip_edges()
	var role := normalize_role(local_profile.get("type", ""))
	var language := normalize_language(local_profile.get("language", ""))
	if first_name.is_empty() or last_name.is_empty() or role.is_empty():
		return {"ok": true, "profile": server_profile, "synced": false}

	var result: Dictionary = await _cookies.complete_onboarding(
		first_name,
		last_name,
		role
	)
	if not result.get("ok", false):
		return result
	if not language.is_empty() and _cookies.has_method("apply_preferred_language"):
		_cookies.apply_preferred_language(language)
	result["synced"] = true
	return result


static func _is_complete(profile: Dictionary) -> bool:
	return (
		bool(profile.get("onboarding_complete", false))
		and int(profile.get("onboarding_version", 0)) >= CURRENT_VERSION
	)


func _current_graphics_quality() -> String:
	var service: Variant = _get_graphics_quality_service()
	if service != null and service.has_method("get_graphics_quality"):
		var value: String = normalize_graphics_quality(service.get_graphics_quality())
		if not value.is_empty():
			return value
	return "medium"


func _apply_graphics_quality(value: String) -> void:
	var service: Variant = _get_graphics_quality_service()
	if service != null and service.has_method("set_graphics_quality"):
		service.set_graphics_quality(value)


func _get_graphics_quality_service() -> Variant:
	if _graphics_quality_service != null:
		return _graphics_quality_service
	var scene_tree := Engine.get_main_loop() as SceneTree
	if scene_tree == null:
		return null
	return scene_tree.root.get_node_or_null("glob")


func _pilot_enabled() -> bool:
	return (
		_pilot_client != null
		and str(_pilot_config.get("enrollment_id", "")) != ""
		and str(_pilot_config.get("enrollment_token", "")) != ""
		and str(_pilot_config.get("installation_id", "")) != ""
	)


static func _prefill_names(profile: Dictionary, user_info: Dictionary) -> Dictionary:
	var first_name := str(profile.get("first_name", "")).strip_edges()
	var last_name := str(profile.get("last_name", "")).strip_edges()
	if first_name.is_empty():
		first_name = str(user_info.get("given_name", "")).strip_edges()
	if last_name.is_empty():
		last_name = str(user_info.get("family_name", "")).strip_edges()
	if first_name.is_empty() or last_name.is_empty():
		var full_name := str(user_info.get("name", user_info.get("display_name", ""))).strip_edges()
		var parts := full_name.split(" ", false)
		if first_name.is_empty() and not parts.is_empty():
			first_name = parts[0]
		if last_name.is_empty() and parts.size() > 1:
			last_name = " ".join(parts.slice(1))
	return {"first_name": first_name, "last_name": last_name}
