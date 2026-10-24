extends RefCounted
class_name DialogSpec

const DEFAULT_ICON_PATH := "res://game_assets/icons/warn.png"
const DEFAULT_SIZE := Vector2(480, 280)
const MIN_SIZE := Vector2(280, 160)
const VIEWPORT_MARGIN := Vector2(48, 48)
const SUPPORTED_FORMATS := ["plain", "markdown"]
const SUPPORTED_BUTTON_STYLES := ["primary", "secondary"]
const SUPPORTED_SURFACES := ["default", "transparent"]
const SUPPORTED_ACTION_LAYOUTS := ["horizontal", "vertical"]
const SUPPORTED_CLOSE_MODES := ["animated", "handoff"]
const SUPPORTED_BUTTON_TEXT_ALIGNMENTS := ["left", "center", "right"]
const SUPPORTED_FIELD_TYPES := ["text", "choice"]
const DEFAULT_APPEARANCE := {
	"show_icon": true,
	"title_font_size": 22,
	"body_font_size": 16,
	"button_height": 32.0,
	"button_width": 0.0,
	"button_font_scale": 0.45,
	"button_text_alignment": "center",
	"button_text_padding": 0.0,
	"field_columns": 1,
	"field_height": 40.0,
	"field_font_size": 18,
	"field_font_scale": 0.5,
	"field_label_font_size": 14,
	"action_separation": 10,
	"hide_node_palette": false,
}


static func normalize(spec: Dictionary, language: String, viewport_size: Vector2) -> Dictionary:
	var dialog_id := str(spec.get("id", "")).strip_edges()
	if dialog_id.is_empty():
		dialog_id = "dialog"

	var content_format := str(spec.get("format", "plain")).to_lower()
	if content_format not in SUPPORTED_FORMATS:
		content_format = "plain"
	var surface := str(spec.get("surface", "")).to_lower()
	if surface.is_empty() and _bool_or_default(spec.get("transparent_background"), false):
		surface = "transparent"
	if surface not in SUPPORTED_SURFACES:
		surface = "default"
	var action_layout := str(spec.get("action_layout", "horizontal")).to_lower()
	if action_layout not in SUPPORTED_ACTION_LAYOUTS:
		action_layout = "horizontal"
	var close_mode := str(spec.get("close_mode", "animated")).to_lower()
	if close_mode not in SUPPORTED_CLOSE_MODES:
		close_mode = "animated"

	return {
		"id": dialog_id,
		"title": localize(spec.get("title", ""), language),
		"body": localize(spec.get("body", ""), language),
		"format": content_format,
		"icon_path": _normalize_icon_path(spec.get("icon_path", DEFAULT_ICON_PATH)),
		"size": _normalize_size(spec.get("size", {}), viewport_size),
		"scale": _number_or_default(spec.get("scale"), 1.0),
		"inner": _bool_or_default(spec.get("inner"), false),
		"surface": surface,
		"action_layout": action_layout,
		"close_mode": close_mode,
		"transparent_background": surface == "transparent",
		"dismiss_on_escape": _bool_or_default(spec.get("dismiss_on_escape"), true),
		"dismiss_on_outside_click": _bool_or_default(spec.get("dismiss_on_outside_click"), true),
		"progress": _normalize_progress(spec.get("progress", {}), language),
		"fields": _normalize_fields(spec.get("fields", []), language),
		"buttons": normalize_buttons(spec.get("buttons", []), language),
		"appearance": _normalize_appearance(spec.get("appearance", {})),
	}


static func localize(value: Variant, language: String) -> String:
	if value is String:
		return value
	if not value is Dictionary:
		return ""

	var localized: Dictionary = value
	var preferred_keys: Array[String] = [language, "en"]
	for key in preferred_keys:
		if localized.has(key) and localized[key] is String and not localized[key].is_empty():
			return localized[key]

	for candidate in localized.values():
		if candidate is String and not candidate.is_empty():
			return candidate
	return ""


