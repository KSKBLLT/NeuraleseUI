class_name SimulationKernelAgent
extends RefCounted

const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")
const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")
const SignalCodec = preload("res://scripts/simulations/simulation_signal_codec.gd")

const MAX_OBSERVED_SPEED := 600.0
const DEFAULT_RAY_DISTANCE := 320.0
const DEFAULT_RAY_ARC := 132.0

var _kernel = null
var _index := -1
var _agent_id: StringName = &""
var _physics_kind: StringName = &""
var _binding: Dictionary = {}
var _pending: Dictionary = {}


func configure(kernel, index: int, definition: Dictionary, properties: Dictionary) -> void:
	_kernel = kernel
	_index = index
	_agent_id = StringName(definition.get("agent_id", "side_view_car"))
	_physics_kind = StringName(Registry.agent(_agent_id).get("physics_kind", "ground_rigid"))
	var candidate: Variant = properties.get("model_binding", {})
	_binding = candidate.duplicate(true) if candidate is Dictionary and ModelBinding.validate(candidate).get("valid", false) else ModelBinding.create_default(_agent_id)
	_reset_pending()


func get_agent_id() -> StringName:
	return _agent_id


func get_model_binding() -> Dictionary:
	return _binding.duplicate(true)


func set_model_binding(binding: Dictionary) -> bool:
	if not ModelBinding.validate(binding).get("valid", false) or StringName(binding.get("agent_id", "")) != _agent_id:
		return false
	_binding = binding.duplicate(true)
	return true


func observation_for_binding(context: Dictionary = {}) -> Dictionary:
	var effective_context: Dictionary = _kernel.context_for_agent(_index) if context.is_empty() else context
	return SignalCodec.encode(self, _binding, effective_context)


func apply_model_outputs(outputs: PackedFloat32Array, context: Dictionary = {}) -> Dictionary:
	_reset_pending()
	var effective_context: Dictionary = _kernel.context_for_agent(_index) if context.is_empty() else context
	var decoded := SignalCodec.decode(self, _binding, outputs, effective_context)
	if decoded.get("valid", false):
		_kernel.apply_agent_controls(_index, _physics_kind, _pending)
	else:
		clear_actions()
	return decoded


func apply_actions(actions: PackedFloat32Array) -> void:
	if actions.size() < 2:
		clear_actions()
		return
	_reset_pending()
	_pending["steering"] = clampf(actions[0], -1.0, 1.0)
	_pending["throttle"] = clampf(actions[1], -1.0, 1.0)
	_pending["brake"] = clampf(actions[2], 0.0, 1.0) if actions.size() > 2 else 0.0
	_kernel.apply_agent_controls(_index, _physics_kind, _pending)


func clear_actions() -> void:
	_reset_pending()
	if _kernel != null:
		_kernel.apply_agent_controls(_index, _physics_kind, _pending)


func encode_ray_distance(width: int, _context: Dictionary) -> PackedFloat32Array:
	return _kernel.raycast_fan(_index, width, DEFAULT_RAY_DISTANCE, DEFAULT_RAY_ARC)


func encode_speed(_width: int, _context: Dictionary) -> PackedFloat32Array:
	return PackedFloat32Array([clampf(_kernel.velocity_for(_index).length() / MAX_OBSERVED_SPEED, 0.0, 1.0)])


func encode_velocity_x(_width: int, _context: Dictionary) -> PackedFloat32Array:
	return PackedFloat32Array([clampf(_kernel.velocity_for(_index).x / MAX_OBSERVED_SPEED, -1.0, 1.0)])


func encode_velocity_y(_width: int, _context: Dictionary) -> PackedFloat32Array:
	return PackedFloat32Array([clampf(_kernel.velocity_for(_index).y / MAX_OBSERVED_SPEED, -1.0, 1.0)])


func encode_rotation(_width: int, _context: Dictionary) -> PackedFloat32Array:
	return PackedFloat32Array([wrapf(_kernel.rotation_for(_index), -PI, PI) / PI])


