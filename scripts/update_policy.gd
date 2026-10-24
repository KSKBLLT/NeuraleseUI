extends RefCounted
class_name UpdatePolicy


static func is_valid_version(version: String) -> bool:
	var parts := _parse_version(version)
	return parts.size() == 3


static func is_newer_version(candidate: String, current: String) -> bool:
	var candidate_parts := _parse_version(candidate)
	var current_parts := _parse_version(current)
	if candidate_parts.is_empty() or current_parts.is_empty():
		return false

	var component_count := maxi(candidate_parts.size(), current_parts.size())
	for index in component_count:
		var candidate_component: int = candidate_parts[index] if index < candidate_parts.size() else 0
		var current_component: int = current_parts[index] if index < current_parts.size() else 0
		if candidate_component > current_component:
			return true
		if candidate_component < current_component:
			return false
	return false


static func should_prompt(state: Dictionary, current_version: String) -> bool:
	if state.has("d_req") and state.get("d_req") != true:
		return false
	var remote_version := str(state.get("version", "")).strip_edges()
	return is_newer_version(remote_version, current_version)


static func platform_key(os_name: String) -> String:
	match os_name.to_lower():
		"windows":
			return "windows"
		"macos":
			return "macos"
		"linux", "freebsd", "netbsd", "openbsd", "bsd":
			return "linux"
		_:
			return ""


static func resolve_download(state: Dictionary, os_name: String) -> Dictionary:
	var key := platform_key(os_name)
	if key.is_empty():
		return {}

	var candidate: Variant = null
	var downloads: Variant = state.get("downloads")
	if downloads is Dictionary:
		candidate = downloads.get(key)
	if candidate == null and key == "windows":
		candidate = state.get("exe_url")
	return _normalize_download(candidate, key == "windows")


static func _normalize_download(candidate: Variant, allow_relative: bool) -> Dictionary:
	var url := ""
	var checksum := ""
	if candidate is String:
		url = candidate
	elif candidate is Dictionary:
		url = str(candidate.get("url", ""))
		checksum = str(candidate.get("sha256", "")).to_lower().strip_edges()
	else:
		return {}

	url = url.strip_edges()
	if not _is_valid_url(url, allow_relative):
		return {}
	if not checksum.is_empty() and not _is_sha256(checksum):
		return {}
	return {"url": url, "sha256": checksum}


static func _parse_version(version: String) -> Array[int]:
	var result: Array[int] = []
	var cleaned := version.strip_edges()
	if cleaned.is_empty():
		return result
	for part in cleaned.split("."):
		if part.is_empty() or not part.is_valid_int() or part.begins_with("-") or part.begins_with("+"):
			return []
		result.append(int(part))
	return result


static func _is_valid_url(url: String, allow_relative: bool) -> bool:
	if url.begins_with("https://") or url.begins_with("http://"):
		return not url.contains("[") and not url.contains("]") and not url.contains("\n")
	if not allow_relative or url.contains("://") or url.contains(".."):
		return false
	var route_pattern := RegEx.new()
	if route_pattern.compile("^[A-Za-z0-9][A-Za-z0-9_./-]*$") != OK:
		return false
	return route_pattern.search(url) != null


static func _is_sha256(value: String) -> bool:
	if value.length() != 64:
		return false
	for character in value:
		if not character in "0123456789abcdef":
			return false
	return true
