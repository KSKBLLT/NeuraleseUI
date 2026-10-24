class_name RobotText
extends RefCounted
## The robot window's words that come with a robot rather than a network:
## connecting, the PIN, the cards. Everything about a network's inputs and
## outputs is named by RobotLabels; the rest of the window says its own words
## (RobotPanel.say) or is translated by Loc nodes.
##
## Same shape as the project's other dictionaries keyed by language
## ({"ru", "en", "kz"}); a missing translation falls back to Russian, then to
## English, then to the key itself so a gap is visible rather than blank.

const TEXTS := {
	"connect": {"ru": "Подключить →", "en": "Connect →", "kz": "Қосу →"},
	"use_this": {"ru": "Дальше →", "en": "Continue →", "kz": "Әрі қарай →"},
	"tag_bluetooth": {"ru": "Bluetooth", "en": "Bluetooth", "kz": "Bluetooth"},
	"distance_near": {"ru": "≈ %s м · рядом", "en": "≈ %s m · close", "kz": "≈ %s м · жақын"},
	"distance_far": {"ru": "≈ %s м · далеко", "en": "≈ %s m · far", "kz": "≈ %s м · алыста"},
	"distance_unknown": {"ru": "расстояние неизвестно", "en": "distance unknown", "kz": "қашықтық белгісіз"},
	"model_ev3": {"ru": "LEGO MINDSTORMS EV3", "en": "LEGO MINDSTORMS EV3", "kz": "LEGO MINDSTORMS EV3"},
	"model_dummy": {"ru": "Ездит только на экране — настоящий робот не нужен", "en": "Drives on the screen only, no real robot needed", "kz": "Тек экранда жүреді — нақты робот керек емес"},
	"model_replay": {"ru": "Запись поездки настоящего робота", "en": "A recording of a real robot's run", "kz": "Нақты роботтың жүрісінің жазбасы"},
	"stage_connecting": {"ru": "Подключение…", "en": "Connecting…", "kz": "Қосылуда…"},
	"stage_pairing": {
		"ru": "На экране EV3 появится вопрос о подключении — нажмите центральную кнопку. Когда появится код, нажмите её ещё раз.",
		"en": "The EV3's screen will ask to connect: press the centre button. When the code appears, press it again.",
		"kz": "EV3 экранында қосылу туралы сұрақ шығады — ортаңғы батырманы басыңыз. Код шыққанда, оны тағы басыңыз.",
	},
	"stage_repairing": {"ru": "Переподключение к роботу…", "en": "Reconnecting to the robot…", "kz": "Роботқа қайта қосылу…"},
	"stage_waiting_for_port": {"ru": "Ждём ответа робота…", "en": "Waiting for the connection…", "kz": "Байланыс күтілуде…"},
	"stage_inspecting": {"ru": "Смотрим, какие датчики и моторы подключены к роботу…", "en": "Looking at which sensors and motors are plugged into the robot…", "kz": "Роботқа қандай датчиктер мен моторлар қосылғанын қарап жатырмыз…"},
	"pin_title": {"ru": "Подключение к %s", "en": "Connecting to %s", "kz": "%s роботына қосылу"},
	"pin_body": {
		"ru": "Введите код, который покажет EV3 (обычно 1234), и нажмите «Подключить». На экране EV3 появится вопрос о подключении — нажмите центральную кнопку, а когда появится код, нажмите её ещё раз.",
		"en": "Enter the code the EV3 shows (usually 1234) and press Connect. The EV3's screen will ask to connect: press the centre button, and when the code appears, press it again.",
		"kz": "EV3 көрсететін кодты (әдетте 1234) енгізіп, «Қосу» түймесін басыңыз. EV3 экранында қосылу туралы сұрақ шығады — ортаңғы батырманы басыңыз, ал код шыққанда, оны тағы басыңыз.",
	},
	"pin_field": {"ru": "Код робота (PIN)", "en": "Robot code (PIN)", "kz": "Робот коды (PIN)"},
	"pin_go": {"ru": "Подключить", "en": "Connect", "kz": "Қосу"},
	"cancel": {"ru": "Отмена", "en": "Cancel", "kz": "Болдырмау"},
	"link_lost": {
		"ru": "Связь с роботом пропала. Робот остановлен.",
		"en": "The connection to the robot was lost. The robot has been stopped.",
		"kz": "Роботпен байланыс үзілді. Робот тоқтатылды.",
	},
	"low_battery": {"ru": "Батарея робота почти села — он может выключиться посреди поездки.", "en": "The robot's battery is low: it may switch off during the run.", "kz": "Робот батареясы таусылуға жақын: жүріс кезінде сөнуі мүмкін."},
}


## The text broken into lines between words so that each line fits the width
## on the label's font; a word wider than that keeps a line of its own. Lines
## already in the text stay.
static func fit(text: String, label: Label, width: float) -> String:
	if width <= 0.0:
		return text
	var font := label.get_theme_font("font")
	var font_size := label.get_theme_font_size("font_size")
	var lines: PackedStringArray = []
	for paragraph in text.split("\n"):
		var line := ""
		for word in paragraph.split(" ", false):
			var longer := word if line.is_empty() else line + " " + word
			if line.is_empty() or font.get_string_size(longer, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size).x <= width:
				line = longer
			else:
				lines.append(line)
				line = word
		lines.append(line)
	return "\n".join(lines)


static func lang() -> String:
	return str(glob.get_lang())


static func t(key: String) -> String:
	var entry: Variant = TEXTS.get(key)
	if not entry is Dictionary:
		return key
	var code := lang()
	for candidate in [code, "ru", "en"]:
		if entry.has(candidate) and not str(entry[candidate]).is_empty():
			return str(entry[candidate])
	return key


static func tf(key: String, args: Array) -> String:
	return t(key) % args


## A text that came from Python as {"ru", "en", "kz"}.
static func pick(texts: Variant) -> String:
	if not texts is Dictionary:
		return str(texts)
	var code := lang()
	for candidate in [code, "ru", "en"]:
		if texts.has(candidate) and not str(texts[candidate]).is_empty():
			return str(texts[candidate])
	return ""
