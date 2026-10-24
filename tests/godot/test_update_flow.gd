extends SceneTree

const UpdateManagerClass := preload("res://scripts/update_state.gd")

const INSTALL_MARKER := "NEURALESE_INSTALL_MARKER_V1:Neuralese"
const PACKAGE_URL := "https://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Neuralese-Setup.exe"

var failures: Array[String] = []
var _case_index := 0


class FakeHandle:
	extends RefCounted

	var cancelled := false

	func cancel() -> void:
		cancelled = true


class FakeManifestRequest:
	extends RefCounted

	signal completed(response: Dictionary)

	var response: Dictionary

	func deliver() -> void:
		completed.emit(response)


class FakeWeb:
	extends RefCounted

	var response: Dictionary
	var manifest_requests := 0
	var download_requests := 0
	var handles: Array[FakeHandle] = []
	var manifest_handles: Array[FakeManifestRequest] = []

	func GET(_url: String, _headers: Dictionary = {}, bytes: bool = false) -> Variant:
		if bytes:
			download_requests += 1
			var handle := FakeHandle.new()
			handles.append(handle)
			return handle
		manifest_requests += 1
		var request := FakeManifestRequest.new()
		request.response = response
		manifest_handles.append(request)
		request.call_deferred("deliver")
		return request.completed


class FakeDownloader:
	extends RefCounted

	signal progress(downloaded_bytes: int, total_bytes: int, percent: float)

	var results: Array[Dictionary] = []
	var calls := 0

	func download(_handle: RefCounted, package: Dictionary, destination: String) -> Dictionary:
		calls += 1
		progress.emit(int(package["size_bytes"] / 2), int(package["size_bytes"]), 50.0)
		await Engine.get_main_loop().process_frame
		if results.is_empty():
			return {"ok": true, "path": destination}
		return results.pop_front()


class FakeDialog:
	extends RefCounted

	signal action_selected(result: Dictionary)

	var error_action := ""
	var progress_values: Array[float] = []
	var action_sets: Array[Array] = []
	var _last_result: Dictionary = {}

	func set_progress(value: float, _status: String, _detail: String) -> void:
		progress_values.append(value)

	func set_actions(actions: Array[Dictionary]) -> void:
		action_sets.append(actions.duplicate(true))
		if not error_action.is_empty():
			call_deferred("emit_action", error_action)

	func emit_action(action: String) -> void:
		_last_result = {"action": action}
		action_selected.emit(_last_result)

	func wait_for_result() -> Dictionary:
		if not _last_result.is_empty():
			return _last_result
		return await action_selected


class FakeDialogService:
	extends RefCounted

	var specs: Array[Dictionary] = []
	var dialogs: Array[FakeDialog] = []
	var error_actions: Array[String] = []
	var initial_actions: Array[String] = []

	func show_dialog(spec: Dictionary) -> FakeDialog:
		specs.append(spec.duplicate(true))
		var dialog := FakeDialog.new()
		if not error_actions.is_empty():
			dialog.error_action = error_actions.pop_front()
		dialogs.append(dialog)
		if not initial_actions.is_empty():
			var initial_action: String = initial_actions.pop_front()
			if not initial_action.is_empty():
				dialog.call_deferred("emit_action", initial_action)
		return dialog


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var contract_manager = UpdateManagerClass.new()
	if not contract_manager.has_method("configure_dependencies"):
		push_error("UpdateManager.configure_dependencies is missing")
		contract_manager.free()
		quit(1)
		return
	_expect_equal(_action_ids(contract_manager._error_actions(false, false)), ["continue"], "final optional actions")
	_expect_equal(_action_ids(contract_manager._error_actions(true, false)), ["exit"], "final mandatory actions")
	contract_manager.free()

	await _test_offline_and_current_do_not_prompt()
	await _test_optional_and_mandatory_success()
	await _test_continue_during_download()
	await _test_checksum_failure_can_continue()
	await _test_retry_then_success()
	await _test_missing_install_marker_blocks_launch()
	await _test_managed_install_never_checks_for_updates()

	if failures.is_empty():
		print("PASS test_update_flow")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_offline_and_current_do_not_prompt() -> void:
	var offline := await _run_case({}, [], false)
	_expect_equal(offline.dialogs.specs.size(), 0, "offline dialog count")
	_expect_equal(offline.launches.size(), 0, "offline launch count")

	var current := await _run_case(_response(_manifest("1.0.8", false)), [], true)
	_expect_equal(current.dialogs.specs.size(), 0, "current dialog count")
	_expect_equal(current.launches.size(), 0, "current launch count")


