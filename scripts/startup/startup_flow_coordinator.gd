extends Node
class_name StartupFlowCoordinator

# Version 3 is the first version shipped through the integrated startup flow.
# Existing installations may have recorded version 2 while that flow was only
# partially present, so they must be offered the complete tour once.
const INTERFACE_TOUR_VERSION := 3
const INTERFACE_TOUR_SOURCE_KEY := "00_interface_tour"
const UpdateManagerCore := preload("res://scripts/update_state.gd")
const ProfileOnboardingCore := preload("res://scripts/startup/profile_onboarding.gd")
const StartupStateCore := preload("res://scripts/startup/startup_onboarding_state.gd")
const StartupMainMenuCore := preload("res://scripts/startup/startup_main_menu.gd")
const StartupTutorialPromptCore := preload("res://scripts/startup/startup_tutorial_prompt.gd")
const PilotOnboardingClientCore := preload("res://scripts/auth/pilot_onboarding_client.gd")

signal pre_workspace_completed(result: Dictionary)
signal post_workspace_completed(result: Dictionary)
signal interface_tour_phase_completed(result: Dictionary)
signal interface_tour_resolved(result: Dictionary)
signal pilot_auth_prepared(result: Dictionary)

var _dependencies: Dictionary = {}
var _pre_running := false
var _post_running := false
var _pre_result: Dictionary = {}
var _post_result: Dictionary = {}
var _tour_phase_running := false
var _tour_phase_result: Dictionary = {}
var _profile: Dictionary = {}
var _state: Variant = null
var _update_manager: Variant = null
var _tour_running := false
var _active_tour_lesson_key := ""
var _pilot_auth_result: Dictionary = {}
var _early_tutorial_prompt_result: Dictionary = {}
var _update_check_started := false


func configure_dependencies(overrides: Dictionary) -> void:
	_dependencies = overrides.duplicate()


func run_pre_workspace() -> Dictionary:
	if not _pre_result.is_empty():
		return _pre_result.duplicate(true)
	if _pre_running:
		return await pre_workspace_completed
	_pre_running = true

	var cookies_service = _cookies()
	var ui_service = _ui()
	if cookies_service == null or ui_service == null:
		return _finish_pre({"ok": false, "error": "startup_dependencies_unavailable"})

	var pilot_config := _pilot_config()

	if _pilot_mode_enabled():
		if pilot_config.is_empty():
			return _finish_pre({"ok": false, "error": "pilot_enrollment_not_configured"})
		
		_set_palette_visible(false)
		
		var onboarding = _dependencies.get("profile_onboarding")
		if onboarding == null:
			var pilot_client := PilotOnboardingClientCore.new(_web(), cookies_service)
			onboarding = ProfileOnboardingCore.new(
				cookies_service,
				ui_service,
				pilot_client,
				pilot_config
			)
		_schedule_pilot_auth(cookies_service, onboarding)
		var onboarding_result: Dictionary = await onboarding.collect_pilot_launch_identity()
		if not onboarding_result.get("ok", false):
			return _finish_pre(onboarding_result)
		# The invitation is pure UI and does not need an authenticated account or
		# a loaded workspace. Ask it as soon as the identity dialog closes, then
		# consume the answer in run_interface_tour_phase() once the workspace is
		# ready to actually start the tour.
		_early_tutorial_prompt_result = await _ask_tutorial_prompt()
		if not _early_tutorial_prompt_result.get("ok", false):
			return _finish_pre(_early_tutorial_prompt_result)
		# Authentication is a background capability, not a startup prerequisite.
		# Build the launch profile from the locally stored runtime identity and let
		# _prepare_pilot_auth() refresh the shared session whenever the network is
		# ready. Nothing in the onboarding path awaits that work.
		_profile = onboarding_result.get(
			"profile", cookies_service.get_neuralese_profile()
		).duplicate(true)
		_profile.merge(onboarding_result.get("runtime_identity", {}), true)
		if _pilot_auth_result.get("ok", false):
			var authenticated_profile: Dictionary = (
				cookies_service.get_neuralese_profile().duplicate(true)
			)
			if not authenticated_profile.is_empty():
				_profile = authenticated_profile
				_profile.merge(onboarding_result.get("runtime_identity", {}), true)
	else:
		# Ordinary Neuralese is usable before signing in. Browser login remains an
		# explicit user action from the existing UI, never a startup barrier.
		await cookies_service.restore_or_refresh_session()
		_profile = cookies_service.get_neuralese_profile().duplicate(true)

	var account_id := _account_id_for_profile(_profile, cookies_service)
	if account_id.is_empty():
		return _finish_pre({"ok": false, "error": "missing_account_id"})
	if not _select_state(account_id):
		return _finish_pre({"ok": false, "error": "invalid_account_id"})
	_state.set_value(
		"startup_onboarding_version",
		int(_profile.get("onboarding_version", 0))
	)
	return _finish_pre({"ok": true, "profile": _profile.duplicate(true)})


