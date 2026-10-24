class_name RobotLogoArt
extends Control
## The picture on a robot's card: the drawing of its kind of robot as the build
## screen shows it (the virtual one is drawn as the EV3 it imitates), facing up
## so it fills the card's tall frame.

var platform := "dummy"


func _draw() -> void:
	var texture := RobotArtData.view_texture(platform)
	if texture == null:
		return
	var image := texture.get_size()
	# Turned a quarter: the image's length runs along the frame's height.
	var fit := minf(size.y * 0.86 / image.x, size.x * 0.86 / image.y)
	draw_set_transform(size * 0.5, -PI * 0.5, Vector2(fit, fit))
	draw_texture(texture, -image * 0.5, RobotArtData.tint())
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()
