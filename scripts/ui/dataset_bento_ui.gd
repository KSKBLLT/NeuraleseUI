extends RefCounted
## Dataset Bento: the design's light theme (tokens named after the Claude
## Design file's CSS variables), its JetBrains Mono type, small factories for
## cards, chips and buttons, and every string in Russian, Kazakh and English.

const PAGE := Color("#F1EFF4")
const CARD := Color("#FFFFFF")
const INK := Color("#120F17")
const TEXT_1 := Color("#17141C")
const TEXT_2 := Color("#6B6478")
const TEXT_3 := Color("#8F889A")
const LIST_TEXT := Color("#3D3747")
const CHIP := Color("#F1EEF5")
const BUTTON := Color("#EFECF3")
const BUTTON_HOVER := Color("#E4E0EA")
const WELL := Color("#F3F1F7")
const TILE := Color("#F6F4F9")
const TILE_HOVER := Color("#E8E4EE")
const LINE := Color("#E6E2EC")
const PICKED := Color("#F3E7FC")
const PICKED_SOFT := Color("#EAD8F7")
const VIOLET := Color("#C059FF")
const ON_VIOLET := Color("#140A18")
const VIOLET_TEXT := Color("#8A2FC9")
const MINT := Color("#0E9A73")
const YELLOW := Color("#B88A00")
const CORAL := Color("#F47A79")
const GREY := Color("#717078")

const _FONT_FILE := "res://game_assets/fonts/JetBrainsMono-VariableFont_wght.ttf"
static var _fonts := {}

const TEXT := {
	"datasets": ["Датасеты", "Датасеттер", "Datasets"],
	"tables": ["ТАБЛИЦЫ", "КЕСТЕЛЕР", "TABLES"],
	"images": ["ИЗОБРАЖЕНИЯ", "СУРЕТТЕР", "IMAGES"],
	"table": ["Таблица", "Кесте", "Table"],
	"image": ["Изображения", "Суреттер", "Images"],
	"mistakes": ["Похоже на ошибку", "Қатеге ұқсайды", "Looks like a mistake"],
	"mistakes_rows": ["похожие строки делают по-другому", "ұқсас жолдар басқаша жасайды", "alike rows act differently"],
	"mistakes_frames": ["похожие кадры размечены по-другому", "ұқсас кадрлар басқаша белгіленген", "alike frames are labelled differently"],
	"no_mistakes": ["ошибок не нашлось", "қате табылмады", "no mistakes found"],
	"view": ["Смотреть", "Көру", "Show"],
	"hide": ["Скрыть", "Жасыру", "Hide"],
	"delete": ["Удалить", "Жою", "Delete"],
	"inside": ["Что внутри", "Ішінде не бар", "What's inside"],
	"sees": ["ВИДИТ", "КӨРЕДІ", "SEES"],
	"does": ["ДЕЛАЕТ", "ЖАСАЙДЫ", "DOES"],
	"map": ["Карта похожести", "Ұқсастық картасы", "Likeness map"],
	"map_hint": ["рядом = похожи", "жақын = ұқсас", "close = alike"],
	"situations": ["Ситуации", "Жағдаяттар", "Situations"],
	"all_rows": ["Все строки", "Барлық жолдар", "All rows"],
	"all_frames": ["Все кадры", "Барлық кадрлар", "All frames"],
	"pictures": ["Картинки", "Суреттер", "Pictures"],
	"numbers": ["Числа", "Сандар", "Numbers"],
	"delete_group": ["Удалить группу", "Топты жою", "Delete group"],
	"delete_all": ["Удалить все", "Бәрін жою", "Delete all"],
	"undo": ["↺ Вернуть", "↺ Қайтару", "↺ Undo"],
	"reset": ["Сброс", "Қалпына", "Reset"],
	"empty": ["Здесь пусто", "Мұнда бос", "Nothing here"],
	"preview": ["Превью", "Қарау", "Preview"],
	"row": ["Пример", "Мысал", "Example"],
	"frame": ["Кадр", "Кадр", "Frame"],
	"of": ["из", "/", "of"],
	"keep": ["Оставить", "Қалдыру", "Keep"],
	"ray_legend": ["луч до стены", "қабырғаға дейінгі сәуле", "ray to the wall"],
	"way_legend": ["куда едет", "қайда барады", "where it goes"],
	"inputs_legend": ["признаки", "белгілер", "features"],
	"answer_legend": ["ответ", "жауап", "answer"],
	"speed": ["скорость", "жылдамдық", "speed"],
	"gas": ["газ", "газ", "throttle"],
	"why": ["Похожие строки обычно «%s», а здесь «%s».", "Ұқсас жолдарда әдетте «%s», ал мұнда «%s».", "Alike rows usually say “%s”, this one says “%s”."],
	"deleted": ["удалено %s", "жойылды %s", "%s deleted"],
	"before_training": ["Перед обучением", "Оқытудан бұрын", "Before training"],
	"delete_dataset": ["Удалить датасет", "Датасетті жою", "Delete dataset"],
	"sure": ["Точно удалить?", "Шынымен жою?", "Delete for sure?"],
	"typical": ["Обычные", "Әдеттегі", "Typical"],
	"camera_frame": ["кадр с камеры", "камера кадры", "camera frame"],
	"free": ["Свободно", "Жол бос", "Clear road"],
	"start": ["Старт · разгон", "Старт · екпін", "Start · speeding up"],
	"obstacle": ["Препятствие впереди", "Алда кедергі", "Obstacle ahead"],
	"wall_right": ["Стена справа", "Оң жақта қабырға", "Wall on the right"],
	"wall_left": ["Стена слева", "Сол жақта қабырға", "Wall on the left"],
	"corridor": ["Коридор", "Дәліз", "Corridor"],
	"mixed": ["Смешанный", "Аралас", "Mixed"],
	"brake": ["тормозит", "тежейді", "brakes"],
	"left": ["рулит влево", "солға бұрады", "steers left"],
	"right": ["рулит вправо", "оңға бұрады", "steers right"],
	"straight": ["едет прямо", "тура жүреді", "goes straight"],
	"steering": ["руль", "руль", "steering"],
	"throttle": ["газ", "газ", "throttle"],
}
const _LANGS := ["ru", "kz", "en"]


