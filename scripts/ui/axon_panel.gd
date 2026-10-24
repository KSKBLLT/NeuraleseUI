extends RefCounted
## Pixel design: the Axon chat as the right side panel of the team's light
## theme. Builds the header, the greeting with the mascot and quick actions,
## and the sign-in / offline state around the existing chat
## (scripts/ai_help.gd), which still sends, streams and keeps the history.

const WorkspaceScript = preload("res://scripts/ui/workspace.gd")
const AxonMascot = preload("res://scripts/ui/axon_mascot.gd")

const TEXT := {
	"title": {"ru": "Аксон", "kz": "Аксон", "en": "Axon"},
	"about": {"ru": "Говорим про", "kz": "Тақырып:", "en": "Talking about"},
	"whole": {"ru": "весь граф", "kz": "бүкіл граф", "en": "the whole graph"},
	"hello": {"ru": "Чем помочь?", "kz": "Немен көмектесейін?", "en": "How can I help?"},
	"intro": {
		"ru": "Я Аксон, помощник по нейросетям. Выбери нод на холсте — разберём его вместе.",
		"kz": "Мен — Аксон, нейрондық желілер бойынша көмекшіңмін. Жұмыс алаңынан нодты таңда — бірге талдаймыз.",
		"en": "I'm Axon, your neural network helper. Pick a node on the canvas and we'll figure it out together.",
	},
	"input": {"ru": "Спроси Аксона…", "kz": "Аксоннан сұра…", "en": "Ask Axon…"},
	"disclaimer": {
		"ru": "Аксон может ошибаться. Проверяй его ответы на своей сети.",
		"kz": "Аксон қателесуі мүмкін. Жауаптарын өз желіңде тексер.",
		"en": "Axon can make mistakes. Check its answers on your own network.",
	},
	"signin": {
		"ru": "Чтобы поговорить с Аксоном, войди в аккаунт.",
		"kz": "Аксонмен сөйлесу үшін аккаунтқа кір.",
		"en": "Sign in to talk to Axon.",
	},
	"signin_button": {"ru": "Войти", "kz": "Кіру", "en": "Sign in"},
	"offline": {
		"ru": "Аксону нужен интернет. Уроки и обучение работают и без него.",
		"kz": "Аксонға интернет керек. Сабақтар мен оқыту онсыз да жұмыс істейді.",
		"en": "Axon needs the internet. Lessons and training work without it.",
	},
	"new_chat": {"ru": "Новый разговор", "kz": "Жаңа әңгіме", "en": "New chat"},
}

## Quick actions: icon, title, hint, and the question sent ({node} is the
## selected node's name; `whole` is used when nothing is selected).
const ACTIONS := [
	{
		"icon": "?",
		"title": {"ru": "Объясни", "kz": "Түсіндір", "en": "Explain"},
		"hint": {"ru": "что это и зачем нужно", "kz": "бұл не және не үшін керек", "en": "what it is and why it's here"},
		"ask": {"ru": "Объясни, что делает «{node}» в моей сети.", "kz": "«{node}» менің желімде не істейтінін түсіндір.", "en": "Explain what {node} does in my network."},
		"whole": {"ru": "Объясни, как работает моя сеть.", "kz": "Менің желім қалай жұмыс істейтінін түсіндір.", "en": "Explain how my network works."},
	},
	{
		"icon": "→",
		"title": {"ru": "Что дальше?", "kz": "Әрі қарай не?", "en": "What's next?"},
		"hint": {"ru": "следующий шаг для твоей сети", "kz": "желіңе келесі қадам", "en": "the next step for your network"},
		"ask": {"ru": "Что мне сделать дальше?", "kz": "Әрі қарай не істеуім керек?", "en": "What should I do next?"},
		"whole": {"ru": "Что мне сделать дальше?", "kz": "Әрі қарай не істеуім керек?", "en": "What should I do next?"},
	},
	{
		"icon": "✓",
		"title": {"ru": "Проверь меня", "kz": "Мені тексер", "en": "Quiz me"},
		"hint": {"ru": "задам вопрос, а ты ответишь", "kz": "сұрақ қоямын, сен жауап бересің", "en": "I ask, you answer"},
		"ask": {"ru": "Задай мне вопрос про «{node}».", "kz": "«{node}» туралы маған сұрақ қой.", "en": "Ask me a question about {node}."},
		"whole": {"ru": "Задай мне вопрос про мою сеть.", "kz": "Менің желім туралы маған сұрақ қой.", "en": "Ask me a question about my network."},
	},
	{
		"icon": "!",
		"title": {"ru": "Почему не работает?", "kz": "Неге жұмыс істемейді?", "en": "Why isn't it working?"},
		"hint": {"ru": "найдём, что мешает учиться", "kz": "оқуға не кедергі екенін табамыз", "en": "let's find what's blocking training"},
		"ask": {"ru": "Почему моя сеть не учится?", "kz": "Неге менің желім үйренбейді?", "en": "Why isn't my network learning?"},
		"whole": {"ru": "Почему моя сеть не учится?", "kz": "Неге менің желім үйренбейді?", "en": "Why isn't my network learning?"},
	},
]

