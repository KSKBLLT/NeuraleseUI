extends SceneTree

const UpdatePolicy = preload("res://scripts/update_policy.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_semantic_versions()
	_test_prompt_policy()
	_test_platform_downloads()

	if failures.is_empty():
		print("PASS test_update_policy: 3 cases")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_semantic_versions() -> void:
	_expect_equal(UpdatePolicy.is_newer_version("1.0.10", "1.0.9"), true, "numeric patch comparison")
	_expect_equal(UpdatePolicy.is_newer_version("2.0", "1.99.99"), true, "major comparison")
	_expect_equal(UpdatePolicy.is_newer_version("1.0.7", "1.0.7"), false, "equal version")
	_expect_equal(UpdatePolicy.is_newer_version("1.0.6", "1.0.7"), false, "older version")
	_expect_equal(UpdatePolicy.is_newer_version("latest", "1.0.7"), false, "malformed version")


func _test_prompt_policy() -> void:
	_expect_equal(UpdatePolicy.should_prompt({"version": "1.0.8"}, "1.0.7"), true, "strict manifest without legacy flag")
	_expect_equal(UpdatePolicy.should_prompt({"version": "1.0.8", "d_req": true}, "1.0.7"), true, "new required download")
	_expect_equal(UpdatePolicy.should_prompt({"version": "1.0.8", "d_req": false}, "1.0.7"), false, "disabled download")
	_expect_equal(UpdatePolicy.should_prompt({"version": "1.0.7", "d_req": true}, "1.0.7"), false, "current version")


func _test_platform_downloads() -> void:
	var legacy := {"exe_url": "download"}
	_expect_equal(UpdatePolicy.resolve_download(legacy, "Windows"), {"url": "download", "sha256": ""}, "legacy Windows URL")
	_expect_equal(UpdatePolicy.resolve_download(legacy, "macOS"), {}, "legacy URL rejected on macOS")

	var sha := "a".repeat(64)
	var platform_payload := {
		"downloads": {
			"windows": {"url": "https://example.com/Neuralese.exe", "sha256": sha},
			"macos": {"url": "https://example.com/Neuralese-macOS.zip"},
			"linux": "https://example.com/Neuralese.AppImage"
		}
	}
	_expect_equal(UpdatePolicy.resolve_download(platform_payload, "Windows"), {"url": "https://example.com/Neuralese.exe", "sha256": sha}, "Windows package")
	_expect_equal(UpdatePolicy.resolve_download(platform_payload, "macOS"), {"url": "https://example.com/Neuralese-macOS.zip", "sha256": ""}, "macOS package")
	_expect_equal(UpdatePolicy.resolve_download(platform_payload, "Linux"), {"url": "https://example.com/Neuralese.AppImage", "sha256": ""}, "Linux package")

	var unsafe := {"downloads": {"macos": {"url": "javascript:alert(1)"}}}
	_expect_equal(UpdatePolicy.resolve_download(unsafe, "macOS"), {}, "unsafe URL")
	var invalid_sha := {"downloads": {"windows": {"url": "https://example.com/app.exe", "sha256": "bad"}}}
	_expect_equal(UpdatePolicy.resolve_download(invalid_sha, "Windows"), {}, "invalid checksum")


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
