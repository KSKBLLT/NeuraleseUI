class_name SimulationModelRunner
extends Node

const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

signal status_changed(message: String)

const INFERENCE_INTERVAL := 0.1
const LEASE_OWNER := "simulation_runtime"
const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")

var _runtime: SimulationRuntime
var _input_graph: Graph = null
var _enabled := false
var _paused := false
var _request_in_flight := false
var _elapsed := 0.0
var _last_error := ""
var _session_id := 0


func _ready() -> void:
	set_process(false)


func configure(runtime: SimulationRuntime) -> void:
	_runtime = runtime


func start() -> bool:
	if _enabled:
		resume()
		return true
	var agents := _agents()
	if agents.is_empty():
		return _fail("Add an agent before running the model.")
	for agent in agents:
		var validation := ModelBinding.validate(agent.get_model_binding())
		if not validation.get("valid", false):
			return _fail(_first_error_message(validation))
	_input_graph = graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME)
	if not is_instance_valid(_input_graph):
		return _fail("Select a project model in Graphs before running the simulation.")
	var properties: Dictionary = _input_graph.useful_properties()
	var graph_input_width := int(properties.get("shape", 0))
	var graph_output_width := _graph_output_width(_input_graph)
	for agent in agents:
		var error := binding_contract_error(agent.get_model_binding(), graph_input_width, graph_output_width)
		if not error.is_empty():
			return _fail(error)
	if not nn.validate_infer_channel(_input_graph):
		return _fail("Train the selected project model before running the simulation.")
	nn.acquire_infer_channel_lease(_input_graph, LEASE_OWNER)
	if not nn.is_infer_channel(_input_graph):
		var opened = await nn.open_infer_channel(_input_graph, _on_channel_closed)
		if not opened or not nn.is_infer_channel(_input_graph):
			nn.release_infer_channel_lease(_input_graph, LEASE_OWNER)
			_input_graph = null
			return _fail("The selected project model could not be started.")
	_enabled = true
	_paused = false
	_request_in_flight = false
	_elapsed = INFERENCE_INTERVAL
	_last_error = ""
	_session_id += 1
	set_process(true)
	status_changed.emit("Model running")
	return true


func pause() -> void:
	if _enabled:
		_paused = true
		_clear_agent_actions()
		status_changed.emit("Model paused")


func resume() -> void:
	if _enabled:
		_paused = false
		_elapsed = INFERENCE_INTERVAL
		status_changed.emit("Model running")


func stop() -> void:
	_session_id += 1
	if is_instance_valid(_input_graph):
		nn.release_infer_channel_lease(_input_graph, LEASE_OWNER)
	_enabled = false
	_paused = false
	_request_in_flight = false
	set_process(false)
	_clear_agent_actions()
	_input_graph = null
	status_changed.emit("Model stopped")


func is_running_model() -> bool:
	return _enabled and not _paused


func last_error() -> String:
	return _last_error


func graph_output_width(input_graph: Node) -> int:
	return _graph_output_width(input_graph)


func _process(delta: float) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"model_runner.process")
	_profiled_process(delta)
	PerformanceProbe.end_scope(&"model_runner.process", perf_token)


func _profiled_process(delta: float) -> void:
	if not _enabled or _paused or _request_in_flight:
		return
	_elapsed += delta
	if _elapsed >= INFERENCE_INTERVAL:
		_elapsed = 0.0
		_run_inference_tick.call_deferred()


func _run_inference_tick() -> void:
	if not _enabled or _paused or _request_in_flight or not is_instance_valid(_input_graph):
		return
	_request_in_flight = true
	var request_session := _session_id
	for agent in _agents():
		if request_session != _session_id or _paused:
			break
		var binding: Dictionary = agent.get_model_binding()
		var encoded: Dictionary = agent.observation_for_binding()
		if not encoded.get("valid", false):
			_fail(_first_error_message(encoded))
			stop()
			break
		var observation: PackedFloat32Array = encoded.get("values", PackedFloat32Array())
		var payload: Dictionary = _input_graph.useful_properties()
		payload["raw_values"] = Array(observation)
		payload["shape"] = observation.size()
		if not await nn.wait_infer_channel_idle(_input_graph, LEASE_OWNER, 2.0):
			continue
		var raw_result = await nn.send_inference_data(_input_graph, payload, true)
		if request_session != _session_id:
			break
		var actions := extract_actions(raw_result if raw_result is Dictionary else {}, int(binding.get("output_width", 0)))
		if actions.is_empty() or not agent.apply_model_outputs(actions).get("valid", false):
			_fail("The project model returned incompatible mapped outputs.")
			stop()
			break
	if request_session == _session_id:
		_request_in_flight = false


func _agents() -> Array:
	if not is_instance_valid(_runtime) or _runtime.kernel() == null:
		return []
	var result := []
	for object_id in _runtime.kernel().agent_object_ids():
		result.append(_runtime.kernel().agent(object_id))
	return result


func _clear_agent_actions() -> void:
	for agent in _agents():
		agent.clear_actions()


func _graph_output_width(input_graph: Node) -> int:
	for graph in graphs.simple_reach(input_graph, true):
		if is_instance_valid(graph) and StringName(graph.server_typename) == &"ClassifierNode":
			var units: Variant = graph.get("units")
			if units is Array:
				return units.size()
	return 0


func _first_error_message(result: Dictionary) -> String:
	for error in result.get("errors", []):
		if error is Dictionary and not str(error.get("message", "")).is_empty():
			return str(error["message"])
	return "The simulation model binding is invalid."


func _on_channel_closed() -> void:
	_session_id += 1
	_enabled = false
	_paused = false
	_request_in_flight = false
	_input_graph = null
	set_process(false)
	status_changed.emit("Model stopped")


func _fail(message: String) -> bool:
	_last_error = message
	status_changed.emit(message)
	return false


static func extract_actions(outputs: Dictionary, required_width: int = 2) -> PackedFloat32Array:
	var flattened: Array[float] = []
	for value in outputs.values():
		_flatten_numbers(value, flattened)
		if flattened.size() >= required_width:
			break
	if required_width <= 0 or flattened.size() < required_width:
		return PackedFloat32Array()
	var result := PackedFloat32Array()
	for index in required_width:
		result.append(clampf(flattened[index], -1.0, 1.0))
	return result


static func binding_shape_error(binding: Dictionary, model_input_width: int) -> String:
	if model_input_width <= 0:
		return "The selected project model does not expose a valid input shape."
	var binding_width := int(binding.get("input_width", 0))
	return "" if binding_width == model_input_width else "The project model expects %d inputs, but this agent mapping provides %d." % [model_input_width, binding_width]


static func binding_contract_error(binding: Dictionary, model_input_width: int, model_output_width: int) -> String:
	var input_error := binding_shape_error(binding, model_input_width)
	if not input_error.is_empty():
		return input_error
	if model_output_width <= 0:
		return "The selected project model does not expose a valid output shape."
	var binding_width := int(binding.get("output_width", 0))
	return "" if binding_width == model_output_width else "The project model provides %d outputs, but this agent mapping requires %d." % [model_output_width, binding_width]


static func _flatten_numbers(value: Variant, output: Array[float]) -> void:
	if value is Array or value is PackedFloat32Array or value is PackedFloat64Array:
		for item in value:
			_flatten_numbers(item, output)
	elif value is float or value is int:
		output.append(float(value))
