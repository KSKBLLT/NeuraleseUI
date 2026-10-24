class_name SimulationVirtualObject
extends Node2D

## The editor owns exactly one proxy for its current selection. Existing inspector,
## gizmo and brain-mapping controls can keep a node-shaped API without object nodes.

const Catalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const ModelBinding = preload("res://scripts/simulations/simulation_model_binding.gd")

var object_id := ""
var type_id: StringName = &""
var object_size := Vector2(64.0, 64.0)
var properties: Dictionary = {}
var _document: SimulationWorldState


func bind_document_object(document: SimulationWorldState, next_object_id: String) -> bool:
	_document = document
	object_id = next_object_id
	return sync_from_document()


func sync_from_document() -> bool:
	if _document == null:
		return false
	var data := _document.object_data(object_id)
	if data.is_empty():
		return false
	type_id = StringName(data["type_id"])
	position = data["position"]
	rotation = data["rotation"]
	scale = data["scale"]
	object_size = data["size"]
	properties = data["properties"]
	return true


func sync_runtime_transform(next_position: Vector2, next_rotation: float) -> void:
	position = next_position
	rotation = next_rotation


func get_definition() -> Dictionary:
	return Catalog.definition(type_id)


func get_agent() -> SimulationVirtualObject:
	return self if str(get_definition().get("body_kind", "")) == "agent" else null


func get_agent_id() -> StringName:
	return StringName(get_definition().get("agent_id", ""))


func get_model_binding() -> Dictionary:
	var binding: Variant = properties.get("model_binding", {})
	if binding is Dictionary and ModelBinding.validate(binding).get("valid", false):
		return binding.duplicate(true)
	return ModelBinding.create_default(get_agent_id())


func set_model_binding(binding: Dictionary) -> bool:
	if _document == null or not ModelBinding.validate(binding).get("valid", false):
		return false
	if StringName(binding.get("agent_id", "")) != get_agent_id():
		return false
	properties["model_binding"] = binding.duplicate(true)
	return _document.update_object(object_id, {"properties": {"model_binding": binding}})


func serialize() -> Dictionary:
	return _document.object_data(object_id) if _document != null else {}


func set_object_size(next_size: Vector2) -> void:
	object_size = Vector2(maxf(8.0, next_size.x), maxf(8.0, next_size.y))


func set_selected(_value: bool) -> void:
	pass


func is_live_editable() -> bool:
	return str(get_definition().get("body_kind", "")) in ["static", "area"]
