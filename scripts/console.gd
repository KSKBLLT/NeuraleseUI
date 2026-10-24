extends RichTextLabel

@export var wheel_mult : float = 6.0  # adjust this to suit
@export var is_custom: bool  =false

var vsb : VScrollBar = null

func _ready():
	# Attempt to get internal VScrollBar
	vsb = get_v_scroll_bar()
	if is_custom:
		# Pixel design: this label's text shader would turn a filled box into ink,
		# so the box stays clear and the backdrop carries the light surface.
		var box := Color(0, 0, 0, 0) if design.pixel else Color(0.014, 0.014, 0.014)
		var backdrop := design.SC_LOW if design.pixel else Color(0.014, 0.014, 0.014)
		get_theme_stylebox("normal").bg_color = box
		get_theme_stylebox("focus").bg_color = box
		if get_parent().get_node_or_null("ColorRect"):
			get_parent().get_node("ColorRect").color = backdrop

func _process(delta: float) -> void:
	pass

	#(get_theme_stylebox("normal").bg_color)

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.is_pressed():
		if event.button_index == MouseButton.MOUSE_BUTTON_WHEEL_UP:
			if vsb:
				#("A")
				vsb.value = max(vsb.min_value, vsb.value - vsb.step * wheel_mult)
				accept_event()
		elif event.button_index == MouseButton.MOUSE_BUTTON_WHEEL_DOWN:
			if vsb:
				vsb.value = min(vsb.max_value, vsb.value + vsb.step * wheel_mult)
				accept_event()
