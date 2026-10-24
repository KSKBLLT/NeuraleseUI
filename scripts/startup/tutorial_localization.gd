class_name TutorialLocalization
extends RefCounted

const LANGUAGES := ["en", "ru", "kz"]


static func text(value: Variant, language: String, fallback: String = "") -> String:
	var resolved: Variant = _resolve(value, language)
	if resolved is String or resolved is StringName:
		var output := str(resolved).strip_edges()
		return output if not output.is_empty() else fallback
	if resolved is Array:
		var lines: Array[String] = []
		for item in resolved:
			var line := str(item).strip_edges()
			if not line.is_empty():
				lines.append(line)
		return "\n".join(lines) if not lines.is_empty() else fallback
	return fallback


static func segments(value: Variant, language: String) -> Array[String]:
	var resolved: Variant = _resolve(value, language)
	var output: Array[String] = []
	if resolved is Array:
		for item in resolved:
			var line := str(item).strip_edges()
			if not line.is_empty():
				output.append(line)
	elif resolved is String or resolved is StringName:
		var line := str(resolved).strip_edges()
		if not line.is_empty():
			output.append(line)
	return output


static func is_valid(value: Variant, allow_segments: bool = false) -> bool:
	if value is String or value is StringName:
		return not str(value).strip_edges().is_empty()
	if allow_segments and value is Array:
		return not segments(value, "en").is_empty()
	if typeof(value) != TYPE_DICTIONARY or value.is_empty():
		return false
	for language in LANGUAGES:
		if not value.has(language):
			return false
		var localized: Variant = value[language]
		if allow_segments:
			if segments(localized, language).is_empty():
				return false
		elif not (localized is String or localized is StringName) or str(localized).strip_edges().is_empty():
			return false
	return true


static func _resolve(value: Variant, language: String) -> Variant:
	if typeof(value) != TYPE_DICTIONARY:
		return value
	var normalized := language.to_lower().strip_edges()
	if normalized == "kk":
		normalized = "kz"
	for candidate in [normalized, "en", "ru", "kz"]:
		if value.has(candidate):
			return value[candidate]
	for candidate in value.values():
		return candidate
	return ""