static func _normalize_icon_path(value: Variant) -> String:
	if not value is String:
		return DEFAULT_ICON_PATH
	var path: String = value
	if not path.begins_with("res://game_assets/icons/"):
		return DEFAULT_ICON_PATH
	if not path.to_lower().ends_with(".png") or path.contains(".."):
		return DEFAULT_ICON_PATH
	if not ResourceLoader.exists(path):
		return DEFAULT_ICON_PATH
	return path


static func _normalize_size(value: Variant, viewport_size: Vector2) -> Vector2:
	var requested := DEFAULT_SIZE
	if value is Vector2:
		requested = value
	elif value is Dictionary:
		var raw_size: Dictionary = value
		requested.x = _number_or_default(raw_size.get("width"), DEFAULT_SIZE.x)
		requested.y = _number_or_default(raw_size.get("height"), DEFAULT_SIZE.y)

	var maximum := Vector2(
		maxf(1.0, viewport_size.x - VIEWPORT_MARGIN.x),
		maxf(1.0, viewport_size.y - VIEWPORT_MARGIN.y)
	)
	var minimum := Vector2(minf(MIN_SIZE.x, maximum.x), minf(MIN_SIZE.y, maximum.y))
	return Vector2(
		clampf(requested.x, minimum.x, maximum.x),
		clampf(requested.y, minimum.y, maximum.y)
	)


static func normalize_buttons(value: Variant, language: String) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	if not value is Array:
		return normalized

	var seen_ids: Dictionary = {}
	for candidate in value:
		if not candidate is Dictionary:
			continue
		var button: Dictionary = candidate
		var button_id := str(button.get("id", "")).strip_edges()
		if button_id.is_empty() or seen_ids.has(button_id):
			continue
		var text := localize(button.get("text", ""), language)
		if text.is_empty():
			continue
		var style := str(button.get("style", "secondary")).to_lower()
		if style not in SUPPORTED_BUTTON_STYLES:
			style = "secondary"
		var can_go = _bool_or_default(button.get("can_go"), true)
		seen_ids[button_id] = true
		var normalized_button := {
			"id": button_id,
			"text": text,
			"style": style,
			"can_go": can_go,
		}
		var close_mode := str(button.get("close_mode", "")).to_lower()
		if close_mode in SUPPORTED_CLOSE_MODES:
			normalized_button["close_mode"] = close_mode
		normalized.append(normalized_button)
	return normalized


static func _normalize_progress(value: Variant, language: String) -> Dictionary:
	var progress: Dictionary = value if value is Dictionary else {}
	return {
		"visible": progress.get("visible", false) == true,
		"value": clampf(_number_or_default(progress.get("value"), 0.0), 0.0, 100.0),
		"status": localize(progress.get("status", ""), language),
		"detail": localize(progress.get("detail", ""), language),
	}


static func _number_or_default(value: Variant, default_value: float) -> float:
	if value is int or value is float:
		return float(value)
	return default_value


static func _bool_or_default(value: Variant, default_value: bool) -> bool:
	if value is bool:
		return value
	return default_value


