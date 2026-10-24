class_name SimulationDropSurface
extends Control

signal object_dropped(type_id: StringName, viewport_position: Vector2)

func _ready():
	glob.sim_ui = self

func _can_drop_data(_at_position: Vector2, data: Variant) -> bool:
	return (
		data is Dictionary
		and data.has("simulation_type_id")
		and not str(data["simulation_type_id"]).is_empty()
	)


func _drop_data(at_position: Vector2, data: Variant) -> void:
	if not _can_drop_data(at_position, data):
		return
	object_dropped.emit(StringName(data["simulation_type_id"]), at_position)
