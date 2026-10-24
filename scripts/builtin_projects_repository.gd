class_name BuiltinProjectsRepository
extends RefCounted

const CATALOG_PATH := "res://built_in_projects/catalog.tres"
const Catalog = preload("res://scripts/builtin_projects_catalog.gd")

var _catalog: Resource
var _projects_by_id: Dictionary = {}
var errors: PackedStringArray = []


func load_catalog() -> Array[Resource]:
	errors.clear()
	_projects_by_id.clear()
	_catalog = load(CATALOG_PATH) as Catalog
	if _catalog == null:
		errors.append("Could not load built-in project catalog: %s" % CATALOG_PATH)
		return []

	var projects: Array[Resource] = []
	for definition in _catalog.projects:
		if not _validate(definition):
			continue
		_projects_by_id[definition.id] = definition
		projects.append(definition)
	projects.sort_custom(func(left: Resource, right: Resource) -> bool:
		if left.sort_order == right.sort_order:
			return String(left.id) < String(right.id)
		return left.sort_order < right.sort_order
	)
	return projects


func get_project(id: StringName) -> Resource:
	return _projects_by_id.get(id)


func create_user_copy(id: StringName, language: String) -> Dictionary:
	var definition := get_project(id)
	if definition == null:
		return {"ok": false, "error": "unknown_builtin_project"}
	return await glob.create_builtin_project_copy(
		String(definition.id),
		definition.source_scene,
		definition.localized_title(language),
		definition.version
	)


func _validate(definition: Resource) -> bool:
	if definition == null:
		errors.append("Built-in project catalog contains an empty entry.")
		return false
	if definition.id.is_empty():
		errors.append("Built-in project entry has no id.")
		return false
	if _projects_by_id.has(definition.id):
		errors.append("Duplicate built-in project id: %s" % definition.id)
		return false
	if definition.source_scene.is_empty() or not FileAccess.file_exists(definition.source_scene):
		errors.append("Built-in project '%s' has no project blob." % definition.id)
		return false
	if definition.preview == null:
		errors.append("Built-in project '%s' has no preview." % definition.id)
		return false
	for value in [definition.title_ru, definition.title_en, definition.title_kz]:
		if value.strip_edges().is_empty():
			errors.append("Built-in project '%s' has an empty localized title." % definition.id)
			return false
	for value in [definition.description_ru, definition.description_en, definition.description_kz]:
		if value.strip_edges().is_empty():
			errors.append("Built-in project '%s' has an empty localized description." % definition.id)
			return false
	return true
