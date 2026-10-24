extends RefCounted
class_name IdleCamera

## Disables Camera2D's idle polling while preserving assignment-driven updates.
## Re-entering the tree re-enables native polling, so an idempotent hook applies
## the optimization again after Camera2D's own enter-tree handling.


static func apply(camera: Camera2D) -> void:
	if not is_instance_valid(camera):
		return
	var callback := _on_tree_entered.bind(camera)
	if not camera.tree_entered.is_connected(callback):
		camera.tree_entered.connect(callback)
	_disable_polling(camera)


static func _on_tree_entered(camera: Camera2D) -> void:
	_disable_polling(camera)


static func _disable_polling(camera: Camera2D) -> void:
	if camera.is_inside_tree():
		camera.set_process_internal(false)
		camera.set_physics_process_internal(false)
		camera.force_update_scroll()
