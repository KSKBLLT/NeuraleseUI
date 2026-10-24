extends SceneTree

const StartupFlowCoordinator = preload("res://scripts/startup/startup_flow_coordinator.gd")

var failures: Array[String] = []


class FakeUpdate:
	extends RefCounted
	var order: Array[String]
	func _init(record: Array[String]) -> void: order = record
	func check_update() -> void: order.append("update")


class FakeBlockingUpdate:
	extends RefCounted
	signal update_released
	var order: Array[String]
	func _init(record: Array[String]) -> void: order = record
	func check_update() -> void:
		order.append("update_started")
		await update_released
		order.append("update_finished")
	func release_update() -> void:
		update_released.emit()


class FakeCookies:
	extends RefCounted
	var order: Array[String]
	var session := true
	var pilot_session := false
	var browser_login_calls := 0
	var cleared_pilot_sessions := 0
	var profile := {"account_id": "account-1", "onboarding_complete": true, "onboarding_version": 1}
	func _init(record: Array[String]) -> void: order = record
	func restore_or_refresh_session(_saved: Dictionary = {}) -> bool:
		order.append("restore")
		return session
	func has_auth_session() -> bool: return session
	func has_pilot_session() -> bool: return pilot_session
	func clear_auth_session() -> void:
		cleared_pilot_sessions += 1
		session = false
		pilot_session = false
	func login_cached_or_browser(_open_browser: bool = true) -> Dictionary:
		browser_login_calls += 1
		session = true
		profile = {"account_id": "browser-account", "onboarding_complete": true, "onboarding_version": 1}
		return {"ok": true}
	func get_auth_user() -> Dictionary: return {"sub": "browser-subject"}
	func get_neuralese_profile() -> Dictionary: return profile.duplicate(true)


class FakeSlowCookies:
	extends FakeCookies
	signal restore_released
	func restore_or_refresh_session(_saved: Dictionary = {}) -> bool:
		order.append("restore_started")
		await restore_released
		order.append("restore_finished")
		return session
	func release_restore() -> void:
		restore_released.emit()


class FakeUi:
	extends RefCounted
	var order: Array[String]
	var cookies: FakeCookies
	func _init(record: Array[String], auth: FakeCookies) -> void:
		order = record
		cookies = auth
	func splash_and_get_result(menu: String, _from = null, _emitter = null, _inner = false, _data = null) -> Dictionary:
		order.append(menu)
		cookies.session = true
		return {"ok": true}


class FakeProfileFlow:
	extends RefCounted
	var order: Array[String]
	var profile: Dictionary
	func _init(record: Array[String], saved_profile: Dictionary) -> void:
		order = record
		profile = saved_profile
	func ensure_complete() -> Dictionary:
		order.append("onboarding")
		return {"ok": true, "profile": profile.duplicate(true)}
	func collect_pilot_launch_identity() -> Dictionary:
		order.append("onboarding")
		return {"ok": true, "profile": profile.duplicate(true)}
	func ensure_pilot_session() -> Dictionary:
		order.append("pilot_auth")
		return {"ok": true, "profile": profile.duplicate(true)}


class FakeState:
	extends RefCounted
	var selected := ""
	var values := {}
	var tour_marks: Array[Dictionary] = []
	var needs_tour := true
	func select_account(account_id: String) -> bool:
		selected = account_id
		return true
	func set_value(key: String, value: Variant) -> bool:
		values[key] = value
		return true
	func needs_interface_tour(_version: int) -> bool: return needs_tour
	func mark_interface_tour(status: String, version: int) -> bool:
		tour_marks.append({"status": status, "version": version})
		return true


class FakeMainMenu:
	extends RefCounted
	var order: Array[String]
	func _init(record: Array[String]) -> void: order = record
	func show(_profile: Dictionary, _open_route: bool = true, _but = null) -> Dictionary:
		order.append("menu")
		return {"action": "continue"}
	func open_action(_action: String) -> void:
		order.append("route")


class FakeBlockingMainMenu:
	extends FakeMainMenu
	signal released
	func show(_profile: Dictionary, _open_route: bool = true, _but = null) -> Dictionary:
		order.append("menu")
		await released
		return {"action": "continue"}
	func release() -> void:
		released.emit()


