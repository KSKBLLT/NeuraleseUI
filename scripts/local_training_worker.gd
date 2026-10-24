extends RefCounted

signal worker_ready(bootstrap: Dictionary)
signal prepared(handle: Dictionary)
signal packet_received(packet: Dictionary)
signal worker_failed(details: Dictionary)

const PROTOCOL_VERSION := 1
const MAX_FRAME_BYTES := 8 * 1024 * 1024
const BOOTSTRAP_TIMEOUT_MSEC := 30_000

var state := "idle"
var process_pid := -1
var process_generation := ""
var token := ""
var bootstrap_path := ""
var _python_path := ""
var _entry_path := ""
var _runtime_root := ""
var _cache_root := ""
var _parent_pid := 0
var _bootstrap_deadline_msec := 0
var _peer: StreamPeerTCP
var _receive_buffer := PackedByteArray()
var _expected_frame_bytes := -1
var _next_request_id := 1
var _restart_count := 0
var _shutting_down := false


func configure(
	python_path: String,
	entry_path: String,
	runtime_root: String,
	state_root: String,
	parent_pid: int
) -> void:
	_python_path = python_path
	_entry_path = entry_path
	_runtime_root = runtime_root
	_cache_root = state_root.path_join("cache")
	bootstrap_path = state_root.path_join("bootstrap.json")
	_parent_pid = parent_pid


func start_warm() -> bool:
	if state in ["bootstrapping", "connecting", "ready"]:
		return true
	if _python_path == "" or _entry_path == "" or _runtime_root == "" or bootstrap_path == "":
		_fail("worker_not_configured", "Local training worker is not configured")
		return false
	DirAccess.make_dir_recursive_absolute(bootstrap_path.get_base_dir())
	DirAccess.make_dir_recursive_absolute(_cache_root)
	if FileAccess.file_exists(bootstrap_path):
		DirAccess.remove_absolute(bootstrap_path)
	process_pid = OS.create_process(_python_path, [
		_entry_path,
		"--bootstrap", bootstrap_path,
		"--runtime-root", _runtime_root,
		"--cache-root", _cache_root,
		"--parent-pid", str(_parent_pid),
	])
	if process_pid <= 0:
		_fail("worker_start_failed", "Could not start local training worker")
		return false
	state = "bootstrapping"
	_bootstrap_deadline_msec = Time.get_ticks_msec() + BOOTSTRAP_TIMEOUT_MSEC
	return true


func poll() -> void:
	if state == "bootstrapping":
		_poll_bootstrap()
	if state == "connecting" or state == "ready":
		_poll_peer()


func prepare(snapshot: Dictionary) -> int:
	return _send_command("PREPARE", {"request": snapshot})


func start_prepared(handle: Dictionary, config: Dictionary) -> int:
	return _send_command("START", {
		"prepared_id": str(handle.get("prepared_id", "")),
		"graph_generation": int(handle.get("graph_generation", -1)),
		"run_config": config,
	})


func stop(request_id: int = -1) -> int:
	return _send_command("STOP", {"training_request_id": request_id})


func status() -> int:
	return _send_command("STATUS")


func shutdown() -> void:
	if _shutting_down:
		return
	_shutting_down = true
	if state == "ready":
		_send_command("SHUTDOWN")
	state = "stopping"


func force_kill() -> void:
	if process_pid > 0:
		OS.kill(process_pid)
	process_pid = -1
	state = "stopped"
	_peer = null


func is_ready() -> bool:
	return state == "ready"


func _poll_bootstrap() -> void:
	if not FileAccess.file_exists(bootstrap_path):
		if Time.get_ticks_msec() >= _bootstrap_deadline_msec:
			_fail_or_restart("worker_bootstrap_timeout", "Local training worker did not become ready")
		return
	var file := FileAccess.open(bootstrap_path, FileAccess.READ)
	if file == null:
		return
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	if not parsed is Dictionary:
		return
	var bootstrap: Dictionary = parsed
	if int(bootstrap.get("protocol_version", -1)) != PROTOCOL_VERSION:
		_fail("worker_protocol_mismatch", "Local training worker protocol mismatch")
		return
	if int(bootstrap.get("pid", -1)) != process_pid:
		_fail("worker_pid_mismatch", "Local training worker bootstrap belongs to another process")
		return
	token = str(bootstrap.get("token", ""))
	process_generation = str(bootstrap.get("process_generation", ""))
	var port := int(bootstrap.get("port", 0))
	if token == "" or process_generation == "" or port <= 0:
		_fail("worker_bootstrap_invalid", "Local training worker bootstrap is incomplete")
		return
	_peer = StreamPeerTCP.new()
	var error := _peer.connect_to_host("127.0.0.1", port)
	if error != OK:
		_fail_or_restart("worker_connect_failed", "Could not connect to local training worker")
		return
	state = "connecting"


