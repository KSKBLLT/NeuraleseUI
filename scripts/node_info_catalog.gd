extends RefCounted
class_name NodeInfoCatalog

const CATALOG_PATH := "res://resources/node_info_catalog.json"

const ACTION_LABELS := {
	"en": "Ask Axon",
	"ru": "Спросить Аксона",
	"kz": "Аксоннан сұрау",
}
const QUESTION_TEMPLATES := {
	"en": "What does %s do in this context and overall?",
	"ru": "Что делает %s в этом контексте и в целом?",
	"kz": "%s осы контексте және жалпы не істейді?",
}
const SOURCE_TEMPLATES := {
	"en": "From %s info",
	"ru": "Из описания %s",
	"kz": "%s сипаттамасынан",
}
const MISSING_MESSAGES := {
	"en": "Information about this node is unavailable.",
	"ru": "Информация об этом узле недоступна.",
	"kz": "Бұл түйін туралы ақпарат қолжетімсіз.",
}
const HEADINGS := {
	"en": {"operation": "How it works", "ports": "Connections", "settings": "Settings"},
	"ru": {"operation": "Как это работает", "ports": "Подключения", "settings": "Настройки"},
	"kz": {"operation": "Қалай жұмыс істейді", "ports": "Қосылымдар", "settings": "Баптаулар"},
}
const DIRECTION_LABELS := {
	"en": {"input": "input", "output": "output"},
	"ru": {"input": "вход", "output": "выход"},
	"kz": {"input": "кіріс", "output": "шығыс"},
}

static var _loaded := false
static var _catalog: Dictionary = {}
static var _warnings: Dictionary = {}


static func get_info(node_id: String, requested_lang: String) -> Dictionary:
	var lang := _language(requested_lang)
	var catalog := _load_catalog()
	var nodes: Dictionary = catalog.get("nodes", {})
	if node_id.is_empty() or not nodes.has(node_id) or not nodes[node_id] is Dictionary:
		_warn_once("node:%s" % node_id, "Node information is unavailable for '%s'." % node_id)
		return _unavailable(node_id, lang)

	var document: Dictionary = nodes[node_id]
	var generated: Dictionary = document.get("generated", {})
	var docs: Dictionary = document.get("docs", {})
	var title := _localized(
		docs.get("title", {}),
		"en",
		_localized(generated.get("title_candidates", {}), "en", node_id),
	)
	return {
		"available": true,
		"node_id": node_id,
		"lang": lang,
		"title": title,
		"summary": _localized(docs.get("summary", {}), lang),
		"operation": _localized(docs.get("operation", {}), lang),
		"compact": _localized(docs.get("compact", {}).get("body", {}), lang),
		"ports": _normalize_ports(generated, docs, lang),
		"settings": _normalize_settings(generated, docs, lang),
		"headings": HEADINGS[lang].duplicate(true),
	}


static func action_label(requested_lang: String) -> String:
	return str(ACTION_LABELS[_language(requested_lang)])


static func make_axon_request(info: Dictionary, requested_lang: String, request_id: String) -> Dictionary:
	if not bool(info.get("available", false)):
		return {}
	var lang := _language(requested_lang)
	var title := str(info.get("title", info.get("node_id", "node")))
	return {
		"request_id": request_id,
		"node_id": str(info.get("node_id", "")),
		"question": str(QUESTION_TEMPLATES[lang]) % title,
		"source_label": str(SOURCE_TEMPLATES[lang]) % title,
	}


