extends Node

signal inference_dispatched(input, request_id: int)
signal inference_visual_repeated(input, request_id: int)
signal inference_finished(input, request_id: int)
signal inference_failed(input, request_id: int, error_data: Variant)

const FullyLocalConfigScript := preload("res://scripts/fully_local_config.gd")
const LocalTrainingWorkerScript := preload("res://scripts/local_training_worker.gd")
const RuntimeErrorMessages := preload("res://scripts/runtime_error_messages.gd")
const RemoteSessionGateCore := preload("res://scripts/auth/remote_session_gate.gd")
const FULLY_LOCAL_TRAINING := FullyLocalConfigScript.TRAINING
const RESIDENT_TRAINING_WORKER := FullyLocalConfigScript.RESIDENT_TRAINING_WORKER
const RESIDENT_TRAINING_FALLBACK := FullyLocalConfigScript.RESIDENT_TRAINING_FALLBACK
const FULLY_LOCAL_RUNTIME_ENTRY := "res://local_runtime/neuralese_local/train_entry.py"
const FULLY_LOCAL_WORKER_ENTRY := "res://local_runtime/neuralese_local/train_worker.py"
const FULLY_LOCAL_EXPORT_ENTRY := "res://local_runtime/neuralese_local/export_yolk.py"
const FULLY_LOCAL_INFER_ENTRY := "res://local_runtime/neuralese_local/infer_once.py"
const FULLY_LOCAL_INFER_LOOP_ENTRY := "res://local_runtime/neuralese_local/infer_loop.py"
const FULLY_LOCAL_PYTHON_RES := "res://local_runtime/python/python.exe"
const FULLY_LOCAL_INFER_DEBUG := true
const FULLY_LOCAL_INFER_IDLE_TIMEOUT_S := 60 * 30
const DEFAULT_INFER_WARM_RETRY_S := 1.0
const DEFAULT_INFER_WARM_FAILURE_RETRY_S := 10.0
const FULLY_LOCAL_JOB_GC_TTL_S := 60 * 60 * 24
const TRAINING_PREPARE_DEBOUNCE_MSEC := int(FullyLocalConfigScript.TRAINING_PREPARE_DEBOUNCE_S * 1000.0)
const FULLY_LOCAL_DATASET_NAMES := {
	"mnist": true,
	"cifar10": true,
	"iris": true,
	"titanic": true,
	"car_track": true,
	"eco_ai": true,
}

class LocalInferChannel:
	extends RefCounted
	var model_path: String = ""
	var graph: Dictionary = {}
	var context_id: String = ""
	var output_node_id: String = ""
	var on_close: Callable = Callable()
	var closed: bool = false
	var index: int = 0
	var pid: int = -1
	var job_dir: String = ""
	var control_path: String = ""
	var request_path: String = ""
	var response_path: String = ""
	var stop_path: String = ""
	var last_response_index: int = -1
	var last_request_msec: int = 0
	var no_response_logged: bool = false
	var parse_fail_count: int = 0
	var request_in_flight: bool = false
	var pending_data = null
	var packet_callback: Callable
	var queued_requests: Array[Dictionary] = []
	var active_request: Dictionary = {}
	var reader: Thread
	var current_request_visual: bool = false

var inference_channel_leases := {}

func _infer_log(message: String, data: Dictionary = {}) -> void:
	if not FULLY_LOCAL_INFER_DEBUG:
		return
	var suffix := ""
	if not data.is_empty():
		suffix = " " + JSON.stringify(data)
	#print("[FullyLocalInfer] " + message + suffix)


func _report_runtime_error(error_data: Variant, operation: String) -> void:
	var packet: Dictionary = error_data if error_data is Dictionary else {}
	var technical := str(packet.get("technical_message", packet.get("message", error_data)))
	var code := str(packet.get("code", operation + "_failed"))
	var details = packet.get("details", {})
	printerr("[RuntimeError] operation=%s code=%s details=%s technical=%s" % [operation, code, JSON.stringify(details), technical])
	ui.error(RuntimeErrorMessages.for_packet(packet, operation, str(glob.get_lang())))


func _report_runtime_code(code: String, operation: String, details: Dictionary = {}, technical: String = "") -> void:
	_report_runtime_error({
		"code": code,
		"details": details,
		"technical_message": technical,
	}, operation)

func _infer_input_tag(input) -> String:
	if not is_instance_valid(input):
		return "<invalid-input>"
	if not input is Graph: return str(input.name)
	return "%s graph_id=%s context=%s" % [str(input.server_typename), str(input.graph_id), str(input.context_id)]


func _infer_channel_state_dict(sock) -> Dictionary:
	if sock is LocalInferChannel:
		return {
			"type": "local",
			"pid": sock.pid,
			"seq": sock.index,
			"closed": sock.closed,
			"request_in_flight": sock.request_in_flight,
			"has_pending_data": sock.pending_data is Dictionary,
			"last_response_index": sock.last_response_index,
			"job_dir": sock.job_dir,
			"request_path": sock.request_path,
			"response_path": sock.response_path,
		}
	return {
		"type": "remote_or_unknown",
		"valid": is_instance_valid(sock),
		"class": sock.get_class() if is_instance_valid(sock) else "<invalid>",
	}


func _infer_channel_lease_summary(input) -> Array:
	if not input in inference_channel_leases:
		return []
	var leases: Dictionary = inference_channel_leases[input]
	return leases.keys()


func infer_channel_lease_summary(input) -> Array:
	return _infer_channel_lease_summary(input)


func acquire_infer_channel_lease(input, owner: String) -> bool:
	if not is_instance_valid(input) or owner == "":
		return false
	var leases: Dictionary = inference_channel_leases.get(input, {})
	leases[owner] = true
	inference_channel_leases[input] = leases
	_infer_log("lease acquired", {
		"input": _infer_input_tag(input),
		"owner": owner,
		"leases": leases.keys(),
	})
	return true


func release_infer_channel_lease(input, owner: String) -> void:
	if owner == "":
		return
	if not input in inference_channel_leases:
		return
	var leases: Dictionary = inference_channel_leases[input]
	if owner in leases:
		leases.erase(owner)
	if leases.is_empty():
		inference_channel_leases.erase(input)
	else:
		inference_channel_leases[input] = leases
	_infer_log("lease released", {
		"input": _infer_input_tag(input) if is_instance_valid(input) else str(input),
		"owner": owner,
		"remaining_leases": leases.keys(),
	})


func infer_channel_has_external_lease(input) -> bool:
	if not input in inference_channel_leases:
		return false
	var leases: Dictionary = inference_channel_leases[input]
	return not leases.is_empty()


func close_auto_infer_channel(input) -> bool:
	if infer_channel_has_external_lease(input):
		_infer_log("auto close skipped: channel leased", {
			"input": _infer_input_tag(input),
			"leases": _infer_channel_lease_summary(input),
		})
		return false
	close_infer_channel(input)
	return true


func wait_infer_channel_idle(input, owner: String = "", timeout_s: float = 5.0) -> bool:
	var start_msec := Time.get_ticks_msec()
	while input in inference_sockets:
		var sock = inference_sockets[input]
		if !(sock is LocalInferChannel):
			return true
		if not sock.request_in_flight:
			return true
		if timeout_s >= 0.0 and float(Time.get_ticks_msec() - start_msec) / 1000.0 >= timeout_s:
			_infer_log("wait idle timed out", {
				"input": _infer_input_tag(input),
				"owner": owner,
				"channel": _infer_channel_state_dict(sock),
				"leases": _infer_channel_lease_summary(input),
			})
			return false
		await get_tree().process_frame
	return true


func delete_ctx(id):
	if FULLY_LOCAL_TRAINING:
		_delete_local_ctx(str(id))
	else:
		if not glob.remote_session_ready():
			return false
		await web.POST("delete_ctx", {"user": cookies.user(), "pass": cookies.pwd(), "scene": str(glob.get_project_id()), "contexts": [str(id)]})
	return true


var local_training_jobs := {}
var _shutdown_cleanup_started := false
var _runtime_gc_accum := 0.0
var _default_infer_warm_retry_s := DEFAULT_INFER_WARM_RETRY_S
var _default_infer_warm_accum := 0.0
var _default_infer_warm_opening := false
var _default_infer_training_pause := false
var _local_training_worker
var _training_graph_generation := 0
var _training_structural_fingerprint := ""
var _training_prepared_handle: Dictionary = {}
var _training_prepare_requests := {}
var _training_prepare_in_flight := false
var _training_prepare_due_msec := 0
var _training_last_input
var _training_pending_start: Dictionary = {}
var _resident_training_jobs := {}
var _resident_start_requests := {}
var _capturing_training_snapshot := false


func _local_training_worker_state_root_abs() -> String:
	var root := ProjectSettings.globalize_path("user://fullylocal/training_worker")
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _start_local_training_worker_warm() -> void:
	if not FULLY_LOCAL_TRAINING or not RESIDENT_TRAINING_WORKER:
		return
	if not local_runtime.is_ready():
		return
	var python_path := await _local_python_path()
	var runtime_root := await _local_runtime_root_abs()
	var entry_path := await local_runtime.entry_path(FULLY_LOCAL_WORKER_ENTRY)
	if python_path == "" or runtime_root == "" or not FileAccess.file_exists(entry_path):
		push_warning("Resident local training worker is unavailable; one-shot fallback remains enabled")
		return
	_local_training_worker = LocalTrainingWorkerScript.new()
	_local_training_worker.worker_ready.connect(_on_local_training_worker_ready)
	_local_training_worker.packet_received.connect(_on_local_training_worker_packet)
	_local_training_worker.worker_failed.connect(_on_local_training_worker_failed)
	_local_training_worker.configure(
		python_path,
		entry_path,
		runtime_root,
		_local_training_worker_state_root_abs(),
		OS.get_process_id()
	)
	_local_training_worker.start_warm()


static func _training_canonical_value(value: Variant) -> Variant:
	if value is Dictionary:
		var source: Dictionary = value
		var keys := source.keys()
		keys.sort_custom(func(a, b): return str(a) < str(b))
		var result := {}
		for key in keys:
			if str(key) in ["epochs", "batch_size", "lr", "learning_rate", "job_dir", "checkpoint_dir", "parent_pid", "path_class"]:
				continue
			if str(key)=="config" and source.get("op","")=="text_input":
				var config: Dictionary=source[key].duplicate()
				config.erase("text")
				result[str(key)]=_training_canonical_value(config)
			else: result[str(key)] = _training_canonical_value(source[key])
		return result
	if value is Array:
		var result: Array = []
		for item in value:
			result.append(_training_canonical_value(item))
		return result
	return value


static func training_structural_fingerprint(payload: Dictionary) -> String:
	var structural := {
		"graph": payload.get("language_graph",payload.get("graph", {})),
		"dataset_inline":payload.get("dataset_inline",{}),
		"train_graph": payload.get("train_graph", {}),
		"dataset_ref": payload.get("dataset_ref", {}),
	}
	return JSON.stringify(_training_canonical_value(structural)).sha256_text()


func _on_training_snapshot_invalidated(_reason: String) -> void:
	for jobs in [local_training_jobs,_resident_training_jobs]:
		for head in jobs.keys():
			var job: Dictionary=jobs[head]
			if not job.get("language",false): continue
			var source=job.get("source")
			if not is_instance_valid(source): stop_train(head); continue
			var current := training_structural_fingerprint({"language_graph":graphs.LanguageAdapter.collect(source)})
			if current!=str(job.get("model_fingerprint",current)):
				stop_train(head)
				source.controller.end_training()
	if not FULLY_LOCAL_TRAINING or not RESIDENT_TRAINING_WORKER:
		return
	if _capturing_training_snapshot:
		return
	if not is_instance_valid(_training_last_input) and is_instance_valid(graphs._training_head):
		_training_last_input = graphs._training_head
	if not is_instance_valid(_training_last_input):
		return
	_training_prepare_due_msec = Time.get_ticks_msec() + TRAINING_PREPARE_DEBOUNCE_MSEC


func _on_local_training_worker_ready(_bootstrap: Dictionary) -> void:
	if not is_instance_valid(_training_last_input) and is_instance_valid(graphs._training_head):
		_training_last_input = graphs._training_head
	if is_instance_valid(_training_last_input):
		_training_prepare_due_msec = Time.get_ticks_msec() + TRAINING_PREPARE_DEBOUNCE_MSEC


func _on_local_training_worker_failed(details: Dictionary) -> void:
	push_warning("Resident local training worker failed: " + JSON.stringify(details))
	_training_prepare_in_flight = false
	_training_prepare_requests.clear()
	_training_prepared_handle.clear()
	if not _training_pending_start.is_empty():
		_fallback_pending_training.call_deferred(details)
	for train_input in _resident_training_jobs.keys():
		var job: Dictionary = _resident_training_jobs[train_input]
		_handle_train_state_dict({"phase": "error", "error": details}, job.get("additional", glob.def), job.get("training_head", null))
		_finalize_local_training_job(job)
	_resident_training_jobs.clear()
	_resident_start_requests.clear()
	_default_infer_training_pause = false
	_request_default_infer_warm()


func _resident_dataset_ref(ds_name: String, report_errors: bool = true) -> Dictionary:
	if FULLY_LOCAL_DATASET_NAMES.has(ds_name):
		return {"kind": "builtin_numpy", "name": ds_name}
	var dataset_payload := _local_dataset_to_training_json(ds_name)
	if not dataset_payload.get("ok", false):
		if report_errors:
			_report_runtime_code(
				str(dataset_payload.get("error_code", "training_failed")),
				"training",
				dataset_payload.get("details", {"dataset": ds_name}),
				"Could not prepare local dataset: " + ds_name
			)
		return {}
	dataset_payload.erase("ok")
	var serialized := JSON.stringify(dataset_payload)
	var revision := serialized.sha256_text()
	var datasets_root := _local_training_worker_state_root_abs().path_join("datasets")
	var dataset_path := datasets_root.path_join(revision + ".json")
	if not FileAccess.file_exists(dataset_path) and not _write_json(dataset_path, dataset_payload):
		if report_errors:
			_report_runtime_code("runtime_data_write_failed", "training", {}, "Could not write local dataset payload: " + dataset_path)
		return {}
	return {
		"kind": "godot_json",
		"name": ds_name,
		"path": dataset_path,
		"revision": revision,
	}


