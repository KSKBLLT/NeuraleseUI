extends SceneTree

const KernelAgent = preload("res://scripts/simulations/simulation_kernel_agent.gd")

class FakeProvider:
	extends RefCounted

	var steering := 0.0
	var throttle := 0.0
	var brake := 0.0

	func encode_ray_distance(width: int, _context: Dictionary) -> PackedFloat32Array:
		var result := PackedFloat32Array()
		for index in width:
			result.append(float(index + 1) / float(width))
		return result

	func encode_speed(_width: int, _context: Dictionary) -> PackedFloat32Array:
		return PackedFloat32Array([0.25])

	func apply_steering(values: PackedFloat32Array, _context: Dictionary) -> void:
		steering = values[0]

	func apply_throttle(values: PackedFloat32Array, _context: Dictionary) -> void:
		throttle = values[0]

	func apply_brake(values: PackedFloat32Array, _context: Dictionary) -> void:
		brake = values[0]


class MissingEncoderProvider:
	extends RefCounted


var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var codec_path := "res://scripts/simulations/simulation_signal_codec.gd"
	_expect(ResourceLoader.exists(codec_path), "simulation signal codec must exist")
	if not ResourceLoader.exists(codec_path):
		_finish()
		return

	var codec = load(codec_path)
	_expect(codec != null and codec.can_instantiate(), "simulation signal codec must parse")
	if codec == null or not codec.can_instantiate():
		_finish()
		return

	var binding := {
		"version": 1,
		"agent_id": "side_view_car",
		"input_width": 5,
		"output_width": 3,
		"inputs": [
			{"sensor_id": "ray_distance", "start": 0, "length": 4},
			{"sensor_id": "speed", "start": 4, "length": 1},
		],
		"outputs": [
			{"actuator_id": "steering", "start": 0, "length": 1},
			{"actuator_id": "throttle", "start": 1, "length": 1},
			{"actuator_id": "brake", "start": 2, "length": 1},
		],
	}
	var provider := FakeProvider.new()
	var encoded: Dictionary = codec.encode(provider, binding)
	_expect(encoded.get("valid") == true, "codec must encode a valid mapped observation")
	_expect(
		encoded.get("values") == PackedFloat32Array([0.25, 0.5, 0.75, 1.0, 0.25]),
		"codec must place sensor values into their mapped model ranges"
	)

	var decoded: Dictionary = codec.decode(
		provider,
		binding,
		PackedFloat32Array([2.0, -0.5, 1.4])
	)
	_expect(decoded.get("valid") == true, "codec must decode complete model output")
	_expect(is_equal_approx(provider.steering, 1.0), "codec must clamp steering to its registry range")
	_expect(is_equal_approx(provider.throttle, 0.0), "codec must clamp throttle to its registry range")
	_expect(is_equal_approx(provider.brake, 1.0), "codec must clamp brake to its registry range")

	var missing_encoder: Dictionary = codec.encode(MissingEncoderProvider.new(), binding)
	_expect(not missing_encoder.get("valid", true), "missing encoder implementation must fail safely")
	_expect(_has_code(missing_encoder, "missing_encoder"), "codec failures must be machine-readable")

	var short_output: Dictionary = codec.decode(provider, binding, PackedFloat32Array([0.0, 1.0]))
	_expect(not short_output.get("valid", true), "wrong model output width must fail before applying actions")
	_expect(_has_code(short_output, "output_width_mismatch"), "output width failure must be explicit")

	var jump_binding := binding.duplicate(true)
	jump_binding["outputs"] = [
		{"actuator_id": "steering", "start": 0, "length": 1},
		{"actuator_id": "throttle", "start": 1, "length": 1},
		{"actuator_id": "jump", "start": 2, "length": 1},
	]
	var kernel_agent := KernelAgent.new()
	var jump_decoded: Dictionary = codec.decode(
		kernel_agent,
		jump_binding,
		PackedFloat32Array([0.5, 1.0, 1.0])
	)
	_expect(jump_decoded.get("valid") == true, "side-view agent must decode a mapped jump output")
	_expect(is_equal_approx(float(kernel_agent._pending.get("jump", 0.0)), 1.0), "decoded jump output must reach pending physics controls")
	_finish()


func _has_code(result: Dictionary, code: String) -> bool:
	for error in result.get("errors", []):
		if error is Dictionary and str(error.get("code", "")) == code:
			return true
	return false


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_signal_codec")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_signal_codec: %d failure(s)" % failures.size())
	quit(1)
