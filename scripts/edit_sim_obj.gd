@tool
extends BlockComponent
# edit simulation object menu
@export var implement: bool = true

var menu_call: Callable
var menu_call_alt: Callable

func show_for_objects(count: int, call_delete: Callable, call_copy: Callable):
	
	if count == 1:
		match glob.get_lang():
			"en": text = "Object      *"
			"ru": text = "Объект      *"
			"kz": text = "Нысан       *"
			_: text = "Object      *"
	else:
		var s = str(count)
		match glob.get_lang():
			"en": text = s + " Objects *"
			"ru": text = s + " Объектов*"
			"kz": text = s + " Нысан   *"
			_: text = s + " Objects *"
			
	menu_call = call_delete
	menu_call_alt = call_copy
	menu_show(pos_clamp(get_global_mouse_position()))
	state.holding = false
	while not glob.space_pressed:
		await get_tree().process_frame
	menu_hide()

func pos_clamp(pos: Vector2):
	last_mouse_pos = pos
	pos.x = clamp(pos.x, 0.0, glob.space_end.x - size.x * mult.x)
	if not expand_upwards:
		var max = min(max_size, expanded_size) if max_size else expanded_size
		pos.y = clamp(pos.y, 0.0, glob.space_end.y - max * mult.y)
	return pos

func _process(delta: float) -> void:
	super(delta)

func _menu_handle_release(button: BlockComponent):
	if implement:
		if button.hint == "copy":
			menu_call_alt.call()
			menu_hide()
		elif button.hint == "delete":
			menu_call.call()
			menu_hide()
