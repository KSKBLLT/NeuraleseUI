extends SceneTree

const UpdateDownload = preload("res://scripts/update_download.gd")

const VALID_URL := "https://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Neuralese-Setup.exe"

var failures: Array[String] = []
var _case_index := 0


class FakeRequest:
	extends RefCounted

	signal on_chunk(chunk: PackedByteArray)
	signal completed(result: Dictionary)

	var chunks: Array[PackedByteArray] = []
	var result: Dictionary = {"ok": true}
	var cancelled := false

	func cancel() -> void:
		cancelled = true

	func deliver() -> void:
		for chunk in chunks:
			if cancelled:
				break
			on_chunk.emit(chunk)
		completed.emit(result)


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://updates"))
	await _test_success_and_monotonic_progress()
	await _test_size_mismatch()
	await _test_checksum_mismatch()
	await _test_network_error()
	await _test_oversized_stream_is_cancelled()
	_test_url_allowlist()
	_test_formatting_and_retry_limit()

	if failures.is_empty():
		print("PASS test_update_download")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _test_success_and_monotonic_progress() -> void:
	var chunks: Array[PackedByteArray] = [
		PackedByteArray([1, 2]),
		PackedByteArray([3]),
		PackedByteArray([4, 5, 6]),
	]
	var expected := PackedByteArray([1, 2, 3, 4, 5, 6])
	var destination := _destination("success")
	var downloader = UpdateDownload.new()
	var percentages: Array[float] = []
	downloader.progress.connect(func(_downloaded: int, _total: int, percent: float): percentages.append(percent))
	var handle := _handle(chunks, {"ok": true})
	handle.call_deferred("deliver")
	var result: Dictionary = await downloader.download(handle, _package(expected), destination)

	_expect_equal(result, {"ok": true, "path": destination}, "successful result")
	_expect_equal(FileAccess.get_file_as_bytes(destination), expected, "downloaded bytes")
	_expect_equal(FileAccess.file_exists(destination + ".part"), false, "successful part removed")
	_expect_equal(percentages.size(), 3, "progress event count")
	_expect_equal(_is_monotonic(percentages), true, "monotonic progress")
	_expect_equal(percentages[-1] if not percentages.is_empty() else -1.0, 100.0, "final progress")
	_remove(destination)


func _test_size_mismatch() -> void:
	var actual := PackedByteArray([1, 2, 3])
	var expected := PackedByteArray([1, 2, 3, 4])
	var destination := _destination("size")
	var result: Dictionary = await _run_download([actual], {"ok": true}, _package(expected), destination)
	_expect_equal(result.get("error"), "size", "size mismatch")
	_expect_equal(FileAccess.file_exists(destination + ".part"), false, "size mismatch part removed")
	_remove(destination)


func _test_checksum_mismatch() -> void:
	var bytes := PackedByteArray([5, 6, 7])
	var package := _package(bytes)
	package["sha256"] = "0".repeat(64)
	var destination := _destination("checksum")
	var result: Dictionary = await _run_download([bytes], {"ok": true}, package, destination)
	_expect_equal(result.get("error"), "checksum", "checksum mismatch")
	_expect_equal(FileAccess.file_exists(destination + ".part"), false, "checksum part removed")
	_remove(destination)


func _test_network_error() -> void:
	var bytes := PackedByteArray([8, 9])
	var destination := _destination("network")
	var result: Dictionary = await _run_download([bytes], {"ok": false}, _package(bytes), destination)
	_expect_equal(result.get("error"), "network", "network error")
	_expect_equal(FileAccess.file_exists(destination + ".part"), false, "network part removed")
	_remove(destination)


func _test_oversized_stream_is_cancelled() -> void:
	var expected := PackedByteArray([1, 2])
	var destination := _destination("oversized")
	var handle := _handle([PackedByteArray([1, 2, 3]), PackedByteArray([4])], {"ok": true})
	var downloader = UpdateDownload.new()
	handle.call_deferred("deliver")
	var result: Dictionary = await downloader.download(handle, _package(expected), destination)
	_expect_equal(result.get("error"), "size", "oversized stream")
	_expect_equal(handle.cancelled, true, "oversized request cancelled")
	_expect_equal(FileAccess.file_exists(destination + ".part"), false, "oversized part removed")
	_remove(destination)


func _test_url_allowlist() -> void:
	_expect_equal(UpdateDownload.is_allowed_installer_url(VALID_URL), true, "allowed installer URL")
	_expect_equal(UpdateDownload.is_allowed_installer_url("https://example.com/Neuralese-Setup.exe"), false, "foreign host")
	_expect_equal(UpdateDownload.is_allowed_installer_url("https://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Other.exe"), false, "wrong filename")
	_expect_equal(UpdateDownload.is_allowed_installer_url(VALID_URL + "?token=secret"), false, "query rejected")


func _test_formatting_and_retry_limit() -> void:
	_expect_equal(UpdateDownload.format_bytes(0), "0 B", "zero bytes")
	_expect_equal(UpdateDownload.format_bytes(1024 * 1024), "1.0 MB", "one megabyte")
	_expect_equal(UpdateDownload.format_bytes(120 * 1024 * 1024), "120.0 MB", "120 megabytes")
	_expect_equal(UpdateDownload.can_retry(1), true, "first retry")
	_expect_equal(UpdateDownload.can_retry(2), true, "second retry")
	_expect_equal(UpdateDownload.can_retry(3), false, "third attempt is final")
	_expect_equal(UpdateDownload.retry_delay_seconds(1), 1.0, "first retry delay")
	_expect_equal(UpdateDownload.retry_delay_seconds(2), 2.0, "second retry delay")


func _run_download(chunks: Array[PackedByteArray], response: Dictionary, package: Dictionary, destination: String) -> Dictionary:
	var downloader = UpdateDownload.new()
	var handle := _handle(chunks, response)
	handle.call_deferred("deliver")
	return await downloader.download(handle, package, destination)


func _handle(chunks: Array[PackedByteArray], response: Dictionary) -> FakeRequest:
	var handle := FakeRequest.new()
	handle.chunks = chunks
	handle.result = response
	return handle


func _package(bytes: PackedByteArray) -> Dictionary:
	return {
		"url": VALID_URL,
		"size_bytes": bytes.size(),
		"sha256": _sha256(bytes),
	}


func _sha256(bytes: PackedByteArray) -> String:
	var hashing := HashingContext.new()
	hashing.start(HashingContext.HASH_SHA256)
	hashing.update(bytes)
	return hashing.finish().hex_encode()


func _destination(label: String) -> String:
	_case_index += 1
	return "user://updates/test-%s-%s-%s.exe" % [label, Time.get_ticks_usec(), _case_index]


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
