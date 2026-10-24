@tool

extends BlockComponent

@onready var par = get_parent()


func _ready() -> void:
	if not Engine.is_editor_hint():
		super()


func _process(delta: float) -> void:
	super(delta)


var passed_who: String = ""

func show_up(iter, _node = null) -> void:
	var vocab_ref = get_node_or_null("ProceduralNodes") if has_node("ProceduralNodes") else glob.getref("vocabulary")
	if is_instance_valid(vocab_ref):
		vocab_ref.unroll(iter)
	await get_tree().process_frame
	if not mouse_open:
		menu_show(position)
	state.holding = false
	unblock_input()
	tune(passed_who)


func tune(with_who: String) -> void:
	if with_who:
		var wh = button_by_hint.get(with_who)
		if wh:
			wh.set_tuning(wh.base_tuning * 1.8)