func _schedule_pilot_auth(cookies_service: Variant, onboarding: Variant) -> void:
	_pilot_auth_result = {}
	call_deferred("_prepare_pilot_auth", cookies_service, onboarding)


func _schedule_update_check() -> void:
	if _update_check_started:
		return
	var update_manager = _get_update_manager()
	if update_manager == null:
		return
	_update_check_started = true
	call_deferred("_check_update_in_background", update_manager)


func _check_update_in_background(update_manager: Variant) -> void:
	# Update discovery is useful, but it must never sit between two startup
	# dialogs.  The manager owns its own UI when a result eventually arrives.
	await update_manager.check_update()


func _prepare_pilot_auth(cookies_service: Variant, onboarding: Variant) -> void:
	await cookies_service.restore_or_refresh_session()
	var result: Dictionary
	if onboarding == null or not onboarding.has_method("ensure_pilot_session"):
		result = {"ok": false, "error": "pilot_device_session_unavailable"}
	else:
		result = await onboarding.ensure_pilot_session()
	_pilot_auth_result = result.duplicate(true)
	if result.get("ok", false):
		var refreshed_profile: Dictionary = (
			cookies_service.get_neuralese_profile().duplicate(true)
		)
		if not refreshed_profile.is_empty():
			_profile = refreshed_profile
	pilot_auth_prepared.emit(_pilot_auth_result.duplicate(true))


func _select_state(account_id: String) -> bool:
	_state = _dependencies.get("state")
	if _state == null:
		_state = StartupStateCore.new()
	return _state.select_account(account_id)


func run_post_workspace() -> Dictionary:
	if not _post_result.is_empty():
		return _post_result.duplicate(true)
	if _post_running:
		return await post_workspace_completed
	if _pre_result.is_empty() or not _pre_result.get("ok", false):
		var pre: Dictionary = await run_pre_workspace()
		if not pre.get("ok", false):
			return _finish_post(pre)
	_post_running = true

	var tutorial_result: Dictionary = await run_interface_tour_phase()
	if not tutorial_result.get("ok", false) and tutorial_result.get("error") != "tour_not_needed":
		return _finish_post(tutorial_result)
	var menu_result: Dictionary = await _show_main_menu(false)
	
	var tour_passed = tutorial_result.get("ok", false) and not tutorial_result.get("skipped", false)
	if not tour_passed:
		_set_palette_visible(true)

	# The greeting is intentionally shown before datasets/projects finish their
	# local warm-up.  Only the selected route needs a usable workspace.
	var workspace_result := await _await_workspace_ready()
	if not workspace_result.get("ok", false):
		return _finish_post(workspace_result)
	
	var global_service := get_node_or_null("/root/glob")
	var load_last_project := false
	if _dependencies.has("load_last_project"):
		load_last_project = bool(_dependencies["load_last_project"])
	elif is_instance_valid(global_service):
		load_last_project = bool(global_service.LOAD_LAST_PROJECT)
	if load_last_project and is_instance_valid(global_service):
		await global_service.open_last_project()
	_open_main_menu_action(str(menu_result.get("action", "")))
	# Do not let a discovered update open a second dialog on top of onboarding
	# or the startup chooser. Discovery starts only after the chosen route is
	# usable and remains detached from the startup result.
	_schedule_update_check()
	return _finish_post({"ok": true, "profile": _profile.duplicate(true)})


