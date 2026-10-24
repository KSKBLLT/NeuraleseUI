extends RefCounted
class_name LocalProjectWriter

var result: Dictionary = {}
var _user_root := ""
var _project_id := ""
var _project_data: Dictionary = {}
var _write_cache := false


func _init(
	user_root: String = "",
	project_id: String = "",
	project_data: Dictionary = {},
	write_cache: bool = false
) -> void:
	_user_root = user_root
	_project_id = project_id
	_project_data = project_data
	_write_cache = write_cache


func run() -> void:
	result = write_project(_user_root, _project_id, _project_data, _write_cache)


static func write_project(
	user_root: String,
	project_id: String,
	project_data: Dictionary,
	write_cache: bool
) -> Dictionary:
	var started_usec := Time.get_ticks_usec()
	var encode_started_usec := started_usec
	var bytes := var_to_bytes(project_data)
	var encode_ms := float(Time.get_ticks_usec() - encode_started_usec) / 1000.0
	var primary_path := user_root.path_join("local_projects/%s.scn" % project_id)
	var primary_error := _store_var_atomic(primary_path, bytes)
	if not primary_error.is_empty():
		return _error_result(primary_error, bytes.size(), encode_ms, started_usec)

	var cache_error := ""
	if write_cache:
		cache_error = _store_var_atomic(
			user_root.path_join("cached_projects/%s.scn" % project_id),
			bytes
		)

	return {
		"status": "ok",
		"local": true,
		"scene": project_id,
		"payload_bytes": bytes.size(),
		"encode_ms": encode_ms,
		"worker_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
		"cache_written": write_cache and cache_error.is_empty(),
		"cache_error": cache_error,
	}


static func _store_var_atomic(path: String, value: Variant) -> String:
	var base_dir := path.get_base_dir()
	var mkdir_error := DirAccess.make_dir_recursive_absolute(base_dir)
	if mkdir_error != OK and not DirAccess.dir_exists_absolute(base_dir):
		return "Could not create local project directory: %s" % base_dir

	var temp_path := "%s.tmp.%s.%s" % [
		path,
		str(OS.get_process_id()),
		str(Time.get_ticks_usec()),
	]
	var backup_path := path + ".bak"
	var file := FileAccess.open(temp_path, FileAccess.WRITE)
	if file == null:
		return "Could not open local project temporary file: %s" % temp_path
	file.store_var(value)
	file.flush()
	var write_error := file.get_error()
	file.close()
	if write_error != OK:
		DirAccess.remove_absolute(temp_path)
		return "Could not flush local project temporary file: %s" % temp_path

	var had_previous := FileAccess.file_exists(path)
	if FileAccess.file_exists(backup_path):
		DirAccess.remove_absolute(backup_path)
	if had_previous and DirAccess.rename_absolute(path, backup_path) != OK:
		DirAccess.remove_absolute(temp_path)
		return "Could not stage previous local project file: %s" % path
	if DirAccess.rename_absolute(temp_path, path) != OK:
		if had_previous:
			DirAccess.rename_absolute(backup_path, path)
		DirAccess.remove_absolute(temp_path)
		return "Could not publish local project file: %s" % path
	return ""


static func _error_result(error: String, payload_bytes: int, encode_ms: float, started_usec: int) -> Dictionary:
	return {
		"status": "error",
		"local": true,
		"error": error,
		"payload_bytes": payload_bytes,
		"encode_ms": encode_ms,
		"worker_ms": float(Time.get_ticks_usec() - started_usec) / 1000.0,
	}
