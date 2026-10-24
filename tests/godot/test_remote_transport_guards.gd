extends SceneTree

# web.gd and its peers use autoloads directly. A --script test is compiled
# before the autoloads become globals, so load these at run time, not preload.
var WebScript: GDScript
var SocketsScript: GDScript
var TranscriberScript: GDScript

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	WebScript = load("res://scripts/web.gd")
	SocketsScript = load("res://scripts/sockets.gd")
	TranscriberScript = load("res://scripts/transcriber.gd")
	var guarded_web = WebScript.new()
	guarded_web.set_auth_header_provider(func() -> Dictionary: return {})
	root.add_child(guarded_web)
	var before: int = guarded_web._threads.size()
	var denied: Dictionary = await guarded_web.POST("ask_once", {"text": "hello"})
	_expect_equal(denied.get("error_code", ""), "auth_not_ready", "REST denied")
	_expect_equal(guarded_web._threads.size(), before, "denial creates no thread")
	_expect(guarded_web._access_headers("health").get("allowed", false), "public REST allowed")

	guarded_web.set_auth_header_provider(
		func() -> Dictionary: return {"Authorization": "Bearer current"}
	)
	var access: Dictionary = guarded_web._access_headers(
		"ask_once",
		{"Authorization": "Basic stale", "X-Test": "yes"}
	)
	_expect(access.get("allowed", false), "protected REST accepts current bearer")
	_expect_equal(
		access.get("headers", {}).get("Authorization", ""),
		"Bearer current",
		"REST uses trusted bearer"
	)

	var guarded_sockets = SocketsScript.new()
	guarded_sockets.set_auth_header_provider(func() -> Dictionary: return {})
	var socket = guarded_sockets.connect_to("ws/talk")
	_expect(socket == null, "WebSocket denied")
	_expect(guarded_sockets._conns.is_empty(), "denial stores no connection")

	var transcriber = TranscriberScript.new()
	transcriber.set_auth_header_provider(func() -> Dictionary: return {})
	var audio_handle = transcriber._request_raw(
		"https://example.invalid/transcribe_file",
		PackedByteArray(),
		PackedStringArray()
	)
	var audio_denied: Dictionary = await audio_handle.completed
	_expect_equal(
		audio_denied.get("error_code", ""),
		"auth_not_ready",
		"transcription denied before request allocation"
	)

	# The await above resumes inside the transcriber's own deferred call, which
	# keeps it locked; free it only once that call has returned.
	await process_frame
	guarded_web.queue_free()
	guarded_sockets.free()
	transcriber.free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _expect_equal(actual: Variant, expected: Variant, message: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [message, str(expected), str(actual)])


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_remote_transport_guards")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