func _resident_prepare_request(prepared: Dictionary, report_errors: bool = true) -> Dictionary:
	var train_input_origin: Graph = prepared.get("train_input_origin")
	if not is_instance_valid(train_input_origin):
		return {}
	var ds_name: String = train_input_origin.dataset_meta.get("name", "")
	if not _is_fully_local_dataset(ds_name) and not prepared.payload.has("language_graph"):
		if report_errors:
			var dataset_code := "dataset_not_selected" if ds_name == "" else "dataset_unavailable"
			_report_runtime_code(dataset_code, "training", {"dataset": ds_name}, _fully_local_dataset_error(ds_name))
		return {}
	var dataset_ref := {"kind":"inline","name":ds_name} if prepared.payload.has("language_graph") else _resident_dataset_ref(ds_name, report_errors)
	if dataset_ref.is_empty():
		return {}
	var payload: Dictionary = prepared["payload"].duplicate(true)
	payload["dataset_ref"] = dataset_ref
	payload["runtime_root"] = await _local_runtime_root_abs()
	payload["job_dir"] = _local_training_worker_state_root_abs().path_join("prepared")
	payload["checkpoint_dir"] = _local_context_dir_abs(prepared["execute_input_origin"].context_id)
	payload["local_mode"] = "fullylocal_ort"
	payload["parent_pid"] = OS.get_process_id()
	payload.erase("local")
	return payload


func _prepare_resident_snapshot(train_input, prepared: Dictionary, queued_start: Dictionary = {}) -> bool:
	if _local_training_worker == null or not _local_training_worker.is_ready():
		return false
	var request := await _resident_prepare_request(prepared, not queued_start.is_empty())
	if request.is_empty():
		return false
	var fingerprint := training_structural_fingerprint(request)
	if fingerprint != _training_structural_fingerprint:
		_training_graph_generation += 1
		_training_structural_fingerprint = fingerprint
		_training_prepared_handle.clear()
	request["graph_generation"] = _training_graph_generation
	if not queued_start.is_empty():
		_training_pending_start = queued_start
		_training_pending_start["generation"] = _training_graph_generation
		_training_pending_start["fingerprint"] = fingerprint
		_training_pending_start["worker_request"] = request
	if not _training_prepared_handle.is_empty() \
		and int(_training_prepared_handle.get("graph_generation", -1)) == _training_graph_generation \
		and str(_training_prepared_handle.get("fingerprint", "")) == fingerprint:
		if not queued_start.is_empty():
			return _start_resident_prepared(_training_pending_start)
		return true
	if _training_prepare_in_flight:
		return true
	var request_id: int = int(_local_training_worker.prepare(request))
	if request_id < 0:
		return false
	_training_prepare_in_flight = true
	_training_prepare_requests[request_id] = {
		"generation": _training_graph_generation,
		"fingerprint": fingerprint,
		"train_input": train_input,
	}
	return true


func _start_resident_prepared(pending: Dictionary) -> bool:
	if pending.is_empty() or _training_prepared_handle.is_empty():
		return false
	if int(pending.get("generation", -1)) != int(_training_prepared_handle.get("graph_generation", -2)):
		return false
	var prepared: Dictionary = pending["prepared"]
	var run_config: Dictionary = pending.get("worker_request", {}).duplicate(true)
	var job_dir := _make_local_training_job_dir()
	run_config["job_dir"] = job_dir
	run_config["checkpoint_dir"] = _local_context_dir_abs(prepared["execute_input_origin"].context_id)
	run_config["graph_generation"] = int(_training_prepared_handle["graph_generation"])
	var request_id: int = int(_local_training_worker.start_prepared(_training_prepared_handle, run_config))
	if request_id < 0:
		_finalize_local_training_job({"dir": job_dir})
		return false
	var train_input = pending["train_input"]
	var job := {
		"worker_request_id": request_id,
		"dir": job_dir,
		"additional": pending.get("additional", glob.def),
		"train_input_origin": prepared["train_input_origin"],
		"training_head": train_input,
		"acked": false,
		"fallback_started": false,
		"prepared": prepared,
	}
	if prepared.payload.has("language_graph"):
		prepared.execute_input_origin.controller.begin_training()
		job["language"]=true
		job["source"]=prepared.execute_input_origin
		job["model_fingerprint"]=training_structural_fingerprint({"language_graph":prepared.payload.language_graph})
	_resident_training_jobs[train_input] = job
	_resident_start_requests[request_id] = train_input
	_training_pending_start.clear()
	return true


func _fallback_pending_training(details: Dictionary = {}) -> void:
	if _training_pending_start.is_empty():
		return
	var pending := _training_pending_start
	_training_pending_start = {}
	if pending.get("fallback_started", false):
		return
	pending["fallback_started"] = true
	if not RESIDENT_TRAINING_FALLBACK:
		_report_runtime_error(details, "training")
		_default_infer_training_pause = false
		return
	var started := await _start_train_fully_local(pending["train_input"], pending["prepared"], pending.get("additional", glob.def))
	if not started:
		_default_infer_training_pause = false
		_request_default_infer_warm()


func _on_local_training_worker_packet(packet: Dictionary) -> void:
	var request_id := int(packet.get("request_id", -1))
	var event := str(packet.get("event", ""))
	if _training_prepare_requests.has(request_id):
		var info: Dictionary = _training_prepare_requests[request_id]
		_training_prepare_requests.erase(request_id)
		_training_prepare_in_flight = false
		if event == "PREPARED":
			var handle: Dictionary = packet.get("data", {}).duplicate(true)
			if int(info.get("generation", -1)) != _training_graph_generation:
				_schedule_speculative_training_prepare()
				return
			handle["fingerprint"] = info.get("fingerprint", "")
			_training_prepared_handle = handle
			if not _training_pending_start.is_empty() and int(_training_pending_start.get("generation", -1)) == _training_graph_generation:
				if not _start_resident_prepared(_training_pending_start):
					_fallback_pending_training.call_deferred({"code": "prepared_start_failed"})
		elif not _training_pending_start.is_empty():
			_fallback_pending_training.call_deferred(packet.get("error", packet))
		return
	if not _resident_start_requests.has(request_id):
		return
	var train_input = _resident_start_requests[request_id]
	var job: Dictionary = _resident_training_jobs.get(train_input, {})
	if job.is_empty():
		return
	if event == "ACK":
		job["acked"] = true
		_resident_training_jobs[train_input] = job
		return
	if event == "PROGRESS":
		var lifecycle = packet.get("data", {})
		if lifecycle is Dictionary:
			_handle_train_state_dict(lifecycle, job.get("additional", glob.def), job.get("training_head", null))
			if str(lifecycle.get("phase", "")) in ["done", "stopped", "error"]:
				_finish_resident_training_job(train_input, job)
		return
	if event == "ERROR":
		if not job.get("acked", false) and not job.get("fallback_started", false):
			job["fallback_started"] = true
			_resident_training_jobs.erase(train_input)
			_resident_start_requests.erase(request_id)
			_training_pending_start = {
				"train_input": train_input,
				"prepared": job["prepared"],
				"additional": job.get("additional", glob.def),
			}
			_finalize_local_training_job(job)
			_fallback_pending_training.call_deferred(packet.get("error", packet))
		else:
			_handle_train_state_dict({"phase": "error", "error": packet.get("error", packet)}, job.get("additional", glob.def), job.get("training_head", null))
			_finish_resident_training_job(train_input, job)


func _finish_resident_training_job(train_input, job: Dictionary) -> void:
	_resident_training_jobs.erase(train_input)
	_resident_start_requests.erase(int(job.get("worker_request_id", -1)))
	_finalize_local_training_job(job)
	_default_infer_training_pause = false
	_request_default_infer_warm()
	_schedule_speculative_training_prepare()


func _schedule_speculative_training_prepare() -> void:
	if is_instance_valid(_training_last_input):
		_training_prepare_due_msec = Time.get_ticks_msec() + TRAINING_PREPARE_DEBOUNCE_MSEC


func _run_speculative_training_prepare() -> void:
	if _training_prepare_in_flight or not _resident_training_jobs.is_empty():
		_schedule_speculative_training_prepare()
		return
	if _local_training_worker == null or not _local_training_worker.is_ready() or not is_instance_valid(_training_last_input):
		return
	var prepared = _build_train_payload(_training_last_input, false)
	if prepared is Dictionary:
		await _prepare_resident_snapshot(_training_last_input, prepared)

func _request_default_infer_warm() -> void:
	if not FULLY_LOCAL_TRAINING:
		return
	_default_infer_warm_accum = _default_infer_warm_retry_s

func _tick_default_infer_warm(delta: float) -> void:
	if not FULLY_LOCAL_TRAINING:
		return
	if not bool(glob.AUTO_INPUT_INFERENCE_ENABLED):
		return
	if _default_infer_training_pause or _default_infer_warm_opening or not local_training_jobs.is_empty() or not _resident_training_jobs.is_empty():
		return
	var input: Graph = graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME)
	if not is_instance_valid(input) or is_infer_channel(input):
		return
	_default_infer_warm_accum += delta
	if _default_infer_warm_accum < _default_infer_warm_retry_s:
		return
	_default_infer_warm_accum = 0.0
	_default_infer_warm_opening = true
	_open_default_infer_warm.call_deferred()

func _open_default_infer_warm() -> void:
	var input: Graph = graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME)
	if not is_instance_valid(input) or is_infer_channel(input):
		_default_infer_warm_opening = false
		return
	if _default_infer_training_pause or not local_training_jobs.is_empty() or not _resident_training_jobs.is_empty():
		_default_infer_warm_opening = false
		return
	if not local_runtime.is_ready():
		_default_infer_warm_opening = false
		return
	if not validate_infer_channel(input):
		_default_infer_warm_opening = false
		return
	var entry_path := await _local_infer_loop_entry_abs()
	if not FileAccess.file_exists(entry_path):
		_infer_log("default warm skipped: missing local loop entry", {"entry_path": entry_path})
		_default_infer_warm_opening = false
		_default_infer_warm_retry_s = DEFAULT_INFER_WARM_FAILURE_RETRY_S
		return
	var on_close := glob.def
	if input.has_method("close_runner"):
		on_close = Callable(input, "close_runner")
	_infer_log("default warm open begin", {"input": _infer_input_tag(input)})
	var opened = await open_infer_channel(input, on_close)
	_default_infer_warm_opening = false
	if opened:
		_default_infer_warm_retry_s = DEFAULT_INFER_WARM_RETRY_S
		_infer_log("default warm open complete", {"input": _infer_input_tag(input)})
	else:
		_default_infer_warm_retry_s = DEFAULT_INFER_WARM_FAILURE_RETRY_S
		_infer_log("default warm open failed", {"input": _infer_input_tag(input)})

func _ready() -> void:
	if not graphs.training_snapshot_invalidated.is_connected(_on_training_snapshot_invalidated):
		graphs.training_snapshot_invalidated.connect(_on_training_snapshot_invalidated)
	await local_runtime.ensure_ready()
	_gc_fully_local_runtime_dirs(true)
	_start_local_training_worker_warm.call_deferred()
	await glob.wait(1, true)
	DisplayServer.window_set_title("Neuralese")
	_request_default_infer_warm()

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		close_all(true)
		if what == NOTIFICATION_WM_CLOSE_REQUEST and is_inside_tree():
			get_tree().quit()

func _handle_train_state_dict(dict: Dictionary, additional: Callable, training_head: Graph = null):
	if not dict.has("phase"):
		return
	if is_instance_valid(training_head): _apply_training_visualization(training_head,dict)
	additional.call(dict)
	if dict["phase"] == "error":
		var error_data = dict.get("error", {})
		_report_runtime_error(error_data, "training")
		var head_to_stop = training_head if is_instance_valid(training_head) else graphs._training_head
		if is_instance_valid(head_to_stop):
			head_to_stop.train_stop()
		return
	if dict["phase"] == "state":
		if dict["data"]["type"] == "complete":
			var head_to_stop = training_head if is_instance_valid(training_head) else graphs._training_head
			head_to_stop.train_stop()
			return
		var data = dict["data"]["data"]
		var acc = data["val_acc"]
		var head_to_update = training_head if is_instance_valid(training_head) else graphs._training_head
		if is_instance_valid(head_to_update):
			if head_to_update.has_method("push_acceptance"):
				head_to_update.push_acceptance(acc, 0.0)

func _apply_training_visualization(head: Graph, packet: Dictionary) -> void:
	var runner=graphs._reach_input(head,"RunModel")
	var source=runner.language_source() if is_instance_valid(runner) and runner.has_method("language_source") else null
	if not is_instance_valid(source): return
	if packet.has("visualization") and packet.get("source_text","")==str(source.cfg.get("text","")):
		if str(source.cfg.get("text","")).strip_edges().is_empty(): source.controller.clear_training_snapshot()
		else: source.controller.apply_training_snapshot(packet.visualization)
	if packet.get("phase","") in ["done","stopped","error"]:
		source.controller.end_training()
		if packet.has("result"): runner.language_preparation=packet.result

func train_state_received(bytes: PackedByteArray, additional: Callable):
	var jsonified = bytes.get_string_from_utf8()
	var dict = JSON.parse_string(jsonified)
	if not dict: return
	if !(dict is Dictionary): return
	_handle_train_state_dict(dict, additional)



func request_save():
	for g in graphs._graphs:
		var node = graphs._graphs[g]
		if is_instance_valid(node) and node.has_method("request_save"):
			node.request_save()

