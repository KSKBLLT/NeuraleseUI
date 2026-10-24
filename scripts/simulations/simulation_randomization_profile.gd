class_name SimulationRandomizationProfile
extends RefCounted

const DEFINITIONS := {
	"start_position": {
		"label": "Start position",
		"value_key": "jitter",
		"default_value": Vector2(10.0, 3.0),
		"nonnegative": true,
	},
	"goal_position": {
		"label": "Goal position",
		"value_key": "jitter",
		"default_value": Vector2(16.0, 8.0),
		"nonnegative": true,
	},
	"initial_speed": {
		"label": "Initial speed",
		"value_key": "range",
		"default_value": Vector2.ZERO,
		"ordered": true,
	},
	"obstacle_position": {
		"label": "Obstacle position",
	},
	"surface_material": {
		"label": "Surface material",
	},
}


static func definitions() -> Dictionary:
	return DEFINITIONS.duplicate(true)


static func active_config(raw: Variant) -> Dictionary:
	if raw is not Dictionary:
		return {}
	var result := {}
	for key in DEFINITIONS:
		var value: Variant = raw.get(key, false)
		var enabled := false
		var normalized: Dictionary = {}
		if value is Dictionary:
			enabled = bool(value.get("enabled", false))
			normalized = value.duplicate(true)
		elif value is bool:
			enabled = value
			normalized = {"enabled": true}
		if not enabled:
			continue
		var definition: Dictionary = DEFINITIONS[key]
		var value_key := str(definition.get("value_key", ""))
		if not value_key.is_empty() and not normalized.has(value_key):
			normalized[value_key] = definition.get("default_value", Vector2.ZERO)
		result[key] = normalized
	return result


static func active_labels(raw: Variant) -> Array[String]:
	var active := active_config(raw)
	var result: Array[String] = []
	for key in DEFINITIONS:
		if active.has(key):
			result.append(str(DEFINITIONS[key]["label"]))
	return result


static func vector_value(active: Dictionary, variation_id: String) -> Vector2:
	if not DEFINITIONS.has(variation_id) or not active.has(variation_id):
		return Vector2.ZERO
	var definition: Dictionary = DEFINITIONS[variation_id]
	var value_key := str(definition.get("value_key", ""))
	if value_key.is_empty():
		return Vector2.ZERO
	var config: Variant = active[variation_id]
	if config is not Dictionary:
		return Vector2(definition["default_value"])
	return _as_vector2(config.get(value_key), Vector2(definition["default_value"]))


static func validate(raw: Variant) -> Dictionary:
	var errors: Array[Dictionary] = []
	if raw is not Dictionary:
		return {
			"valid": false,
			"errors": [{
				"code": "invalid_randomization",
				"message": "Simulation randomization must be an object.",
			}],
		}
	for key in DEFINITIONS:
		if not raw.has(key):
			continue
		var config: Variant = raw[key]
		if config is bool:
			continue
		if config is not Dictionary or config.get("enabled", false) is not bool:
			errors.append(_error("invalid_variation", "Variation '%s' must contain a boolean enabled flag." % key, key))
			continue
		var definition: Dictionary = DEFINITIONS[key]
		var value_key := str(definition.get("value_key", ""))
		if value_key.is_empty():
			continue
		if not config.has(value_key):
			continue
		var vector := _as_vector2(config[value_key], Vector2(NAN, NAN))
		if not _finite_vector(vector):
			errors.append(_error("invalid_variation_range", "Variation '%s' has a malformed range." % key, key))
			continue
		if definition.get("nonnegative", false) and (vector.x < 0.0 or vector.y < 0.0):
			errors.append(_error("negative_variation_range", "Variation '%s' cannot use negative jitter." % key, key))
		elif definition.get("ordered", false) and vector.x > vector.y:
			errors.append(_error("reversed_variation_range", "Variation '%s' minimum must not exceed its maximum." % key, key))
	return {"valid": errors.is_empty(), "errors": errors}


static func _as_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Array and value.size() >= 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


static func _finite_vector(value: Vector2) -> bool:
	return not is_nan(value.x) and not is_inf(value.x) \
		and not is_nan(value.y) and not is_inf(value.y)


static func _error(code: String, message: String, variation_id: String) -> Dictionary:
	return {"code": code, "message": message, "variation_id": variation_id}
