extends ColorRect

@onready var base_tuning = glob.inst_uniform_read(self, "tuning")


func _ready() -> void:
	RenderingServer.frame_pre_draw.connect(_sync_visibility)
	_sync_visibility()


func set_tuning(color_: Color):
	RenderingServer.canvas_item_set_instance_shader_parameter(get_canvas_item(), &"tuning", color_)


func _sync_visibility() -> void:
	# This is a full-screen live-screen blur. Alpha zero is visually empty but
	# otherwise still triggers a framebuffer copy and full-screen shader pass.
	var should_show := self_modulate.a > 0.001
	if should_show != visible:
		visible = should_show
