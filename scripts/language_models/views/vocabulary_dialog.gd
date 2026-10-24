extends PopupPanel
const S = preload("res://scripts/language_models/language_style.gd")
var session_id := ""
var revision := 0
var service: Node
var rows: VBoxContainer
var search: LineEdit
var page_label: Label
var offset := 0
var total := 0
var _pending := -1

func open(value: Node, sid: String, graph_revision: int) -> void:
	service = value; session_id = sid; revision = graph_revision
	theme = preload("res://resources/theme.tres")
	transient = true
	add_theme_stylebox_override("panel",S.box(Color("202725"),Color(S.ACCENT,0.6),12))
	var layout := VBoxContainer.new(); layout.add_theme_constant_override("separation",12); add_child(layout)
	var title := S.label(S.localized("Vocabulary","Словарь","Сөздік"),S.INK,15); layout.add_child(title)
	search = S.line_field(); search.placeholder_text = S.localized("Find token or ID…","Найти токен или ID…","Токен немесе ID…"); S.field(search); layout.add_child(search)
	search.text_changed.connect(func(_text): offset=0; _request())
	var scroll := ScrollContainer.new(); scroll.theme=preload("res://resources/theme.tres"); scroll.custom_minimum_size = Vector2(380,370); layout.add_child(scroll)
	rows = VBoxContainer.new(); rows.size_flags_horizontal=Control.SIZE_EXPAND_FILL; scroll.add_child(rows)
	var controls := HBoxContainer.new(); controls.add_theme_constant_override("separation",12); layout.add_child(controls)
	controls.add_child(S.button("‹",func(): offset=maxi(0,offset-50); _request()))
	page_label = S.label(""); page_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL; controls.add_child(page_label)
	controls.add_child(S.button("›",func():
		if offset+50<total: offset+=50; _request()))
	controls.add_child(S.button(S.localized("Close","Закрыть","Жабу"),hide))
	service.response_ready.connect(_response)
	popup_hide.connect(queue_free)
	popup_centered(Vector2i(420,500))
	_request()

func _request() -> void:
	_pending = service.request(&"vocabulary_page",{"query":search.text,"offset":offset,"limit":50},session_id,revision)

func _response(response: Dictionary) -> void:
	if response.get("request_id") != _pending: return
	if not response.ok: page_label.text=str(response.error.message); return
	set_page(response.result)

func set_page(page: Dictionary) -> void:
	for row in rows.get_children(): rows.remove_child(row); row.queue_free()
	total = int(page.total)
	for entry in page.entries:
		rows.add_child(S.label("#%d   %s" % [entry.id,entry.piece],S.INK,12))
	page_label.text = "%d–%d / %d" % [mini(offset+1,total),mini(offset+50,total),total]

func _exit_tree() -> void:
	if is_instance_valid(service) and service.response_ready.is_connected(_response): service.response_ready.disconnect(_response)