func ws_ds_frames(train_input_origin, initial: Dictionary, ws: SocketConnection) -> void:
	if FULLY_LOCAL_TRAINING:
		push_warning("Skipping websocket dataset frames because FullyLocal training is enabled.")
		return
	var ds_name = train_input_origin.dataset_meta.get("name", "")
	if ds_name == "":
		push_warning("No dataset name found.")
		return
	if not glob.rle_cache.has(ds_name):
		push_warning("Dataset not yet compressed or cached.")
		return

	await glob.join_ds_processing()
	DsObjRLE.flush_now(ds_name, glob.dataset_datas[ds_name])
	#(DsObjProbe.probe_dataset(ds_name))

	var ds: Dictionary = glob.rle_cache[ds_name]
	var inputs: Array = ds["data"][0]
	var outputs: Array = ds["data"][1]
	var header: Dictionary = ds["header"]

	var block_hashes := {"inputs": [], "outputs": []}
	for col in inputs:
		block_hashes["inputs"].append(col.get("hashes", []))
	for col in outputs:
		block_hashes["outputs"].append(col.get("hashes", []))

	initial["session"] = cookies.user()
	initial["header"] = header
	initial["header"]["name"] = ds_name
	initial["block_hashes"] = block_hashes
	initial["hash_algo"] = "sha256"

	# --- send header ---
	var header_bytes = glob.compress_dict_zstd(initial)
	ws.send(header_bytes)
	#("[WS] Sent compressed header (%.2f KB)" % [float(header_bytes.size()) / 1024.0])

	var stats := {
		"total_bytes": 0.0,
		"total_blocks": 0,
		"side_bytes": {"inputs": 0.0, "outputs": 0.0}
	}

	### FIX: add dataset upload phase state flag
	var ds_phase_done := false

	var _on_packet: Callable
	_on_packet = func(data: PackedByteArray) -> void:
		# --- ignore if already done ---
		if ds_phase_done:
			return

		var text := data.get_string_from_utf8()
		if text == "__end__":
			return

		var parsed = JSON.parse_string(text)
		if typeof(parsed) != TYPE_DICTIONARY:
			# not JSON or not a dict — ignore
			return

		### FIX: only react to valid NEED payloads
		if not (parsed.has("inputs") or parsed.has("outputs")):
			return

		var need: Dictionary = parsed

		var _send_block = func(side: String, col_i: int, blk_i: int, blk_data: PackedByteArray) -> void:
			var meta := {"side": side, "col": col_i, "blk": blk_i}
			var meta_bytes := JSON.stringify(meta).to_utf8_buffer()

			var frame := PackedByteArray()
			frame.append((meta_bytes.size() >> 8) & 0xFF)
			frame.append(meta_bytes.size() & 0xFF)
			frame.append_array(meta_bytes)
			frame.append_array(blk_data)

			ws.send(frame)

			var bytes_sent = float(frame.size())
			stats["total_bytes"] += bytes_sent
			stats["total_blocks"] += 1
			stats["side_bytes"][side] += bytes_sent

			#if int(stats["total_blocks"]) % 50 == 0:
				#("[WS] Sent %d blocks (%.2f KB so far)" % [
				#	int(stats["total_blocks"]), stats["total_bytes"] / 1024.0
				#])

		# --- transmit all requested blocks ---
		for side in ["inputs", "outputs"]:
			if not need.has(side):
				continue
			var cols_arr := (inputs if side == "inputs" else outputs)
			for col_key in need[side].keys():
				var col_i := int(col_key)
				var missing: Array = need[side][col_key]
				if missing.is_empty():
					continue
				var col_data: Dictionary = cols_arr[col_i]
				var blocks: Array = col_data.get("blocks", [])
				for blk_i in missing:
					if blk_i >= 0 and blk_i < blocks.size():
						var blk_data: PackedByteArray = blocks[blk_i]
						_send_block.call(side, col_i, blk_i, blk_data)

		# --- end transmission ---
		ws.send("__end__".to_utf8_buffer())

		#("[WS] Sent all missing dataset blocks to server.")
		#("[WS] Blocks sent: %d  |  Total bytes: %.2f KB (%.2f MB)" %
		#	[int(stats["total_blocks"]), stats["total_bytes"] / 1024.0, stats["total_bytes"] / 1024.0 / 1024.0])
		#("[WS] Inputs: %.2f KB   Outputs: %.2f KB" %
		#	[stats["side_bytes"]["inputs"] / 1024.0, stats["side_bytes"]["outputs"] / 1024.0])

		### FIX: disconnect after sending once
		ds_phase_done = true
		if ws.packet.is_connected(_on_packet):
			ws.packet.disconnect(_on_packet)

	ws.packet.connect(_on_packet)







func try_print(train_input):
	if not is_instance_valid(train_input):
		return
	var train_input_origin = graphs._reach_input(train_input, "TrainBegin")
	if not is_instance_valid(train_input_origin):
		return
	var execute_input_origin = null
	var _d = {}
	var cachify = func(from: Connection, to: Connection, branch_cache: Dictionary):
		if to.parent_graph.server_typename == "RunModel":
			assert(not _d.get("input"), "compile failed, run_model node >1 times banned")

			_d["input"] = graphs.get_input_graph_by_name(to.parent_graph.name_graph)
	#var all =
	#(train_input_origin)
	graphs.reach(train_input_origin, cachify)
	execute_input_origin = _d["input"]
	#if !is_instance_valid(train_input_origin) or !execute_input_origin: return false
	#print({		"graph": graphs.get_syntax_tree(execute_input_origin),
	#		"train_graph": graphs.get_syntax_tree(train_input_origin),})


var training_sockets = {}
func _build_train_payload(train_input, report_errors: bool = true):
	if not is_instance_valid(train_input) or not is_instance_valid(graphs._reach_input(train_input, "TrainBegin")):
		if report_errors:
			_report_runtime_code("training_graph_invalid", "training", {}, "Training graph has no valid training root")
		return false
	var runner=graphs._reach_input(train_input,"RunModel")
	var source=runner.language_source() if is_instance_valid(runner) and runner.has_method("language_source") else null
	if is_instance_valid(source):
		var origin=graphs._reach_input(train_input,"TrainBegin")
		var payload={"language_graph":graphs.LanguageAdapter.collect(source),"dataset_inline":origin.dataset_meta,"epochs":origin.epochs,"text":str(source.cfg.get("text",""))}
		return {"train_input_origin":origin,"execute_input_origin":source,"payload":payload,"tdata":{}}
	if not check_valid(train_input, true):
		if report_errors:
			_report_runtime_code("training_graph_invalid", "training", {}, "Training graph validation failed")
		return false
	var train_input_origin = graphs._reach_input(train_input, "TrainBegin")
	var execute_input_origin = null
	var _d = {}
	var cachify = func(from: Connection, to: Connection, branch_cache: Dictionary):
		if to.parent_graph.server_typename == "RunModel":
			assert(not _d.get("input"), "compile failed, run_model node >1 times banned")

			_d["input"] = graphs.get_input_graph_by_name(to.parent_graph.name_graph)
	#var all =
	#(train_input_origin)
	graphs.reach(train_input_origin, cachify)
	execute_input_origin = _d["input"]
	if !is_instance_valid(train_input_origin) or !execute_input_origin:
		if report_errors:
			_report_runtime_code("training_graph_invalid", "training", {}, "Training graph has no valid training or execution root")
		return false
	if not train_input_origin.dataset_meta or not train_input_origin.dataset_meta.get("name", ""):
		if report_errors:
			_report_runtime_code("dataset_not_selected", "training")
		return false
	if not check_valid(execute_input_origin, false):
		if report_errors:
			_report_runtime_code("training_graph_invalid", "training", {}, "Model graph validation failed")
		return false
	_capturing_training_snapshot = true
	request_save()
	_capturing_training_snapshot = false
	var tdata = train_input_origin.get_training_data()
	var compressed = ({
		"session": "neriqward",
		"graph": graphs.get_syntax_tree(execute_input_origin),
		"train_graph": graphs.get_syntax_tree(train_input_origin),
		"scene_id": str(glob.get_project_id()),
		"context": str(execute_input_origin.context_id),
	}.merged(tdata))
	return {
		"train_input_origin": train_input_origin,
		"execute_input_origin": execute_input_origin,
		"tdata": tdata,
		"payload": compressed,
	}

func _is_fully_local_dataset(ds_name: String) -> bool:
	return FULLY_LOCAL_TRAINING and ds_name != "" and (FULLY_LOCAL_DATASET_NAMES.has(ds_name) or glob.dataset_datas.has(ds_name))

func _fully_local_dataset_error(ds_name: String) -> String:
	if ds_name == "":
		return "No dataset is selected."
	if FULLY_LOCAL_DATASET_NAMES.has(ds_name):
		return ""
	if glob.dataset_datas.has(ds_name):
		return ""
	return "FullyLocal training can use builtin datasets or datasets created in this project. Dataset '%s' is not available locally." % ds_name

func _ensure_local_runtime_ready(operation: String = "training") -> bool:
	if OS.has_feature("editor") and FileAccess.file_exists(OS.get_environment("NEURALESE_LANGUAGE_PYTHON")): return true
	if local_runtime.is_ready():
		return true
	_report_runtime_code("runtime_unavailable", operation, {}, local_runtime.last_error())
	return false

func _local_runtime_root_abs() -> String:
	var root = await local_runtime.runtime_root_abs()
	return root if root != "" else ProjectSettings.globalize_path("res://local_runtime")

func _local_runtime_entry_abs() -> String:
	return ProjectSettings.globalize_path(FULLY_LOCAL_RUNTIME_ENTRY) if OS.has_feature("editor") and OS.get_environment("NEURALESE_LANGUAGE_PYTHON")!="" else await local_runtime.entry_path(FULLY_LOCAL_RUNTIME_ENTRY)

func _local_export_entry_abs() -> String:
	return await local_runtime.entry_path(FULLY_LOCAL_EXPORT_ENTRY)

func _local_infer_entry_abs() -> String:
	return await local_runtime.entry_path(FULLY_LOCAL_INFER_ENTRY)

func _local_infer_loop_entry_abs() -> String:
	return await local_runtime.entry_path(FULLY_LOCAL_INFER_LOOP_ENTRY)

func _local_checkpoint_root_abs() -> String:
	var root = ProjectSettings.globalize_path("user://fullylocal/checkpoints").path_join(str(glob.get_project_id()))
	DirAccess.make_dir_recursive_absolute(root)
	return root

func _local_context_dir_abs(context_id) -> String:
	return _local_checkpoint_root_abs().path_join(str(context_id))

func _local_inference_model_path(context_id) -> String:
	return _local_context_dir_abs(context_id).path_join("inference.onnx")

func _normalize_abs_path(path: String) -> String:
	return path.replace("\\", "/").rstrip("/")

func _path_is_under(path: String, root: String) -> bool:
	var normalized_path := _normalize_abs_path(path)
	var normalized_root := _normalize_abs_path(root)
	return normalized_path == normalized_root or normalized_path.begins_with(normalized_root + "/")

func _remove_dir_recursive_abs(path: String, allowed_roots: Array = []) -> bool:
	if allowed_roots.is_empty():
		allowed_roots = [_local_checkpoint_root_abs()]
	var allowed := false
	for root in allowed_roots:
		if _path_is_under(path, str(root)):
			allowed = true
			break
	if not allowed:
		push_warning("Refusing to remove local runtime directory outside allowed roots: " + path)
		return false
	if not DirAccess.dir_exists_absolute(path):
		return true
	var dir := DirAccess.open(path)
	if not dir:
		return false
	for file_name in dir.get_files():
		dir.remove(file_name)
	for dir_name in dir.get_directories():
		_remove_dir_recursive_abs(path.path_join(dir_name), allowed_roots)
	var parent := DirAccess.open(path.get_base_dir())
	if parent:
		parent.remove(path.get_file())
	return true

func _delete_local_ctx(context_id: String) -> void:
	_remove_dir_recursive_abs(_local_context_dir_abs(context_id))

func _fully_local_jobs_root_abs() -> String:
	var root = ProjectSettings.globalize_path("user://fullylocal/jobs")
	DirAccess.make_dir_recursive_absolute(root)
	return root

func _fully_local_infer_root_abs() -> String:
	var root = ProjectSettings.globalize_path("user://fullylocal/infer")
	DirAccess.make_dir_recursive_absolute(root)
	return root

func _fully_local_exports_root_abs() -> String:
	var root = ProjectSettings.globalize_path("user://fullylocal/exports")
	DirAccess.make_dir_recursive_absolute(root)
	return root

func _kill_pid(pid: int, reason: String = "") -> void:
	if pid <= 0:
		return
	var err = OS.kill(pid)
	if err != OK and err != ERR_DOES_NOT_EXIST:
		push_warning("Could not kill local runtime process %s (%s): %s" % [str(pid), reason, str(err)])

func _job_timestamp_from_name(name: String) -> float:
	var parts := name.split("_", false)
	if parts.is_empty():
		return 0.0
	return float(parts[0])

func _gc_fully_local_runtime_dirs(startup: bool = false) -> void:
	if not FULLY_LOCAL_TRAINING:
		return
	var infer_root := _fully_local_infer_root_abs()
	var jobs_root := _fully_local_jobs_root_abs()
	if startup:
		_remove_dir_recursive_abs(infer_root, [infer_root])
		DirAccess.make_dir_recursive_absolute(infer_root)
	var now := Time.get_unix_time_from_system()
	var jobs := DirAccess.open(jobs_root)
	if jobs:
		for dir_name in jobs.get_directories():
			var stamp := _job_timestamp_from_name(dir_name)
			if stamp <= 0.0 or now - stamp > FULLY_LOCAL_JOB_GC_TTL_S:
				_remove_dir_recursive_abs(jobs_root.path_join(dir_name), [jobs_root])

