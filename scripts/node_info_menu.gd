extends BlockComponent
class_name NodeInfoMenu

const NodeInfoCatalogCore := preload("res://scripts/node_info_catalog.gd")

signal axon_context_requested(request: Dictionary)

var current_info: Dictionary = {}
var current_lang := "en"


func _ready() -> void:
	super()
	axon_context_requested.connect(_open_axon_context)


func configure_for_node_id(node_id: String, lang: String = "") -> void:
	current_lang = lang if not lang.is_empty() else glob.get_lang()
	current_info = NodeInfoCatalogCore.get_info(node_id, current_lang)
	var title := str(current_info.get("title", ""))
	text = title +  " ".repeat((24-len(title)-1)) + "ⓘ"
	var body := get_body_label()
	if body != null:
		body.text = NodeInfoCatalogCore.render_bbcode(current_info)
	var ask_button := get_ask_button()
	if ask_button != null:
		ask_button.text = NodeInfoCatalogCore.action_label(current_lang)
		if bool(current_info.get("available", false)):
			ask_button.unblock_input(true)
		else:
			ask_button.block_input(true)


func show_for_node(node: Graph, at: Vector2) -> void:
	var node_id := str(node.get_meta("created_with", "")) if is_instance_valid(node) else ""
	configure_for_node_id(node_id)
	menu_show(pos_clamp(at))
	state.holding = false
	unblock_input(true)


func get_ask_button() -> BlockComponent:
	return button_by_hint.get(&"ask_axon")


func get_body_label() -> RichTextLabel:
	var row: BlockComponent = button_by_hint.get(&"text")
	if row == null:
		return null
	return row.get_node_or_null("RichTextLabel")


func get_body_text() -> String:
	var body := get_body_label()
	return body.text if body != null else ""


func _menu_handle_release(button: BlockComponent):
	if button.hint != &"ask_axon" or not bool(current_info.get("available", false)):
		super(button)
		return
	var request_id := "%s-%s" % [str(current_info.get("node_id", "node")), str(Time.get_ticks_usec())]
	var request: Dictionary = NodeInfoCatalogCore.make_axon_request(current_info, current_lang, request_id)
	if not request.is_empty():
		axon_context_requested.emit(request)
	menu_hide()


func _open_axon_context(request: Dictionary) -> void:
	if not glob.require_remote_session():
		return
	var axon_menu = ui.splash("ai_help", self)
	if axon_menu != null and axon_menu.has_method("queue_context_request"):
		axon_menu.queue_context_request(request)
