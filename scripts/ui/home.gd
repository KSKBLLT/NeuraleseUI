extends SplashMenu
## Pixel design: the home screen in the spirit of LEGO SPIKE: a left menu, a
## banner with one main action, tiles for projects and the lessons with their
## progress. "Lessons" shows the "Let's continue!" page. It opens in place of
## the startup menu and returns the same actions ({"action": "create",
## "continue" or "tutorials"}); a lesson it opens itself.

const LessonProgress = preload("res://scripts/ui/lesson_progress.gd")
const AxonMascot = preload("res://scripts/ui/axon_mascot.gd")
const NAV_WIDTH := 264.0

const TEXT := {
	"home": {"ru": "Главная", "kz": "Басты бет", "en": "Home"},
	"lessons": {"ru": "Уроки", "kz": "Сабақтар", "en": "Lessons"},
	"projects": {"ru": "Мои проекты", "kz": "Менің жобаларым", "en": "My projects"},
	"ready": {"ru": "Готовые проекты", "kz": "Дайын жобалар", "en": "Ready-made projects"},
	"settings": {"ru": "Настройки", "kz": "Баптаулар", "en": "Settings"},
	"first_title": {"ru": "Собери свой первый ИИ", "kz": "Алғашқы нейрожеліңді құрастыр", "en": "Build your first AI"},
	"first_text": {"ru": "Уроки по шагам: собери сеть, обучи её и проверь, чему она научилась.", "kz": "Қадамдық сабақтар: желіні құрастыр, оқыт және не үйренгенін тексер.", "en": "Step-by-step lessons: build a network, train it and check what it learned."},
	"start": {"ru": "Начать", "kz": "Бастау", "en": "Start"},
	"back_title": {"ru": "С возвращением, %s!", "kz": "Қайта қош келдің, %s!", "en": "Welcome back, %s!"},
	"back_title_plain": {"ru": "С возвращением!", "kz": "Қайта қош келдің!", "en": "Welcome back!"},
	"next_lesson": {"ru": "Дальше: %s", "kz": "Келесі: %s", "en": "Next: %s"},
	"continue": {"ru": "Продолжить", "kz": "Жалғастыру", "en": "Continue"},
	"all_lessons": {"ru": "Все уроки", "kz": "Барлық сабақ", "en": "All lessons"},
	"create": {"ru": "Создать новую ИИ-модель", "kz": "Жаңа ЖИ моделін жасау", "en": "Create a new AI model"},
	"open": {"ru": "Открыть проект", "kz": "Жобаны ашу", "en": "Open project"},
	"tutorials": {"ru": "Готовые ИИ-модели", "kz": "Дайын ЖИ модельдері", "en": "Ready-made AI models"},
	"done_of": {"ru": "Пройдено %d из %d", "kz": "Өтілді: %d / %d", "en": "%d of %d done"},
	"done": {"ru": "Пройден", "kz": "Өтілді", "en": "Done"},
	"now": {"ru": "Сейчас", "kz": "Қазір", "en": "Now"},
	"lesson_n": {"ru": "Урок %d", "kz": "%d-сабақ", "en": "Lesson %d"},
	"go_on": {"ru": "Продолжим!", "kz": "Жалғастырайық!", "en": "Let's continue!"},
	"begin": {"ru": "Начнём!", "kz": "Бастайық!", "en": "Let's start!"},
	"saved_for": {"ru": "Прогресс сохраняется для «%s» на этом компьютере.", "kz": "Прогресс осы компьютерде «%s» үшін сақталады.", "en": "Progress is saved for “%s” on this computer."},
}

var _lang := "ru"
var _plain := CanvasItemMaterial.new()
var _nav_buttons := {}
var _page_box: VBoxContainer
var _lessons: Array[Dictionary] = []


func _ready() -> void:
	typename = "home"
	dismiss_on_outside_click = false
	_lang = str(glob.get_lang())
	_lessons = _read_lessons()
	_build()
	super()


