extends RefCounted
class_name PilotOnboardingClient

const REGISTER_ENDPOINT := "api/pilot/onboarding/register"
const DEFAULT_INSTALLATION_ID_PATH := "user://pilot_installation_id"
const _INSTALLATION_ID_BYTES := 24
const _TECHNICAL_FIRST_NAME := "Neuralese"
const _TECHNICAL_LAST_NAME := "Device"

var _web_api
var _cookies


func _init(web_api, cookie_manager) -> void:
	_web_api = web_api
	_cookies = cookie_manager


func register(
	role: String,
	first_name: String,
	last_name: String,
	enrollment_id: String,
	enrollment_token: String,
	installation_id: String
) -> Dictionary:
	var normalized_role := role.strip_edges().to_lower()
	if normalized_role not in ["student", "teacher"]:
		return _error("invalid_role")

	var payload := {
		"role": normalized_role,
		"first_name": first_name.strip_edges(),
		"last_name": last_name.strip_edges(),
		"enrollment_id": enrollment_id.strip_edges(),
		"enrollment_token": enrollment_token.strip_edges(),
		"installation_id": installation_id.strip_edges(),
	}
	for field in [
		"first_name",
		"last_name",
		"enrollment_id",
		"enrollment_token",
		"installation_id",
	]:
		if str(payload[field]) == "":
			return _error("missing_%s" % field)

	var response: Dictionary = await _web_api.JPOST(REGISTER_ENDPOINT, payload)
	if not response.get("ok", false):
		return response
	var applied: Dictionary = _cookies.apply_pilot_session(response)
	if not applied.get("ok", false):
		return applied

	var result := response.duplicate(true)
	result["session"] = applied.get("session", {})
	return result


func ensure_device_session(
	account_role: String,
	enrollment_id: String,
	enrollment_token: String,
	installation_id: String,
	persisted_profile: Dictionary = {}
) -> Dictionary:
	var identity := technical_account_identity(
		account_role,
		enrollment_id,
		persisted_profile
	)
	var result := await register(
		str(identity["role"]),
		str(identity["first_name"]),
		str(identity["last_name"]),
		enrollment_id,
		enrollment_token,
		installation_id
	)
	if not result.get("ok", false) and result.get("error", "") == "pilot_profile_conflict":
		var fallback_identity := technical_account_identity(
			account_role,
			enrollment_id,
			{} # Force fallback to technical default by ignoring persisted profile
		)
		result = await register(
			str(fallback_identity["role"]),
			str(fallback_identity["first_name"]),
			str(fallback_identity["last_name"]),
			enrollment_id,
			enrollment_token,
			installation_id
		)
	return result


static func technical_account_identity(
	account_role: String,
	enrollment_id: String,
	persisted_profile: Dictionary = {}
) -> Dictionary:
	var normalized_role := account_role.strip_edges().to_lower()
	if normalized_role not in ["student", "teacher"]:
		normalized_role = "student"
	var previous_first := str(
		persisted_profile.get("first_name", "")
	).strip_edges()
	var previous_last := str(
		persisted_profile.get("last_name", "")
	).strip_edges()
	var previous_role := str(persisted_profile.get("type", "")).strip_edges().to_lower()
	if (
		not previous_first.is_empty()
		and not previous_last.is_empty()
		and previous_role in ["student", "teacher"]
	):
		return {
			"role": previous_role,
			"first_name": previous_first,
			"last_name": previous_last,
		}
	return {
		"role": normalized_role,
		"first_name": _TECHNICAL_FIRST_NAME,
		"last_name": _TECHNICAL_LAST_NAME,
	}


static func get_or_create_installation_id(
	path: String = DEFAULT_INSTALLATION_ID_PATH
) -> String:
	if FileAccess.file_exists(path):
		var existing_file := FileAccess.open(path, FileAccess.READ)
		if existing_file:
			var existing := existing_file.get_as_text().strip_edges().to_lower()
			if _is_valid_installation_id(existing):
				return existing

	var generated := Crypto.new().generate_random_bytes(
		_INSTALLATION_ID_BYTES
	).hex_encode()
	var output := FileAccess.open(path, FileAccess.WRITE)
	if output:
		output.store_string(generated)
		output.flush()
	return generated


static func _is_valid_installation_id(value: String) -> bool:
	if value.length() != _INSTALLATION_ID_BYTES * 2:
		return false
	for character in value:
		if character not in "0123456789abcdef":
			return false
	return true


static func _error(code: String) -> Dictionary:
	return {"ok": false, "error": code}