const HEADER_HEIGHT := 112.0
const BODY_TOP := 134.0
const FOOTER_HEIGHT := 112.0

var _menu: Control
var _card: Control
var _scroll: Control
var _input: Control
var _classic_clear: Control
var _header: Panel
var _title: Label
var _close: Button
var _new_chat: Button
var _about: Label
var _dot: Panel
var _node_name: Label
var _intro: VBoxContainer
## Waves when the panel opens, blinks at a picked node, thinks over a question.
var _mascot: AxonMascot
var _greeting: Label
var _intro_text: Label
var _action_buttons: Array[Button] = []
var _gate: VBoxContainer
var _gate_text: Label
var _gate_button: Button
var _disclaimer: Label
var _lang := ""
var _node: Node = null
## Labels here set their own colours, so they skip the design text shader.
var _plain := CanvasItemMaterial.new()


## The panel's place on screen.
func rect() -> Rect2:
	return WorkspaceScript.axon_rect()


## Tells the workspace to make room for the panel, or to take it back.
func set_open(value: bool) -> void:
	WorkspaceScript.axon_open = value


func build(menu: Control) -> void:
	_menu = menu
	_card = menu.get_node("ColorRect")
	_scroll = menu.get_node("ColorRect/ScrollContainer")
	_input = menu.get_node("ColorRect/Label2")
	_classic_clear = menu.get_node_or_null("ColorRect/train")
	design.set_role(_card, design.Role.PANEL)
	design.set_colour(_card, &"design_fill", design.SC_LOWEST)
	# The classic "/axon" header and its scroll shades give way to the new header.
	for path in ["ColorRect/root/i", "ColorRect/root/Label", "ColorRect/root/TextureRect", "ColorRect/root/TextureRect2"]:
		var old := menu.get_node_or_null(path) as CanvasItem
		if old:
			old.modulate.a = 0.0
	_build_header()
	_build_intro()
	_build_gate()
	_disclaimer = _label(12, design.ON_SURFACE_VAR)
	_disclaimer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_disclaimer.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_card.add_child(_disclaimer)
	_style_input()


func update() -> void:
	var lang: String = glob.curr_lang
	if lang != _lang:
		_apply_texts(lang)
	if is_instance_valid(_classic_clear) and _classic_clear.visible:
		_classic_clear.hide()
	var signed_in: bool = glob.logged_in()
	var online: bool = glob.remote_session_ready()
	var empty: bool = _menu.get_last_message() == null
	_gate.visible = not online
	_gate_text.text = _t("offline") if signed_in else _t("signin")
	_gate_button.visible = not signed_in
	_intro.visible = online and empty
	_scroll.visible = not empty
	_input.visible = online
	_new_chat.visible = online and not empty
	_update_context()
	_layout()
	_block_canvas_under_mouse()


func _layout() -> void:
	var size: Vector2 = _card.size
	_header.position = Vector2(10, 10)
	_header.size = Vector2(size.x - 20, HEADER_HEIGHT)
	_close.position = Vector2(_header.size.x - 50, 14)
	_new_chat.position = Vector2(_header.size.x - 60 - _new_chat.size.x, 18)
	var body_bottom := size.y - FOOTER_HEIGHT
	_intro.position = Vector2(22, BODY_TOP)
	_intro.size = Vector2(size.x - 44, body_bottom - BODY_TOP)
	_gate.position = _intro.position
	_gate.size = _intro.size
	_scroll.position = Vector2(12, BODY_TOP)
	_scroll.size = Vector2(size.x - 24, body_bottom - BODY_TOP)
	_input.offset_left = 16.0
	_input.offset_right = size.x - 16.0
	_disclaimer.position = Vector2(18, size.y - 42)
	_disclaimer.size = Vector2(size.x - 36, 36)