## The home fills the window instead of floating in its centre.
func tick():
	$ColorRect.position = Vector2.ZERO
	$ColorRect.pivot_offset = glob.window_size * 0.5
	target_size = glob.window_size
	$ColorRect.size = glob.window_size


func _build() -> void:
	var sheet: ColorRect = $ColorRect
	sheet.color = design.FRAME_BG
	var nav := Panel.new()
	nav.position = Vector2.ZERO
	nav.size = Vector2(NAV_WIDTH, 2000)
	nav.add_theme_stylebox_override(&"panel", _box(design.SC_LOWEST, 0))
	sheet.add_child(nav)
	var column := VBoxContainer.new()
	column.position = Vector2(20, 22)
	column.size = Vector2(NAV_WIDTH - 40, 860)
	column.add_theme_constant_override(&"separation", 6)
	nav.add_child(column)
	var brand := _label("Neuralese", 24, design.ON_SURFACE, true)
	brand.custom_minimum_size.y = 56
	column.add_child(brand)
	for page in ["home", "lessons", "projects", "ready"]:
		var item := _nav_item(_t(page))
		item.pressed.connect(_on_nav.bind(page))
		_nav_buttons[page] = item
		column.add_child(item)
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	column.add_child(fill)
	var settings := _nav_item(_t("settings"))
	settings.pressed.connect(func(): ui.splash("settings"))
	column.add_child(settings)
	var scroll := ScrollContainer.new()
	scroll.position = Vector2(NAV_WIDTH, 0)
	scroll.size = glob.window_size - Vector2(NAV_WIDTH, 0)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sheet.add_child(scroll)
	var margin := MarginContainer.new()
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in [&"margin_left", &"margin_right"]:
		margin.add_theme_constant_override(side, 44)
	margin.add_theme_constant_override(&"margin_top", 36)
	margin.add_theme_constant_override(&"margin_bottom", 36)
	scroll.add_child(margin)
	_page_box = VBoxContainer.new()
	_page_box.add_theme_constant_override(&"separation", 30)
	margin.add_child(_page_box)
	_show_page("home")


func _on_nav(page: String) -> void:
	match page:
		"projects":
			quit({"action": "continue"})
		"ready":
			quit({"action": "tutorials"})
		_:
			_show_page(page)


func _show_page(page: String) -> void:
	for key in _nav_buttons:
		var face := _box(design.SC_HIGH if key == page else Color(0, 0, 0, 0), 14)
		face.content_margin_left = 16.0
		_nav_buttons[key].add_theme_stylebox_override(&"normal", face)
	for child in _page_box.get_children():
		child.queue_free()
	if page == "lessons":
		_build_lessons_page()
	else:
		_build_home_page()