func _local_python_path() -> String:
	var override := OS.get_environment("NEURALESE_LANGUAGE_PYTHON") if OS.has_feature("editor") else ""
	if override!="": return override
	var bootstrap_python := await local_runtime.python_path()
	if bootstrap_python != "":
		return bootstrap_python
	var candidates := []
	candidates.append(ProjectSettings.globalize_path(FULLY_LOCAL_PYTHON_RES))
	candidates.append(ProjectSettings.globalize_path("res://local_runtime/python/Scripts/python.exe"))
	candidates.append(OS.get_executable_path().get_base_dir().path_join("local_runtime").path_join("python").path_join("python.exe"))
	candidates.append(OS.get_executable_path().get_base_dir().path_join("local_runtime").path_join("python").path_join("Scripts").path_join("python.exe"))
	candidates.append(OS.get_executable_path().get_base_dir().path_join("python").path_join("python.exe"))
	for candidate in candidates:
		if FileAccess.file_exists(candidate):
			return candidate
	return "python"

func _make_local_training_job_dir() -> String:
	var jobs_root = _fully_local_jobs_root_abs()
	var job_id = "%s_%s" % [str(Time.get_unix_time_from_system()), str(randi())]
	var job_dir = jobs_root.path_join(job_id)
	DirAccess.make_dir_recursive_absolute(job_dir)
	return job_dir

func _write_json(path: String, data: Dictionary) -> bool:
	return _write_json_atomic(path, data)

func _write_json_atomic(path: String, data: Dictionary) -> bool:
	var parent := path.get_base_dir()
	if parent != "" and DirAccess.make_dir_recursive_absolute(parent) != OK:
		push_warning("Could not create local runtime directory: " + parent)
		return false
	var tmp_path := "%s.tmp.%s.%s.%s" % [path, str(OS.get_process_id()), str(Time.get_ticks_usec()), str(randi())]
	var wrote_temp := false
	# Windows can temporarily deny a newly-created file while Defender or another
	# process inspects it. Retry the open itself; the former code retried only
	# publishing a file that had already been opened successfully.
	for attempt in range(3):
		var f = FileAccess.open(tmp_path, FileAccess.WRITE)
		if f:
			f.store_string(JSON.stringify(data, "\t"))
			f.flush()
			f.close()
			wrote_temp = true
			break
		OS.delay_msec(8 * (attempt + 1))
	if not wrote_temp:
		push_warning("Could not write local runtime temp file: " + tmp_path)
		return false
	for attempt in range(5):
		var rename_err := DirAccess.rename_absolute(tmp_path, path)
		if rename_err == OK:
			return true
		if FileAccess.file_exists(path):
			var remove_err := DirAccess.remove_absolute(path)
			if remove_err != OK and remove_err != ERR_DOES_NOT_EXIST:
				continue
			rename_err = DirAccess.rename_absolute(tmp_path, path)
			if rename_err == OK:
				return true
	push_warning("Could not publish local runtime file after retries: " + path)
	DirAccess.remove_absolute(tmp_path)
	return false

func local_export_extension(platform: String) -> String:
	match platform:
		"windows":
			return ".exe"
		"linux":
			return ""
		"onnx":
			return ".onnx"
		"microbit", "ev3", "spike":
			# A robot export is a folder, not a file. See export_robot_bundle().
			return ""
		_:
			return ".bin"

func can_export_fully_local(input) -> bool:
	return FULLY_LOCAL_TRAINING and is_instance_valid(input) and FileAccess.file_exists(_local_inference_model_path(input.context_id))

func _copy_file_abs(from_path: String, to_path: String) -> Dictionary:
	var in_file = FileAccess.open(from_path, FileAccess.READ)
	if not in_file:
		return {"status": "error", "error": "Could not open source file: " + from_path}
	var bytes := in_file.get_buffer(in_file.get_length())
	in_file.close()
	var parent_dir := to_path.get_base_dir()
	if parent_dir != "":
		DirAccess.make_dir_recursive_absolute(parent_dir)
	var out_file = FileAccess.open(to_path, FileAccess.WRITE)
	if not out_file:
		return {"status": "error", "error": "Could not open output file: " + to_path}
	out_file.store_buffer(bytes)
	out_file.close()
	if not FileAccess.file_exists(to_path):
		return {"status": "error", "error": "Export did not create output file: " + to_path}
	var verify = FileAccess.open(to_path, FileAccess.READ)
	var written_size := verify.get_length() if verify else 0
	if verify:
		verify.close()
	if written_size <= 0:
		return {"status": "error", "error": "Export wrote an empty output file: " + to_path}
	return {"status": "ok", "platform": "onnx", "output_path": to_path, "bytes": written_size}

func _run_local_export_process(args: Array) -> Dictionary:
	var python_path: String = args[0]
	var entry_path: String = args[1]
	var request_path: String = args[2]
	var response_path: String = args[3]
	var output := []
	var exit_code := OS.execute(python_path, [entry_path, request_path], output, true, false)
	if exit_code != 0:
		var err_text := ""
		for line in output:
			err_text += str(line) + "\n"
		var parsed_err = JSON.parse_string(FileAccess.get_file_as_string(response_path)) if FileAccess.file_exists(response_path) else null
		if parsed_err is Dictionary:
			return parsed_err
		return {"status": "error", "error": "FullyLocal export failed: " + err_text}
	if not FileAccess.file_exists(response_path):
		return {"status": "error", "error": "FullyLocal export finished without response.json."}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(response_path))
	if parsed is Dictionary:
		return parsed
	return {"status": "error", "error": "FullyLocal export returned invalid response."}

func export_fully_local_model(input, platform: String, quant: String, output_path: String) -> Dictionary:
	if is_instance_valid(input) and graphs.LanguageAdapter.is_language(input):
		return {"status":"error", "error":"Language demo graphs cannot be exported as trained models.", "code":"language_demo_only"}
	if not FULLY_LOCAL_TRAINING:
		return {"status": "error", "error": "FullyLocal mode is disabled."}
	if not is_instance_valid(input):
		return {"status": "error", "error": "No model input graph selected."}
	if platform == "tensorrt":
		return {"status": "error", "error": "FullyLocal executable export supports onnx, windows, and linux only."}
	if is_robot_platform(platform):
		# Robot targets produce a folder, not a packed executable, and need a
		# sensor/motor mapping this function knows nothing about. Falling through
		# would reach _pack_executable and raise something unreadable.
		return {"status": "error", "error": "Use export_robot_bundle() for robot targets (%s)." % platform}
	var model_path := _local_inference_model_path(input.context_id)
	if not FileAccess.file_exists(model_path):
		return {"status": "error", "error": "No local trained model found for this graph. Train it once before exporting."}
	if quant != "" and quant != "none":
		push_warning("FullyLocal executable export currently ignores quantization mode '" + quant + "' and exports the trained f32 ONNX model.")
	if platform == "onnx":
		return _copy_file_abs(model_path, output_path)
	if not await _ensure_local_runtime_ready():
		return {"status": "error", "error": local_runtime.last_error()}
	var entry_path := await _local_export_entry_abs()
	if not FileAccess.file_exists(entry_path):
		return {"status": "error", "error": "FullyLocal export runtime entry not found: " + entry_path}

	var job_id = "%s_%s" % [str(Time.get_unix_time_from_system()), str(randi())]
	var job_dir = _fully_local_exports_root_abs().path_join(job_id)
	DirAccess.make_dir_recursive_absolute(job_dir)
	var request_path := job_dir.path_join("request.json")
	var response_path := job_dir.path_join("response.json")
	var payload := {
		"model_path": model_path,
		"platform": platform,
		"output_path": output_path,
		"context": str(input.context_id),
		"scene_id": str(glob.get_project_id()),
		"graph_name": input.get_title() if input.has_method("get_title") else str(input.name),
	}
	if not _write_json(request_path, payload):
		return {"status": "error", "error": "Could not write FullyLocal export request."}

	var python_path := await _local_python_path()
	var thread := Thread.new()
	var start_err := thread.start(Callable(self, "_run_local_export_process").bind([python_path, entry_path, request_path, response_path]))
	if start_err != OK:
		return {"status": "error", "error": "Could not start FullyLocal export worker thread: " + str(start_err)}
	while thread.is_alive():
		await get_tree().process_frame
	return thread.wait_to_finish()

func _column_dtype_from_name(column_name: Variant) -> String:
	var parts := str(column_name).rsplit(":", true, 1)
	return parts[1] if parts.size() > 1 else "text"

func _cell_to_training_values(cell: Variant, dtype: String) -> Array:
	if not (cell is Dictionary):
		return [float(cell) if str(cell).is_valid_float() else 0.0]
	var c: Dictionary = cell
	var ctype := str(c.get("type", dtype))
	match ctype:
		"num":
			return [float(c.get("num", 0))]
		"float":
			return [float(c.get("val", 0.0))]
		"image":
			var tex = c.get("img", null)
			if tex == null or not (tex is Object) or not tex.has_method("get_image"):
				var x := int(c.get("x", 0))
				var y := int(c.get("y", 0))
				var count = max(0, x * y)
				var zeros: Array = []
				zeros.resize(count)
				zeros.fill(0.0)
				return zeros
			var img: Image = tex.get_image()
			if img == null:
				return []
			if img.get_format() != Image.FORMAT_L8:
				img.convert(Image.FORMAT_L8)
			var data := img.get_data()
			var out: Array = []
			out.resize(data.size())
			for i in data.size():
				out[i] = float(data[i]) / 255.0
			return out
		"text":
			var text := str(c.get("text", ""))
			return [float(text) if text.is_valid_float() else 0.0]
		_:
			if c.has("val"):
				return [float(c.get("val", 0.0))]
			if c.has("num"):
				return [float(c.get("num", 0))]
			return [0.0]

func _local_dataset_to_training_json(ds_name: String) -> Dictionary:
	if not glob.dataset_datas.has(ds_name):
		return {"ok": false, "error_code": "dataset_unavailable", "details": {"dataset": ds_name}}
	var ds: Dictionary = glob.dataset_datas[ds_name]
	if PackedNumericDataset.is_packed(ds):
		var packed_rows := PackedNumericDataset.row_count(ds)
		var packed_columns := PackedNumericDataset.column_count(ds)
		var packed_outputs_from := int(ds.get("outputs_from", 1))
		if packed_rows <= 0 or packed_outputs_from <= 0 or packed_outputs_from >= packed_columns:
			return {"ok": false, "error_code": "dataset_empty", "details": {"dataset": ds_name}}
		var packed_x: Array = []
		var packed_y: Array = []
		packed_x.resize(packed_rows)
		packed_y.resize(packed_rows)
		for row_index in packed_rows:
			var x := PackedFloat32Array()
			var y := PackedFloat32Array()
			x.resize(packed_outputs_from)
			y.resize(packed_columns - packed_outputs_from)
			for column_index in packed_columns:
				var number := PackedNumericDataset.value(ds, row_index, column_index)
				if column_index < packed_outputs_from:
					x[column_index] = number
				else:
					y[column_index - packed_outputs_from] = number
			packed_x[row_index] = Array(x)
			packed_y[row_index] = y[0] if y.size() == 1 else Array(y)
		return {
			"ok": true,
			"name": ds_name,
			"x": packed_x,
			"y": packed_y,
			"meta": {
				"col_names": ds.get("col_names", []),
				"outputs_from": packed_outputs_from,
				"preview": DsObjRLE.get_preview(ds),
			},
		}
	var rows: Array = ds.get("arr", [])
	if rows.is_empty():
		return {"ok": false, "error_code": "dataset_empty", "details": {"dataset": ds_name}}
	var outputs_from := int(ds.get("outputs_from", 1))
	var col_names: Array = ds.get("col_names", [])
	var col_dtypes: Array = []
	for col_i in range(rows[0].size()):
		col_dtypes.append(_column_dtype_from_name(col_names[col_i]) if col_i < col_names.size() else "")
	var x_rows: Array = []
	var y_rows: Array = []
	for row in rows:
		if not (row is Array) or row.size() <= outputs_from:
			continue
		var x: Array = []
		var y: Array = []
		for col_i in range(row.size()):
			var vals := _cell_to_training_values(row[col_i], str(col_dtypes[col_i]) if col_i < col_dtypes.size() else "")
			if col_i < outputs_from:
				x.append_array(vals)
			else:
				y.append_array(vals)
		x_rows.append(x)
		y_rows.append(y[0] if y.size() == 1 else y)
	if x_rows.is_empty():
		return {"ok": false, "error_code": "dataset_no_trainable_rows", "details": {"dataset": ds_name}}
	return {
		"ok": true,
		"name": ds_name,
		"x": x_rows,
		"y": y_rows,
		"meta": {
			"col_names": col_names,
			"outputs_from": outputs_from,
			"preview": DsObjRLE.get_preview(ds),
		},
	}

func _start_train_remote(train_input, prepared: Dictionary, additional_call: Callable) -> bool:
	var train_input_origin: Graph = prepared["train_input_origin"]
	var tdata: Dictionary = prepared["tdata"]
	var compressed: Dictionary = prepared["payload"]
	var a = sockets.connect_to("ws/train", train_state_received.bind(additional_call))
	if a == null:
		return false

	training_sockets[train_input] = a
	a.connected.connect(func():
		#if tdata.get("local"):
		#	var data = DsObjRLE.compress_and_send(train_input_origin.dataset_meta["name"]) if tdata.get("local") else {}
		#	a.send()
		#("send...")
		a.send(glob.compress_dict_zstd(compressed))
		#await a.packet
		if tdata["local"]:
			#("A")
			ws_ds_frames(train_input_origin, tdata, a)
		)
		#ws_ds_frames(train_input_origin, compressed, a))
	a.kill.connect(func(...x):
		#("AA")
		train_input_origin.train_stop(true))
	return true

