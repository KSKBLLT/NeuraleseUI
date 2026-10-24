extends Node
class_name UpdateManager

const RELEASE_MANIFEST_URL := "https://github.com/hex358/neuralese-builder/releases/latest/download/latest.json"
const INSTALL_MARKER_FILE := ".neuralese-install-marker"
const INSTALL_MARKER_VALUE := "NEURALESE_INSTALL_MARKER_V1:Neuralese"
const MANAGED_INSTALL_MARKER_FILE := ".neuralese-managed-install"
const MANAGED_INSTALL_MARKER_VALUE := "NEURALESE_MANAGED_INSTALL_V1"
const INSTALLER_PATH := "user://updates/Neuralese-Setup.exe"

const UpdateDownloadCore := preload("res://scripts/update_download.gd")
const UpdateManifestCore := preload("res://scripts/update_manifest.gd")
const UpdatePolicyCore := preload("res://scripts/update_policy.gd")
const UpdatePromptSpecCore := preload("res://scripts/update_prompt_spec.gd")

enum State {
	IDLE,
	CHECKING,
	DOWNLOADING,
	VERIFYING,
	LAUNCHING_INSTALLER,
	ERROR,
}

var current_state := State.IDLE
var _dependencies: Dictionary = {}


func configure_dependencies(overrides: Dictionary) -> void:
	_dependencies = overrides.duplicate()


func _local_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0.0.0")).strip_edges()


func check_update() -> void:
	if OS.has_feature("editor") and _dependencies.get("allow_editor", false) != true:
		return
	if is_managed_install(_executable_path()):
		current_state = State.IDLE
		return
	current_state = State.CHECKING
	var manifest: Dictionary = await _fetch_update_manifest()
	if manifest.is_empty() or not UpdatePolicyCore.should_prompt(manifest, _local_version()):
		current_state = State.IDLE
		return
	if _os_name() != "Windows":
		current_state = State.IDLE
		return

	var install_root := find_install_root(_executable_path())
	if install_root.is_empty():
		push_warning("Automatic update skipped: Neuralese install marker was not found")
		current_state = State.IDLE
		return
	var package: Variant = manifest.get("downloads", {}).get("windows")
	if not package is Dictionary:
		current_state = State.IDLE
		return
	await _run_windows_flow(manifest, package, install_root)


func _fetch_update_manifest() -> Dictionary:
	var web_client = _web_client()
	if web_client == null:
		return {}
	var response: Variant = await web_client.GET(RELEASE_MANIFEST_URL)
	if not response is Dictionary or response.get("ok", false) != true:
		return {}
	var body: Variant = response.get("body")
	var text := ""
	if body is PackedByteArray:
		text = body.get_string_from_utf8()
	elif body is String:
		text = body
	else:
		return {}
	var payload: Variant = JSON.parse_string(text)
	return UpdateManifestCore.parse(payload)


func _run_windows_flow(manifest: Dictionary, package: Dictionary, install_root: String) -> void:
	var attempts := 0
	while attempts < UpdateDownloadCore.MAX_ATTEMPTS:
		attempts += 1
		var dialog = _show_dialog(UpdatePromptSpecCore.build(manifest))
		if dialog == null:
			current_state = State.IDLE
			return
		current_state = State.DOWNLOADING
		var web_client = _web_client()
		if web_client == null:
			current_state = State.IDLE
			return
		var handle = web_client.GET(str(package["url"]), {}, true)
		var selected_action := {"id": ""}
		if dialog.has_signal("action_selected"):
			dialog.action_selected.connect(
				func(result: Dictionary):
					selected_action["id"] = str(result.get("action", ""))
					if selected_action["id"] == "continue" and handle.has_method("cancel"):
						handle.cancel(),
				CONNECT_ONE_SHOT
			)

		var downloader = _create_downloader()
		if downloader == null:
			current_state = State.ERROR
			return
		if downloader.has_signal("progress"):
			downloader.progress.connect(_on_download_progress.bind(dialog))
		var result: Dictionary = await downloader.download(handle, package, INSTALLER_PATH)
		if selected_action["id"] == "continue":
			current_state = State.IDLE
			return

		if result.get("ok", false) == true:
			current_state = State.VERIFYING
			if is_instance_valid(dialog):
				var no_actions: Array[Dictionary] = []
				dialog.set_actions(no_actions)
				dialog.set_progress(100.0, _text("installing"), _text("verified"))
			var launch_result := _launch_installer(str(result["path"]), install_root)
			if launch_result.get("ok", false) == true:
				return
			result = launch_result

		current_state = State.ERROR
		if not is_instance_valid(dialog):
			current_state = State.IDLE
			return
		dialog.set_progress(0.0, _text("failed"), _error_detail(str(result.get("error", "network"))))
		dialog.set_actions(_error_actions(
			manifest.get("mandatory", false) == true,
			UpdateDownloadCore.can_retry(attempts)
		))
		var decision: Dictionary = await dialog.wait_for_result()
		var action := str(decision.get("action", ""))
		if action == "retry" and UpdateDownloadCore.can_retry(attempts):
			await _wait_before_retry(attempts)
			continue
		if action == "exit" or manifest.get("mandatory", false) == true:
			_quit_application()
		else:
			current_state = State.IDLE
		return


func _on_download_progress(downloaded: int, total: int, percent: float, dialog: Variant) -> void:
	if not is_instance_valid(dialog):
		return
	dialog.set_progress(
		percent,
		_text("downloading"),
		"%s / %s" % [UpdateDownloadCore.format_bytes(downloaded), UpdateDownloadCore.format_bytes(total)]
	)


