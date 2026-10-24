class_name RobotSessionClient
extends Node
## Godot's side of one robot session (local_runtime/neuralese_local/robot/robot_session.py).
##
## The same job-directory pattern as the other local runtime processes
## (run_manager.gd: RobotLink, LocalInferChannel): Godot makes a directory,
## starts the Python process on it, writes request.json, reads the answers and
## events from progress.jsonl, and stops it with files. The process owns the
## robot link and the model, so Godot is never in the 20 Hz control loop.
##
## Requests are one at a time: request.json is a single slot that the process
## polls every 10 ms, so a second request is held back until the first has had
## time to be picked up. Emergency stop does not use the slot; it is a file.

signal event_received(event: Dictionary)
signal closed

const SPAWN_TIMEOUT_S := 25.0
const REQUEST_GAP_S := 0.08
const POLL_S := 0.04
const STALE_JOB_AGE_S := 24.0 * 3600.0

var job_dir := ""
var pid := -1
var last_error := ""
var alive := false

var _seq := 0
var _responses: Dictionary = {}
var _offset := 0
var _tail := PackedByteArray()
var _poll := 0.0
var _last_write_ms := 0
var _closing := false


## Starts the process. Returns true once it has announced itself.
func start() -> bool:
	if not nn.FULLY_LOCAL_TRAINING:
		last_error = "FullyLocal mode is disabled."
		return false
	if not await nn._ensure_local_runtime_ready("robot"):
		last_error = local_runtime.last_error()
		return false
	var entry: String = await nn._robot_session_entry_abs()
	if not FileAccess.file_exists(entry):
		last_error = "Robot session entry not found: " + entry
		return false
	_remove_stale_jobs()
	job_dir = nn._make_robot_link_job_dir()
	var control := {
		"parent_pid": OS.get_process_id(),
		"profiles_dir": nn.robot_profiles_dir_abs(),
		"logs_dir": nn.robot_logs_dir_abs(),
	}
	if not nn._write_json(job_dir.path_join("control.json"), control):
		last_error = "Could not write the robot session control file."
		return false
	var python: String = await nn._local_python_path()
	pid = OS.create_process(python, [entry, job_dir])
	if pid <= 0:
		last_error = "Could not start the robot session: " + python + " " + entry
		return false
	var waited := 0.0
	while not alive:
		_read_events()
		if alive:
			break
		await get_tree().process_frame
		waited += get_process_delta_time()
		if waited > SPAWN_TIMEOUT_S:
			last_error = "The robot session did not start in time."
			kill()
			return false
	return true


func _process(delta: float) -> void:
	if job_dir.is_empty():
		return
	_poll += delta
	if _poll >= POLL_S:
		_poll = 0.0
		_read_events()


## Sends a command and waits for its answer: {"ok": bool, "result": {...} | "error": {...}}.
func call_command(command: String, args: Dictionary = {}, timeout_s: float = 90.0) -> Dictionary:
	if not alive and not _closing:
		return _failure("session_down", "The robot session is not running.")
	_seq += 1
	var seq := _seq
	# Hold a request back until the previous one has had time to be read.
	var since := (Time.get_ticks_msec() - _last_write_ms) / 1000.0
	if since < REQUEST_GAP_S:
		await get_tree().create_timer(REQUEST_GAP_S - since).timeout
	var request := {"seq": seq, "command": command, "args": args}
	if not await _publish(job_dir.path_join("request.json"), request):
		return _failure("io_failed", "Could not write the robot request.")
	_last_write_ms = Time.get_ticks_msec()
	var waited := 0.0
	while not _responses.has(seq):
		await get_tree().process_frame
		waited += get_process_delta_time()
		if not alive:
			return _failure("session_down", "The robot session stopped.")
		if waited > timeout_s:
			return _failure("timeout", "The robot did not answer in time.")
	var response: Dictionary = _responses[seq]
	_responses.erase(seq)
	return response


## Writes the request next to its final name and moves it into place. The
## session process reads request.json every few milliseconds, and Windows will
## not replace a file while it is open, so a move that meets the reader waits a
## frame and tries again instead of failing.
func _publish(path: String, data: Dictionary) -> bool:
	var tmp_path := "%s.tmp.%d" % [path, Time.get_ticks_usec()]
	var file := FileAccess.open(tmp_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify(data))
	file.close()
	for attempt in 40:
		if DirAccess.rename_absolute(tmp_path, path) == OK:
			return true
		if FileAccess.file_exists(path) and DirAccess.remove_absolute(path) == OK 				and DirAccess.rename_absolute(tmp_path, path) == OK:
			return true
		await get_tree().create_timer(0.01).timeout
	DirAccess.remove_absolute(tmp_path)
	return false


## Stops the motors at once, without waiting in the request queue.
func estop() -> void:
	if job_dir.is_empty():
		return
	var flag := FileAccess.open(job_dir.path_join("estop"), FileAccess.WRITE)
	if flag:
		flag.store_string("estop")
		flag.close()


func status() -> Dictionary:
	var path := job_dir.path_join("status.json")
	if job_dir.is_empty() or not FileAccess.file_exists(path):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return parsed if parsed is Dictionary else {}


## Asks the process to stop the robot, release the link and exit.
func shutdown() -> void:
	if _closing:
		return
	_closing = true
	if not job_dir.is_empty():
		var flag := FileAccess.open(job_dir.path_join("stop"), FileAccess.WRITE)
		if flag:
			flag.store_string("stop")
			flag.close()
	if pid > 0 and is_inside_tree():
		var waited := 0.0
		while OS.is_process_running(pid) and waited < 4.0:
			await get_tree().process_frame
			waited += get_process_delta_time()
		kill()
	alive = false
	closed.emit()


func kill() -> void:
	if pid > 0 and OS.is_process_running(pid):
		OS.kill(pid)


func _exit_tree() -> void:
	# The window is going away: whatever happens, the robot must not keep driving.
	if not job_dir.is_empty() and not _closing:
		var flag := FileAccess.open(job_dir.path_join("stop"), FileAccess.WRITE)
		if flag:
			flag.store_string("stop")
			flag.close()


func _failure(code: String, message: String) -> Dictionary:
	return {"ok": false, "error": {"code": code, "message": message}}


func _read_events() -> void:
	var path := job_dir.path_join("progress.jsonl")
	if not FileAccess.file_exists(path):
		return
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var length := file.get_length()
	if length > _offset:
		file.seek(_offset)
		_tail.append_array(file.get_buffer(length - _offset))
		_offset = length
	file.close()
	var start := 0
	for index in _tail.size():
		if _tail[index] != 10:
			continue
		var line := _tail.slice(start, index).get_string_from_utf8().strip_edges()
		start = index + 1
		if line.is_empty():
			continue
		var parsed: Variant = JSON.parse_string(line)
		if parsed is Dictionary:
			_dispatch(parsed)
	_tail = _tail.slice(start)


func _dispatch(event: Dictionary) -> void:
	match str(event.get("event", "")):
		"ready":
			alive = true
		"response":
			_responses[int(event.get("seq", -1))] = event
		"closed":
			alive = false
			closed.emit()
		_:
			event_received.emit(event)


## Old session folders are not needed after a day.
func _remove_stale_jobs() -> void:
	var root: String = nn._fully_local_robot_links_root_abs()
	var directory := DirAccess.open(root)
	if directory == null:
		return
	var now := Time.get_unix_time_from_system()
	for name in directory.get_directories():
		var stamp := nn._job_timestamp_from_name(name)
		if stamp > 0.0 and now - stamp > STALE_JOB_AGE_S:
			nn._remove_dir_recursive_abs(root.path_join(name), [root])
