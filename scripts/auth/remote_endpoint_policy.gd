class_name RemoteEndpointPolicy
extends RefCounted

enum Access {
	UNKNOWN,
	PUBLIC,
	AUTH_REQUIRED,
	EXTERNAL_PUBLIC,
}

const CATALOG_PATH := "res://resources/network_endpoint_policy.json"

static var _catalog_cache: Dictionary = {}


static func canonical_rest(page: String) -> String:
	return _canonical(page, "rest")


static func canonical_websocket(page: String) -> String:
	return _canonical(page, "websocket")


static func rest_access(page: String) -> Access:
	if _is_absolute_http_url(page):
		return Access.EXTERNAL_PUBLIC
	return _access_for(canonical_rest(page), "rest")


static func websocket_access(page: String) -> Access:
	if _is_absolute_websocket_url(page):
		return Access.EXTERNAL_PUBLIC
	return _access_for(canonical_websocket(page), "websocket")


static func catalog() -> Dictionary:
	return _load_catalog().duplicate(true)


static func _canonical(page: String, section_name: String) -> String:
	var path := _normalize_path(page)
	var section: Dictionary = _load_catalog().get(section_name, {})
	var aliases: Dictionary = section.get("aliases", {})
	return str(aliases.get(path, path))


static func _access_for(path: String, section_name: String) -> Access:
	var section: Dictionary = _load_catalog().get(section_name, {})
	var public_routes: Array = section.get("public", [])
	if public_routes.has(path):
		return Access.PUBLIC
	var protected_routes: Array = section.get("auth_required", [])
	if protected_routes.has(path):
		return Access.AUTH_REQUIRED
	return Access.UNKNOWN


static func _normalize_path(page: String) -> String:
	var normalized := page.strip_edges().trim_prefix("/")
	if normalized.contains("?"):
		normalized = normalized.get_slice("?", 0)
	if normalized.contains("#"):
		normalized = normalized.get_slice("#", 0)
	return normalized


static func _is_absolute_http_url(page: String) -> bool:
	var normalized := page.strip_edges().to_lower()
	return normalized.begins_with("http://") or normalized.begins_with("https://")


static func _is_absolute_websocket_url(page: String) -> bool:
	var normalized := page.strip_edges().to_lower()
	return normalized.begins_with("ws://") or normalized.begins_with("wss://")


static func _load_catalog() -> Dictionary:
	if not _catalog_cache.is_empty():
		return _catalog_cache
	if not FileAccess.file_exists(CATALOG_PATH):
		push_error("Remote endpoint policy is missing: %s" % CATALOG_PATH)
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(CATALOG_PATH))
	if not parsed is Dictionary or int(parsed.get("schema_version", 0)) != 1:
		push_error("Remote endpoint policy is invalid: %s" % CATALOG_PATH)
		return {}
	_catalog_cache = parsed
	return _catalog_cache