func _build_home_page() -> void:
	var done := LessonProgress.done_lessons()
	var next := _next_lesson(done)
	var banner := PanelContainer.new()
	var banner_box := _box(design.AXON, 28)
	banner_box.content_margin_left = 52.0
	banner_box.content_margin_right = 40.0
	banner_box.content_margin_top = 40.0
	banner_box.content_margin_bottom = 40.0
	banner.add_theme_stylebox_override(&"panel", banner_box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override(&"separation", 32)
	banner.add_child(row)
	var words := VBoxContainer.new()
	words.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	words.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	words.add_theme_constant_override(&"separation", 14)
	row.add_child(words)
	var student := LessonProgress.student()
	var first_name := student.get_slice(" ", 0) if student != "guest" else ""
	var title_text := _t("first_title")
	var lead_text := _t("first_text")
	if not done.is_empty():
		title_text = _t("back_title") % first_name if not first_name.is_empty() else _t("back_title_plain")
	if not done.is_empty() and not next.is_empty():
		lead_text = _t("next_lesson") % next["title"]
	words.add_child(_label(title_text, 42, Color.WHITE, true))
	var lead := _label(lead_text, 18, Color(1, 1, 1, 0.86))
	lead.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	words.add_child(lead)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override(&"separation", 14)
	var main_action := _pill(_t("continue") if not done.is_empty() else _t("start"), design.SC_LOWEST, design.INK)
	main_action.pressed.connect(_on_main_action.bind(next))
	actions.add_child(main_action)
	var all_lessons := _pill(_t("all_lessons"), Color(1, 1, 1, 0.16), Color.WHITE)
	all_lessons.pressed.connect(_show_page.bind("lessons"))
	actions.add_child(all_lessons)
	words.add_child(actions)
	var sticker := PanelContainer.new()
	sticker.custom_minimum_size = Vector2(300, 200)
	sticker.add_theme_stylebox_override(&"panel", _box(design.SC_LOWEST, 28))
	# Axon waves when the home opens; a child can poke it.
	var mascot := AxonMascot.new()
	mascot.greet_on_show = true
	mascot.pokeable = true
	sticker.add_child(mascot)
	row.add_child(sticker)
	_page_box.add_child(banner)

	var tiles := HBoxContainer.new()
	tiles.add_theme_constant_override(&"separation", 22)
	tiles.add_child(_tile(_TileIcon.PLUS, _t("create"), "create"))
	tiles.add_child(_tile(_TileIcon.FOLDER, _t("open"), "continue"))
	tiles.add_child(_tile(_TileIcon.SPARKLE, _t("tutorials"), "tutorials"))
	_page_box.add_child(tiles)

	var head := HBoxContainer.new()
	head.add_theme_constant_override(&"separation", 16)
	head.add_child(_label(_t("lessons"), 26, design.ON_SURFACE, true))
	var count := _label(_t("done_of") % [_count_done(done), _lessons.size()], 15, design.ON_SURFACE_VAR)
	count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(count)
	var push := Control.new()
	push.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(push)
	var more := _pill(_t("all_lessons") + "  →", Color(0, 0, 0, 0), design.ON_SURFACE)
	more.pressed.connect(_show_page.bind("lessons"))
	head.add_child(more)
	_page_box.add_child(head)
	var cards := HBoxContainer.new()
	cards.add_theme_constant_override(&"separation", 18)
	for lesson in _lessons:
		cards.add_child(_lesson_card(lesson, done, next, false))
	_page_box.add_child(cards)


func _build_lessons_page() -> void:
	var done := LessonProgress.done_lessons()
	var next := _next_lesson(done)
	var title := _label(_t("go_on") if not done.is_empty() else _t("begin"), 56, design.ON_SURFACE, true)
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_box.add_child(title)
	var count := _label(_t("done_of") % [_count_done(done), _lessons.size()], 17, design.ON_SURFACE_VAR)
	count.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_box.add_child(count)
	var cards := HBoxContainer.new()
	cards.alignment = BoxContainer.ALIGNMENT_CENTER
	cards.add_theme_constant_override(&"separation", 22)
	for lesson in _lessons:
		cards.add_child(_lesson_card(lesson, done, next, true))
	_page_box.add_child(cards)
	var note := _label(_t("saved_for") % LessonProgress.student(), 13, design.ON_SURFACE_VAR)
	note.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_page_box.add_child(note)


## A lesson card: number and title; done ones fade with a green tick, the
## current one is outlined in ink with a Continue button, as in SPIKE.
func _lesson_card(lesson: Dictionary, done: Array, next: Dictionary, large: bool) -> Control:
	var is_done: bool = done.has(lesson["key"])
	var is_current: bool = not next.is_empty() and next["key"] == lesson["key"]
	var card := Button.new()
	card.focus_mode = Control.FOCUS_NONE
	card.custom_minimum_size = Vector2(250, 330) if large else Vector2(236, 170)
	var face := _box(design.SC_LOWEST, 24)
	if is_current:
		face.border_color = design.INK
		face.set_border_width_all(2)
	for state in [&"normal", &"hover", &"pressed"]:
		card.add_theme_stylebox_override(state, face)
	card.pressed.connect(_open_lesson.bind(lesson))
	card.modulate.a = 1.0 if is_current else 0.62
	var body := VBoxContainer.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT)
	body.offset_left = 18.0
	body.offset_right = -18.0
	body.offset_top = 18.0
	body.offset_bottom = -18.0
	body.add_theme_constant_override(&"separation", 8)
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	card.add_child(body)
	var art := PanelContainer.new()
	art.custom_minimum_size = Vector2(0, 150 if large else 0)
	art.add_theme_stylebox_override(&"panel", _box(design.SC_LOW if large else Color(0, 0, 0, 0), 18))
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var number := _label(str(lesson["number"]), 64 if large else 30, design.ON_SURFACE, true)
	number.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER if large else HORIZONTAL_ALIGNMENT_LEFT
	number.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	art.add_child(number)
	if is_done:
		var tick := PanelContainer.new()
		tick.add_theme_stylebox_override(&"panel", _box(design.GO, 22))
		tick.size_flags_horizontal = Control.SIZE_SHRINK_END
		tick.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		tick.custom_minimum_size = Vector2(44, 44)
		tick.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var mark := _label("✓", 22, Color.WHITE, true)
		mark.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		mark.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		tick.add_child(mark)
		art.add_child(tick)
	body.add_child(art)
	var lesson_title := _label(lesson["title"], 19 if large else 16, design.ON_SURFACE, true)
	lesson_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lesson_title.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(lesson_title)
	var status_text := _t("lesson_n") % lesson["number"]
	var status_colour := design.ON_SURFACE_VAR
	if is_done:
		status_text = "✓ " + _t("done")
		status_colour = design.GO
	elif is_current:
		status_text = _t("now")
		status_colour = design.INK
	if is_current and large:
		var go_on := _pill(_t("continue"), design.INK, Color.WHITE)
		go_on.pressed.connect(_open_lesson.bind(lesson))
		body.add_child(go_on)
	else:
		body.add_child(_label(status_text, 14, status_colour, is_done or is_current))
	return card