func _build_header() -> void:
	_header = Panel.new()
	_header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_header.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	var shape := StyleBoxFlat.new()
	shape.bg_color = design.AXON_MINT_SOFT
	shape.set_corner_radius_all(20)
	_header.add_theme_stylebox_override(&"panel", shape)
	var wash := TextureRect.new()
	var gradient := GradientTexture2D.new()
	gradient.gradient = Gradient.new()
	gradient.gradient.set_color(0, design.AXON_MINT)
	gradient.gradient.set_color(1, design.AXON_MINT_SOFT)
	gradient.fill_from = Vector2(0, 0)
	gradient.fill_to = Vector2(0, 1)
	wash.texture = gradient
	wash.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	wash.stretch_mode = TextureRect.STRETCH_SCALE
	wash.mouse_filter = Control.MOUSE_FILTER_IGNORE
	wash.set_anchors_preset(Control.PRESET_FULL_RECT)
	_header.add_child(wash)
	_title = _label(28, design.ON_SURFACE)
	_title.add_theme_font_override(&"font", design.sans_title)
	_title.position = Vector2(20, 14)
	_header.add_child(_title)
	var context := HBoxContainer.new()
	context.add_theme_constant_override(&"separation", 7)
	context.position = Vector2(20, 72)
	_about = _label(15, design.ON_SURFACE_VAR)
	_dot = Panel.new()
	_dot.custom_minimum_size = Vector2(10, 10)
	_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_node_name = _label(15, design.ON_SURFACE)
	_node_name.add_theme_font_override(&"font", design.sans_title)
	for part in [_about, _dot, _node_name]:
		context.add_child(part)
	_header.add_child(context)
	_card.add_child(_header)
	# Buttons sit on the card, above the clipped header, so they take clicks.
	_close = _circle_button("✕")
	_close.pressed.connect(func(): _menu.go_away())
	_card.add_child(_close)
	_new_chat = Button.new()
	_new_chat.flat = true
	_new_chat.add_theme_font_size_override(&"font_size", 13)
	_new_chat.add_theme_color_override(&"font_color", design.ON_SURFACE_VAR)
	_new_chat.pressed.connect(func(): _menu._on_cl_released())
	_card.add_child(_new_chat)


func _build_intro() -> void:
	_intro = VBoxContainer.new()
	_intro.add_theme_constant_override(&"separation", 10)
	_mascot = _new_mascot()
	_intro.add_child(_mascot)
	_greeting = _label(24, design.ON_SURFACE)
	_greeting.add_theme_font_override(&"font", design.sans_title)
	_intro.add_child(_greeting)
	_intro_text = _label(15, design.ON_SURFACE_VAR)
	_intro_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_intro.add_child(_intro_text)
	for i in ACTIONS.size():
		var card := _action_card(ACTIONS[i]["icon"])
		card.pressed.connect(_ask.bind(i))
		card.mouse_entered.connect(func(): _mascot.react(&"think"))
		_action_buttons.append(card)
		_intro.add_child(card)
	_card.add_child(_intro)


func _build_gate() -> void:
	_gate = VBoxContainer.new()
	_gate.add_theme_constant_override(&"separation", 14)
	_gate.add_child(_new_mascot())
	_gate_text = _label(16, design.ON_SURFACE)
	_gate_text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_gate_text.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_gate.add_child(_gate_text)
	_gate_button = Button.new()
	_gate_button.custom_minimum_size = Vector2(0, 46)
	_gate_button.add_theme_font_size_override(&"font_size", 16)
	_gate_button.add_theme_color_override(&"font_color", Color.WHITE)
	_gate_button.add_theme_color_override(&"font_hover_color", Color.WHITE)
	_gate_button.add_theme_color_override(&"font_pressed_color", Color.WHITE)
	for state in [&"normal", &"hover", &"pressed", &"focus"]:
		var fill := StyleBoxFlat.new()
		fill.bg_color = design.AXON.lightened(0.08) if state == &"hover" else design.AXON
		fill.set_corner_radius_all(999)
		_gate_button.add_theme_stylebox_override(state, fill)
	_gate_button.pressed.connect(func(): glob.fg._on_login_released())
	_gate.add_child(_gate_button)
	_card.add_child(_gate)


func _apply_texts(lang: String) -> void:
	_lang = lang
	_title.text = _t("title")
	_about.text = _t("about")
	_greeting.text = _t("hello")
	_intro_text.text = _t("intro")
	_gate_button.text = _t("signin_button")
	_new_chat.text = _t("new_chat")
	_disclaimer.text = _t("disclaimer")
	_input.set(&"placeholder_text", _t("input"))
	for i in ACTIONS.size():
		var action: Dictionary = ACTIONS[i]
		_action_buttons[i].get_node("Row/Text/Title").text = _pick(action["title"])
		_action_buttons[i].get_node("Row/Text/Hint").text = _pick(action["hint"])


## The node the student has selected, shown as "Talking about ● node".
func _update_context() -> void:
	var selected: Node = null
	for graph in graphs.selected_nodes:
		if is_instance_valid(graph):
			selected = graph
			break
	if selected == _node and _node_name.text != "":
		return
	if selected != null and _node_name.text != "":
		_mascot.react(&"blink")
	_node = selected
	var dot_style := StyleBoxFlat.new()
	dot_style.set_corner_radius_all(5)
	if selected == null:
		_node_name.text = _t("whole")
		dot_style.bg_color = design.OUTLINE
	else:
		_node_name.text = _node_title(selected)
		dot_style.bg_color = design.category_colours(design.category_of(selected)).get("accent", design.OUTLINE)
	_dot.add_theme_stylebox_override(&"panel", dot_style)


