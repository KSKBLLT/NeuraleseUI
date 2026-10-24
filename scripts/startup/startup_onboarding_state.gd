extends RefCounted
class_name StartupOnboardingState

const SCHEMA_VERSION := 1
const DEFAULT_PATH := "user://startup_onboarding_state.json"
const TOUR_STATUSES := ["not_started", "in_progress", "completed", "dismissed"]
const DEFAULT_ACCOUNT_STATE := {
	"startup_onboarding_version": 0,
	"interface_tour_version": 0,
	"interface_tour_status": "not_started",
}

var _path: String
var _accounts: Dictionary = {}
var _account_id := ""


func _init(path: String = DEFAULT_PATH) -> void:
	_path = path
	_load()


func select_account(account_id: String) -> bool:
	var normalized := account_id.strip_edges()
	if normalized.is_empty():
		return false
	_account_id = normalized
	if not _accounts.has(_account_id) or typeof(_accounts[_account_id]) != TYPE_DICTIONARY:
		_accounts[_account_id] = DEFAULT_ACCOUNT_STATE.duplicate(true)
		_save()
	return true


func get_value(key: String) -> Variant:
	if _account_id.is_empty():
		return DEFAULT_ACCOUNT_STATE.get(key)
	var state: Dictionary = _accounts.get(_account_id, {})
	return state.get(key, DEFAULT_ACCOUNT_STATE.get(key))


func set_value(key: String, value: Variant) -> bool:
	if _account_id.is_empty() or not DEFAULT_ACCOUNT_STATE.has(key):
		return false
	var normalized: Variant = value
	if key in ["startup_onboarding_version", "interface_tour_version"]:
		normalized = maxi(0, int(value))
	elif key == "interface_tour_status":
		normalized = str(value)
		if normalized not in TOUR_STATUSES:
			return false
	var state: Dictionary = _accounts[_account_id]
	state[key] = normalized
	_accounts[_account_id] = state
	return _save()


func mark_interface_tour(status: String, version: int) -> bool:
	if status not in TOUR_STATUSES or _account_id.is_empty():
		return false
	var state: Dictionary = _accounts[_account_id]
	state["interface_tour_status"] = status
	state["interface_tour_version"] = maxi(0, version)
	_accounts[_account_id] = state
	return _save()


func needs_interface_tour(version: int) -> bool:
	var current_version := int(get_value("interface_tour_version"))
	var status := str(get_value("interface_tour_status"))
	if current_version < version:
		return true
	return status not in ["completed", "dismissed"]


func snapshot() -> Dictionary:
	if _account_id.is_empty():
		return DEFAULT_ACCOUNT_STATE.duplicate(true)
	return Dictionary(_accounts.get(_account_id, DEFAULT_ACCOUNT_STATE)).duplicate(true)


func _load() -> void:
	if not FileAccess.file_exists(_path):
		return
	var file := FileAccess.open(_path, FileAccess.READ)
	if file == null:
		return
	var parsed: Variant = JSON.parse_string(file.get_as_text())
	if typeof(parsed) != TYPE_DICTIONARY or int(parsed.get("schema_version", 0)) != SCHEMA_VERSION:
		return
	var accounts: Variant = parsed.get("accounts", {})
	if typeof(accounts) == TYPE_DICTIONARY:
		_accounts = accounts.duplicate(true)


func _save() -> bool:
	var file := FileAccess.open(_path, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({
		"schema_version": SCHEMA_VERSION,
		"accounts": _accounts,
	}))
	file.close()
	return true