func encode_normalized_position(_width: int, context: Dictionary) -> PackedFloat32Array:
	var bounds: Rect2 = context.get("world_bounds", Rect2(-1.0, -1.0, 2.0, 2.0))
	var value: Vector2 = _kernel.position_for(_index)
	return PackedFloat32Array([_normalize_axis(value.x, bounds.position.x, bounds.end.x), _normalize_axis(value.y, bounds.position.y, bounds.end.y)])


func encode_goal_direction(_width: int, context: Dictionary) -> PackedFloat32Array:
	var delta := _goal_delta(context).normalized()
	return PackedFloat32Array([delta.x, delta.y])


func encode_local_goal_direction(_width: int, context: Dictionary) -> PackedFloat32Array:
	var position: Vector2 = _kernel.position_for(_index)
	var goal_position: Vector2 = context.get("goal_position", position)
	var delta: Vector2 = (goal_position - position).rotated(-_kernel.rotation_for(_index)).normalized()
	return PackedFloat32Array([delta.x, delta.y])


func encode_goal_distance(_width: int, context: Dictionary) -> PackedFloat32Array:
	var bounds: Rect2 = context.get("world_bounds", Rect2(-1.0, -1.0, 2.0, 2.0))
	return PackedFloat32Array([clampf(_goal_delta(context).length() / maxf(float(context.get("max_goal_distance", bounds.size.length())), 0.001), 0.0, 1.0)])


func encode_heading_sincos(_width: int, _context: Dictionary) -> PackedFloat32Array:
	var angle: float = _kernel.rotation_for(_index)
	return PackedFloat32Array([sin(angle), cos(angle)])


func encode_height(_width: int, context: Dictionary) -> PackedFloat32Array:
	var bounds: Rect2 = context.get("world_bounds", Rect2(-1.0, -1.0, 2.0, 2.0))
	return PackedFloat32Array([clampf(1.0 - inverse_lerp(bounds.position.y, bounds.end.y, _kernel.position_for(_index).y), 0.0, 1.0)])


func encode_grounded(_width: int, _context: Dictionary) -> PackedFloat32Array:
	return PackedFloat32Array([1.0 if _kernel.grounded(_index) else 0.0])


func apply_steering(values: PackedFloat32Array, _context: Dictionary) -> void:
	_pending["steering"] = values[0]


func apply_throttle(values: PackedFloat32Array, _context: Dictionary) -> void:
	_pending["throttle"] = values[0]


func apply_brake(values: PackedFloat32Array, _context: Dictionary) -> void:
	_pending["brake"] = values[0]


func apply_horizontal_thrust(values: PackedFloat32Array, _context: Dictionary) -> void:
	_pending["horizontal_thrust"] = values[0]


func apply_vertical_thrust(values: PackedFloat32Array, _context: Dictionary) -> void:
	_pending["vertical_thrust"] = values[0]


func apply_jump(values: PackedFloat32Array, context: Dictionary) -> void:
	_pending["jump"] = values[0]
	_pending["grounded"] = (
		bool(context["grounded"])
		if context.has("grounded")
		else (_kernel != null and _kernel.grounded(_index))
	)


func _reset_pending() -> void:
	_pending = {
		"steering": 0.0,
		"throttle": 0.0,
		"brake": 0.0,
		"horizontal_thrust": 0.0,
		"vertical_thrust": 0.0,
		"jump": 0.0,
		"grounded": false,
	}


func _goal_delta(context: Dictionary) -> Vector2:
	return context.get("navigation_target", context.get("goal_position", _kernel.position_for(_index))) - _kernel.position_for(_index)


func _normalize_axis(value: float, minimum: float, maximum: float) -> float:
	return 0.0 if is_equal_approx(minimum, maximum) else clampf(inverse_lerp(minimum, maximum, value) * 2.0 - 1.0, -1.0, 1.0)
