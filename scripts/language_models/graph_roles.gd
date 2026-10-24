extends RefCounted
# UI roles come from node_defs; numeric-only callers must explicitly request numeric input.
const Catalog = preload("res://scripts/generated/node_catalog.gd")
const Language = preload("res://scripts/language_models/language_contract.gd")

static func type_id(node: Node) -> StringName:
	return StringName(node.get_meta("created_with", ""))

static func is_input(node: Node) -> bool:
	return Catalog.input_types().has(type_id(node))

static func is_numeric_input(node: Node) -> bool:
	return is_input(node) and not is_language_type(type_id(node))

static func is_language_type(id: StringName) -> bool:
	return Catalog.DEFINITIONS.get(id,{}).get("roles",[]).has("language")

static func is_output_type(id: StringName) -> bool:
	return Catalog.DEFINITIONS.get(id,{}).get("roles",[]).has("output")

static func alternatives(current: StringName, candidates: Array, language_component: bool = false) -> Array:
	var result: Array = []
	var current_is_input := Catalog.input_types().has(current)
	for id in candidates:
		if StringName(id)==current: continue
		if current_is_input != Catalog.input_types().has(StringName(id)): continue
		# Replacement removes the old node and its edges. Switching the source
		# or output form is therefore valid even when its data contract changes.
		if current_is_input or (is_output_type(current) and is_output_type(StringName(id))):
			result.append(id)
			continue
		if language_component or is_language_type(current):
			if not Language.OPS.has(StringName(id)): continue
		elif is_language_type(StringName(id)): continue
		result.append(id)
	return result
