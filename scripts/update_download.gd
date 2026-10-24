extends RefCounted
class_name UpdateDownload

signal progress(downloaded_bytes: int, total_bytes: int, percent: float)

const RELEASE_URL_PREFIX := "https://github.com/hex358/neuralese-builder/releases/download/"
const INSTALLER_FILENAME := "Neuralese-Setup.exe"
const MAX_ATTEMPTS := 3
const STALE_PART_SECONDS := 24 * 60 * 60

var _file: FileAccess
var _downloaded := 0
var _expected_size := 0
var _abort_error := ""


func download(handle: RefCounted, package: Dictionary, destination: String) -> Dictionary:
	if not _is_valid_package(package) or destination.strip_edges().is_empty():
		return _error("io")
	if not handle.has_signal("on_chunk") or not handle.has_signal("completed"):
		return _error("network")

	cleanup_stale_parts()
	var part_path := destination + ".part"
	_cleanup_file(part_path)
	var destination_dir := destination.get_base_dir()
	if destination_dir.is_empty():
		return _error("io")
	if DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(destination_dir)) != OK:
		return _error("io")

	_file = FileAccess.open(part_path, FileAccess.WRITE)
	if _file == null:
		return _error("io")
	_downloaded = 0
	_expected_size = int(package["size_bytes"])
	_abort_error = ""

	var chunk_callback := _on_chunk.bind(handle)
	handle.connect("on_chunk", chunk_callback)
	var response: Variant = await Signal(handle, "completed")
	if handle.is_connected("on_chunk", chunk_callback):
		handle.disconnect("on_chunk", chunk_callback)
	_close_file()

	if not _abort_error.is_empty():
		_cleanup_file(part_path)
		return _error(_abort_error)
	if not response is Dictionary or response.get("ok", false) != true:
		_cleanup_file(part_path)
		return _error("network")
	if _downloaded != _expected_size:
		_cleanup_file(part_path)
		return _error("size")
	if FileAccess.get_sha256(part_path) != str(package["sha256"]):
		_cleanup_file(part_path)
		return _error("checksum")

	if FileAccess.file_exists(destination):
		var remove_error := DirAccess.remove_absolute(ProjectSettings.globalize_path(destination))
		if remove_error != OK:
			_cleanup_file(part_path)
			return _error("io")
	var rename_error := DirAccess.rename_absolute(
		ProjectSettings.globalize_path(part_path),
		ProjectSettings.globalize_path(destination)
	)
	if rename_error != OK:
		_cleanup_file(part_path)
		return _error("io")
	return {"ok": true, "path": destination}


func _on_chunk(chunk: PackedByteArray, handle: RefCounted) -> void:
	if not _abort_error.is_empty() or chunk.is_empty():
		return
	if _downloaded + chunk.size() > _expected_size:
		_abort("size", handle)
		return
	_file.store_buffer(chunk)
	if _file.get_error() != OK:
		_abort("io", handle)
		return
	_downloaded += chunk.size()
	_emit_progress(_downloaded, _expected_size)


func _abort(error: String, handle: RefCounted) -> void:
	_abort_error = error
	_close_file()
	if handle.has_method("cancel"):
		handle.call("cancel")


func _close_file() -> void:
	if _file != null:
		_file.close()
		_file = null


func _emit_progress(downloaded: int, total: int) -> void:
	var percent := clampf((float(downloaded) / float(total)) * 100.0, 0.0, 100.0)
	progress.emit(downloaded, total, percent)


static func is_allowed_installer_url(url: String) -> bool:
	var value := url.strip_edges()
	if not value.begins_with(RELEASE_URL_PREFIX):
		return false
	for forbidden in ["?", "#", "\n", "\r", "\t", " "]:
		if value.contains(forbidden):
			return false
	var remainder := value.substr(RELEASE_URL_PREFIX.length())
	var parts := remainder.split("/", false)
	if parts.size() != 2 or parts[1] != INSTALLER_FILENAME:
		return false
	return _is_release_tag(parts[0])


static func format_bytes(value: int) -> String:
	var safe_value := maxi(value, 0)
	if safe_value == 0:
		return "0 B"
	if safe_value < 1024:
		return "%d B" % safe_value
	if safe_value < 1024 * 1024:
		return "%.1f KB" % (float(safe_value) / 1024.0)
	if safe_value < 1024 * 1024 * 1024:
		return "%.1f MB" % (float(safe_value) / float(1024 * 1024))
	return "%.1f GB" % (float(safe_value) / float(1024 * 1024 * 1024))


static func can_retry(completed_attempts: int) -> bool:
	return completed_attempts >= 1 and completed_attempts < MAX_ATTEMPTS


static func retry_delay_seconds(completed_attempts: int) -> float:
	if not can_retry(completed_attempts):
		return 0.0
	return float(1 << (completed_attempts - 1))


static func cleanup_stale_parts(now_unix: int = -1) -> void:
	var updates_dir := "user://updates"
	var absolute_dir := ProjectSettings.globalize_path(updates_dir)
	if not DirAccess.dir_exists_absolute(absolute_dir):
		return
	var current_time := int(Time.get_unix_time_from_system()) if now_unix < 0 else now_unix
	for filename in DirAccess.get_files_at(updates_dir):
		if not filename.ends_with(".part"):
			continue
		var path := updates_dir.path_join(filename)
		var modified := int(FileAccess.get_modified_time(path))
		if modified > 0 and current_time - modified > STALE_PART_SECONDS:
			DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func _is_valid_package(package: Dictionary) -> bool:
	var size: Variant = package.get("size_bytes")
	var checksum := str(package.get("sha256", ""))
	return (
		is_allowed_installer_url(str(package.get("url", "")))
		and size is int
		and size > 0
		and _is_lower_hex(checksum, 64)
	)


static func _is_release_tag(value: String) -> bool:
	if not value.begins_with("v"):
		return false
	var parts := value.substr(1).split(".")
	if parts.size() != 3:
		return false
	for part in parts:
		if part.is_empty() or not part.is_valid_int() or part.begins_with("-") or part.begins_with("+"):
			return false
	return true


static func _is_lower_hex(value: String, expected_length: int) -> bool:
	if value.length() != expected_length:
		return false
	for character in value:
		if not character in "0123456789abcdef":
			return false
	return true


static func _cleanup_file(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(ProjectSettings.globalize_path(path))


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