static func render_bbcode(info: Dictionary) -> String:
	if not bool(info.get("available", false)):
		return _escape_bbcode(str(info.get("message", MISSING_MESSAGES.en)))

	var headings: Dictionary = info.get("headings", HEADINGS.en)
	var lines: Array[String] = [
		"[font_size=30][b]%s[/b][/font_size]" % _escape_bbcode(str(info.get("title", ""))),
	]
	var summary := str(info.get("summary", "")).strip_edges()
	if not summary.is_empty():
		lines.append(_escape_bbcode(summary))
	var operation := str(info.get("operation", "")).strip_edges()
	if not operation.is_empty():
		lines.append("")
		lines.append("[b]%s[/b]" % _escape_bbcode(str(headings.get("operation", "How it works"))))
		lines.append(_escape_bbcode(operation))

	var ports: Array = info.get("ports", [])
	if not ports.is_empty():
		lines.append("")
		lines.append("[b]%s[/b]" % _escape_bbcode(str(headings.get("ports", "Connections"))))
		for port in ports:
			var port_line := "• %s (%s)" % [str(port.get("label", "")), str(port.get("direction_label", ""))]
			var description := str(port.get("description", "")).strip_edges()
			if not description.is_empty():
				port_line += ": %s" % description
			lines.append(_escape_bbcode(port_line))

	var settings: Array = info.get("settings", [])
	if not settings.is_empty():
		lines.append("")
		lines.append("[b]%s[/b]" % _escape_bbcode(str(headings.get("settings", "Settings"))))
		for setting in settings:
			var setting_line := "• %s" % str(setting.get("label", ""))
			var description := str(setting.get("description", "")).strip_edges()
			if not description.is_empty():
				setting_line += ": %s" % description
			lines.append(_escape_bbcode(setting_line))
	return "\n".join(lines)


static func _load_catalog() -> Dictionary:
	if _loaded:
		return _catalog
	_loaded = true
	if not FileAccess.file_exists(CATALOG_PATH):
		_warn_once("catalog:missing", "Node info catalog is missing: %s" % CATALOG_PATH)
		return _catalog
	var file := FileAccess.open(CATALOG_PATH, FileAccess.READ)
	if file == null:
		_warn_once("catalog:open", "Node info catalog cannot be opened: %s" % CATALOG_PATH)
		return _catalog
	var parser := JSON.new()
	var error := parser.parse(file.get_as_text())
	if error != OK or not parser.data is Dictionary:
		_warn_once(
			"catalog:parse",
			"Node info catalog is invalid at line %d: %s" % [parser.get_error_line(), parser.get_error_message()],
		)
		return _catalog
	_catalog = parser.data
	return _catalog


static func _normalize_ports(generated: Dictionary, docs: Dictionary, lang: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var port_docs: Dictionary = docs.get("ports", {})
	for raw_port in generated.get("ports", []):
		if not raw_port is Dictionary:
			continue
		var port: Dictionary = raw_port
		var port_id := str(port.get("id", ""))
		var authored: Dictionary = port_docs.get(port_id, {})
		var label_fallback := str(port.get("server_name", ""))
		if label_fallback.is_empty():
			label_fallback = port_id
		var direction := str(port.get("direction", ""))
		result.append({
			"id": port_id,
			"label": _localized(authored.get("label", {}), "en", label_fallback),
			"description": _localized(authored.get("description", {}), lang),
			"direction": direction,
			"direction_label": str(DIRECTION_LABELS[lang].get(direction, direction)),
			"datatypes": port.get("datatypes", []),
		})
	return result


static func _normalize_settings(generated: Dictionary, docs: Dictionary, lang: String) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var setting_docs: Dictionary = docs.get("settings", {})
	for raw_setting in generated.get("settings", []):
		if not raw_setting is Dictionary:
			continue
		var setting: Dictionary = raw_setting
		var setting_id := str(setting.get("id", ""))
		var authored: Dictionary = setting_docs.get(setting_id, {})
		result.append({
			"id": setting_id,
			"label": _localized(authored.get("label", {}), "en", setting_id),
			"description": _localized(authored.get("description", {}), lang),
			"default": setting.get("default"),
		})
	return result


static func _localized(value: Variant, lang: String, fallback: String = "") -> String:
	if value is Dictionary:
		var localized := str(value.get(lang, "")).strip_edges()
		if not localized.is_empty():
			return localized
		var english := str(value.get("en", "")).strip_edges()
		if not english.is_empty():
			return english
	return fallback


static func _language(requested: String) -> String:
	return requested if requested in ACTION_LABELS else "en"


static func _unavailable(node_id: String, lang: String) -> Dictionary:
	return {
		"available": false,
		"node_id": node_id,
		"lang": lang,
		"title": "",
		"message": MISSING_MESSAGES[lang],
		"ports": [],
		"settings": [],
		"headings": HEADINGS[lang].duplicate(true),
	}


static func _escape_bbcode(value: String) -> String:
	return value.replace("[", "\uE000").replace("]", "[rb]").replace("\uE000", "[lb]")


static func _warn_once(key: String, message: String) -> void:
	if _warnings.has(key):
		return
	_warnings[key] = true
	push_warning(message)