class FakeWorkspaceGate:
	extends RefCounted
	signal released
	var order: Array[String]
	var ready := false
	func _init(record: Array[String]) -> void: order = record
	func wait_until_ready() -> void:
		order.append("workspace_wait_started")
		if not ready:
			await released
		order.append("workspace_ready")
	func release() -> void:
		ready = true
		released.emit()


class FakeTutorialPrompt:
	extends RefCounted
	var order: Array[String]
	var start_tour := true
	func _init(record: Array[String], should_start: bool = true) -> void:
		order = record
		start_tour = should_start
	func ask() -> Dictionary:
		order.append("tutorial_prompt")
		return {"ok": true, "start": start_tour, "action": "start" if start_tour else "later"}


class FakeTourHeader:
	extends RefCounted
	var visibility: Array[Dictionary] = []
	func set_interface_tour_controls(visible: bool, show_progress: bool = true) -> void:
		visibility.append({"visible": visible, "show_progress": show_progress})


class FakeTourUi:
	extends RefCounted
	var lesson_bar := FakeTourHeader.new()
	var arrows_hidden := 0
	var highlights_hidden := 0
	var config_resets := 0
	func hide_arrows() -> void:
		arrows_hidden += 1
	func hide_ui_highlights() -> void:
		highlights_hidden += 1
	func reset_tutorial_ui_config() -> void:
		config_resets += 1


class FakeNodePalette:
	extends CanvasLayer
	var collapsed := true
	var collapse_updates: Array[bool] = []
	func set_collapsed(value: bool, _animated: bool = true) -> void:
		collapsed = value
		collapse_updates.append(value)


class FakeLearner:
	extends RefCounted
	signal lesson_completed(lesson_key: String)
	var entered: Array[String] = []
	var stopped := 0
	func find_offline_lesson_key(_source_key: String) -> String:
		return "offline-tour"
	func get_lesson_tutorial_ui(_lesson_key: String) -> Dictionary:
		return {"show_progress": false}
	func enter_lesson(lesson_key: String) -> void:
		entered.append(lesson_key)
	func stop_lesson() -> void:
		stopped += 1


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_startup_opens_clean_workspace()
	_test_startup_warmup_waits_for_visible_frame()
	_test_pilot_config_prefers_environment_and_falls_back_to_glob()
	await _test_order_and_account_scope()
	await _test_pilot_onboarding_opens_before_network_startup()
	await _test_pilot_tutorial_prompt_does_not_wait_for_auth()
	await _test_pilot_tutorial_prompt_does_not_wait_for_update()
	await _test_completed_tour_is_not_offered_again_for_normal_login()
	await _test_standard_startup_does_not_open_browser_or_pilot_profile_form()
	await _test_standard_startup_leaves_a_previous_pilot_session_untouched()
	await _test_declined_tour_goes_directly_to_main_menu()
	await _test_main_menu_opens_before_workspace_is_ready()
	await _test_tour_can_be_skipped_without_opening_a_route()
	_test_folder_destination_tracks_tour_state()

	if failures.is_empty():
		print("PASS test_startup_flow_coordinator")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_startup_opens_clean_workspace() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/glob.gd")
	#_expect_equal(
		#source.contains("const LOAD_LAST_PROJECT: bool = 0"),
		#true,
		#"startup does not restore a previous graph behind onboarding"
	#)
	_expect_equal(
		source.contains('await load_empty_scene(project_id, "")'),
		true,
		"startup initializes an empty workspace"
	)


func _test_startup_warmup_waits_for_visible_frame() -> void:
	var source := FileAccess.get_file_as_string("res://scripts/glob.gd")
	var function_start := source.find("func _prepare_startup_workspace()")
	var draw_wait := source.find("await RenderingServer.frame_post_draw", function_start)
	var dataset_load := source.find("\tload_datasets()", function_start)
	_expect_equal(function_start >= 0, true, "startup workspace preparation exists")
	_expect_equal(draw_wait > function_start, true, "workspace warm-up waits for a rendered startup frame")
	_expect_equal(dataset_load > draw_wait, true, "dataset parsing starts only after the startup frame is visible")


