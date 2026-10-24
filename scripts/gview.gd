extends Node2D

@export var target_offset: Vector2 = Vector2(0, 0)

func _process(delta: float) -> void:
	if position == target_offset:
		return
	var next_position := position.lerp(target_offset, minf(1.0, delta * 20.0))
	if next_position.distance_squared_to(target_offset) < 1e-8:
		next_position = target_offset
	position = next_position
