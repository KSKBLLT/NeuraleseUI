extends Node2D

var navigator = null # SimulationNavigator
var current_path: PackedVector2Array = PackedVector2Array()

func _draw() -> void:
	if navigator != null:
		navigator.debug_draw(self)

	if current_path.size() > 1:
		for i in range(current_path.size() - 1):
			draw_line(current_path[i], current_path[i+1], Color(1.0, 0.0, 0.0, 0.8), 4.0)