## The banner's button: the next lesson, or the lessons page once all are done.
func _on_main_action(next: Dictionary) -> void:
	if next.is_empty():
		_show_page("lessons")
	else:
		_open_lesson(next)


func _open_lesson(lesson: Dictionary) -> void:
	if lesson.is_empty():
		return
	quit({"action": "lesson"})
	glob.load_lesson(lesson["key"])


## The built-in lessons in course order: "Урок N — Title" entries.
func _read_lessons() -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var pattern := RegEx.create_from_string("(\\d+)\\D*?[—–-]\\s*(.+)")
	var listed: Dictionary = learner.lesson_list()
	for key in listed:
		var found := pattern.search(str(listed[key].get("name", "")))
		if found == null:
			continue
		result.append({"key": key, "number": int(found.get_string(1)), "title": found.get_string(2).strip_edges()})
	return result


func _next_lesson(done: Array) -> Dictionary:
	for lesson in _lessons:
		if not done.has(lesson["key"]):
			return lesson
	return {}


func _count_done(done: Array) -> int:
	var count := 0
	for lesson in _lessons:
		if done.has(lesson["key"]):
			count += 1
	return count


func _tile(kind: int, caption: String, action: String) -> Control:
	var column := VBoxContainer.new()
	column.add_theme_constant_override(&"separation", 10)
	var tile := Button.new()
	tile.custom_minimum_size = Vector2(132, 132)
	tile.focus_mode = Control.FOCUS_NONE
	var face := _box(design.SC_LOWEST, 24)
	face.border_color = design.OUTLINE_VAR
	face.set_border_width_all(1)
	var hover := face.duplicate()
	hover.bg_color = design.SC_LOW
	tile.add_theme_stylebox_override(&"normal", face)
	tile.add_theme_stylebox_override(&"hover", hover)
	tile.add_theme_stylebox_override(&"pressed", hover)
	tile.pressed.connect(func(): quit({"action": action}))
	var icon := _TileIcon.new()
	icon.kind = kind
	icon.set_anchors_preset(Control.PRESET_FULL_RECT)
	icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(icon)
	column.add_child(tile)
	var label := _label(caption, 15, design.ON_SURFACE)
	label.custom_minimum_size.x = 132
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	column.add_child(label)
	return column