func _launch_installer(installer_path: String, install_root: String) -> Dictionary:
	current_state = State.LAUNCHING_INSTALLER
	var absolute_installer := ProjectSettings.globalize_path(installer_path)
	var args := PackedStringArray([
		"--silent-update",
		"--install-dir",
		install_root,
		"--wait-pid",
		str(_process_id()),
		"--launch-after-update",
	])
	var process_id := 0
	var launcher: Variant = _dependencies.get("process_launcher")
	if launcher is Callable and launcher.is_valid():
		process_id = int(launcher.call(absolute_installer, args))
	else:
		process_id = OS.create_process(absolute_installer, args)
	if process_id <= 0:
		return {"ok": false, "error": "installer_launch"}
	_quit_application()
	return {"ok": true}


static func find_install_root(executable_path: String) -> String:
	var absolute_path := ProjectSettings.globalize_path(executable_path.strip_edges()).replace("\\", "/").simplify_path()
	if absolute_path.is_empty():
		return ""
	var current := absolute_path.get_base_dir()
	while not current.is_empty():
		var marker_path := current.path_join(INSTALL_MARKER_FILE)
		if FileAccess.file_exists(marker_path):
			var marker := FileAccess.get_file_as_string(marker_path).strip_edges()
			if marker == INSTALL_MARKER_VALUE:
				return current
			return ""
		var parent := current.get_base_dir()
		if parent == current or parent.is_empty():
			break
		current = parent
	return ""


static func is_managed_install(executable_path: String) -> bool:
	var absolute_path := ProjectSettings.globalize_path(executable_path.strip_edges()).replace("\\", "/").simplify_path()
	if absolute_path.is_empty():
		return false
	var current := absolute_path.get_base_dir()
	while not current.is_empty():
		var marker_path := current.path_join(MANAGED_INSTALL_MARKER_FILE)
		if FileAccess.file_exists(marker_path):
			return FileAccess.get_file_as_string(marker_path).strip_edges() == MANAGED_INSTALL_MARKER_VALUE
		var parent := current.get_base_dir()
		if parent == current or parent.is_empty():
			break
		current = parent
	return false


func _error_actions(mandatory: bool, allow_retry: bool = true) -> Array[Dictionary]:
	var actions: Array[Dictionary] = []
	if allow_retry:
		actions.append({
			"id": "retry",
			"text": {"en": "Retry", "ru": "Повторить", "kz": "Қайталау"},
			"style": "primary",
		})
	if mandatory:
		actions.append({
			"id": "exit",
			"text": {"en": "Exit", "ru": "Выйти", "kz": "Шығу"},
			"style": "secondary",
		})
	else:
		actions.append({
			"id": "continue",
			"text": {
				"en": "Continue without updating",
				"ru": "Продолжить без обновления",
				"kz": "Жаңартусыз жалғастыру",
			},
			"style": "secondary",
		})
	return actions


func _wait_before_retry(completed_attempts: int) -> void:
	if is_inside_tree():
		await get_tree().process_frame
	var delay := float(_dependencies.get(
		"retry_delay",
		UpdateDownloadCore.retry_delay_seconds(completed_attempts)
	))
	if delay > 0.0 and is_inside_tree():
		await get_tree().create_timer(delay).timeout


func _web_client() -> Variant:
	if _dependencies.has("web"):
		return _dependencies["web"]
	return get_node_or_null("/root/web")


func _show_dialog(spec: Dictionary) -> Variant:
	var service: Variant = _dependencies.get("dialogs")
	if service == null:
		service = get_node_or_null("/root/ui")
	if service == null or not service.has_method("show_dialog"):
		push_warning("Update dialog service is unavailable")
		return null
	return service.show_dialog(spec)


func _create_downloader() -> Variant:
	var factory: Variant = _dependencies.get("downloader_factory")
	if factory is Callable and factory.is_valid():
		return factory.call()
	return UpdateDownloadCore.new()


func _os_name() -> String:
	return str(_dependencies.get("os_name", OS.get_name()))


func _executable_path() -> String:
	return str(_dependencies.get("executable_path", OS.get_executable_path()))


func _process_id() -> int:
	return int(_dependencies.get("process_id", OS.get_process_id()))


func _quit_application() -> void:
	var quit_callback: Variant = _dependencies.get("quit")
	if quit_callback is Callable and quit_callback.is_valid():
		quit_callback.call()
	elif is_inside_tree():
		get_tree().quit()


func _text(key: String) -> String:
	var language := str(_dependencies.get("language", ""))
	if language.is_empty():
		var global_state := get_node_or_null("/root/glob")
		if global_state != null and global_state.has_method("get_lang"):
			language = str(global_state.get_lang())
	var translations := {
		"downloading": {"en": "Downloading update", "ru": "Скачивание обновления", "kz": "Жаңартуды жүктеу"},
		"installing": {"en": "Installing update", "ru": "Установка обновления", "kz": "Жаңартуды орнату"},
		"verified": {"en": "Download verified", "ru": "Файл проверен", "kz": "Файл тексерілді"},
		"failed": {"en": "Update failed", "ru": "Ошибка обновления", "kz": "Жаңарту қатесі"},
	}
	var localized: Dictionary = translations.get(key, {})
	return str(localized.get(language, localized.get("en", key)))


func _error_detail(error: String) -> String:
	var messages := {
		"network": "Network connection failed",
		"size": "Downloaded file size did not match",
		"checksum": "Downloaded file checksum did not match",
		"io": "Could not save the update",
		"installer_launch": "Could not start the installer",
	}
	return str(messages.get(error, "Update could not be completed"))
