extends TextureRect

func _process(delta: float):
	$"../SubViewport/bg/ColorRect".process(delta)
	#global_position = glob.cam.global_position-glob.window_size/2
