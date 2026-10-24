extends SceneTree

const NodeCatalog = preload("res://scripts/generated/node_catalog.gd")


func _initialize() -> void:
	var errors: Array[String] = []
	for type_id in NodeCatalog.load_order():
		var definition: Dictionary = NodeCatalog.DEFINITIONS[type_id]
		var source_path := str(definition.get("source_path", ""))
		var source_kind := StringName(definition.get("source_kind", &""))
		var source := load(source_path)
		if source == null:
			errors.append("%s source could not be loaded: %s" % [type_id, source_path])
			continue

		if source_kind == &"scene":
			_validate_scene(type_id, source, errors)
		elif source_kind == &"provider":
			_validate_provider(type_id, source, definition, errors)
		else:
			errors.append("%s has unsupported source kind: %s" % [type_id, source_kind])

	if errors.is_empty():
		print("NODE_DEV_SOURCES_OK: %d" % NodeCatalog.DEFINITIONS.size())
		quit(0)
		return

	for error in errors:
		push_error("NODE_DEV: %s" % error)
	quit(1)


func _validate_scene(type_id: StringName, source: Resource, errors: Array[String]) -> void:
	if not source is PackedScene:
		errors.append("%s source is not a PackedScene" % type_id)
		return
	var scene := source as PackedScene
	if not scene.can_instantiate():
		errors.append("%s is not an instantiable PackedScene" % type_id)
		return
	var created := scene.instantiate()
	if not is_instance_valid(created):
		errors.append("%s scene returned no node" % type_id)
		return
	created.free()


func _validate_provider(
	type_id: StringName,
	source: Resource,
	definition: Dictionary,
	errors: Array[String],
) -> void:
	if not source is Script:
		errors.append("%s provider source is not a Script" % type_id)
		return
	var script := source as Script
	if not script.can_instantiate():
		errors.append("%s is not an instantiable provider Script" % type_id)
		return
	var provider: Object = script.new()
	if not provider.has_method("instantiate_node"):
		errors.append("%s provider has no instantiate_node method" % type_id)
		return
	var created: Variant = provider.call("instantiate_node", definition.duplicate(true))
	if not is_instance_valid(created):
		errors.append("%s provider returned no node" % type_id)
		return
	if created is Node:
		(created as Node).free()
