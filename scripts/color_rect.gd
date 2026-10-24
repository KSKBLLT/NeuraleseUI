extends ColorRect

@export var rect: TextureRect
@export var offset_mult: float = 1.0

func process(_delta: float) -> void:
	var cam: Camera2D = glob.cam
	if not is_instance_valid(cam):
		return

	var active_zoom := cam.zoom
	if is_zero_approx(active_zoom.x) or is_zero_approx(active_zoom.y):
		return

	var background_camera := $"../../Camera2D" as Camera2D
	if not background_camera.position.is_equal_approx(cam.position):
		background_camera.position = cam.position
	if not background_camera.zoom.is_equal_approx(active_zoom):
		background_camera.zoom = active_zoom
	# sub_viewport.gd is the sole owner of the render-target size. The previous
	# second write here fought it every frame and repeatedly recreated the target.
	var target_position := (
		cam.get_screen_center_position()
		- glob.window_size / 2.0 / active_zoom * offset_mult
	)
	if not position.is_equal_approx(target_position):
		position = target_position
	#rect.position = ( cam.position- get_viewport_rect().size/2/cam.zoom)
