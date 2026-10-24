extends RefCounted
class_name UpdateHealth

const HEALTH_DIRECTORY := "user://updates/health"
const HEALTH_FILE_SUFFIX := ".json"


static func acknowledge_from_command_line() -> bool:
	return acknowledge(
		OS.get_cmdline_args(),
		HEALTH_DIRECTORY,
		str(ProjectSettings.get_setting("application/config/version", "0.0.0")).strip_edges(),
		OS.get_process_id()
	)


static func acknowledge(
	args: PackedStringArray,
	health_directory: String,
	version: String,
	pid: int
) -> bool:
	var health_file := _argument_value(args, "--post-update-health-file=")
	var token := _argument_value(args, "--post-update-token=")
	if health_file.is_empty() or not _is_uuid(token) or version.is_empty() or pid <= 0:
		return false

	var allowed_directory := _normalized_absolute(health_directory)
	var target_path := _normalized_absolute(health_file)
	if allowed_directory.is_empty() or target_path.is_empty():
		return false
	if not DirAccess.dir_exists_absolute(allowed_directory):
		return false
	if _path_key(target_path.get_base_dir()) != _path_key(allowed_directory):
		return false
	if not _is_health_filename(target_path.get_file()):
		return false
	if FileAccess.file_exists(target_path):
		return false

	var temporary_path := "%s.tmp.%s.%s" % [target_path, pid, Time.get_ticks_usec()]
	var file := FileAccess.open(temporary_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({
		"token": token,
		"version": version,
		"pid": pid,
	}))
	file.flush()
	var file_error := file.get_error()
	file.close()
	if file_error != OK:
		_cleanup(temporary_path)
		return false
	var rename_error := DirAccess.rename_absolute(temporary_path, target_path)
	if rename_error != OK:
		_cleanup(temporary_path)
		return false
	return true


static func _argument_value(args: PackedStringArray, prefix: String) -> String:
	for argument in args:
		if argument.begins_with(prefix):
			return argument.substr(prefix.length()).strip_edges()
	return ""


static func _normalized_absolute(path: String) -> String:
	var value := path.strip_edges()
	if value.is_empty() or value.contains("\n") or value.contains("\r") or value.contains("\u0000"):
		return ""
	return ProjectSettings.globalize_path(value).replace("\\", "/").simplify_path().trim_suffix("/")


static func _path_key(path: String) -> String:
	var normalized := path.replace("\\", "/").simplify_path().trim_suffix("/")
	return normalized.to_lower() if OS.get_name() == "Windows" else normalized


static func _is_health_filename(filename: String) -> bool:
	if not filename.ends_with(HEALTH_FILE_SUFFIX):
		return false
	return _is_lower_hex(filename.trim_suffix(HEALTH_FILE_SUFFIX), 32)


static func _is_uuid(value: String) -> bool:
	if value.length() != 36:
		return false
	for index in value.length():
		var character := value[index]
		if index in [8, 13, 18, 23]:
			if character != "-":
				return false
		elif character not in "0123456789abcdef":
			return false
	return true


static func _is_lower_hex(value: String, expected_length: int) -> bool:
	if value.length() != expected_length:
		return false
	for character in value:
		if character not in "0123456789abcdef":
			return false
	return true


static func _cleanup(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