func _start_train_fully_local(train_input, prepared: Dictionary, additional_call: Callable) -> bool:
	var train_input_origin: Graph = prepared["train_input_origin"]
	var payload: Dictionary = prepared["payload"].duplicate(true)
	var ds_name: String = train_input_origin.dataset_meta.get("name", "")
	if not _is_fully_local_dataset(ds_name) and not prepared.payload.has("language_graph"):
		var dataset_code := "dataset_not_selected" if ds_name == "" else "dataset_unavailable"
		_report_runtime_code(dataset_code, "training", {"dataset": ds_name}, _fully_local_dataset_error(ds_name))
		return false

	if not await _ensure_local_runtime_ready():
		return false
	var entry_path := await _local_runtime_entry_abs()
	if not FileAccess.file_exists(entry_path):
		_report_runtime_code("runtime_component_missing", "training", {}, "Training runtime entry not found: " + entry_path)
		return false

	var job_dir := _make_local_training_job_dir()
	if payload.has("language_graph"):
		pass
	elif FULLY_LOCAL_DATASET_NAMES.has(ds_name):
		payload["dataset_ref"] = {"kind": "builtin_numpy", "name": ds_name}
	else:
		var dataset_payload := _local_dataset_to_training_json(ds_name)
		if not dataset_payload.get("ok", false):
			_report_runtime_code(
				str(dataset_payload.get("error_code", "training_failed")),
				"training",
				dataset_payload.get("details", {"dataset": ds_name}),
				"Could not prepare local dataset: " + ds_name
			)
			return false
		var dataset_path := job_dir.path_join("dataset.json")
		dataset_payload.erase("ok")
		if not _write_json(dataset_path, dataset_payload):
			_report_runtime_code("runtime_data_write_failed", "training", {}, "Could not write local dataset payload: " + dataset_path)
			return false
		payload["dataset_ref"] = {"kind": "godot_json", "name": ds_name, "path": dataset_path}
	payload["runtime_root"] = await _local_runtime_root_abs()
	payload["job_dir"] = job_dir
	payload["checkpoint_dir"] = _local_context_dir_abs(prepared["execute_input_origin"].context_id)
	payload["local_mode"] = "fullylocal_ort"
	payload["parent_pid"] = OS.get_process_id()
	payload.erase("local")

	if not _write_json(job_dir.path_join("request.json"), payload):
		return false

	var python_path := await _local_python_path()
	var pid := OS.create_process(python_path, [entry_path, job_dir])
	if pid == -1:
		_report_runtime_code("runtime_start_failed", "training", {}, "Could not start runtime executable: " + python_path)
		return false

	if payload.has("language_graph"):
		prepared.execute_input_origin.controller.begin_training()
	local_training_jobs[train_input] = {
		"pid": pid,
		"dir": job_dir,
		"progress_path": job_dir.path_join("progress.jsonl"),
		"stop_path": job_dir.path_join("stop"),
		"line_count": 0,
		"additional": additional_call,
		"train_input_origin": train_input_origin,
		"training_head": train_input,
		"source":prepared.get("execute_input_origin"),
		"language":payload.has("language_graph"),
		"model_fingerprint":training_structural_fingerprint({"language_graph":payload.get("language_graph",{})}),
	}
	return true


func _training_dataset_meta(ds_name: String, selected_meta: Dictionary) -> Dictionary:
	# Use the same source precedence as _start_train_fully_local.
	if FULLY_LOCAL_TRAINING:
		if FULLY_LOCAL_DATASET_NAMES.has(ds_name):
			return glob.FULLY_LOCAL_BUILTIN_DATASETS.get(ds_name, {})
		if glob.dataset_datas.has(ds_name):
			var meta: Dictionary = DsObjRLE.get_preview(glob.dataset_datas[ds_name])
			var outputs: Array = meta.get("outputs", [])
			# One target column may encode class indices, not a single output neuron.
			# The runtime checks its values against the compiled model and selected loss.
			if outputs.size() == 1 and int(outputs[0].get("x", 0)) == 1:
				meta.erase("outputs")
			return meta
	return selected_meta


static func training_dataset_shape_error(
	ds_meta: Dictionary,
	actual_in: int,
	model_out: int,
	label_count: int = -1,
	language: String = "ru",
	actual_channels: int = -1
) -> String:
	var inputs: Dictionary = ds_meta.get("inputs", {})
	var expected_in: int = inputs.get("x", 0)
	var expected_channels := int(inputs.get("channels", 1))
	var pictures: bool = inputs.get("datatype", "") == "2d"
	if pictures:
		# Input2D exposes a flattened shape, while dataset metadata stores width, height and channels.
		expected_in *= int(inputs.get("y", 1)) * expected_channels
	var expected_out: int = -1
	var outs = ds_meta.get("outputs", [])
	if outs.size() > 0:
		expected_out = outs[0].get("x", 0)
	var messages: Array[String] = []
	if expected_in > 0 and actual_in != -1 and actual_in != expected_in and pictures \
			and actual_channels > 0 and actual_channels != expected_channels:
		# Colour against grey: the node to take is said, not the numbers.
		var colour_dataset := expected_channels == 3
		match language:
			"en":
				messages.append(("The pictures in dataset “%s” are in colour, but the input node is grey. Use the “Input RGB” node." if colour_dataset
					else "The pictures in dataset “%s” are grey, but the input node is in colour. Use the “Input2D” node.") % ds_meta.get("name", ""))
			"kz":
				messages.append(("«%s» деректер жиынындағы суреттер түрлі түсті, ал кіріс түйіні сұр. «Кіріс RGB» түйінін алыңыз." if colour_dataset
					else "«%s» деректер жиынындағы суреттер сұр, ал кіріс түйіні түрлі түсті. «Кіріс2D» түйінін алыңыз.") % ds_meta.get("name", ""))
			_:
				messages.append(("Картинки датасета «%s» цветные, а узел ввода серый. Возьмите узел «Ввод RGB»." if colour_dataset
					else "Картинки датасета «%s» серые, а узел ввода цветной. Возьмите узел «Ввод2D».") % ds_meta.get("name", ""))
	elif expected_in > 0 and actual_in != -1 and actual_in != expected_in:
		match language:
			"en":
				messages.append("The dataset expects %d inputs, but the input node provides %d." % [expected_in, actual_in])
			"kz":
				messages.append("Деректер жиыны %d кіріс күтеді, ал кіріс түйіні %d мән береді." % [expected_in, actual_in])
			_:
				messages.append("Датасет ожидает %d входов, а узел ввода передаёт %d." % [expected_in, actual_in])
	if expected_out > 0 and model_out != -1 and model_out != expected_out:
		match language:
			"en":
				messages.append("Dataset “%s” requires %d classes, but the model output has %d output neurons. Set the model output size to %d." % [ds_meta.get("name", ""), expected_out, model_out, expected_out])
			"kz":
				messages.append("«%s» деректер жиынына %d класс қажет, ал модель шығысында %d шығыс нейроны бар. Модель шығысының өлшемін %d етіп орнатыңыз." % [ds_meta.get("name", ""), expected_out, model_out, expected_out])
			_:
				messages.append("Для датасета «%s» нужно классов: %d, а у выхода модели %d выходных нейрона. Установите размер выхода модели %d." % [ds_meta.get("name", ""), expected_out, model_out, expected_out])
	if label_count > 0 and model_out > 0 and label_count != model_out:
		match language:
			"en":
				messages.append("The answer panel has %d labels, but the model has %d output neurons. Make these counts equal." % [label_count, model_out])
			"kz":
				messages.append("Жауап панелінде %d белгі бар, ал модельде %d шығыс нейроны бар. Бұл сандарды теңестіріңіз." % [label_count, model_out])
			_:
				messages.append("В панели «Вывод-Ответ» меток: %d, а выходных нейронов модели: %d. Сделайте эти значения одинаковыми." % [label_count, model_out])
	return " ".join(messages)


static func training_shape_error_title(language: String) -> String:
	match language:
		"en":
			return "Model shape error: "
		"kz":
			return "Модель пішінінің қатесі: "
		_:
			return "Ошибка формы модели: "


static func classifier_model_output_width(classifier: Object) -> int:
	if not is_instance_valid(classifier):
		return -1
	# run_m.gd displays this same propagated metadata for each model branch.
	# Reusing it keeps training validation compatible with adaptive output nodes.
	var propagated_meta = classifier.get("res_meta")
	if typeof(propagated_meta) == TYPE_DICTIONARY:
		return int(propagated_meta.get("x", -1))
	return -1


func start_train(train_input, additional_call: Callable = glob.def, run_but: BlockComponent = null) -> bool:
	if not FULLY_LOCAL_TRAINING:
		if not await glob.require_remote_session_for_action(run_but):
			return false
	try_print(train_input)
	var prepared = _build_train_payload(train_input)
	if !(prepared is Dictionary):
		return false
	var train_input_origin: Graph = prepared["train_input_origin"]
	var ds_name: String = train_input_origin.dataset_meta.get("name", "")

	var ds_meta := _training_dataset_meta(ds_name, train_input_origin.dataset_meta)

	if not ds_meta.is_empty() and not prepared.payload.has("language_graph"):
		var actual_in := -1
		var actual_channels := -1
		var model_out := -1
		var label_count := -1
		var execute_input: Graph = prepared["execute_input_origin"]
		for node in graphs.simple_reach(execute_input, true):
			if node.server_typename == "InputNode":
				actual_in = node.useful_properties().get("shape", -1)
				if node.has_method("image_channels"):
					actual_channels = node.image_channels()
			elif node.server_typename == "ClassifierNode":
				model_out = classifier_model_output_width(node)
				label_count = node.cfg.get("label_names", []).size()

		var language := str(glob.get_lang())
		var err_msg := training_dataset_shape_error(ds_meta, actual_in, model_out, label_count, language, actual_channels)
		if err_msg != "":
			ui.error(training_shape_error_title(language) + err_msg)
			return false

	if FULLY_LOCAL_TRAINING:
		_default_infer_training_pause = true
		await close_infer_channel(graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME))
		_training_last_input = train_input
		if RESIDENT_TRAINING_WORKER and _local_training_worker != null and _local_training_worker.is_ready():
			var pending := {
				"train_input": train_input,
				"prepared": prepared,
				"additional": additional_call,
				"fallback_started": false,
			}
			if await _prepare_resident_snapshot(train_input, prepared, pending):
				return true
		var started := await _start_train_fully_local(train_input, prepared, additional_call)
		if not started:
			_default_infer_training_pause = false
			_request_default_infer_warm()
		return started
	return await _start_train_remote(train_input, prepared, additional_call)

func stop_train(train_input, force_process: bool = false):
	if train_input in _resident_training_jobs:
		var resident_job: Dictionary = _resident_training_jobs[train_input]
		if _local_training_worker != null:
			_local_training_worker.stop(int(resident_job.get("worker_request_id", -1)))
		if force_process and _local_training_worker != null:
			_local_training_worker.force_kill()
		return
	if train_input in local_training_jobs:
		var job: Dictionary = local_training_jobs[train_input]
		_stop_local_training_job(job, force_process)
		return
	if not train_input in training_sockets:
		#web.POST("end_train", {})
		return
	training_sockets[train_input].send(glob.compress_dict_zstd({"stop": "true"}))
	training_sockets.erase(train_input)

func _stop_local_training_job(job: Dictionary, force_process: bool = false) -> void:
	var stop_path: String = job.get("stop_path", "")
	if stop_path != "":
		var f = FileAccess.open(stop_path, FileAccess.WRITE)
		if f:
			f.store_string("stop")
			f.close()
	if force_process:
		_kill_pid(int(job.get("pid", -1)), "force stop local training")

func _finalize_local_training_job(job: Dictionary) -> void:
	var job_dir: String = job.get("dir", "")
	if job_dir != "":
		_remove_dir_recursive_abs(job_dir, [_fully_local_jobs_root_abs()])



var inference_sockets := {}
var _last_inference_request_ids: Dictionary = {}
var _remote_inference_request_queues: Dictionary = {}


func _is_visual_inference_request(data: Dictionary) -> bool:
	# full_graph only refreshes the runtime topology; no values are inferred.
	return not data.has("full_graph") and not data.has("stop")


func _next_inference_request_id(input) -> int:
	var next_id := int(_last_inference_request_ids.get(input, 0)) + 1
	_last_inference_request_ids[input] = next_id
	return next_id


func _dispatch_remote_inference_request(input) -> int:
	var request_id := _next_inference_request_id(input)
	var queued: Array = _remote_inference_request_queues.get(input, [])
	queued.append(request_id)
	_remote_inference_request_queues[input] = queued
	inference_dispatched.emit(input, request_id)
	return request_id


func _finish_remote_inference_request(input, failed: bool, error_data: Variant = null) -> void:
	var queued: Array = _remote_inference_request_queues.get(input, [])
	if queued.is_empty():
		return
	var request_id := int(queued.pop_front())
	if queued.is_empty():
		_remote_inference_request_queues.erase(input)
	else:
		_remote_inference_request_queues[input] = queued
	if failed:
		inference_failed.emit(input, request_id, error_data)
	else:
		inference_finished.emit(input, request_id)

func _infer_result_to_outputs(_dict: Dictionary, ws = null) -> Dictionary:
	var outs = {}
	if "ack" in _dict:
		if ws:
			#("ACK")
			ws.ack.emit()
	if "result" in _dict and _dict["result"] is Dictionary:
		for i in _dict["result"]:
			var node: Graph = graphs._graphs.get(int(i))
			if not node: continue
			for to_push in _dict["result"][i].values():
				if node.is_head:
					var flattened = glob.flatten_array(to_push)
					node.push_values(flattened, node.per)
					outs[node.get_title()] = flattened
	return outs

func _infer_state_received(bytes: PackedByteArray, ws: SocketConnection):
	var _dict = JSON.parse_string(bytes.get_string_from_utf8())
	if _dict and _dict is Dictionary:
		if _dict.get("phase", "") == "error" or _dict.has("error"):
			_report_runtime_error(_dict.get("error", _dict), "inference")
			return {}
		return _infer_result_to_outputs(_dict, ws)
	return {}
	#(_dict)


