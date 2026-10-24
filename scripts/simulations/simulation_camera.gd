class_name SimulationCamera
extends GraphViewport

var min_zoom: float:
	get: return MIN_ZOOM

var max_zoom: float:
	get: return MAX_ZOOM

func focus_world_position(world_position: Vector2) -> void:
	target_position = world_position
	position = world_position

func set_navigation_enabled(value: bool) -> void:
	if value:
		resume()
	else:
		stop()

func navigation_enabled() -> bool:
	return not paused
