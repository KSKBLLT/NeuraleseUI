class_name SimulationObjectCatalog
extends RefCounted

const GROUPS := {
	"Geometry": [&"block", &"circle", &"slope"],
	"Materials": [&"ice", &"sand", &"trampoline", &"finish", &"water"],
	"Hazards": [&"spikes", &"lava"],
	"Dynamics": [&"crate", &"ball"],
	"Agents": [&"car", &"rover", &"flying_agent"],
}

const DEFINITIONS := {
	&"block": {
		"label": "Block",
		"body_kind": "static",
		"shape_kind": "rectangle",
		"default_size": Vector2(160.0, 32.0),
		"color": Color("60646d"),
		"dataset_role": "geometry",
		"friction": 0.8,
		"bounce": 0.0,
	},
	&"circle": {
		"label": "Circle",
		"body_kind": "static",
		"shape_kind": "circle",
		"default_size": Vector2(64.0, 64.0),
		"color": Color("737780"),
		"dataset_role": "geometry",
		"friction": 0.8,
		"bounce": 0.0,
	},
	&"slope": {
		"label": "Slope",
		"body_kind": "static",
		"shape_kind": "slope",
		"default_size": Vector2(160.0, 80.0),
		"color": Color("676b73"),
		"dataset_role": "geometry",
		"friction": 0.8,
		"bounce": 0.0,
	},
	&"ice": {
		"label": "Ice",
		"body_kind": "static",
		"shape_kind": "rectangle",
		"default_size": Vector2(160.0, 32.0),
		"color": Color("62b9d4"),
		"dataset_role": "material",
		"material_id": "ice",
		"friction": 0.05,
		"bounce": 0.0,
	},
	&"sand": {
		"label": "Sand",
		"body_kind": "static",
		"shape_kind": "rectangle",
		"default_size": Vector2(160.0, 32.0),
		"color": Color("c9a45e"),
		"dataset_role": "material",
		"material_id": "sand",
		"friction": 2.4,
		"bounce": 0.0,
	},
	&"trampoline": {
		"label": "Trampoline",
		"body_kind": "static",
		"shape_kind": "rectangle",
		"default_size": Vector2(112.0, 18.0),
		"color": Color("967ad7"),
		"dataset_role": "material",
		"material_id": "trampoline",
		"effect": "trampoline",
		"friction": 0.6,
		"bounce": 1.0,
	},
	&"water": {
		"label": "Water",
		"body_kind": "area",
		"shape_kind": "rectangle",
		"default_size": Vector2(160.0, 64.0),
		"color": Color("4da6ff"),
		"dataset_role": "material",
		"viscosity": 15.0,
	},
	&"finish": {
		"label": "Finish",
		"body_kind": "area",
		"shape_kind": "rectangle",
		"default_size": Vector2(72.0, 112.0),
		"color": Color("64d59a"),
		"dataset_role": "goal",
		"effect": "finish",
	},
	&"spikes": {
		"label": "Spikes",
		"body_kind": "area",
		"shape_kind": "rectangle",
		"default_size": Vector2(112.0, 28.0),
		"color": Color("da7373"),
		"dataset_role": "hazard",
		"effect": "damage",
	},
	&"lava": {
		"label": "Lava",
		"body_kind": "area",
		"shape_kind": "rectangle",
		"default_size": Vector2(160.0, 48.0),
		"color": Color("df604e"),
		"dataset_role": "hazard",
		"effect": "reset",
	},
	&"crate": {
		"label": "Crate",
		"body_kind": "rigid",
		"shape_kind": "rectangle",
		"default_size": Vector2(56.0, 56.0),
		"color": Color("a47c55"),
		"dataset_role": "dynamic",
		"mass": 1.0,
		"friction": 0.8,
		"bounce": 0.05,
	},
	&"ball": {
		"label": "Ball",
		"body_kind": "rigid",
		"shape_kind": "circle",
		"default_size": Vector2(48.0, 48.0),
		"color": Color("8b92a1"),
		"dataset_role": "dynamic",
		"mass": 0.8,
		"friction": 0.5,
		"bounce": 0.45,
	},
	&"car": {
		"label": "Car",
		"body_kind": "agent",
		"shape_kind": "rectangle",
		"default_size": Vector2(92.0, 42.0),
		"color": Color("a487d8"),
		"dataset_role": "agent",
		"agent_id": &"side_view_car",
		"mass": 1.2,
		"friction": 1.0,
		"bounce": 0.0,
		"compatible_perspective": &"side_view",
	},
	&"platformer": {
		"label": "Platformer",
		"body_kind": "agent",
		"shape_kind": "rectangle",
		"default_size": Vector2(42.0, 64.0),
		"color": Color("809bd3"),
		"dataset_role": "agent",
		"agent_id": &"side_view_car",
		"mass": 1.0,
		"friction": 1.0,
		"bounce": 0.0,
		"compatible_perspective": &"side_view",
	},
	&"rover": {
		"label": "Top-down Rover",
		"body_kind": "agent",
		"shape_kind": "rectangle",
		"default_size": Vector2(72.0, 48.0),
		"color": Color("65c7bd"),
		"dataset_role": "agent",
		"agent_id": &"top_down_rover",
		"mass": 1.0,
		"friction": 0.8,
		"bounce": 0.0,
		"compatible_perspective": &"top_down",
	},
	&"flying_agent": {
		"label": "Flying Agent",
		"body_kind": "agent",
		"shape_kind": "circle",
		"default_size": Vector2(58.0, 58.0),
		"color": Color("9d87df"),
		"dataset_role": "agent",
		"agent_id": &"flying_agent",
		"mass": 0.8,
		"friction": 0.2,
		"bounce": 0.1,
		"compatible_perspective": &"side_view",
	},
}


static func grouped_types() -> Dictionary:
	return GROUPS.duplicate(true)


static func visible_types() -> Array[StringName]:
	var result: Array[StringName] = []
	for group_name in GROUPS:
		for type_id in GROUPS[group_name]:
			result.append(type_id)
	return result


static func definition(type_id: StringName) -> Dictionary:
	if not DEFINITIONS.has(type_id):
		return {}
	return DEFINITIONS[type_id].duplicate(true)


static func has_type(type_id: StringName) -> bool:
	return DEFINITIONS.has(type_id)


static func is_surface_type(type_id: StringName) -> bool:
	var item := definition(type_id)
	return (
		str(item.get("body_kind", "")) == "static"
		and str(item.get("shape_kind", "")) == "rectangle"
		and item.has("friction")
	)


static func is_obstacle_type(type_id: StringName) -> bool:
	var role := str(definition(type_id).get("dataset_role", ""))
	return role in ["geometry", "material", "hazard", "dynamic"]
