extends SceneTree

const UpdateManifest = preload("res://scripts/update_manifest.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_valid_manifest()
	_test_json_round_trip()
	_test_required_fields()
	_test_checksums_and_urls()
	_test_schema_and_notes()
	_test_unknown_fields()

	if failures.is_empty():
		print("PASS test_update_manifest")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _valid_manifest() -> Dictionary:
	return {
		"schema_version": 1,
		"version": "1.0.8",
		"mandatory": false,
		"published_at": "2026-07-16T18:00:00Z",
		"builder_commit_sha": "a".repeat(40),
		"setup_commit_sha": "b".repeat(40),
		"notes_markdown": {
			"ru": "Исправления и улучшения.",
			"en": "Fixes and improvements.",
		},
		"downloads": {
			"windows": {
				"url": "https://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Neuralese-Setup.exe",
				"size_bytes": 125829120,
				"sha256": "c".repeat(64),
			}
		},
	}


func _test_valid_manifest() -> void:
	var parsed: Dictionary = UpdateManifest.parse(_valid_manifest())
	_expect_equal(parsed.get("version"), "1.0.8", "version")
	_expect_equal(parsed.get("mandatory"), false, "mandatory")
	_expect_equal(parsed.get("builder_commit_sha"), "a".repeat(40), "builder commit")
	_expect_equal(parsed.get("setup_commit_sha"), "b".repeat(40), "setup commit")
	_expect_equal(parsed.get("downloads", {}).get("windows", {}).get("size_bytes"), 125829120, "package size")
	_expect_equal(parsed.get("notes_markdown", {}).get("ru"), "Исправления и улучшения.", "localized notes")

	var string_notes := _valid_manifest()
	string_notes["notes_markdown"] = "Single-language notes"
	_expect_equal(UpdateManifest.parse(string_notes).get("notes_markdown"), {"ru": "Single-language notes"}, "string notes")


func _test_json_round_trip() -> void:
	var decoded: Variant = JSON.parse_string(JSON.stringify(_valid_manifest()))
	var parsed := UpdateManifest.parse(decoded)
	_expect_equal(parsed.get("schema_version"), 1, "JSON schema version")
	_expect_equal(parsed.get("downloads", {}).get("windows", {}).get("size_bytes"), 125829120, "JSON package size")


func _test_required_fields() -> void:
	var missing_size := _valid_manifest()
	missing_size["downloads"]["windows"].erase("size_bytes")
	_expect_empty(UpdateManifest.parse(missing_size), "missing package size")

	var short_commit := _valid_manifest()
	short_commit["builder_commit_sha"] = "a".repeat(39)
	_expect_empty(UpdateManifest.parse(short_commit), "short builder commit")

	var uppercase_commit := _valid_manifest()
	uppercase_commit["setup_commit_sha"] = "B".repeat(40)
	_expect_empty(UpdateManifest.parse(uppercase_commit), "uppercase setup commit")


func _test_checksums_and_urls() -> void:
	var bad_checksum := _valid_manifest()
	bad_checksum["downloads"]["windows"]["sha256"] = "bad"
	_expect_empty(UpdateManifest.parse(bad_checksum), "invalid checksum")

	var uppercase_checksum := _valid_manifest()
	uppercase_checksum["downloads"]["windows"]["sha256"] = "C".repeat(64)
	_expect_empty(UpdateManifest.parse(uppercase_checksum), "uppercase checksum")

	var unsafe_url := _valid_manifest()
	unsafe_url["downloads"]["windows"]["url"] = "javascript:alert(1)"
	_expect_empty(UpdateManifest.parse(unsafe_url), "unsafe URL")

	var tiny_package := _valid_manifest()
	tiny_package["downloads"]["windows"]["size_bytes"] = 1024
	_expect_empty(UpdateManifest.parse(tiny_package), "package below minimum")


func _test_schema_and_notes() -> void:
	_expect_empty(UpdateManifest.parse({"schema_version": 2}), "unknown schema")
	_expect_empty(UpdateManifest.parse("not a dictionary"), "non-dictionary payload")

	var empty_notes := _valid_manifest()
	empty_notes["notes_markdown"] = {"ru": "  "}
	_expect_empty(UpdateManifest.parse(empty_notes), "empty notes")

	var unknown_language := _valid_manifest()
	unknown_language["notes_markdown"] = {"de": "Hinweise"}
	_expect_empty(UpdateManifest.parse(unknown_language), "unknown notes language")


func _test_unknown_fields() -> void:
	var extra_top_level := _valid_manifest()
	extra_top_level["command"] = "run-me"
	_expect_empty(UpdateManifest.parse(extra_top_level), "unknown top-level field")

	var extra_package_field := _valid_manifest()
	extra_package_field["downloads"]["windows"]["arguments"] = ["--unsafe"]
	_expect_empty(UpdateManifest.parse(extra_package_field), "unknown package field")


func _expect_empty(actual: Dictionary, label: String) -> void:
	_expect_equal(actual, {}, label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
