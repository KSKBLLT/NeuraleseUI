extends RefCounted
class_name UpdateManifest

const UpdatePolicyCore := preload("res://scripts/update_policy.gd")

const SCHEMA_VERSION := 1
const MIN_PACKAGE_SIZE := 1024 * 1024
const MAX_PACKAGE_SIZE := 4 * 1024 * 1024 * 1024
const TOP_LEVEL_KEYS := [
	"schema_version",
	"version",
	"mandatory",
	"published_at",
	"builder_commit_sha",
	"setup_commit_sha",
	"notes_markdown",
	"downloads",
]
const PACKAGE_KEYS := ["url", "size_bytes", "sha256"]
const NOTE_LANGUAGES := ["ru", "en", "kz"]


static func parse(payload: Variant) -> Dictionary:
	if not payload is Dictionary or not _has_only_keys(payload, TOP_LEVEL_KEYS):
		return {}
	if payload.size() != TOP_LEVEL_KEYS.size():
		return {}
	if _normalized_integer(payload.get("schema_version")) != SCHEMA_VERSION:
		return {}

	var version := str(payload.get("version", "")).strip_edges()
	if not UpdatePolicyCore.is_valid_version(version):
		return {}
	if not payload.get("mandatory") is bool:
		return {}

	var published_at := str(payload.get("published_at", "")).strip_edges()
	var package := _parse_windows_package(payload.get("downloads"))
	var notes := _parse_notes(payload.get("notes_markdown"))
	var builder_sha := _parse_commit_sha(payload.get("builder_commit_sha"))
	var setup_sha := _parse_commit_sha(payload.get("setup_commit_sha"))
	if published_at.is_empty() or package.is_empty() or notes.is_empty():
		return {}
	if builder_sha.is_empty() or setup_sha.is_empty():
		return {}

	return {
		"schema_version": SCHEMA_VERSION,
		"version": version,
		"mandatory": payload["mandatory"],
		"published_at": published_at,
		"builder_commit_sha": builder_sha,
		"setup_commit_sha": setup_sha,
		"notes_markdown": notes,
		"downloads": {"windows": package},
	}


static func _parse_windows_package(downloads: Variant) -> Dictionary:
	if not downloads is Dictionary or downloads.size() != 1 or not downloads.has("windows"):
		return {}
	var package: Variant = downloads["windows"]
	if not package is Dictionary:
		return {}
	if package.size() != PACKAGE_KEYS.size() or not _has_only_keys(package, PACKAGE_KEYS):
		return {}

	var url := str(package.get("url", "")).strip_edges()
	var size := _normalized_integer(package.get("size_bytes"))
	var checksum := str(package.get("sha256", "")).strip_edges()
	if not _is_safe_https_url(url):
		return {}
	if size < MIN_PACKAGE_SIZE or size > MAX_PACKAGE_SIZE:
		return {}
	if not _is_lower_hex(checksum, 64):
		return {}
	return {"url": url, "size_bytes": size, "sha256": checksum}


static func _parse_notes(value: Variant) -> Dictionary:
	if value is String:
		var text: String = value.strip_edges()
		return {"ru": text} if not text.is_empty() else {}
	if not value is Dictionary or value.is_empty() or not _has_only_keys(value, NOTE_LANGUAGES):
		return {}

	var notes: Dictionary = {}
	for language in NOTE_LANGUAGES:
		if not value.has(language):
			continue
		if not value[language] is String:
			return {}
		var text: String = value[language].strip_edges()
		if text.is_empty():
			return {}
		notes[language] = text
	return notes


static func _parse_commit_sha(value: Variant) -> String:
	if not value is String:
		return ""
	var checksum: String = value.strip_edges()
	return checksum if _is_lower_hex(checksum, 40) else ""


static func _normalized_integer(value: Variant) -> int:
	if value is int:
		return value
	if value is float and value == floorf(value):
		return int(value)
	return -1


static func _has_only_keys(value: Dictionary, allowed: Array) -> bool:
	for key in value.keys():
		if not key is String or not key in allowed:
			return false
	return true


static func _is_safe_https_url(url: String) -> bool:
	if not url.begins_with("https://"):
		return false
	for forbidden in ["\n", "\r", "\t", "[", "]", " "]:
		if url.contains(forbidden):
			return false
	return true


static func _is_lower_hex(value: String, expected_length: int) -> bool:
	if value.length() != expected_length:
		return false
	for character in value:
		if not character in "0123456789abcdef":
			return false
	return true