static func _normalize_appearance(value: Variant) -> Dictionary:
	var appearance: Dictionary = value if value is Dictionary else {}
	var button_text_alignment := str(
		appearance.get("button_text_alignment", DEFAULT_APPEARANCE["button_text_alignment"])
	).to_lower()
	if button_text_alignment not in SUPPORTED_BUTTON_TEXT_ALIGNMENTS:
		button_text_alignment = DEFAULT_APPEARANCE["button_text_alignment"]
	return {
		"show_icon": _bool_or_default(
			appearance.get("show_icon"),
			DEFAULT_APPEARANCE["show_icon"]
		),
		"title_font_size": clampi(
			int(_number_or_default(appearance.get("title_font_size"), DEFAULT_APPEARANCE["title_font_size"])),
			12,
			48
		),
		"body_font_size": clampi(
			int(_number_or_default(appearance.get("body_font_size"), DEFAULT_APPEARANCE["body_font_size"])),
			12,
			30
		),
		"button_height": clampf(
			_number_or_default(appearance.get("button_height"), DEFAULT_APPEARANCE["button_height"]),
			28.0,
			72.0
		),
		"button_width": clampf(
			_number_or_default(appearance.get("button_width"), DEFAULT_APPEARANCE["button_width"]),
			0.0,
			1200.0
		),
		"button_font_scale": clampf(
			_number_or_default(appearance.get("button_font_scale"), DEFAULT_APPEARANCE["button_font_scale"]),
			0.3,
			1.0
		),
		"button_text_alignment": button_text_alignment,
		"button_text_padding": clampf(
			_number_or_default(appearance.get("button_text_padding"), DEFAULT_APPEARANCE["button_text_padding"]),
			0.0,
			64.0
		),
		"field_columns": clampi(
			int(_number_or_default(appearance.get("field_columns"), DEFAULT_APPEARANCE["field_columns"])),
			1,
			3
		),
		"field_height": clampf(
			_number_or_default(appearance.get("field_height"), DEFAULT_APPEARANCE["field_height"]),
			32.0,
			64.0
		),
		"field_font_size": clampi(
			int(_number_or_default(appearance.get("field_font_size"), DEFAULT_APPEARANCE["field_font_size"])),
			14,
			28
		),
		"field_font_scale": clampf(
			_number_or_default(appearance.get("field_font_scale"), DEFAULT_APPEARANCE["field_font_scale"]),
			0.35,
			0.8
		),
		"field_label_font_size": clampi(
			int(_number_or_default(appearance.get("field_label_font_size"), DEFAULT_APPEARANCE["field_label_font_size"])),
			12,
			24
		),
		"action_separation": clampi(
			int(_number_or_default(appearance.get("action_separation"), DEFAULT_APPEARANCE["action_separation"])),
			4,
			32
		),
		"hide_node_palette": _bool_or_default(
			appearance.get("hide_node_palette"),
			DEFAULT_APPEARANCE["hide_node_palette"]
		),
	}


static func _normalize_fields(value: Variant, language: String) -> Array[Dictionary]:
	var normalized: Array[Dictionary] = []
	if not value is Array:
		return normalized

	var seen_ids: Dictionary = {}
	for candidate in value:
		if not candidate is Dictionary:
			continue
		var field: Dictionary = candidate
		var field_id := str(field.get("id", "")).strip_edges()
		if field_id.is_empty() or seen_ids.has(field_id):
			continue
		var type := str(field.get("type", "text")).to_lower()
		if type == "dropdown":
			type = "choice"
		if type not in SUPPORTED_FIELD_TYPES:
			continue
		var norm_field := {
			"id": field_id,
			"type": type,
			"label": localize(field.get("label", ""), language),
			"placeholder": localize(field.get("placeholder", ""), language),
			"required": _bool_or_default(field.get("required"), false),
			"value": str(field.get("value", "")),
		}
		if type == "choice":
			if _bool_or_default(field.get("live_language"), false):
				norm_field["live_language"] = true
			var opts: Array[Dictionary] = []
			var seen_values: Dictionary = {}
			if field.has("options") and field["options"] is Array:
				for opt in field["options"]:
					var option_value := ""
					var option_text := ""
					if opt is Dictionary:
						option_value = str(opt.get("value", "")).strip_edges()
						option_text = localize(opt.get("text", ""), language)
					else:
						option_text = localize(opt, language)
						option_value = option_text
					if option_value.is_empty() or option_text.is_empty() or seen_values.has(option_value):
						continue
					seen_values[option_value] = true
					opts.append({"value": option_value, "text": option_text})
			if opts.is_empty():
				continue
			if not seen_values.has(norm_field["value"]):
				norm_field["value"] = opts[0]["value"]
			norm_field["options"] = opts
		seen_ids[field_id] = true
		normalized.append(norm_field)
	return normalized