func _nav_item(text: String) -> Button:
	var item := Button.new()
	item.text = text
	item.alignment = HORIZONTAL_ALIGNMENT_LEFT
	item.custom_minimum_size = Vector2(0, 48)
	item.focus_mode = Control.FOCUS_NONE
	item.add_theme_font_size_override(&"font_size", 17)
	item.add_theme_color_override(&"font_color", design.ON_SURFACE)
	item.add_theme_color_override(&"font_hover_color", design.ON_SURFACE)
	item.add_theme_color_override(&"font_pressed_color", design.ON_SURFACE)
	var idle := _box(Color(0, 0, 0, 0), 14)
	idle.content_margin_left = 16.0
	item.add_theme_stylebox_override(&"normal", idle)
	var hover := _box(design.SC_LOW, 14)
	hover.content_margin_left = 16.0
	item.add_theme_stylebox_override(&"hover", hover)
	item.add_theme_stylebox_override(&"pressed", hover)
	return item


func _pill(text: String, fill: Color, ink: Color) -> Button:
	var pill := Button.new()
	pill.text = text
	pill.custom_minimum_size = Vector2(0, 52)
	pill.focus_mode = Control.FOCUS_NONE
	pill.add_theme_font_size_override(&"font_size", 17)
	for colour_name in [&"font_color", &"font_hover_color", &"font_pressed_color"]:
		pill.add_theme_color_override(colour_name, ink)
	for state in [&"normal", &"hover", &"pressed"]:
		var box := _box(fill if state == &"normal" else fill.lerp(ink, 0.08), 999)
		box.content_margin_left = 28.0
		box.content_margin_right = 28.0
		pill.add_theme_stylebox_override(state, box)
	return pill


func _label(text: String, font_size: int, colour: Color, bold := false) -> Label:
	var label := Label.new()
	label.text = text
	label.material = _plain
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_theme_font_size_override(&"font_size", font_size)
	label.add_theme_color_override(&"font_color", colour)
	if bold:
		label.add_theme_font_override(&"font", design.sans_title)
	return label


func _box(fill: Color, radius: int) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(radius)
	return box


func _t(key: String) -> String:
	var variants: Dictionary = TEXT[key]
	return variants.get(_lang, variants["ru"])


## Tile pictograms drawn with lines, so they need no icon font.
class _TileIcon extends Control:
	const PLUS := 0
	const FOLDER := 1
	const SPARKLE := 2
	var kind := PLUS

	func _draw() -> void:
		var c := size * 0.5
		var ink := Color("#17161B")
		match kind:
			PLUS:
				draw_line(c - Vector2(18, 0), c + Vector2(18, 0), ink, 4.0, true)
				draw_line(c - Vector2(0, 18), c + Vector2(0, 18), ink, 4.0, true)
			FOLDER:
				var body := Rect2(c - Vector2(24, 12), Vector2(48, 32))
				draw_rect(body, ink, false, 3.0)
				draw_polyline(PackedVector2Array([
					body.position, body.position - Vector2(0, 7), body.position + Vector2(18, -7),
					body.position + Vector2(22, 0)]), ink, 3.0, true)
			SPARKLE:
				var points := PackedVector2Array()
				for i in 8:
					var radius := 24.0 if i % 2 == 0 else 7.0
					var angle := i * PI / 4.0 - PI / 2.0
					points.append(c + Vector2(cos(angle), sin(angle)) * radius)
				points.append(points[0])
				draw_polyline(points, ink, 3.0, true)