func _test_pilot_config_prefers_environment_and_falls_back_to_glob() -> void:
	var fallback := {
		"enrollment_id": "editor-enrollment",
		"enrollment_token": "editor-token",
		"account_role": "teacher",
	}
	var editor_config := StartupFlowCoordinator.resolve_pilot_config({}, fallback)
	_expect_equal(editor_config.get("enrollment_id"), "editor-enrollment", "glob fallback enables a local pilot run")
	_expect_equal(editor_config.get("enrollment_token"), "editor-token", "glob fallback supplies the local pilot token")
	_expect_equal(editor_config.get("account_role"), "teacher", "glob fallback supplies the local pilot role")

	var production_config := StartupFlowCoordinator.resolve_pilot_config({
		"enrollment_id": "environment-enrollment",
		"enrollment_token": "environment-token",
		"account_role": "student",
	}, fallback)
	_expect_equal(production_config.get("enrollment_id"), "environment-enrollment", "environment enrollment overrides glob")
	_expect_equal(production_config.get("enrollment_token"), "environment-token", "environment token overrides glob")
	_expect_equal(production_config.get("account_role"), "student", "environment role overrides glob")
	var combined_config := StartupFlowCoordinator.resolve_pilot_config(
		{"enrollment_id": "only-id"}, fallback
	)
	_expect_equal(combined_config.get("enrollment_id"), "only-id", "pilot sources can be combined per field")
	_expect_equal(combined_config.get("enrollment_token"), "editor-token", "glob supplies a missing environment token")
	_expect_equal(combined_config.get("account_role"), "teacher", "glob supplies a missing environment role")
	_expect_equal(
		StartupFlowCoordinator.resolve_pilot_config({}, {"enrollment_id": "only-id"}),
		{},
		"pilot mode stays disabled without both required credentials"
	)
	_expect_equal(
		StartupFlowCoordinator.resolve_pilot_config(fallback, fallback, false),
		{},
		"PILOT_MODE is the explicit opt-in even when credentials are present"
	)
func _test_order_and_account_scope() -> void:
	var order: Array[String] = []
	var cookies := FakeCookies.new(order)
	var state := FakeState.new()
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": FakeUpdate.new(order),
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"profile_onboarding": FakeProfileFlow.new(order, cookies.profile),
		"state": state,
		"main_menu": FakeMainMenu.new(order),
		"tutorial_prompt": FakeTutorialPrompt.new(order),
		"tutorial_runner": func():
			order.append("tutorial")
			return {"ok": true},
		"load_last_project": false,
		"pilot_mode": false,
	})
	root.add_child(coordinator)

	var pre: Dictionary = await coordinator.run_pre_workspace()
	var post: Dictionary = await coordinator.run_post_workspace()
	_expect_equal(pre.get("ok"), true, "pre-workspace flow succeeds")
	_expect_equal(post.get("ok"), true, "post-workspace flow succeeds")
	_expect_equal(order, ["restore", "tutorial_prompt", "tutorial", "menu", "route"], "regular login skips pilot identity and runs the first tour before the menu")
	_expect_equal(state.selected, "account-1", "state is scoped to server account id")
	_expect_equal(state.values.get("startup_onboarding_version"), 1, "profile onboarding version is retained when available")
	_expect_equal(state.tour_marks, [
		{"status": "in_progress", "version": 3},
		{"status": "completed", "version": 3},
	], "current tour version completes once")

	await coordinator.run_pre_workspace()
	await coordinator.run_post_workspace()
	_expect_equal(order, ["restore", "tutorial_prompt", "tutorial", "menu", "route"], "completed phases do not duplicate windows")
	coordinator.queue_free()


func _test_pilot_onboarding_opens_before_network_startup() -> void:
	var order: Array[String] = []
	var cookies := FakeCookies.new(order)
	var state := FakeState.new()
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": FakeUpdate.new(order),
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"profile_onboarding": FakeProfileFlow.new(order, cookies.profile),
		"tutorial_prompt": FakeTutorialPrompt.new(order, false),
		"state": state,
		"pilot_mode": true,
		"pilot_config": {
			"enrollment_id": "pilot-school",
			"enrollment_token": "runtime-secret",
			"installation_id": "installation_1234567890",
			"account_role": "student",
		},
	})
	root.add_child(coordinator)

	var result: Dictionary = await coordinator.run_pre_workspace()
	_expect_equal(result.get("ok"), true, "pilot pre-workspace flow succeeds")
	_expect_equal(
		order,
		["onboarding", "tutorial_prompt"],
		"pilot pre-workspace finishes without waiting for deferred network work"
	)
	await process_frame
	_expect_equal(order.has("restore"), true, "pilot session restore still runs in the background")
	_expect_equal(order.has("pilot_auth"), true, "pilot auth still runs in the background")
	_expect_equal(order.has("update"), false, "update discovery does not overlap startup dialogs")
	coordinator.queue_free()


