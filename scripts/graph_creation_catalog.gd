extends RefCounted
class_name GraphCreationCatalog

const NodeCatalog = preload("res://scripts/generated/node_catalog.gd")


static func ordered_definitions(
	definitions: Array,
	importance_chain: Array,
	skip_types: Array,
	name_groups: Array,
	hide_inputs: bool
) -> Array[Dictionary]:
	if definitions.any(func(definition): return definition.has("menu_visible")):
		return _compiled_order(definitions, skip_types, hide_inputs)

	var allowed: Dictionary = {}
	for type_name in importance_chain:
		allowed[StringName(type_name)] = true

	var skipped: Dictionary = {}
	for type_name in skip_types:
		skipped[StringName(type_name)] = true

	var definitions_by_name: Dictionary = {}
	for definition in definitions:
		var type_id := StringName(definition.get("name", ""))
		if type_id.is_empty() or not allowed.has(type_id) or skipped.has(type_id):
			continue
		if hide_inputs and NodeCatalog.input_types().has(type_id):
			continue
		definitions_by_name[type_id] = definition

	var ordered: Array[Dictionary] = []
	var added: Dictionary = {}
	for group in name_groups:
		for type_name in group:
			_append_definition(
				ordered,
				added,
				definitions_by_name,
				StringName(type_name)
			)

	for definition in definitions:
		_append_definition(
			ordered,
			added,
			definitions_by_name,
			StringName(definition.get("name", ""))
		)
	return ordered


static func _compiled_order(
	definitions: Array,
	skip_types: Array,
	hide_inputs: bool
) -> Array[Dictionary]:
	var skipped: Dictionary = {}
	for type_name in skip_types:
		skipped[StringName(type_name)] = true
	var input_types := NodeCatalog.input_types()
	var ordered: Array[Dictionary] = []
	for definition in definitions:
		var type_id := StringName(definition.get("name", ""))
		if type_id.is_empty() or skipped.has(type_id):
			continue
		if not definition.get("menu_visible", true):
			continue
		if hide_inputs and input_types.has(type_id):
			continue
		ordered.append(definition)
	ordered.sort_custom(func(a, b):
		var a_menu_order := int(a.get("menu_order", 0))
		var b_menu_order := int(b.get("menu_order", 0))
		if a_menu_order == b_menu_order:
			return int(a.get("load_order", 0)) < int(b.get("load_order", 0))
		return a_menu_order < b_menu_order
	)
	return ordered


static func type_ids(definitions: Array) -> Array[StringName]:
	var result: Array[StringName] = []
	for definition in definitions:
		var type_id := StringName(definition.get("name", ""))
		if not type_id.is_empty():
			result.append(type_id)
	return result


static func _append_definition(
	ordered: Array[Dictionary],
	added: Dictionary,
	definitions_by_name: Dictionary,
	type_id: StringName
) -> void:
	if type_id.is_empty() or added.has(type_id) or not definitions_by_name.has(type_id):
		return
	ordered.append(definitions_by_name[type_id])
	added[type_id] = true