func _handle_remote_inference_packet(input, bytes: PackedByteArray, ws: SocketConnection) -> void:
	var packet = JSON.parse_string(bytes.get_string_from_utf8())
	if not (packet is Dictionary):
		infer_clear(input, {})
		return
	var failed: bool = packet.get("phase", "") == "error" or packet.has("error")
	var terminal: bool = failed or (packet.has("result") and packet["result"] is Dictionary)
	var outs: Dictionary = _infer_state_received(bytes, ws)
	infer_clear(input, outs)
	if terminal:
		_finish_remote_inference_request(input, failed, packet.get("error", packet) if failed else null)


func infer_channels():
	return inference_sockets

func is_infer_channel(input) -> bool:
	if not input in inference_sockets:
		return false
	var sock = inference_sockets[input]
	return sock is LocalInferChannel or is_instance_valid(sock)

func check_valid(input, train: bool = false):
	if not is_instance_valid(input):
		return false
	if graphs.LanguageAdapter.is_language(input):
		_report_runtime_code("language_demo_only", "training" if train else "inference", {}, "Language nodes currently use the demo backend. Numeric training and inference are unavailable for this graph.")
		return false
	if train:
		input = graphs._reach_input(input, "TrainBegin")
		if not is_instance_valid(input):
			return false
	var simple = graphs.simple_reach(input, true)
	var has_necc: bool = false; var in_nodes = {}
	if train: in_nodes = {"RunModel": 1, "ModelName": 1, "DatasetName": 1}
	else: in_nodes = {"ClassifierNode": 1}
	#(in_nodes)
	#(input.server_typename)
	for i in simple:
		if graphs.in_nodes(i, in_nodes): has_necc = true
		if not i.is_valid():
			return false
	return has_necc

func validate_infer_channel(input):
	#if input in inference_sockets and is_instance_valid(inference_sockets[input]):
	#	return false# already open
	if not check_valid(input):
	#	print("fals")
		return false
	if FULLY_LOCAL_TRAINING:
		return RemoteSessionGateCore.inference_ready(
			true,
			FileAccess.file_exists(_local_inference_model_path(input.context_id)),
			false
		)
	return RemoteSessionGateCore.inference_ready(false, false, glob.remote_session_ready())

func _find_local_output_node_id(graph: Dictionary) -> String:
	var pages: Dictionary = graph.get("pages", {})
	if pages.is_empty():
		return "0"
	var page_keys := pages.keys()
	page_keys.sort_custom(func(a, b): return int(a) < int(b) if str(a).is_valid_int() and str(b).is_valid_int() else str(a) < str(b))
	var ignored := {"TrainInput": true, "TrainBegin": true, "RunModel": true, "DatasetName": true, "ModelName": true}
	for pk_i in range(page_keys.size() - 1, -1, -1):
		var page: Dictionary = pages[page_keys[pk_i]]
		var node_keys := page.keys()
		for nk_i in range(node_keys.size() - 1, -1, -1):
			var nid = node_keys[nk_i]
			if not ignored.has(str(page[nid].get("type", ""))):
				return str(nid)
	return str(pages[page_keys[-1]].keys()[0])

func _open_infer_channel_fully_local(input, on_close: Callable = glob.def):
	var model_path := _local_inference_model_path(input.context_id)
	_infer_log("open requested", {
		"input": _infer_input_tag(input),
		"model_path": model_path,
	})
	if not FileAccess.file_exists(model_path):
		_infer_log("open failed: missing model", {"input": _infer_input_tag(input), "model_path": model_path})
		_report_runtime_code("model_not_trained", "inference", {}, "Inference model not found: " + model_path)
		return false
	var graph := graphs.get_syntax_tree(input)
	if not await _ensure_local_runtime_ready("inference"):
		return false
	var entry_path := await _local_infer_loop_entry_abs()
	if not FileAccess.file_exists(entry_path):
		_infer_log("open failed: missing loop entry", {"entry_path": entry_path})
		_report_runtime_code("runtime_component_missing", "inference", {}, "Inference runtime entry not found: " + entry_path)
		return false
	var channel := LocalInferChannel.new()
	channel.model_path = model_path
	channel.graph = graph
	channel.context_id = str(input.context_id)
	channel.output_node_id = _find_local_output_node_id(graph)
	channel.on_close = on_close
	channel.job_dir = _make_local_infer_job_dir(input.context_id)
	if channel.job_dir == "":
		_report_runtime_code("runtime_data_write_failed", "inference", {}, "Could not prepare local inference runtime directory")
		return false
	channel.control_path = channel.job_dir.path_join("control.json")
	channel.request_path = channel.job_dir.path_join("request.json")
	channel.response_path = channel.job_dir.path_join("response.json")
	channel.stop_path = channel.job_dir.path_join("stop")
	_infer_log("channel prepared", {
		"input": _infer_input_tag(input),
		"job_dir": channel.job_dir,
		"output_node_id": channel.output_node_id,
		"request_path": channel.request_path,
		"response_path": channel.response_path,
	})
	if FileAccess.file_exists(channel.stop_path):
		DirAccess.remove_absolute(channel.stop_path)
	if not _write_json(channel.control_path, {
		"model_path": channel.model_path,
		"graph": channel.graph,
		"context": channel.context_id,
		"output_node_id": channel.output_node_id,
		"parent_pid": OS.get_process_id(),
		"idle_timeout_s": FULLY_LOCAL_INFER_IDLE_TIMEOUT_S,
	}):
		_infer_log("open failed: could not write control", {"control_path": channel.control_path})
		_report_runtime_code("runtime_data_write_failed", "inference", {}, "Could not write inference control file: " + channel.control_path)
		return false
	var python_path := await _local_python_path()
	channel.pid = OS.create_process(python_path, [entry_path, channel.job_dir])
	if channel.pid == -1:
		_infer_log("open failed: process launch failed", {"python": python_path, "entry": entry_path})
		_report_runtime_code("runtime_start_failed", "inference", {}, "Could not start inference process: " + python_path + " " + entry_path)
		return false
	input.set_state_open()
	inference_sockets[input] = channel
	_infer_log("channel opened", {
		"input": _infer_input_tag(input),
		"pid": channel.pid,
		"python": python_path,
	})
	return channel

func open_infer_channel(input, on_close: Callable = glob.def, run_but: BlockComponent = null):
	if not FULLY_LOCAL_TRAINING:
		if not await glob.require_remote_session_for_action(run_but):
			return false
	if input in inference_sockets and is_instance_valid(inference_sockets[input]):
		_infer_log("open ignored: channel already exists", {
			"input": _infer_input_tag(input),
			"channel": _infer_channel_state_dict(inference_sockets[input]),
			"leases": _infer_channel_lease_summary(input),
		})
		return inference_sockets[input]
	if not check_valid(input):
	#	print("fals")
		_infer_log("open failed: graph invalid", {"input": _infer_input_tag(input)})
		_report_runtime_code("inference_graph_invalid", "inference", {}, "Model graph validation failed: " + _infer_input_tag(input))
		return false
	if FULLY_LOCAL_TRAINING:
		return await _open_infer_channel_fully_local(input, on_close)
	var init_payload = {
		"session": "neriqward",
		"graph": graphs.get_syntax_tree(input),
		"scene_id": str(glob.get_project_id()),
		"context": str(input.context_id),
	}
	var sock = sockets.connect_to("ws/infer")
	if sock == null:
		return false
	request_save()
	input.set_state_open()
	sock.packet.connect((func(bytes: PackedByteArray):
		_handle_remote_inference_packet(input, bytes, sock)
		))
	inference_sockets[input] = sock
	sock.connected.connect(func() -> void:
		sock.send(glob.compress_dict_zstd(init_payload))
	)
	sock.kill.connect(func(...x) -> void:
		while _remote_inference_request_queues.has(input) and not (_remote_inference_request_queues[input] as Array).is_empty():
			_finish_remote_inference_request(input, true, {"code": "inference_channel_closed"})
		if input in inference_sockets:
			if inference_sockets[input] == sock:
				inference_sockets.erase(input)
		if input in inference_channel_leases:
			inference_channel_leases.erase(input)
		if on_close.is_valid():
			on_close.call()
	)
	#await sock.connected
	return sock

var inference_polling: Dictionary = {}

func infer_clear(who, outputs: Dictionary):
	_infer_log("outputs applied", {
		"input": _infer_input_tag(who) if who is Graph else str(who),
		"output_keys": outputs.keys(),
	})
	inference_polling[who] = outputs

func _make_local_infer_job_dir(context_id) -> String:
	var root = _fully_local_infer_root_abs().path_join(str(context_id))
	if DirAccess.make_dir_recursive_absolute(root) != OK:
		push_warning("Could not create local inference root: " + root)
		return ""
	var job_id = "%s_%s" % [str(Time.get_unix_time_from_system()), str(randi())]
	var job_dir = root.path_join(job_id)
	if DirAccess.make_dir_recursive_absolute(job_dir) != OK:
		push_warning("Could not create local inference job directory: " + job_dir)
		return ""
	return job_dir

func _queue_local_inference_data(input, channel: LocalInferChannel, data: Dictionary, await_response: bool = false) -> bool:
	# A caller may still hold a channel reference for one frame after shutdown.
	# Never recreate its directory: its Python process is gone, so doing that would
	# only hide the real lifecycle error and leave the request waiting forever.
	if channel == null or channel.closed or not inference_sockets.has(input) or inference_sockets.get(input) != channel:
		_infer_log("queue rejected: stale local channel", {"input": _infer_input_tag(input)})
		return false
	if channel.job_dir == "" or not DirAccess.dir_exists_absolute(channel.job_dir):
		_infer_log("queue rejected: local channel directory missing", {
			"input": _infer_input_tag(input),
			"job_dir": channel.job_dir,
		})
		_close_local_infer_channel(input, channel, true, true)
		return false
	if "full_graph" in data:
		if not check_valid(input):
			_infer_log("queue rejected: graph invalid during full_graph update", {"input": _infer_input_tag(input)})
			return false
		channel.graph = data["full_graph"]
		channel.output_node_id = _find_local_output_node_id(channel.graph)
		_infer_log("full graph queued", {
			"input": _infer_input_tag(input),
			"output_node_id": channel.output_node_id,
		})
	if channel.request_in_flight and not await_response:
		channel.pending_data = data.duplicate(true)
		inference_sockets[input] = channel
		if channel.current_request_visual and _is_visual_inference_request(data):
			inference_visual_repeated.emit(input, channel.index)
		_infer_log("request coalesced", {
			"input": _infer_input_tag(input),
			"in_flight_seq": channel.index,
			"has_full_graph": data.has("full_graph"),
			"raw_len": data.get("raw_values", []).size() if data.has("raw_values") and data["raw_values"] is Array else -1,
		})
		return true
	if input in inference_polling:
		inference_polling.erase(input)
	inference_polling[input] = true
	channel.index = max(channel.index, int(_last_inference_request_ids.get(input, 0))) + 1
	_last_inference_request_ids[input] = channel.index
	channel.last_request_msec = Time.get_ticks_msec()
	channel.no_response_logged = false
	channel.request_in_flight = true
	channel.current_request_visual = _is_visual_inference_request(data)
	var request := {
		"seq": channel.index,
		"graph": channel.graph,
		"data": data,
		"context": channel.context_id,
		"output_node_id": channel.output_node_id,
		"index": channel.index,
	}
	_infer_log("request queued", {
		"input": _infer_input_tag(input),
		"seq": channel.index,
		"has_full_graph": data.has("full_graph"),
		"raw_len": data.get("raw_values", []).size() if data.has("raw_values") and data["raw_values"] is Array else -1,
		"request_path": channel.request_path,
	})
	if not _write_json(channel.request_path, request):
		_infer_log("request write failed", {"input": _infer_input_tag(input), "request_path": channel.request_path})
		channel.request_in_flight = false
		channel.current_request_visual = false
		inference_sockets[input] = channel
		inference_polling.erase(input)
		return false
	inference_sockets[input] = channel
	if channel.current_request_visual:
		inference_dispatched.emit(input, channel.index)
	return true

func submit_runtime_request(owner: Node, request: Dictionary, callback: Callable) -> void:
	if not owner in inference_sockets:
		if owner.has_meta("runtime_opening"): return
		var generation: int=int(owner.get_meta("runtime_generation",0))
		owner.set_meta("runtime_opening",generation)
		var python := OS.get_environment("NEURALESE_LANGUAGE_PYTHON") if OS.has_feature("editor") else ""
		var entry := ProjectSettings.globalize_path(FULLY_LOCAL_INFER_LOOP_ENTRY)
		if python=="":
			python=await _local_python_path()
			entry=await _local_infer_loop_entry_abs()
		if not is_instance_valid(owner) or int(owner.get_meta("runtime_generation",0))!=generation: return
		owner.remove_meta("runtime_opening")
		var channel := LocalInferChannel.new()
		channel.packet_callback=callback
		channel.job_dir=_make_local_infer_job_dir("language")
		channel.control_path=channel.job_dir.path_join("control.json")
		channel.request_path=channel.job_dir.path_join("request.json")
		channel.response_path=channel.job_dir.path_join("response.json")
		channel.stop_path=channel.job_dir.path_join("stop")
		var model := OS.get_environment("NEURALESE_LANGUAGE_MODEL_DIR") if OS.has_feature("editor") else ""
		_write_json(channel.control_path,{"model_kind":"language","model_path":model,"parent_pid":OS.get_process_id()})
		channel.pid=OS.create_process(python,[entry,channel.job_dir])
		inference_sockets[owner]=channel
	var channel: LocalInferChannel=inference_sockets[owner]
	channel.queued_requests.append(request)
	_flush_runtime_requests(channel)

