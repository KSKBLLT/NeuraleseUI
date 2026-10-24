extends SceneTree

const UpdateDownload = preload("res://scripts/update_download.gd")

var failures: Array[String] = []
var _case_index := 0


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var fixture_url := _fixture_url()
	if fixture_url.is_empty():
		push_error("missing --fixture-url=<url>")
		quit(1)
		return
	var web = get_root().get_node_or_null("web")
	if web == null:
		push_error("WebAPI autoload is unavailable")
		quit(1)
		return

	var metadata := await _fetch_metadata(web, fixture_url)
	if metadata.is_empty():
		push_error("fixture metadata is unavailable")
		quit(1)
		return

	await _test_success(web, fixture_url, metadata)
	await _test_failure(web, fixture_url + "/wrong-size", metadata, "size", "wrong size")
	await _test_failure(web, fixture_url + "/wrong-sha", metadata, "checksum", "wrong sha")
	await _test_failure(web, fixture_url + "/not-found", metadata, "network", "404")
	await _test_failure(web, fixture_url + "/disconnect", metadata, "size", "disconnect")

	if failures.is_empty():
		print("PASS test_update_integration")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _fetch_metadata(web: Node, fixture_url: String) -> Dictionary:
	var response: Variant = await web.GET(fixture_url + "/metadata")
	if not response is Dictionary or response.get("ok", false) != true:
		return {}
	var payload: Variant = JSON.parse_string(response.get("body", PackedByteArray()).get_string_from_utf8())
	if not payload is Dictionary:
		return {}
	return payload


func _test_success(web: Node, fixture_url: String, metadata: Dictionary) -> void:
	var destination := _destination("success")
	var downloader = UpdateDownload.new()
	var percentages: Array[float] = []
	downloader.progress.connect(
		func(_downloaded: int, _total: int, percent: float): percentages.append(percent)
	)
	var handle: RefCounted = web.GET(fixture_url + "/payload", {}, true)
	var result: Dictionary = await downloader.download(handle, _package(metadata), destination)

	_expect_equal(result, {"ok": true, "path": destination}, "successful result")
	_expect_equal(FileAccess.file_exists(destination), true, "successful destination exists")
	_expect_equal(FileAccess.file_exists(destination + ".part"), false, "successful part removed")
	_expect_equal(FileAccess.get_sha256(destination), str(metadata["sha256"]), "successful sha")
	_expect_equal(percentages.is_empty(), false, "progress emitted")
	_expect_equal(_is_monotonic(percentages), true, "progress monotonic")
	if not percentages.is_empty():
		_expect_equal(percentages[0] > 0.0, true, "progress begins above zero")
		_expect_equal(percentages[-1], 100.0, "progress reaches 100")
	_remove(destination)


func _test_failure(
	web: Node,
	endpoint: String,
	metadata: Dictionary,
	expected_error: String,
	label: String
) -> void:
	var destination := _destination(label.replace(" ", "-"))
	var downloader = UpdateDownload.new()
	var handle: RefCounted = web.GET(endpoint, {}, true)
	var result: Dictionary = await downloader.download(handle, _package(metadata), destination)
	_expect_equal(result.get("error", ""), expected_error, label + " error")
	_expect_equal(FileAccess.file_exists(destination), false, label + " destination removed")
	_expect_equal(FileAccess.file_exists(destination + ".part"), false, label + " part removed")
	_remove(destination)


func _package(metadata: Dictionary) -> Dictionary:
	return {
		"url": str(metadata["package_url"]),
		"size_bytes": int(metadata["size_bytes"]),
		"sha256": str(metadata["sha256"]),
	}


func _fixture_url() -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--fixture-url="):
			return argument.trim_prefix("--fixture-url=").trim_suffix("/")
	return ""


func _destination(label: String) -> String:
	_case_index += 1
	return "user://updates/integration-%s-%s-%s.exe" % [label, Time.get_ticks_usec(), _case_index]


func _remove(path: String) -> void:
	for candidate in [path, path + ".part"]:
		if FileAccess.file_exists(candidate):
			DirAccess.remove_absolute(ProjectSettings.globalize_path(candidate))


func _is_monotonic(values: Array[float]) -> bool:
	for index in range(1, values.size()):
		if values[index] < values[index - 1]:
			return false
	return true


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