static func t(key: String) -> String:
	var variants: Array = TEXT[key]
	return variants[maxi(0, _LANGS.find(str(glob.get_lang())))]


## Russian and English count forms; Kazakh nouns do not change after numbers.
static func count(value: int, ru: Array, kz: String, en: Array) -> String:
	var language := str(glob.get_lang())
	var number := group_digits(value)
	if language == "kz":
		return "%s %s" % [number, kz]
	if language == "en":
		return "%s %s" % [number, en[0] if value == 1 else en[1]]
	var tens := value % 100
	var ones := value % 10
	var form: String = ru[2]
	if tens < 11 or tens > 14:
		if ones == 1:
			form = ru[0]
		elif ones >= 2 and ones <= 4:
			form = ru[1]
	return "%s %s" % [number, form]


static func examples(value: int, image: bool) -> String:
	if image:
		return count(value, ["кадр", "кадра", "кадров"], "кадр", ["frame", "frames"])
	return count(value, ["пример", "примера", "примеров"], "мысал", ["example", "examples"])


static func rows_word(value: int, image: bool) -> String:
	if image:
		return count(value, ["кадр", "кадра", "кадров"], "кадр", ["frame", "frames"]).get_slice(" ", 1)
	return count(value, ["строка", "строки", "строк"], "жол", ["row", "rows"]).get_slice(" ", 1)


## «1 024»: thin groups read better than «1024» at a glance.
static func group_digits(value: int) -> String:
	var digits := str(value)
	var grouped := ""
	while digits.length() > 3:
		grouped = " " + digits.right(3) + grouped
		digits = digits.left(digits.length() - 3)
	return digits + grouped


static func short(value: int) -> String:
	if value >= 1000:
		return String.num(value / 1000.0, 1) + "K"
	return str(value)


## JetBrains Mono at a weight; `spacing` widens letters, for the small caps headings.
static func font(weight := 400, spacing := 0) -> Font:
	var key := weight * 10 + spacing
	if not _fonts.has(key):
		var variation := FontVariation.new()
		# design.gd gives the classic font files Google Sans' outlines and keeps
		# JetBrains Mono's own in design.mono.
		var face: Font = design.mono if design.pixel and design.mono else load(_FONT_FILE)
		variation.base_font = face
		variation.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): weight}
		variation.spacing_glyph = spacing
		# The design sets this tab in JetBrains Mono: design.gd keeps it.
		variation.set_meta(&"design_keep", true)
		_fonts[key] = variation
	return _fonts[key]


static func label(text: String, size: int, colour: Color, weight := 400) -> Label:
	var item := Label.new()
	# A plain material keeps design.gd's label shader off these labels.
	item.material = CanvasItemMaterial.new()
	item.text = text
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	item.add_theme_font_override(&"font", font(weight))
	item.add_theme_font_size_override(&"font_size", size)
	item.add_theme_color_override(&"font_color", colour)
	return item


## Remembers which string a label or button shows, for retranslate().
static func tagged(item: Control, key: String) -> Control:
	item.set_meta(&"bento_text", key)
	item.set(&"text", t(key))
	return item


## Puts every tagged string under root into the current language.
static func retranslate(root: Node) -> void:
	for item in root.find_children("*", "Control", true, false):
		if item.has_meta(&"bento_text"):
			item.set(&"text", t(item.get_meta(&"bento_text")))


static func box(colour: Color, radius: int, margin := 0.0) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = colour
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(margin)
	return style


static func card(colour := CARD, margin := 16.0, radius := 14) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override(&"panel", box(colour, radius, margin))
	return panel


static func chip(text: String, size := 13, colour := TEXT_1, background := CHIP, radius := 7) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := box(background, radius)
	style.content_margin_left = 9.0
	style.content_margin_right = 9.0
	style.content_margin_top = 5.0 if size >= 13 else 1.0
	style.content_margin_bottom = 5.0 if size >= 13 else 1.0
	panel.add_theme_stylebox_override(&"panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(label(text, size, colour))
	return panel


static func button(text: String, size := 12, colour := TEXT_1, background := BUTTON, radius := 8, weight := 400) -> Button:
	var item := Button.new()
	item.text = text
	item.focus_mode = Control.FOCUS_NONE
	item.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	item.add_theme_font_override(&"font", font(weight))
	item.add_theme_font_size_override(&"font_size", size)
	for state in [&"font_color", &"font_hover_color", &"font_pressed_color"]:
		item.add_theme_color_override(state, colour)
	var normal := box(background, radius)
	normal.content_margin_left = 10.0
	normal.content_margin_right = 10.0
	normal.content_margin_top = 5.0
	normal.content_margin_bottom = 5.0
	var hover := normal.duplicate() as StyleBoxFlat
	hover.bg_color = BUTTON_HOVER if background == BUTTON else background.lightened(0.08)
	item.add_theme_stylebox_override(&"normal", normal)
	item.add_theme_stylebox_override(&"hover", hover)
	item.add_theme_stylebox_override(&"pressed", hover)
	return item


static func spacer() -> Control:
	var item := Control.new()
	item.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	item.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return item


static func clear(node: Node) -> void:
	for child in node.get_children():
		node.remove_child(child)
		child.queue_free()