func close_runtime_channel(owner: Node) -> void:
	owner.set_meta("runtime_generation",int(owner.get_meta("runtime_generation",0))+1)
	if owner.has_meta("runtime_opening"): owner.remove_meta("runtime_opening")
	if owner in inference_sockets: _close_local_infer_channel(owner,inference_sockets[owner],true,false)

func _flush_runtime_requests(channel: LocalInferChannel) -> void:
	if channel.request_in_flight or channel.queued_requests.is_empty(): return
	var request: Dictionary=channel.queued_requests.pop_front()
	channel.index+=1
	channel.active_request=request
	channel.request_in_flight=true
	channel.last_request_msec=Time.get_ticks_msec()
	_write_json(channel.request_path,{"seq":channel.index,"data":request})

func _fail_runtime_channel(owner: Node, channel: LocalInferChannel, error: Dictionary) -> void:
	var requests: Array=channel.queued_requests.duplicate()
	if not channel.active_request.is_empty(): requests.push_front(channel.active_request)
	channel.queued_requests.clear()
	channel.active_request={}
	for request in requests:
		var response: Dictionary=request.duplicate()
		response.merge({"provider_id":"onnx-clean1000","is_dummy":false,"ok":false,"result":null,"error":error},true)
		channel.packet_callback.call(response)
	_close_local_infer_channel(owner,channel,true,false)

func _read_runtime_response(path: String) -> Variant:
	# File IO, JSON parsing and integer normalization run outside the UI thread.
	return _normalize_runtime_value(JSON.parse_string(FileAccess.get_file_as_string(path)))

func _normalize_runtime_value(value: Variant, field: String = "") -> Variant:
	if value is Dictionary:
		for key in value: value[key]=_normalize_runtime_value(value[key],str(key))
	elif value is Array:
		for index in value.size(): value[index]=_normalize_runtime_value(value[index],field)
	elif value is float and field in ["schema_version","request_id","graph_revision","selected_id","next_token_id","id","position","start","end","ids","prefix_ids","generated_ids","token_count","positions","layers","input_shape","output_shape","width","head_count","kv_head_count","model_width","max_context","max_new_tokens","requested_depth","effective_depth","total","head_index","layer_index","actual_layer","vocab_size","index"]:
		return int(value)
	return value

func _poll_local_inference_channels() -> void:
	for input in inference_sockets.keys():
		var channel = inference_sockets[input]
		if !(channel is LocalInferChannel):
			continue
		if not is_instance_valid(input):
			_close_local_infer_channel(input, channel, true, false)
			continue
		if channel.closed:
			continue
		if channel.packet_callback.is_valid() and (not OS.is_process_running(channel.pid) or (channel.request_in_flight and Time.get_ticks_msec()-channel.last_request_msec>30000)):
			_fail_runtime_channel(input,channel,{"code":"runtime_unavailable","message":"Local inference worker stopped or timed out","node_id":""})
			continue
		if channel.reader==null and (channel.response_path == "" or not FileAccess.file_exists(channel.response_path)):
			if channel.last_request_msec > 0 and not channel.no_response_logged and Time.get_ticks_msec() - channel.last_request_msec > 1000:
				channel.no_response_logged = true
				inference_sockets[input] = channel
				_infer_log("waiting for response file", {
					"input": _infer_input_tag(input),
					"seq": channel.index,
					"response_path": channel.response_path,
				})
			continue
		if channel.reader==null:
			# Claim one atomic response before reading. A worker may publish its
			# next packet while this thread parses the claimed startup packet.
			if DirAccess.rename_absolute(channel.response_path,channel.response_path+".reading")!=OK: continue
			channel.reader=Thread.new()
			channel.reader.start(_read_runtime_response.bind(channel.response_path+".reading"))
			continue
		if channel.reader.is_alive(): continue
		var parsed = channel.reader.wait_to_finish()
		channel.reader=null
		DirAccess.remove_absolute(channel.response_path+".reading")
		if not parsed is Dictionary: continue
		channel.parse_fail_count = 0
		var response_index := int(parsed.get("index", -1))
		if response_index <= channel.last_response_index:
			continue
		channel.last_response_index = response_index
		inference_sockets[input] = channel
		_infer_log("response received", {
			"input": _infer_input_tag(input),
			"phase": parsed.get("phase", ""),
			"index": response_index,
			"last_request_seq": channel.index,
			"ok": parsed.get("ok", null),
		})
		if parsed.get("phase", "") == "ready":
			continue
		channel.request_in_flight = false
		if channel.packet_callback.is_valid():
			if parsed.has("response"):
				channel.packet_callback.call(parsed.response)
				channel.active_request={}
			elif parsed.get("phase","")=="error":
				_fail_runtime_channel(input,channel,parsed.get("error",{}))
				continue
			_flush_runtime_requests(channel)
			continue
		var completed_visual: bool = channel.current_request_visual
		channel.current_request_visual = false
		var pending_data = channel.pending_data
		channel.pending_data = null
		inference_sockets[input] = channel
		var outs := {}
		if parsed.get("phase", "") == "inference":
			outs = _infer_result_to_outputs(parsed)
		elif parsed.get("phase", "") == "error":
			_report_runtime_error(parsed.get("error", parsed), "inference")
		elif parsed.get("phase", "") == "closed":
			if completed_visual:
				inference_failed.emit(input, response_index, {"code": "inference_channel_closed"})
			if input in inference_polling:
				inference_polling.erase(input)
			inference_sockets.erase(input)
			_remove_dir_recursive_abs(channel.job_dir, [_fully_local_infer_root_abs()])
			if channel.on_close.is_valid():
				channel.on_close.call()
			continue
		infer_clear(input, outs)
		if completed_visual:
			if parsed.get("phase", "") == "error":
				inference_failed.emit(input, response_index, parsed.get("error", parsed))
			else:
				inference_finished.emit(input, response_index)
		if pending_data is Dictionary and input in inference_sockets:
			_infer_log("flushing coalesced request", {
				"input": _infer_input_tag(input),
				"after_response_index": response_index,
			})
			_queue_local_inference_data(input, inference_sockets[input], pending_data, false)

func send_inference_data(input, data: Dictionary, output: bool = false):
	if is_instance_valid(input) and graphs.LanguageAdapter.is_language(input):
		_report_runtime_code("language_demo_only", "inference", {}, "Language demo graphs use their own backend.")
		return {} if output else false
	# make sure channel is open
	if not (input in inference_sockets):
		push_warning("No inference channel open for this graph")
		_infer_log("send rejected: no channel", {"input": _infer_input_tag(input), "output": output})
		return
	#(data)
	if "full_graph" in data:
		if not check_valid(input):
			_infer_log("send rejected: invalid graph", {"input": _infer_input_tag(input)})

			return false
	var sock = inference_sockets[input]
	if sock is LocalInferChannel:
		_infer_log("send local", {
			"input": _infer_input_tag(input),
			"output": output,
			"has_full_graph": data.has("full_graph"),
			"channel": _infer_channel_state_dict(sock),
			"leases": _infer_channel_lease_summary(input),
		})
		if not _queue_local_inference_data(input, sock, data, output):
			return false
		if output:
			while input in inference_polling and inference_polling[input] is bool:
				await get_tree().process_frame
			if not input in inference_polling:
				return
			var local_out = inference_polling[input]
			inference_polling.erase(input)
			return local_out
		return true
	if not is_instance_valid(sock):
		push_warning("Socket instance is no longer valid")
		inference_sockets.erase(input)
		return
	if input in inference_polling:
		inference_polling.erase(input)
	inference_polling[input] = true
	var do_update: bool = false
	var syntax = null

	var payload = {"data": data}
	var compressed = glob.compress_dict_zstd(payload)
	sock.send(compressed)
	if _is_visual_inference_request(data):
		_dispatch_remote_inference_request(input)
	if output:
		while input in inference_polling and inference_polling[input] is bool:
			await get_tree().process_frame
		if not input in inference_polling:
			return
		var out = inference_polling[input]
		inference_polling.erase(input)
		return out
	inference_polling.erase(input)
	return
	#(data)

func _poll_local_training_jobs() -> void:
	for train_input in local_training_jobs.keys():
		var job: Dictionary = local_training_jobs.get(train_input, {})
		if not is_instance_valid(train_input):
			_stop_local_training_job(job, true)
			local_training_jobs.erase(train_input)
			if local_training_jobs.is_empty():
				_default_infer_training_pause = false
				_request_default_infer_warm()
			continue
		var progress_path: String = job.get("progress_path", "")
		if progress_path == "" or not FileAccess.file_exists(progress_path):
			continue

		var last_pos: int = job.get("last_pos", 0)
		var text_buffer: String = job.get("text_buffer", "")

		var f = FileAccess.open(progress_path, FileAccess.READ)
		if not f:
			continue

		var current_len = f.get_length()
		if current_len < last_pos:
			last_pos = 0
			text_buffer = ""

		var complete_count = 0
		var lines: PackedStringArray = []

		if current_len > last_pos:
			f.seek(last_pos)
			var chunk := f.get_buffer(current_len - last_pos).get_string_from_utf8()
			f.close()

			last_pos = current_len
			job["last_pos"] = last_pos

			text_buffer += chunk
			lines = text_buffer.split("\n", true)
			complete_count = lines.size()

			if not text_buffer.ends_with("\n"):
				complete_count -= 1
				text_buffer = lines[complete_count]
			else:
				text_buffer = ""

			job["text_buffer"] = text_buffer
		else:
			f.close()

		var should_erase := false
		for i in range(complete_count):
			var line := String(lines[i]).strip_edges()
			if line == "":
				continue
			var packet = JSON.parse_string(line)
			if packet is Dictionary:
				_handle_train_state_dict(packet, job.get("additional", glob.def), job.get("training_head", null))
				if packet.get("phase", "") in ["done", "stopped", "error"]:
					should_erase = true

		local_training_jobs[train_input] = job
		if should_erase:
			_finalize_local_training_job(job)
			local_training_jobs.erase(train_input)
			if local_training_jobs.is_empty():
				_default_infer_training_pause = false
				_request_default_infer_warm()

func _process(delta: float) -> void:
	for jobs in [local_training_jobs,_resident_training_jobs]:
		for head in jobs.keys():
			var job: Dictionary=jobs[head]
			if not job.get("language",false): continue
			var source=job.get("source")
			if not is_instance_valid(source) or not is_instance_valid(head):
				stop_train(head); continue
			var origin=graphs._reach_input(head,"TrainBegin")
			if not is_instance_valid(origin) or not origin.training:
				stop_train(head); source.controller.end_training(); continue
			var text := str(source.cfg.get("text",""))
			var runner=graphs._reach_input(head,"RunModel")
			if not is_instance_valid(runner) or runner.language_source()!=source:
				stop_train(head); source.controller.end_training(); continue
			if text!=str(job.get("last_text","")):
				_write_json(str(job.dir).path_join("input.json"),{"text":text})
				job["last_text"]=text
				if text.strip_edges().is_empty(): source.controller.clear_training_snapshot()
	if _local_training_worker != null:
		_local_training_worker.poll()
	if _training_prepare_due_msec > 0 and Time.get_ticks_msec() >= _training_prepare_due_msec:
		_training_prepare_due_msec = 0
		_run_speculative_training_prepare.call_deferred()
	_runtime_gc_accum += delta
	if _runtime_gc_accum > 10.0:
		_runtime_gc_accum = 0.0
		_gc_fully_local_runtime_dirs(false)
	_poll_local_training_jobs()
	_poll_local_inference_channels()
	_tick_default_infer_warm(delta)
	#if glob.space_just_pressed:
	#	pass
	#	upl_dataset(null)

func upl_dataset(from):
	if not glob.remote_session_ready():
		return false
	for graph in graphs._graphs.values():
		if graph.server_typename == "TrainBegin":

			var tdata = graph.get_training_data()
			var a = sockets.connect_to("ws/ds_load", func(a): null)
			if a == null:
				return false

			ws_ds_frames(graph, tdata, a)
	return true

func close_all(force_processes: bool = false):
	if _shutdown_cleanup_started and force_processes:
		return
	if force_processes:
		_shutdown_cleanup_started = true
	_infer_log("close_all requested", {
		"inference_channels": inference_sockets.size(),
		"local_training_jobs": local_training_jobs.size(),
		"training_sockets": training_sockets.size(),
		"force_processes": force_processes,
	})
	for i in inference_sockets.keys():
		var sock = inference_sockets.get(i)
		if sock is LocalInferChannel:
			_close_local_infer_channel(i, sock, force_processes, is_instance_valid(i))
		elif is_instance_valid(i):
			close_infer_channel(i, force_processes)
	for i in local_training_jobs.keys():
		stop_train(i, force_processes)
		if force_processes:
			var job: Dictionary = local_training_jobs.get(i, {})
			_finalize_local_training_job(job)
	for i in training_sockets.keys():
		if not is_instance_valid(i):
			continue
		stop_train(i, force_processes)
	local_training_jobs.clear()
	training_sockets.clear()
	inference_sockets.clear()
	inference_channel_leases.clear()
	if force_processes and _local_training_worker != null:
		_local_training_worker.shutdown()

