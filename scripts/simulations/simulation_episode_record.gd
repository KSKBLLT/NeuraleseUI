class_name SimulationEpisodeRecord
extends RefCounted

const FORMAT_VERSION := 1
const TERMINAL_REASONS := [
	&"success",
	&"hazard",
	&"collision",
	&"stuck",
	&"timeout",
	&"cancelled",
	&"sample_limit",
]

var _seed: int
var _agent_id: String
var _binding_id: String
var _steps: Array[Dictionary] = []
var _terminal_reason: StringName = &""
var _metadata: Dictionary = {}


func _init(seed: int = 0, agent_id: String = "", binding_id: String = "") -> void:
	_seed = seed
	_agent_id = agent_id
	_binding_id = binding_id


func append_step(
	observation: PackedFloat32Array,
	target_action: PackedFloat32Array,
	state_before: Dictionary,
	state_after: Dictionary,
	delta: float
) -> bool:
	if not _terminal_reason.is_empty() or delta <= 0.0:
		return false
	if not _finite_values(observation) or not _finite_values(target_action):
		return false
	_steps.append({
		"observation": Array(observation),
		"target_action": Array(target_action),
		"state_before": state_before.duplicate(true),
		"state_after": state_after.duplicate(true),
		"delta": delta,
	})
	return true


func finish(terminal_reason: StringName, metadata: Dictionary = {}) -> bool:
	if not TERMINAL_REASONS.has(terminal_reason):
		return false
	_terminal_reason = terminal_reason
	_metadata = metadata.duplicate(true)
	return true


func to_dictionary() -> Dictionary:
	return {
		"version": FORMAT_VERSION,
		"seed": _seed,
		"agent_id": _agent_id,
		"binding_id": _binding_id,
		"steps": _steps.duplicate(true),
		"terminal_reason": _terminal_reason,
		"metadata": _metadata.duplicate(true),
	}


static func validate(payload: Dictionary) -> Dictionary:
	var errors: Array[Dictionary] = []
	if int(payload.get("version", -1)) != FORMAT_VERSION:
		_add_error(errors, "unsupported_version", "Unsupported episode record version.")
	if str(payload.get("agent_id", "")).is_empty():
		_add_error(errors, "missing_agent", "Episode agent is required.")
	if not TERMINAL_REASONS.has(StringName(payload.get("terminal_reason", ""))):
		_add_error(errors, "invalid_terminal_reason", "Episode terminal reason is invalid.")
	var steps = payload.get("steps", [])
	if steps is not Array or steps.is_empty():
		_add_error(errors, "missing_steps", "Episode must contain at least one step.")
	elif steps is Array:
		for step_index in steps.size():
			var step = steps[step_index]
			if step is not Dictionary:
				_add_error(errors, "invalid_step", "Episode step is malformed.", step_index)
				continue
			if not _finite_values(step.get("observation", [])):
				_add_error(errors, "invalid_observation", "Observation contains a non-finite value.", step_index)
			if not _finite_values(step.get("target_action", [])):
				_add_error(errors, "invalid_target_action", "Target action contains a non-finite value.", step_index)
			if float(step.get("delta", 0.0)) <= 0.0:
				_add_error(errors, "invalid_delta", "Episode step delta must be positive.", step_index)
	return {"valid": errors.is_empty(), "errors": errors}


static func _finite_values(values: Variant) -> bool:
	if values is not Array and values is not PackedFloat32Array and values is not PackedFloat64Array:
		return false
	for value in values:
		if value is not float and value is not int:
			return false
		if is_nan(float(value)) or is_inf(float(value)):
			return false
	return true


static func _add_error(
	errors: Array[Dictionary],
	code: String,
	message: String,
	step_index: int = -1
) -> void:
	var error := {"code": code, "message": message}
	if step_index >= 0:
		error["step_index"] = step_index
	errors.append(error)
