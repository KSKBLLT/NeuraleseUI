extends Node

const EndpointPolicy = preload("res://scripts/auth/remote_endpoint_policy.gd")
const SessionGate = preload("res://scripts/auth/remote_session_gate.gd")

var _conns: Dictionary = {}	# { SocketConnection: true }
var _auth_header_provider := Callable()
#"wss://localhost:8000/"
var connection_prefix: String = glob.get_root_ws()#"wss://neriqward.360hub.ru/api/"

func _process(_dt: float) -> void:
	var to_del: Array = []

	for conn in _conns.keys():
		if conn == null:
			to_del.append(conn)
			continue
		conn._poll()
		if conn.is_closed():
			to_del.append(conn)

	for c in to_del:
		_conns.erase(c)



func connect_to(url: String, on_packet: Callable = Callable(), headers: Dictionary = {}) -> Variant:
	var access := EndpointPolicy.websocket_access(url)
	var prepared := SessionGate.prepare_headers(
		access,
		headers,
		_current_bearer_headers()
	)
	if not prepared.get("ok", false):
		push_warning("WebSocket connection denied: %s (%s)" % [url, prepared.get("error", "")])
		return null
	var c = SocketConnection.new(_compose_ws_url(url), true, prepared.get("headers", {}))
	_conns[c] = true
	if on_packet.is_valid():
		c.packet.connect(on_packet)
	return c


func set_auth_header_provider(provider: Callable) -> void:
	_auth_header_provider = provider


func _current_bearer_headers() -> Dictionary:
	if _auth_header_provider.is_valid():
		var provided: Variant = _auth_header_provider.call()
		return provided if provided is Dictionary else {}
	return cookies.get_bearer_auth_header()


func _compose_ws_url(url: String) -> String:
	var path = _canonical_ws_page(url)
	if path.begins_with("ws://") or path.begins_with("wss://"):
		return path
	var base = connection_prefix.strip_edges()
	if base == "":
		base = glob.get_root_ws()
	if not base.ends_with("/"):
		base += "/"
	path = path.trim_prefix("/")
	return base + path


func _canonical_ws_page(url: String) -> String:
	return EndpointPolicy.canonical_websocket(url)