func _test_pilot_tutorial_prompt_does_not_wait_for_auth() -> void:
	var order: Array[String] = []
	var cookies := FakeSlowCookies.new(order)
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": FakeUpdate.new(order),
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"profile_onboarding": FakeProfileFlow.new(order, cookies.profile),
		"tutorial_prompt": FakeTutorialPrompt.new(order, false),
		"state": FakeState.new(),
		"pilot_mode": true,
		"pilot_config": {
			"enrollment_id": "pilot-school",
			"enrollment_token": "runtime-secret",
			"installation_id": "installation_1234567890",
			"account_role": "student",
		},
	})
	root.add_child(coordinator)

	var completed: Array[Dictionary] = []
	coordinator.pre_workspace_completed.connect(func(result: Dictionary):
		completed.append(result)
	)
	coordinator.run_pre_workspace()
	await process_frame
	_expect_equal(order.has("tutorial_prompt"), true, "tutorial prompt appears while pilot auth is pending")
	_expect_equal(order.has("restore_started"), true, "background pilot auth has started")
	_expect_equal(order.has("update"), false, "update discovery waits until startup dialogs close")
	_expect_equal(completed.size(), 1, "pre-workspace completes without an auth token")
	if not completed.is_empty():
		_expect_equal(completed[0].get("ok"), true, "auth-independent startup succeeds")

	cookies.call_deferred("release_restore")
	await process_frame
	_expect_equal(order.back(), "pilot_auth", "background auth may finish after startup")
	coordinator.queue_free()


func _test_pilot_tutorial_prompt_does_not_wait_for_update() -> void:
	var order: Array[String] = []
	var cookies := FakeCookies.new(order)
	var update := FakeBlockingUpdate.new(order)
	var menu := FakeBlockingMainMenu.new(order)
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": update,
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"profile_onboarding": FakeProfileFlow.new(order, cookies.profile),
		"tutorial_prompt": FakeTutorialPrompt.new(order, false),
		"main_menu": menu,
		"state": FakeState.new(),
		"load_last_project": false,
		"pilot_mode": true,
		"pilot_config": {
			"enrollment_id": "pilot-school",
			"enrollment_token": "runtime-secret",
			"installation_id": "installation_1234567890",
			"account_role": "student",
		},
	})
	root.add_child(coordinator)

	var completed: Array[Dictionary] = []
	coordinator.pre_workspace_completed.connect(func(result: Dictionary):
		completed.append(result)
	)
	coordinator.run_pre_workspace()
	await process_frame
	_expect_equal(order.has("tutorial_prompt"), true, "tutorial prompt is shown before a stalled update finishes")
	_expect_equal(order.has("update_started"), false, "update discovery does not overlap onboarding dialogs")
	_expect_equal(order.has("update_finished"), false, "update remains stalled during auth-independent startup")
	_expect_equal(completed.size(), 1, "pre-workspace completes while the update request is stalled")

	var post_completed: Array[Dictionary] = []
	coordinator.post_workspace_completed.connect(func(result: Dictionary):
		post_completed.append(result)
	)
	coordinator.run_post_workspace()
	await process_frame
	_expect_equal(order.has("menu"), true, "main greeting opens while update discovery is idle")
	_expect_equal(order.has("update_started"), false, "update discovery cannot open over the startup chooser")
	_expect_equal(post_completed.size(), 0, "startup chooser remains interactive while it is open")

	menu.release()
	await process_frame
	await process_frame
	_expect_equal(post_completed.size(), 1, "main greeting and route complete without waiting for the update")
	_expect_equal(order.has("route"), true, "selected route opens after the greeting closes")
	_expect_equal(order.has("update_started"), true, "update discovery begins after the startup chooser closes")
	_expect_equal(order.has("update_finished"), false, "stalled update remains detached from the completed startup flow")
	update.release_update()
	await process_frame
	_expect_equal(order.has("update_finished"), true, "background update may finish after startup")
	coordinator.queue_free()


