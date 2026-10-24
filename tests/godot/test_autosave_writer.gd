extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var writer_script = load("res://scripts/local_project_writer.gd")
	_expect(writer_script != null and writer_script.can_instantiate(), "local project writer must parse")
	if writer_script == null or not writer_script.can_instantiate():
		_finish()
		return

	var root := ProjectSettings.globalize_path("user://autosave_writer_test")
	_remove_tree(root)
	var first_snapshot := {"graphs": {"main": {"nodes": [1, 2, 3]}}, "lua": {"main": "return 1"}}
	var first: Dictionary = await _write_in_worker(writer_script, root, "42", first_snapshot, true)
	_expect(first.get("status") == "ok", "first background write must succeed")
	_expect(int(first.get("payload_bytes", 0)) > 0, "writer must report serialized payload size")
	_expect(FileAccess.file_exists(root.path_join("local_projects/42.scn")), "primary project blob must exist")
	_expect(FileAccess.file_exists(root.path_join("cached_projects/42.scn")), "requested cache copy must exist")
	_expect(_read_snapshot(root.path_join("local_projects/42.scn")) == first_snapshot, "primary blob must round-trip")

	var second_snapshot := {"graphs": {"main": {"nodes": [4, 5]}}, "lua": {"main": "return 2"}}
	var second: Dictionary = await _write_in_worker(writer_script, root, "42", second_snapshot, false)
	_expect(second.get("status") == "ok", "second write must succeed")
	_expect(_read_snapshot(root.path_join("local_projects/42.scn")) == second_snapshot, "new primary blob must replace the old one")
	_expect(_read_snapshot(root.path_join("local_projects/42.scn.bak")) == first_snapshot, "atomic write must keep the previous primary as backup")
	_expect(_read_snapshot(root.path_join("cached_projects/42.scn")) == first_snapshot, "throttled cache copy must remain unchanged")
	var blocked_root := root.path_join("blocked")
	var blocker := FileAccess.open(blocked_root, FileAccess.WRITE)
	blocker.store_string("not a directory")
	blocker.close()
	var failed: Dictionary = await _write_in_worker(writer_script, blocked_root, "42", second_snapshot, false)
	_expect(failed.get("status") == "error", "filesystem failures must be returned without replacing a valid project")
	_expect(_read_snapshot(root.path_join("local_projects/42.scn")) == second_snapshot, "failed writes must not damage the last valid project")

	var glob_source := FileAccess.get_file_as_string("res://scripts/glob.gd")
	_expect("const AUTOSAVE_DEBOUNCE_SECONDS := 3.0" in glob_source, "autosave must wait for an idle editing window")
	_expect("const AUTOSAVE_MIN_INTERVAL_SECONDS := 10.0" in glob_source, "autosave must have a minimum interval")
	_expect("const AUTOSAVE_CACHE_INTERVAL_SECONDS := 60.0" in glob_source, "duplicate cache writes must be throttled")
	_expect("WorkerThreadPool.add_task" in glob_source, "serialization and project blob writes must run outside the UI thread")
	_expect("{\"save_datasets\": false, \"autosave\": true}" in glob_source, "autosave calls must be identifiable for throttling and diagnostics")

	_remove_tree(root)
	_finish()


func _write_in_worker(writer_script, root: String, project_id: String, snapshot: Dictionary, write_cache: bool) -> Dictionary:
	var writer_job = writer_script.new(root, project_id, snapshot, write_cache)
	var task_id := WorkerThreadPool.add_task(Callable(writer_job, "run"), false, "Autosave writer test")
	while not WorkerThreadPool.is_task_completed(task_id):
		await process_frame
	var completion_error := WorkerThreadPool.wait_for_task_completion(task_id)
	if completion_error != OK:
		return {"status": "error", "error": "worker task did not complete"}
	var result = writer_job.result
	return result if result is Dictionary else {"status": "error", "error": "invalid worker result"}


func _read_snapshot(path: String) -> Variant:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return null
	var bytes = file.get_var()
	file.close()
	if not bytes is PackedByteArray:
		return null
	return bytes_to_var(bytes)


func _remove_tree(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		OS.move_to_trash(path)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_autosave_writer")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_autosave_writer: %d failure(s)" % failures.size())
	quit(1)