func run_interface_tour_phase() -> Dictionary:
	if not _tour_phase_result.is_empty():
		return _tour_phase_result.duplicate(true)
	if _tour_phase_running:
		return await interface_tour_phase_completed
	_tour_phase_running = true
	var result: Dictionary
	if _state == null:
		result = {"ok": false, "error": "tour_state_unavailable"}
	elif not _pilot_mode_enabled() and not _state.needs_interface_tour(INTERFACE_TOUR_VERSION):
		# A regular account sees this invitation once.  Pilot mode deliberately
		# ignores the per-account marker because each classroom launch may have a
		# different student at the same workstation.
		result = {"ok": true, "skipped": true, "already_resolved": true}
	else:
		var prompt_result: Dictionary
		if not _early_tutorial_prompt_result.is_empty():
			prompt_result = _early_tutorial_prompt_result.duplicate(true)
		else:
			prompt_result = await _ask_tutorial_prompt()
		if not prompt_result.get("ok", false):
			result = prompt_result
		elif not prompt_result.get("start", false):
			_state.mark_interface_tour("dismissed", INTERFACE_TOUR_VERSION)
			result = {"ok": true, "skipped": true, "declined": true}
		else:
			var workspace_result := await _await_workspace_ready()
			if not workspace_result.get("ok", false):
				result = workspace_result
			else:
				result = await start_interface_tour(true)
	_tour_phase_running = false
	_tour_phase_result = result.duplicate(true)
	interface_tour_phase_completed.emit(_tour_phase_result.duplicate(true))
	return _tour_phase_result.duplicate(true)


func _ask_tutorial_prompt() -> Dictionary:
	var prompt = _dependencies.get("tutorial_prompt")
	if prompt == null:
		prompt = StartupTutorialPromptCore.new(_ui())
	return await prompt.ask()


func show_main_menu(but=null) -> Dictionary:
	return await _show_main_menu(true, but)


func folder_menu_id() -> String:
	return "workslist" if _tour_running else "startup_main_menu"


func _show_main_menu(open_route: bool, but=null) -> Dictionary:
	var menu = _dependencies.get("main_menu")
	if menu == null:
		menu = StartupMainMenuCore.new(_ui())
	return await menu.show(_profile, open_route, but)


func _await_workspace_ready() -> Dictionary:
	var waiter: Variant = _dependencies.get("workspace_ready")
	if not (waiter is Callable) or not waiter.is_valid():
		return {"ok": true}
	var output: Variant = await waiter.call()
	if typeof(output) == TYPE_DICTIONARY:
		return Dictionary(output).duplicate(true)
	if typeof(output) == TYPE_BOOL and not bool(output):
		return {"ok": false, "error": "workspace_preparation_failed"}
	return {"ok": true}


func _open_main_menu_action(action: String) -> void:
	var menu = _dependencies.get("main_menu")
	if menu == null:
		menu = StartupMainMenuCore.new(_ui())
	menu.open_action(action)


func start_interface_tour(force: bool = false) -> Dictionary:
	if _state == null:
		return {"ok": false, "error": "tour_state_unavailable"}
	if not force and not _state.needs_interface_tour(INTERFACE_TOUR_VERSION):
		return {"ok": false, "error": "tour_not_needed"}
	_state.mark_interface_tour("in_progress", INTERFACE_TOUR_VERSION)
	var runner: Variant = _dependencies.get("tutorial_runner")
	var result: Dictionary
	if runner is Callable and runner.is_valid():
		var output: Variant = await runner.call()
		result = output if typeof(output) == TYPE_DICTIONARY else {"ok": bool(output)}
	else:
		result = await _run_interface_tour()
	if result.get("ok", false):
		_state.mark_interface_tour(
			"dismissed" if result.get("skipped", false) else "completed",
			INTERFACE_TOUR_VERSION
		)
	else:
		_state.mark_interface_tour("not_started", INTERFACE_TOUR_VERSION)
	return result