func _test_declined_tour_goes_directly_to_main_menu() -> void:
	var order: Array[String] = []
	var cookies := FakeCookies.new(order)
	var state := FakeState.new()
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": FakeUpdate.new(order),
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"profile_onboarding": FakeProfileFlow.new(order, cookies.profile),
		"state": state,
		"main_menu": FakeMainMenu.new(order),
		"tutorial_prompt": FakeTutorialPrompt.new(order, false),
		"tutorial_runner": func():
			order.append("tutorial")
			return {"ok": true},
		"load_last_project": false,
		"pilot_mode": false,
	})
	root.add_child(coordinator)
	var pre: Dictionary = await coordinator.run_pre_workspace()
	var post: Dictionary = await coordinator.run_post_workspace()
	_expect_equal(pre.get("ok"), true, "declined-tour pre-workspace succeeds")
	_expect_equal(post.get("ok"), true, "declined tour still reaches the workspace")
	_expect_equal(order, ["restore", "tutorial_prompt", "menu", "route"], "declining the tour does not launch its runner")
	_expect_equal(state.tour_marks, [
		{"status": "dismissed", "version": 3},
	], "declining the tutorial records the explicit choice")
	coordinator.queue_free()


func _test_main_menu_opens_before_workspace_is_ready() -> void:
	var order: Array[String] = []
	var cookies := FakeCookies.new(order)
	var gate := FakeWorkspaceGate.new(order)
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": null,
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"profile_onboarding": FakeProfileFlow.new(order, cookies.profile),
		"state": FakeState.new(),
		"main_menu": FakeMainMenu.new(order),
		"tutorial_prompt": FakeTutorialPrompt.new(order, false),
		"workspace_ready": Callable(gate, "wait_until_ready"),
		"load_last_project": false,
		"pilot_mode": false,
	})
	root.add_child(coordinator)
	await coordinator.run_pre_workspace()

	var completed: Array[Dictionary] = []
	coordinator.post_workspace_completed.connect(func(result: Dictionary):
		completed.append(result)
	)
	coordinator.run_post_workspace()
	await process_frame
	_expect_equal(order.has("menu"), true, "main greeting opens before workspace preparation finishes")
	_expect_equal(order.has("route"), false, "selected route waits for a usable workspace")
	_expect_equal(completed.size(), 0, "post-workspace flow remains pending only after the menu is visible")

	gate.release()
	await process_frame
	_expect_equal(order.has("workspace_ready"), true, "workspace readiness releases the selected action")
	_expect_equal(order.has("route"), true, "selected route opens after workspace preparation")
	_expect_equal(completed.size(), 1, "post-workspace flow completes after workspace preparation")
	coordinator.queue_free()


func _test_completed_tour_is_not_offered_again_for_normal_login() -> void:
	var order: Array[String] = []
	var cookies := FakeCookies.new(order)
	cookies.session = false
	var state := FakeState.new()
	state.needs_tour = false
	var main_menu := FakeMainMenu.new(order)
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": FakeUpdate.new(order),
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"profile_onboarding": FakeProfileFlow.new(order, cookies.profile),
		"state": state,
		"main_menu": main_menu,
		"tutorial_prompt": FakeTutorialPrompt.new(order),
		"tutorial_runner": func():
			order.append("tutorial")
			return {"ok": true},
		"load_last_project": false,
		"pilot_config": {},
		"pilot_mode": false,
	})
	root.add_child(coordinator)
	var pre: Dictionary = await coordinator.run_pre_workspace()
	var post: Dictionary = await coordinator.run_post_workspace()
	_expect_equal(pre.get("ok"), true, "returning startup succeeds")
	_expect_equal(post.get("ok"), true, "returning post-startup succeeds")
	_expect_equal(
		order,
		["restore", "menu", "route"],
		"a regular account is not prompted again after resolving the tour"
	)
	_expect_equal(state.tour_marks, [], "resolved normal tour state is not overwritten")
	coordinator.queue_free()


