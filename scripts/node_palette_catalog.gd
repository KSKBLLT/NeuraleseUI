extends RefCounted
class_name NodePaletteCatalog

const DRAG_KIND: StringName = &"neuralese_node_palette"


static func icon_path(type_id: StringName) -> String:
	# Autoloads are looked up at run time: script-mode tests load this class
	# without them, and then the English previews are used.
	var root: Window = (Engine.get_main_loop() as SceneTree).root
	var app: Node = root.get_node_or_null(^"glob")
	var language := str(app.get_lang()) if app else "en"
	# Pixel design previews live beside the classic ones (node_icons/pixel/<lang>).
	var design_ui: Node = root.get_node_or_null(^"design")
	if design_ui and design_ui.pixel:
		var pixel_path := "res://node_icons/pixel/%s/%s" % [language, icon_filename(type_id)]
		if ResourceLoader.exists(pixel_path):
			return pixel_path
	return "res://node_icons/%s/%s" % [language, icon_filename(type_id)]


static func icon_filename(type_id: StringName) -> String:
	return "Icon%s.png" % str(type_id).to_pascal_case()


static func build_entries(
	definitions: Array,
	preferred_order: Array,
	hidden_types: Array,
	language: String
) -> Array[Dictionary]:
	var definitions_by_name: Dictionary = {}
	for definition in definitions:
		var type_id := StringName(definition.get("name", ""))
		if not type_id.is_empty():
			definitions_by_name[type_id] = definition

	var hidden: Dictionary = {}
	for type_name in hidden_types:
		hidden[StringName(type_name)] = true

	var entries: Array[Dictionary] = []
	var added: Dictionary = {}
	for type_name in preferred_order:
		_append_entry(
			entries,
			added,
			definitions_by_name,
			StringName(type_name),
			hidden,
			language
		)
	return entries


static func filter_entries(entries: Array[Dictionary], query: String) -> Array[Dictionary]:
	var normalized_query := _normalize(query)
	if normalized_query.is_empty():
		return entries.duplicate()

	var filtered: Array[Dictionary] = []
	for entry in entries:
		var searchable := str(entry.get("search", "%s|%s" % [
			_normalize(str(entry.get("title", ""))),
			_normalize(str(entry.get("type_id", ""))),
		]))
		if normalized_query in searchable:
			filtered.append(entry)
	return filtered


## Lesson names the catalog title does not contain (the canvas shows «Свёрт2D»).
const _SEARCH_ALIASES := {&"conv2d": ["Свёрт2D", "свёртка", "convolution"]}


## Case, spaces and ё/е do not matter: «Ввод 1D» finds «Ввод1D», «Сверт» finds «Свёрт».
static func _normalize(text: String) -> String:
	return text.to_lower().replace("ё", "е").replace(" ", "")


## Titles in every language plus aliases, so «Conv2D» or «Тығыз» find a node
## whatever the interface language is.
static func _search_text(definition: Dictionary, type_id: StringName) -> String:
	var words: Array = [str(type_id), str(definition.get("title", ""))]
	for language in ["ru", "kz", "en"]:
		words.append(str(definition.get("title_%s" % language, "")))
	words.append_array(_SEARCH_ALIASES.get(type_id, []))
	return "|".join(words.map(func(word): return _normalize(str(word))))


static func drag_payload(type_id: StringName) -> Dictionary:
	return {
		"kind": DRAG_KIND,
		"type_id": type_id,
	}


static func drag_type(data: Variant, known_types: Array) -> StringName:
	if not data is Dictionary or data.get("kind") != DRAG_KIND:
		return StringName()
	var type_id := StringName(data.get("type_id", ""))
	if type_id.is_empty() or not known_types.has(type_id):
		return StringName()
	return type_id


static func is_workspace_drop(
	screen_position: Vector2,
	viewport_size: Vector2,
	panel_width: float,
	top_inset: float
) -> bool:
	return Rect2(
		Vector2(panel_width, top_inset),
		Vector2(maxf(0.0, viewport_size.x - panel_width), maxf(0.0, viewport_size.y - top_inset))
	).has_point(screen_position)


static func _append_entry(
	entries: Array[Dictionary],
	added: Dictionary,
	definitions_by_name: Dictionary,
	type_id: StringName,
	hidden: Dictionary,
	language: String
) -> void:
	if type_id.is_empty() or added.has(type_id) or hidden.has(type_id):
		return
	if not definitions_by_name.has(type_id):
		return

	var definition: Dictionary = definitions_by_name[type_id]
	entries.append({
		"type_id": type_id,
		"search": _search_text(definition, type_id),
		"title": _localized_title(definition, language),
		"icon_path": icon_path(type_id),
		"outline_color": definition.get("outline_color", Color("6aa7ff")),
		"category": StringName(definition.get("category", "")),
	})
	added[type_id] = true


static func _localized_title(definition: Dictionary, language: String) -> String:
	var localized_key := "title_%s" % language
	var localized := str(definition.get(localized_key, "")).strip_edges()
	if not localized.is_empty():
		return localized
	var fallback := str(definition.get("title", "")).strip_edges()
	if not fallback.is_empty():
		return fallback
	return str(definition.get("name", ""))