func _test_optional_and_mandatory_success() -> void:
	var optional := await _run_case(
		_response(_manifest("1.0.9", false)),
		[{"ok": true, "path": "user://updates/Neuralese-Setup.exe"}],
		true
	)
	_expect_equal(optional.dialogs.specs.size(), 1, "optional dialog count")
	_expect_equal(optional.manifest_requests, 1, "optional manifest request count")
	if not optional.dialogs.specs.is_empty():
		_expect_equal(optional.dialogs.specs[0]["buttons"][0]["id"], "continue", "optional initial action")
	_expect_equal(optional.launches.size(), 1, "optional installer launch")
	if not optional.launches.is_empty():
		_expect_installer_arguments(optional.launches[0], optional.install_root)
	_expect_equal(optional.quits.size(), 1, "successful update quits app")

	var mandatory := await _run_case(
		_response(_manifest("2.0.0", true)),
		[{"ok": true, "path": "user://updates/Neuralese-Setup.exe"}],
		true
	)
	if not mandatory.dialogs.specs.is_empty():
		_expect_equal(mandatory.dialogs.specs[0]["buttons"].size(), 0, "mandatory initial actions")
	_expect_equal(mandatory.launches.size(), 1, "mandatory installer launch")


func _test_checksum_failure_can_continue() -> void:
	var result := await _run_case(
		_response(_manifest("1.0.9", false)),
		[{"ok": false, "error": "checksum"}],
		true,
		["continue"]
	)
	_expect_equal(result.launches.size(), 0, "checksum failure launch count")
	if not result.dialogs.dialogs.is_empty() and not result.dialogs.dialogs[0].action_sets.is_empty():
		var ids := _action_ids(result.dialogs.dialogs[0].action_sets[-1])
		_expect_equal(ids, ["retry", "continue"], "optional checksum actions")
	else:
		failures.append("optional checksum actions: no dialog actions, state %s, root %s" % [result.state, result.found_root])


func _test_continue_during_download() -> void:
	var result := await _run_case(
		_response(_manifest("1.0.9", false)),
		[{"ok": true, "path": "user://updates/Neuralese-Setup.exe"}],
		true,
		[],
		["continue"]
	)
	_expect_equal(result.launches.size(), 0, "continue during download launch count")
	_expect_equal(result.web.handles.size(), 1, "continue active request count")
	if not result.web.handles.is_empty():
		_expect_equal(result.web.handles[0].cancelled, true, "continue cancels active request")


func _test_retry_then_success() -> void:
	var result := await _run_case(
		_response(_manifest("1.0.9", false)),
		[
			{"ok": false, "error": "network"},
			{"ok": true, "path": "user://updates/Neuralese-Setup.exe"},
		],
		true,
		["retry", ""]
	)
	_expect_equal(result.downloader.calls, 2, "retry download count")
	_expect_equal(result.launches.size(), 1, "retry installer launch")


func _test_missing_install_marker_blocks_launch() -> void:
	var result := await _run_case(
		_response(_manifest("1.0.9", false)),
		[{"ok": true, "path": "user://updates/Neuralese-Setup.exe"}],
		false
	)
	_expect_equal(result.dialogs.specs.size(), 0, "unmarked install dialog count")
	_expect_equal(result.launches.size(), 0, "unmarked install launch count")


func _test_managed_install_never_checks_for_updates() -> void:
	var result := await _run_case(
		_response(_manifest("1.0.9", true)),
		[{"ok": true, "path": "user://updates/Neuralese-Setup.exe"}],
		true,
		[],
		[],
		true
	)
	_expect_equal(result.manifest_requests, 0, "managed install manifest request count")
	_expect_equal(result.dialogs.specs.size(), 0, "managed install dialog count")
	_expect_equal(result.launches.size(), 0, "managed install launch count")