func _ask(index: int) -> void:
	var action: Dictionary = ACTIONS[index]
	var question: String
	var source := ""
	if is_instance_valid(_node):
		source = _node_title(_node)
		question = _pick(action["ask"]).replace("{node}", source)
	else:
		question = _pick(action["whole"])
	_menu.send_message(question, source)


func _node_title(graph: Node) -> String:
	var title := graph.get_node_or_null("ColorRect/root/Label") as Label
	return title.text if title else str(graph.name)


## The canvas must not zoom or take clicks while the pointer is over the panel.
func _block_canvas_under_mouse() -> void:
	if _card.get_global_rect().has_point(_card.get_global_mouse_position()):
		glob.occupy(_card, &"menu_inside")
		glob.set_scroll_impossible(_card)
	else:
		glob.un_occupy(_card, &"menu_inside")
		glob.set_scroll_possible(_card)


func _style_input() -> void:
	for state in [&"normal", &"focus", &"read_only"]:
		var field := StyleBoxFlat.new()
		field.bg_color = design.SC_LOWEST
		field.border_color = design.AXON_ACTION_ICON
		field.set_border_width_all(2)
		field.set_corner_radius_all(18)
		field.content_margin_left = 16.0
		field.content_margin_right = 52.0
		field.content_margin_top = 12.0
		field.content_margin_bottom = 12.0
		_input.add_theme_stylebox_override(state, field)
	_input.offset_top = -102.0
	_input.offset_bottom = -50.0


func _action_card(icon: String) -> Button:
	var card := Button.new()
	card.custom_minimum_size = Vector2(0, 62)
	card.focus_mode = Control.FOCUS_NONE
	for state in [&"normal", &"hover", &"pressed"]:
		var fill := StyleBoxFlat.new()
		fill.bg_color = design.AXON_ACTION.darkened(0.04) if state != &"normal" else design.AXON_ACTION
		fill.set_corner_radius_all(18)
		card.add_theme_stylebox_override(state, fill)
	var row := HBoxContainer.new()
	row.name = &"Row"
	row.set_anchors_preset(Control.PRESET_FULL_RECT)
	row.offset_left = 12.0
	row.offset_right = -14.0
	row.add_theme_constant_override(&"separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var badge := Panel.new()
	badge.custom_minimum_size = Vector2(36, 36)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = design.AXON_ACTION_ICON
	badge_style.set_corner_radius_all(18)
	badge.add_theme_stylebox_override(&"panel", badge_style)
	var glyph := _label(17, Color.WHITE)
	glyph.text = icon
	glyph.set_anchors_preset(Control.PRESET_FULL_RECT)
	glyph.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	glyph.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	badge.add_child(glyph)
	var text := VBoxContainer.new()
	text.name = &"Text"
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	text.add_theme_constant_override(&"separation", 0)
	text.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var title := _label(15, design.ON_SURFACE)
	title.name = &"Title"
	title.add_theme_font_override(&"font", design.sans_title)
	var hint := _label(12, design.ON_SURFACE_VAR)
	hint.name = &"Hint"
	text.add_child(title)
	text.add_child(hint)
	var arrow := _label(18, design.AXON_ACTION_ICON)
	arrow.text = "→"
	arrow.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for part in [badge, text, arrow]:
		row.add_child(part)
	card.add_child(row)
	return card


func _new_mascot() -> AxonMascot:
	var mascot := AxonMascot.new()
	mascot.custom_minimum_size = Vector2(0, 128)
	mascot.greet_on_show = true
	return mascot


func _circle_button(glyph: String) -> Button:
	var button := Button.new()
	button.text = glyph
	button.custom_minimum_size = Vector2(38, 38)
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override(&"font_size", 15)
	button.add_theme_color_override(&"font_color", design.ON_SURFACE)
	for state in [&"normal", &"hover", &"pressed"]:
		var fill := StyleBoxFlat.new()
		fill.bg_color = design.SC_LOWEST if state == &"normal" else design.SC_HIGH
		fill.set_corner_radius_all(999)
		button.add_theme_stylebox_override(state, fill)
	return button


func _label(font_size: int, colour: Color) -> Label:
	var label := Label.new()
	label.material = _plain
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", colour)
	return label


func _t(key: String) -> String:
	return _pick(TEXT[key])


func _pick(variants: Dictionary) -> String:
	return variants.get(_lang, variants.get("ru", ""))