func _close_local_infer_channel(input, sock: LocalInferChannel, force_process: bool = false, call_on_close: bool = true) -> void:
	_infer_log("close local requested", {
		"input": _infer_input_tag(input) if is_instance_valid(input) else str(input),
		"seq": sock.index,
		"pid": sock.pid,
		"job_dir": sock.job_dir,
		"stop_path": sock.stop_path,
		"force_process": force_process,
	})
	if sock.current_request_visual and is_instance_valid(input):
		inference_failed.emit(input, sock.index, {"code": "inference_channel_closed"})
	if sock.reader!=null:
		sock.reader.wait_to_finish()
		sock.reader=null
	sock.closed = true
	sock.request_in_flight = false
	sock.pending_data = null
	sock.current_request_visual = false
	if sock.stop_path != "":
		var f = FileAccess.open(sock.stop_path, FileAccess.WRITE)
		if f:
			f.store_string("stop")
			f.close()
			_infer_log("stop file written", {"input": _infer_input_tag(input) if is_instance_valid(input) else str(input), "stop_path": sock.stop_path})
		else:
			_infer_log("stop file write failed", {"input": _infer_input_tag(input) if is_instance_valid(input) else str(input), "stop_path": sock.stop_path})
	if force_process:
		_kill_pid(sock.pid, "force close local inference")
	if input in inference_sockets:
		inference_sockets.erase(input)
	if input in inference_polling:
		inference_polling.erase(input)
	if input in inference_channel_leases:
		_infer_log("leases cleared by channel close", {
			"input": _infer_input_tag(input) if is_instance_valid(input) else str(input),
			"leases": _infer_channel_lease_summary(input),
		})
		inference_channel_leases.erase(input)
	if force_process and sock.job_dir != "":
		_remove_dir_recursive_abs(sock.job_dir, [_fully_local_infer_root_abs()])
	if call_on_close and sock.on_close.is_valid():
		_infer_log("calling local on_close", {"input": _infer_input_tag(input) if is_instance_valid(input) else str(input)})
		sock.on_close.call()

func close_infer_channel(input, force_process: bool = false) -> void:
	if not (input in inference_sockets):
		_infer_log("close ignored: no channel", {"input": _infer_input_tag(input) if is_instance_valid(input) else str(input)})
		return
	var sock = inference_sockets[input]
	if sock is LocalInferChannel:
		_close_local_infer_channel(input, sock, force_process, true)
		return
	_infer_log("close remote requested", {"input": _infer_input_tag(input)})
	if input in inference_channel_leases:
		_infer_log("leases cleared by remote close", {
			"input": _infer_input_tag(input),
			"leases": _infer_channel_lease_summary(input),
		})
		inference_channel_leases.erase(input)
	sock.send(glob.compress_dict_zstd({"stop": "true"}))


# ---------------------------------------------------------------------------
# Robot export (micro:bit / LEGO EV3 / LEGO SPIKE Prime)
#
# The robot never runs the network. Its script streams sensor readings to a host
# process, which owns both the link and the onnxruntime session and streams
# motor commands back. Godot is deliberately NOT in that loop -- it starts the
# host process, tails its telemetry, and stops it -- because a 20-50 Hz path from
# sensor to motor must not cross a process boundary.
#
# Everything below is the programmatic surface for the UI to wire into later.
# See local_runtime/neuralese_local/robot/ for the implementation and
# docs/ROBOT_EXPORT.md for the protocol.
# ---------------------------------------------------------------------------

const FULLY_LOCAL_ROBOT_EXPORT_ENTRY := "res://local_runtime/neuralese_local/robot/export_robot.py"
const FULLY_LOCAL_ROBOT_RUN_ENTRY := "res://local_runtime/neuralese_local/robot/run_robot.py"

## Platform ids understood by export_robot_bundle(). Kept in sync with
## local_runtime/neuralese_local/robot/platforms.py, which stays authoritative:
## call robot_platforms() for the full descriptions rather than hard-coding.
const ROBOT_PLATFORMS := ["microbit", "ev3", "spike"]

## A running robot link. Mirrors LocalInferChannel: a job directory the host
## process writes telemetry into, plus the pid so it can be stopped.
class RobotLink:
	extends RefCounted
	var platform: String = ""
	var context_id: String = ""
	var job_dir: String = ""
	var control_path: String = ""
	var status_path: String = ""
	var progress_path: String = ""
	var stop_path: String = ""
	var pid: int = -1
	var closed: bool = false


func is_robot_platform(platform: String) -> bool:
	return ROBOT_PLATFORMS.has(platform)


func can_export_robot(input) -> bool:
	return can_export_fully_local(input)


func robot_export_extension(_platform: String) -> String:
	# A robot export is a folder, not a single file: the child needs the model,
	# the device program, the mapping and the instructions together.
	return ""


func _robot_entry_abs() -> String:
	return await local_runtime.entry_path(FULLY_LOCAL_ROBOT_EXPORT_ENTRY)


func _robot_run_entry_abs() -> String:
	return await local_runtime.entry_path(FULLY_LOCAL_ROBOT_RUN_ENTRY)


## The robot window's process: finds, connects and drives a robot for one
## session. Godot talks to it through RobotSessionClient.
const FULLY_LOCAL_ROBOT_SESSION_ENTRY := "res://local_runtime/neuralese_local/robot/robot_session.py"


func _robot_session_entry_abs() -> String:
	return await local_runtime.entry_path(FULLY_LOCAL_ROBOT_SESSION_ENTRY)


## Where each robot's saved name, geometry and mappings live.
func robot_profiles_dir_abs() -> String:
	var root := ProjectSettings.globalize_path("user://robots/profiles")
	DirAccess.make_dir_recursive_absolute(root)
	return root


## Where the recordings of robot runs are written.
func robot_logs_dir_abs() -> String:
	var root := ProjectSettings.globalize_path("user://robots/runs")
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _robot_error(message: String, code: String = "export_failed") -> Dictionary:
	return {"status": "error", "error": message, "code": code, "message": message}


## Live robot links get their own root rather than sharing the training jobs
## directory, so they are not swept by the training-job GC or listed as training
## runs.
func _fully_local_robot_links_root_abs() -> String:
	var root = ProjectSettings.globalize_path("user://fullylocal/robot_links")
	DirAccess.make_dir_recursive_absolute(root)
	return root


func _make_robot_link_job_dir() -> String:
	var job_id = "%s_%s" % [str(Time.get_unix_time_from_system()), str(randi())]
	var job_dir = _fully_local_robot_links_root_abs().path_join(job_id)
	DirAccess.make_dir_recursive_absolute(job_dir)
	return job_dir


## Runs one export_robot.py action and returns its parsed response.
## Never throws: every failure comes back as {"status": "error", "code", "message"}
## so the UI has one shape to render.
func _robot_request(payload: Dictionary) -> Dictionary:
	if not FULLY_LOCAL_TRAINING:
		return _robot_error("FullyLocal mode is disabled.", "fully_local_disabled")
	if not await _ensure_local_runtime_ready():
		return _robot_error(local_runtime.last_error(), "runtime_not_ready")

	var entry_path := await _robot_entry_abs()
	if not FileAccess.file_exists(entry_path):
		return _robot_error("Robot export runtime entry not found: " + entry_path, "runtime_not_ready")

	var job_id = "%s_%s" % [str(Time.get_unix_time_from_system()), str(randi())]
	var job_dir = _fully_local_exports_root_abs().path_join("robot_" + job_id)
	DirAccess.make_dir_recursive_absolute(job_dir)
	var request_path := job_dir.path_join("request.json")
	var response_path := job_dir.path_join("response.json")
	if not _write_json(request_path, payload):
		return _robot_error("Could not write the robot export request.", "io_failed")

	var python_path := await _local_python_path()
	var thread := Thread.new()
	var start_err := thread.start(Callable(self, "_run_local_export_process").bind([python_path, entry_path, request_path, response_path]))
	if start_err != OK:
		return _robot_error("Could not start the robot export worker thread: " + str(start_err), "thread_failed")
	while thread.is_alive():
		await get_tree().process_frame
	var result = thread.wait_to_finish()
	return result if result is Dictionary else _robot_error("The robot export returned an invalid response.")


# -- read-only queries the UI needs to draw its screens ----------------------

## Full registry: every robot, its sensors and motors (with labels, units and
## native ranges), its transports, and how it is programmed. Everything the
## mapping and connect screens need.
func robot_platforms() -> Dictionary:
	return await _robot_request({"action": "list_platforms"})


## The trained model's input/output arity, for sizing the mapping form.
func robot_model_meta(input) -> Dictionary:
	if not is_instance_valid(input):
		return _robot_error("No model input graph selected.", "model_not_found")
	return await _robot_request({
		"action": "model_meta",
		"model_path": _local_inference_model_path(input.context_id),
	})


## A ready-to-run mapping, guessed from the model and (when given) the dataset's
## column ranges. train_signature should carry the ranges each input column
## actually occupied during training -- without it the guessed scaling falls back
## to identity and the response carries a warning, because a sensor whose range
## does not match the training data makes the robot behave randomly with nothing
## reporting an error.
func robot_default_config(input, platform: String, train_signature: Dictionary = {}) -> Dictionary:
	if not is_robot_platform(platform):
		return _robot_error("Unknown robot platform: " + platform, "unknown_platform")
	var payload := {"action": "default_config", "platform": platform, "train_signature": train_signature}
	if is_instance_valid(input):
		payload["model_path"] = _local_inference_model_path(input.context_id)
	return await _robot_request(payload)


## Checks a mapping and returns EVERY problem at once, each with a "field" like
## "inputs[2].channel" so the UI can highlight the offending row.
func robot_validate_config(config: Dictionary, input: Graph = null) -> Dictionary:
	var payload := {"action": "validate", "config": config}
	if is_instance_valid(input):
		payload["model_path"] = _local_inference_model_path(input.context_id)
	return await _robot_request(payload)


## The device program a mapping would produce, as text, for a preview pane.
func robot_preview_script(config: Dictionary) -> Dictionary:
	return await _robot_request({"action": "preview_script", "config": config})


## Which robots are plugged in right now, for the connect screen. Reports an
## unavailable transport rather than failing when an optional dependency
## (pyserial, bleak) is missing from the runtime.
func robot_list_devices(platform: String) -> Dictionary:
	return await _robot_request({"action": "list_devices", "platform": platform})


# -- export -----------------------------------------------------------------

## Writes the export folder: the trained model, the generated device program,
## the mapping, and instructions. Pass an empty config to have one derived.
func export_robot_bundle(input, platform: String, output_path: String, config: Dictionary = {}, lang: String = "", train_signature: Dictionary = {}) -> Dictionary:
	if is_instance_valid(input) and graphs.LanguageAdapter.is_language(input):
		return {"status":"error", "error":"Language demo graphs cannot be exported as trained models.", "code":"language_demo_only"}
	if not is_robot_platform(platform):
		return _robot_error("Unknown robot platform: " + platform, "unknown_platform")
	if not is_instance_valid(input):
		return _robot_error("No model input graph selected.", "model_not_found")
	var model_path := _local_inference_model_path(input.context_id)
	if not FileAccess.file_exists(model_path):
		return _robot_error("No local trained model found for this graph. Train it once before exporting.", "model_not_found")

	var payload := {
		"action": "export",
		"platform": platform,
		"model_path": model_path,
		"output_path": output_path,
		"lang": lang if lang != "" else glob.get_lang(),
		"train_signature": train_signature,
	}
	if not config.is_empty():
		payload["config"] = config
	return await _robot_request(payload)


# -- live link --------------------------------------------------------------

## Starts the host process that owns the link and the model, and returns a
## RobotLink handle. Poll it with robot_link_status(); stop it with
## stop_robot_link(). Returns null on failure, after reporting via ui.error().
func start_robot_link(input, config: Dictionary):
	if not FULLY_LOCAL_TRAINING:
		_report_runtime_code("runtime_unavailable", "inference", {}, "FullyLocal mode is disabled")
		return null
	if not is_instance_valid(input):
		_report_runtime_code("inference_graph_missing", "inference", {}, "No model input graph selected")
		return null
	var model_path := _local_inference_model_path(input.context_id)
	if not FileAccess.file_exists(model_path):
		_report_runtime_code("model_not_trained", "inference", {}, "Robot inference model not found: " + model_path)
		return null
	if not await _ensure_local_runtime_ready("inference"):
		return null
	var entry_path := await _robot_run_entry_abs()
	if not FileAccess.file_exists(entry_path):
		_report_runtime_code("runtime_component_missing", "inference", {}, "Robot link runtime entry not found: " + entry_path)
		return null

	var link := RobotLink.new()
	link.platform = str(config.get("platform", ""))
	link.context_id = str(input.context_id)
	link.job_dir = _make_robot_link_job_dir()
	link.control_path = link.job_dir.path_join("control.json")
	link.status_path = link.job_dir.path_join("status.json")
	link.progress_path = link.job_dir.path_join("progress.jsonl")
	link.stop_path = link.job_dir.path_join("stop")
	if FileAccess.file_exists(link.stop_path):
		DirAccess.remove_absolute(link.stop_path)

	if not _write_json(link.control_path, {
		"model_path": model_path,
		"config": config,
		# The host process stops itself if Godot dies, so a crash here can never
		# leave a robot driving with nothing left to tell it to stop.
		"parent_pid": OS.get_process_id(),
	}):
		_report_runtime_code("runtime_data_write_failed", "inference", {}, "Could not write robot link control file: " + link.control_path)
		return null

	var python_path := await _local_python_path()
	link.pid = OS.create_process(python_path, [entry_path, link.job_dir])
	if link.pid <= 0:
		_report_runtime_code("runtime_start_failed", "inference", {}, "Could not start robot link process: " + python_path + " " + entry_path)
		return null
	return link


## Current state of a running link: state ("waiting_for_robot" / "running" /
## "stalled" / "stopped" / "error"), frame counters, latency, the last readings
## and the last commands. Safe to call every frame -- it reads a file the host
## rewrites twice a second.
func robot_link_status(link: RobotLink) -> Dictionary:
	if link == null:
		return {"state": "idle"}
	if not FileAccess.file_exists(link.status_path):
		return {"state": "starting", "job_dir": link.job_dir}
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(link.status_path))
	return parsed if parsed is Dictionary else {"state": "starting", "job_dir": link.job_dir}


## Asks the host process to bring the robot to a stop and exit. The robot's own
## watchdog is the backstop if this never arrives.
func stop_robot_link(link: RobotLink) -> void:
	if link == null or link.closed:
		return
	link.closed = true
	var flag = FileAccess.open(link.stop_path, FileAccess.WRITE)
	if flag:
		flag.store_string("stop")
		flag.close()