func _run_case(
	response: Dictionary,
	download_results: Array[Dictionary],
	with_marker: bool,
	error_actions: Array[String] = [],
	initial_actions: Array[String] = [],
	managed_install: bool = false
) -> Dictionary:
	_case_index += 1
	var install_root := ProjectSettings.globalize_path(
		"user://updates/flow-install-%s-%s" % [Time.get_ticks_usec(), _case_index]
	)
	DirAccess.make_dir_recursive_absolute(install_root.path_join("bin"))
	if with_marker:
		var marker := FileAccess.open(install_root.path_join(".neuralese-install-marker"), FileAccess.WRITE)
		marker.store_string(INSTALL_MARKER)
		marker.close()
	if managed_install:
		var managed_marker := FileAccess.open(
			install_root.path_join(".neuralese-managed-install"),
			FileAccess.WRITE
		)
		managed_marker.store_string("NEURALESE_MANAGED_INSTALL_V1")
		managed_marker.close()

	var web := FakeWeb.new()
	web.response = response
	var dialogs := FakeDialogService.new()
	dialogs.error_actions = error_actions.duplicate()
	dialogs.initial_actions = initial_actions.duplicate()
	var downloader := FakeDownloader.new()
	downloader.results = download_results.duplicate(true)
	var launches: Array[Dictionary] = []
	var quits: Array[bool] = []
	var manager = UpdateManagerClass.new()
	var executable_path := install_root.path_join("bin/Neuralese.exe")
	var found_root := UpdateManagerClass.find_install_root(executable_path)
	if with_marker:
		_expect_equal(found_root, install_root, "install root discovery")
	manager.configure_dependencies({
		"allow_editor": true,
		"web": web,
		"dialogs": dialogs,
		"downloader_factory": func(): return downloader,
		"process_launcher": func(path: String, args: PackedStringArray) -> int:
			launches.append({"path": path, "args": args})
			return 777,
		"quit": func(): quits.append(true),
		"os_name": "Windows",
		"executable_path": executable_path,
		"process_id": 4242,
		"retry_delay": 0.0,
	})
	root.add_child(manager)
	await manager.check_update()
	var final_state: int = manager.current_state
	manager.queue_free()
	await process_frame
	_remove_tree(install_root)
	return {
		"dialogs": dialogs,
		"web": web,
		"downloader": downloader,
		"launches": launches,
		"quits": quits,
		"install_root": install_root,
		"found_root": found_root,
		"state": final_state,
		"manifest_requests": web.manifest_requests,
	}


func _manifest(version: String, mandatory: bool) -> Dictionary:
	return {
		"schema_version": 1,
		"version": version,
		"mandatory": mandatory,
		"published_at": "2026-07-16T18:00:00Z",
		"builder_commit_sha": "a".repeat(40),
		"setup_commit_sha": "b".repeat(40),
		"notes_markdown": {"en": "Fixes", "ru": "Исправления"},
		"downloads": {
			"windows": {
				"url": PACKAGE_URL.replace("v1.0.8", "v%s" % version),
				"size_bytes": 2 * 1024 * 1024,
				"sha256": "c".repeat(64),
			}
		},
	}


func _response(manifest: Dictionary) -> Dictionary:
	return {"ok": true, "body": JSON.stringify(manifest).to_utf8_buffer()}


func _expect_installer_arguments(launch: Dictionary, install_root: String) -> void:
	_expect_equal(launch["path"], ProjectSettings.globalize_path("user://updates/Neuralese-Setup.exe"), "installer path")
	_expect_equal(Array(launch["args"]), [
		"--silent-update",
		"--install-dir",
		install_root,
		"--wait-pid",
		"4242",
		"--launch-after-update",
	], "installer arguments")


func _action_ids(actions: Array) -> Array[String]:
	var result: Array[String] = []
	for action in actions:
		result.append(str(action.get("id", "")))
	return result


func _remove_tree(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for filename in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(filename))
	for directory in DirAccess.get_directories_at(path):
		_remove_tree(path.path_join(directory))
	DirAccess.remove_absolute(path)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
