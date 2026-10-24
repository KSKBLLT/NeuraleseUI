extends Node
class_name OAuthLoopbackReceiver

const _MAX_REQUEST_BYTES := 8 * 1024
const _READ_TIMEOUT_MSEC := 5000

var _server := TCPServer.new()
var _path := ""


func start(redirect_uri: String) -> Dictionary:
	var parsed: Dictionary = parse_redirect_uri(redirect_uri)
	if parsed.is_empty():
		return {"ok": false, "error": "invalid_redirect_uri"}
	var listen_error := _server.listen(int(parsed["port"]), str(parsed["host"]))
	if listen_error != OK:
		return {
			"ok": false,
			"error": "callback_listener_unavailable",
			"code": listen_error,
		}
	_path = str(parsed["path"])
	return {"ok": true}


func wait_for_callback(timeout_seconds: int) -> Dictionary:
	if not _server.is_listening():
		return {"ok": false, "error": "callback_listener_not_started"}
	var deadline := Time.get_ticks_msec() + timeout_seconds * 1000
	while Time.get_ticks_msec() < deadline:
		if _server.is_connection_available():
			var peer: StreamPeerTCP = _server.take_connection()
			var result: Dictionary = await _read_request(peer)
			_send_response(peer, result)
			_server.stop()
			return result
		await get_tree().process_frame
	_server.stop()
	return {"ok": false, "error": "callback_timeout"}


func cancel() -> void:
	if _server.is_listening():
		_server.stop()


func _read_request(peer: StreamPeerTCP) -> Dictionary:
	var deadline := Time.get_ticks_msec() + _READ_TIMEOUT_MSEC
	var bytes := PackedByteArray()
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		var available: int = peer.get_available_bytes()
		if available > 0:
			var chunk: Array = peer.get_data(available)
			if int(chunk[0]) != OK:
				return {"ok": false, "error": "callback_read_failed"}
			bytes.append_array(chunk[1] as PackedByteArray)
			if bytes.size() > _MAX_REQUEST_BYTES:
				return {"ok": false, "error": "callback_request_too_large"}
			if bytes.get_string_from_ascii().find("\r\n\r\n") != -1:
				return parse_http_request(bytes.get_string_from_utf8(), _path)
		if peer.get_status() == StreamPeerTCP.STATUS_ERROR:
			return {"ok": false, "error": "callback_connection_failed"}
		await get_tree().process_frame
	return {"ok": false, "error": "callback_read_timeout"}


func _send_response(peer: StreamPeerTCP, result: Dictionary) -> void:
	var success: bool = bool(result.get("ok", false))
	var status: String = "200 OK" if success else "400 Bad Request"
	var body: String = (
		"<!doctype html><meta charset=\"utf-8\"><title>Neuralese</title>"
		+ "<style>body{font:16px system-ui;background:#171719;color:#f5f5f5;"
		+ "display:grid;place-items:center;min-height:100vh;margin:0}</style>"
		+ ("<p>Sign-in complete. You can return to Neuralese.</p>" if success else
		"<p>Sign-in was not completed. Return to Neuralese and try again.</p>")
	)
	var body_bytes: PackedByteArray = body.to_utf8_buffer()
	var response: String = (
		"HTTP/1.1 %s\r\nContent-Type: text/html; charset=utf-8\r\n"
		+ "Content-Length: %d\r\nConnection: close\r\n\r\n%s"
	) % [status, body_bytes.size(), body]
	peer.put_data(response.to_utf8_buffer())
	peer.poll()
	peer.disconnect_from_host()


static func parse_redirect_uri(uri: String) -> Dictionary:
	const PREFIX := "http://127.0.0.1:"
	if not uri.begins_with(PREFIX) or uri.find("?") != -1 or uri.find("#") != -1:
		return {}
	var rest: String = uri.substr(PREFIX.length())
	var slash: int = rest.find("/")
	if slash <= 0:
		return {}
	var port_text: String = rest.substr(0, slash)
	if not port_text.is_valid_int():
		return {}
	var port: int = int(port_text)
	var path: String = rest.substr(slash)
	if port < 1024 or port > 65535 or path != "/auth/callback":
		return {}
	return {"host": "127.0.0.1", "port": port, "path": path}


static func parse_http_request(request: String, expected_path: String) -> Dictionary:
	var first_line: String = request.get_slice("\r\n", 0)
	var parts: PackedStringArray = first_line.split(" ", false)
	if parts.size() != 3 or parts[0] != "GET":
		return {"ok": false, "error": "invalid_callback_method"}
	var target: String = str(parts[1])
	var path: String = target.get_slice("?", 0)
	if path != expected_path:
		return {"ok": false, "error": "invalid_callback_path"}
	var fields: Dictionary = _query_fields(target.get_slice("?", 1))
	var state: String = str(fields.get("state", ""))
	var oidc_error: String = str(fields.get("error", ""))
	if oidc_error != "":
		return {"ok": false, "error": oidc_error, "state": state}
	var code: String = str(fields.get("code", ""))
	if code == "" or state == "":
		return {"ok": false, "error": "invalid_callback_response"}
	return {"ok": true, "code": code, "state": state}


static func _query_fields(query: String) -> Dictionary:
	var result: Dictionary = {}
	for item in query.split("&", false):
		var key: String = item.get_slice("=", 0).uri_decode()
		var value: String = item.get_slice("=", 1).uri_decode()
		if key != "" and not result.has(key):
			result[key] = value
	return result