func mark_interface_tour_completed() -> void:
	if _state != null:
		_state.mark_interface_tour("completed", INTERFACE_TOUR_VERSION)


func dismiss_interface_tour() -> Dictionary:
	if not _tour_running:
		return {"ok": false, "error": "interface_tour_not_running"}
	var result := {"ok": true, "skipped": true}
	interface_tour_resolved.emit(result)
	return result


func _run_interface_tour() -> Dictionary:
	var tutorial_service = _learner()
	if tutorial_service == null:
		return {"ok": false, "error": "tutorial_service_unavailable"}
	var lesson_key := str(tutorial_service.find_offline_lesson_key(INTERFACE_TOUR_SOURCE_KEY))
	if lesson_key.is_empty():
		return {"ok": false, "error": "interface_tour_missing"}
	var tutorial_ui := {}
	if tutorial_service.has_method("get_lesson_tutorial_ui"):
		tutorial_ui = tutorial_service.get_lesson_tutorial_ui(lesson_key)
	var show_progress := bool(tutorial_ui.get("show_progress", true))
	_tour_running = true
	_active_tour_lesson_key = lesson_key
	_set_palette_visible(true)
	_set_tour_controls_visible(true, show_progress)
	var completion_callback := func(completed_key: String):
		if completed_key == _active_tour_lesson_key and _tour_running:
			interface_tour_resolved.emit({"ok": true, "lesson_key": completed_key})
	tutorial_service.lesson_completed.connect(completion_callback)
	await tutorial_service.enter_lesson(lesson_key)
	var result: Dictionary = await interface_tour_resolved
	if tutorial_service.lesson_completed.is_connected(completion_callback):
		tutorial_service.lesson_completed.disconnect(completion_callback)
	await _finish_interface_tour(tutorial_service)
	return result


## One terminal path for completion, Skip, and failures.  The interface tour
## owns temporary UI state (the hidden progress bar, Skip button, arrows and
## highlights), so leaving any of it behind can make a later menu visit look
## like the tour started again.
func _finish_interface_tour(tutorial_service: Variant = null) -> void:
	var ui_service = _ui()
	if ui_service != null:
		if ui_service.has_method("hide_arrows"):
			await ui_service.hide_arrows()
		if ui_service.has_method("hide_ui_highlights"):
			ui_service.hide_ui_highlights()
		if ui_service.has_method("reset_tutorial_ui_config"):
			ui_service.reset_tutorial_ui_config()
	if tutorial_service != null:
		await tutorial_service.stop_lesson()
	_set_tour_controls_visible(false, true)
	_tour_running = false
	_active_tour_lesson_key = ""


func _set_palette_visible(visible: bool) -> void:
	var palette: Variant = _dependencies.get("node_palette")
	var global_service := get_node_or_null("/root/glob")
	if palette == null and is_instance_valid(global_service):
		var base_node: Variant = global_service.get("base_node")
		if is_instance_valid(base_node):
			palette = base_node.get_node_or_null("WIN_GRAPH/NodePalette")
	if not is_instance_valid(palette):
		return
	palette.visible = visible
	if visible and palette.has_method("set_collapsed"):
		palette.set_collapsed(false, false)


func _set_tour_controls_visible(visible: bool, show_progress: bool = true) -> void:
	var ui_service = _ui()
	if ui_service == null:
		return
	var lesson_bar: Variant = ui_service.get("lesson_bar")
	if lesson_bar != null and lesson_bar.has_method("set_interface_tour_controls"):
		lesson_bar.set_interface_tour_controls(visible, show_progress)


func _finish_pre(result: Dictionary) -> Dictionary:
	_pre_running = false
	_pre_result = result.duplicate(true)
	pre_workspace_completed.emit(_pre_result.duplicate(true))
	return _pre_result.duplicate(true)


