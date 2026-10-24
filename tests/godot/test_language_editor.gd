extends Node
func _ready() -> void:
	for i in 12: await get_tree().process_frame
	await load("res://scripts/language_models/language_demo.gd").verify_and_capture(get_tree())