func _test_standard_startup_does_not_open_browser_or_pilot_profile_form() -> void:
	var order: Array[String] = []
	var cookies := FakeCookies.new(order)
	cookies.session = false
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": FakeUpdate.new(order),
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"profile_onboarding": FakeProfileFlow.new(order, cookies.profile),
		"state": FakeState.new(),
		"pilot_mode": false,
	})
	root.add_child(coordinator)
	var result: Dictionary = await coordinator.run_pre_workspace()
	_expect_equal(result.get("ok"), true, "ordinary startup succeeds without sign-in")
	_expect_equal(cookies.browser_login_calls, 0, "ordinary startup never opens a browser automatically")
	_expect_equal(order, ["restore"], "ordinary startup never opens the pilot identity dialog")
	coordinator.queue_free()


func _test_standard_startup_leaves_a_previous_pilot_session_untouched() -> void:
	var order: Array[String] = []
	var cookies := FakeCookies.new(order)
	cookies.pilot_session = true
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"update_manager": FakeUpdate.new(order),
		"cookies": cookies,
		"ui": FakeUi.new(order, cookies),
		"state": FakeState.new(),
		"pilot_mode": false,
	})
	root.add_child(coordinator)
	var result: Dictionary = await coordinator.run_pre_workspace()
	_expect_equal(result.get("ok"), true, "ordinary startup remains usable with a previous pilot session")
	_expect_equal(cookies.cleared_pilot_sessions, 0, "ordinary startup does not mutate a previous session")
	_expect_equal(cookies.browser_login_calls, 0, "ordinary startup does not open browser OIDC")
	coordinator.queue_free()


func _test_tour_can_be_skipped_without_opening_a_route() -> void:
	var state := FakeState.new()
	var tour_ui := FakeTourUi.new()
	var learner := FakeLearner.new()
	var palette := FakeNodePalette.new()
	palette.visible = false
	var coordinator = StartupFlowCoordinator.new()
	coordinator.configure_dependencies({
		"state": state,
		"ui": tour_ui,
		"learner": learner,
		"node_palette": palette,
	})
	root.add_child(coordinator)
	root.add_child(palette)
	coordinator._select_state("local-account")
	coordinator.call_deferred("dismiss_interface_tour")
	var result: Dictionary = await coordinator.start_interface_tour(true)
	_expect_equal(result.get("skipped"), true, "skip resolves the running tour")
	_expect_equal(learner.entered, ["offline-tour"], "tour starts before it can be skipped")
	_expect_equal(learner.stopped, 1, "skip stops the active lesson")
	_expect_equal(tour_ui.arrows_hidden, 1, "skip clears tutorial arrows")
	_expect_equal(palette.visible, true, "starting the tour restores the node palette layer")
	_expect_equal(palette.collapsed, false, "starting the tour expands the node palette")
	_expect_equal(palette.collapse_updates, [false], "tour palette state is restored exactly once")
	_expect_equal(tour_ui.highlights_hidden, 1, "skip clears tutorial highlights")
	_expect_equal(tour_ui.config_resets, 1, "skip resets the tutorial-only UI style")
	_expect_equal(coordinator.folder_menu_id(), "startup_main_menu", "skip clears the running-tour state before returning to the menu")
	_expect_equal(tour_ui.lesson_bar.visibility, [
		{"visible": true, "show_progress": false},
		{"visible": false, "show_progress": true},
	], "skip control is shown without progress only while the tour runs")
	_expect_equal(state.tour_marks, [
		{"status": "in_progress", "version": 3},
		{"status": "dismissed", "version": 3},
	], "skipped tour does not appear again automatically")
	coordinator.queue_free()
	palette.queue_free()


func _test_folder_destination_tracks_tour_state() -> void:
	var coordinator = StartupFlowCoordinator.new()
	root.add_child(coordinator)
	_expect_equal(coordinator.folder_menu_id(), "startup_main_menu", "folder normally opens the startup chooser")
	coordinator.set("_tour_running", true)
	_expect_equal(coordinator.folder_menu_id(), "workslist", "folder opens the project list while the interface tour is running")
	coordinator.queue_free()


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