func _poll_peer() -> void:
	if _peer == null:
		return
	_peer.poll()
	var peer_status := _peer.get_status()
	if state == "connecting" and peer_status == StreamPeerTCP.STATUS_CONNECTED:
		state = "ready"
		_restart_count = 0
		var bootstrap := _read_bootstrap_snapshot()
		worker_ready.emit(bootstrap)
	elif peer_status == StreamPeerTCP.STATUS_ERROR or peer_status == StreamPeerTCP.STATUS_NONE:
		if not _shutting_down:
			_fail_or_restart("worker_connection_lost", "Local training worker connection was lost")
		return
	var available := _peer.get_available_bytes()
	if available <= 0:
		return
	var read_result := _peer.get_data(available)
	if int(read_result[0]) != OK:
		_fail_or_restart("worker_read_failed", "Could not read local training worker response")
		return
	_feed_bytes(read_result[1])


func _send_command(command: String, payload: Dictionary = {}) -> int:
	if state != "ready" or _peer == null:
		return -1
	var request_id := _next_request_id
	_next_request_id += 1
	var packet := {
		"token": token,
		"request_id": request_id,
		"command": command,
		"payload": payload,
	}
	var frame := encode_frame(packet)
	var error := _peer.put_data(frame)
	if error != OK:
		_fail_or_restart("worker_write_failed", "Could not send local training worker command")
		return -1
	return request_id


func _feed_bytes(bytes: PackedByteArray) -> void:
	_receive_buffer.append_array(bytes)
	while true:
		if _expected_frame_bytes < 0:
			if _receive_buffer.size() < 4:
				return
			_expected_frame_bytes = (
				(int(_receive_buffer[0]) << 24)
				| (int(_receive_buffer[1]) << 16)
				| (int(_receive_buffer[2]) << 8)
				| int(_receive_buffer[3])
			)
			_receive_buffer = _receive_buffer.slice(4)
			if _expected_frame_bytes <= 0 or _expected_frame_bytes > MAX_FRAME_BYTES:
				_fail("worker_frame_invalid", "Local training worker sent an invalid frame length")
				return
		if _receive_buffer.size() < _expected_frame_bytes:
			return
		var payload := _receive_buffer.slice(0, _expected_frame_bytes)
		_receive_buffer = _receive_buffer.slice(_expected_frame_bytes)
		_expected_frame_bytes = -1
		var decoded = JSON.parse_string(payload.get_string_from_utf8())
		if not decoded is Dictionary:
			_fail("worker_packet_invalid", "Local training worker sent invalid JSON")
			return
		var packet: Dictionary = decoded
		packet_received.emit(packet)
		if str(packet.get("event", "")) == "PREPARED":
			var handle = packet.get("data", {})
			if handle is Dictionary:
				prepared.emit(handle)


static func encode_frame(packet: Dictionary) -> PackedByteArray:
	var payload := JSON.stringify(packet).to_utf8_buffer()
	var result := PackedByteArray()
	var length := payload.size()
	result.append((length >> 24) & 0xff)
	result.append((length >> 16) & 0xff)
	result.append((length >> 8) & 0xff)
	result.append(length & 0xff)
	result.append_array(payload)
	return result


func _read_bootstrap_snapshot() -> Dictionary:
	if not FileAccess.file_exists(bootstrap_path):
		return {}
	var file := FileAccess.open(bootstrap_path, FileAccess.READ)
	if file == null:
		return {}
	var parsed = JSON.parse_string(file.get_as_text())
	file.close()
	return parsed if parsed is Dictionary else {}


func _fail_or_restart(code: String, message: String) -> void:
	if _restart_count == 0 and not _shutting_down:
		_restart_count += 1
		if process_pid > 0:
			OS.kill(process_pid)
		process_pid = -1
		_peer = null
		state = "idle"
		start_warm()
		return
	_fail(code, message)


func _fail(code: String, message: String) -> void:
	state = "failed"
	_peer = null
	worker_failed.emit({"code": code, "message": message})