func _finish_post(result: Dictionary) -> Dictionary:
	_post_running = false
	_post_result = result.duplicate(true)
	post_workspace_completed.emit(_post_result.duplicate(true))
	return _post_result.duplicate(true)


func _get_update_manager() -> Variant:
	if _dependencies.has("update_manager"):
		return _dependencies["update_manager"]
	if not is_instance_valid(_update_manager):
		_update_manager = UpdateManagerCore.new()
		add_child(_update_manager)
	return _update_manager


func _pilot_config() -> Dictionary:
	if not _pilot_mode_enabled():
		return {}
	if _dependencies.has("pilot_config"):
		return Dictionary(_dependencies["pilot_config"]).duplicate(true)
	var environment := {
		"enrollment_id": OS.get_environment("NEURALESE_PILOT_ENROLLMENT_ID"),
		"enrollment_token": OS.get_environment("NEURALESE_PILOT_ENROLLMENT_TOKEN"),
		"account_role": OS.get_environment("NEURALESE_PILOT_ACCOUNT_ROLE"),
	}
	return resolve_pilot_config(environment, _pilot_config_from_global())


## Environment values are the production source of truth.  The glob fallback
## exists solely for local Editor runs, where Godot may not inherit shell env.
static func resolve_pilot_config(
	environment: Dictionary,
	development_fallback: Dictionary = {},
	pilot_mode_enabled: bool = true
) -> Dictionary:
	if not pilot_mode_enabled:
		return {}
	var enrollment_id := _pilot_config_value(
		environment, development_fallback, "enrollment_id"
	)
	var enrollment_token := _pilot_config_value(
		environment, development_fallback, "enrollment_token"
	)
	if enrollment_id.is_empty() or enrollment_token.is_empty():
		return {}
	var account_role := _pilot_config_value(
		environment, development_fallback, "account_role"
	).to_lower()
	if account_role not in ["student", "teacher"]:
		account_role = "student"
	return {
		"enrollment_id": enrollment_id,
		"enrollment_token": enrollment_token,
		"installation_id": PilotOnboardingClientCore.get_or_create_installation_id(),
		"account_role": account_role,
	}


func _pilot_config_from_global() -> Dictionary:
	var global_service := get_node_or_null("/root/glob")
	if global_service == null:
		return {}
	var configured: Variant = global_service.get("PILOT_ENROLLMENT_CONFIG")
	return configured.duplicate(true) if typeof(configured) == TYPE_DICTIONARY else {}


func _pilot_mode_enabled() -> bool:
	if _dependencies.has("pilot_mode"):
		return bool(_dependencies["pilot_mode"])
	var global_service := get_node_or_null("/root/glob")
	return bool(global_service.get("PILOT_MODE")) if global_service != null else false


func _account_id_for_profile(profile: Dictionary, cookies_service: Variant) -> String:
	var account_id := str(profile.get("account_id", "")).strip_edges()
	if not account_id.is_empty():
		return account_id
	if cookies_service != null and cookies_service.has_method("get_auth_user"):
		var user: Variant = cookies_service.get_auth_user()
		if typeof(user) == TYPE_DICTIONARY:
			for field in ["sub", "user_id", "id"]:
				account_id = str(user.get(field, "")).strip_edges()
				if not account_id.is_empty():
					return account_id
	# Anonymous/offline launches still need a stable state bucket so the regular
	# tutorial is not offered on every application start.
	return "local_workspace"


static func _pilot_config_value(
	environment: Dictionary,
	development_fallback: Dictionary,
	key: String
) -> String:
	var environment_value := str(environment.get(key, "")).strip_edges()
	if not environment_value.is_empty():
		return environment_value
	return str(development_fallback.get(key, "")).strip_edges()


func _cookies() -> Variant:
	return _dependencies.get("cookies", get_node_or_null("/root/cookies"))


func _ui() -> Variant:
	return _dependencies.get("ui", get_node_or_null("/root/ui"))


func _web() -> Variant:
	return _dependencies.get("web", get_node_or_null("/root/web"))


func _learner() -> Variant:
	return _dependencies.get("learner", get_node_or_null("/root/learner"))
