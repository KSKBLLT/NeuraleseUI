extends Node
class_name AuthSession

const AuthRuntimeConfigScript = preload("res://scripts/auth/auth_runtime_config.gd")
const OIDCClientScript = preload("res://scripts/auth/oidc_client.gd")
const OAuthLoopbackReceiverScript = preload("res://scripts/auth/oauth_loopback_receiver.gd")

const _MAX_JSON_BYTES := 256 * 1024
const _REQUEST_TIMEOUT_SECONDS := 15.0
const _MIN_DEVICE_POLL_SECONDS := 5

signal login_started(payload: Dictionary)
signal login_completed(session: Dictionary)
signal login_failed(error: Dictionary)
signal session_cleared

var _api_root := ""
var _config_endpoint := ""
var _runtime_config: Dictionary = {}
var _discovery: Dictionary = {}
var _tokens: Dictionary = {}
var _user_info: Dictionary = {}
var _transport: Callable
var _browser_opener: Callable
var _callback_receiver: Callable
var _session_kind := "oidc"
var _internal_provider_id := ""


func configure(api_root: String, config_endpoint: String) -> void:
	_api_root = api_root.strip_edges().trim_suffix("/")
	_config_endpoint = config_endpoint.strip_edges()
	_runtime_config.clear()
	_discovery.clear()


func set_transport(transport: Callable) -> void:
	_transport = transport


func set_browser_opener(browser_opener: Callable) -> void:
	_browser_opener = browser_opener


func set_callback_receiver(callback_receiver: Callable) -> void:
	_callback_receiver = callback_receiver


func load_configuration(force: bool = false) -> Dictionary:
	if not force and not _runtime_config.is_empty() and not _discovery.is_empty():
		return {"ok": true, "auth": _runtime_config, "discovery": _discovery}
	if _api_root == "" or _config_endpoint == "":
		return _error("auth_not_configured")

	var bootstrap_url := _resolve_url(_api_root, _config_endpoint)
	if bootstrap_url == "":
		return _error("invalid_auth_config_endpoint")
	var config_response: Dictionary = await _request_json(
		HTTPClient.METHOD_GET,
		bootstrap_url
	)
	if not config_response.get("ok", false):
		return _error("auth_config_unavailable", config_response)

	var parsed_config: Dictionary = AuthRuntimeConfigScript.parse(
		config_response.get("json", {})
	)
	if parsed_config.is_empty():
		return _error("invalid_auth_config")

	var discovery_response: Dictionary = await _request_json(
		HTTPClient.METHOD_GET,
		str(parsed_config["discovery_url"])
	)
	if not discovery_response.get("ok", false):
		return _error("oidc_discovery_unavailable", discovery_response)
	var parsed_discovery: Dictionary = OIDCClientScript.parse_discovery(
		discovery_response.get("json", {}),
		str(parsed_config["issuer"])
	)
	if parsed_discovery.is_empty():
		return _error("invalid_oidc_discovery")

	_runtime_config = parsed_config
	_discovery = parsed_discovery
	return {"ok": true, "auth": _runtime_config, "discovery": _discovery}


func start_device_authorization() -> Dictionary:
	var loaded: Dictionary = await load_configuration()
	if not loaded.get("ok", false):
		return loaded
	var flow := str(_runtime_config.get("flow", ""))
	var fallback_flow := str(_runtime_config.get("fallback_flow", ""))
	if flow != "device_authorization" and fallback_flow != "device_authorization":
		return _error("device_authorization_not_enabled")

	var response: Dictionary = await _request_json(
		HTTPClient.METHOD_POST,
		str(_discovery["device_authorization_endpoint"]),
		{
			"client_id": _runtime_config["client_id"],
			"scope": " ".join(_runtime_config["scopes"]),
			"resource": _runtime_config["audience"],
		}
	)
	if not response.get("ok", false):
		return _error("device_authorization_failed", response)
	var body: Variant = response.get("json")
	if typeof(body) != TYPE_DICTIONARY:
		return _error("invalid_device_authorization_response")

	var started: Dictionary = body
	for field in ["device_code", "user_code", "verification_uri"]:
		if str(started.get(field, "")).strip_edges() == "":
			return _error("invalid_device_authorization_response")
	if not AuthRuntimeConfigScript._is_safe_url(str(started["verification_uri"])):
		return _error("invalid_device_authorization_response")
	var complete_url := str(started.get("verification_uri_complete", ""))
	if complete_url != "" and not AuthRuntimeConfigScript._is_safe_url(complete_url):
		return _error("invalid_device_authorization_response")

	var now_unix := int(Time.get_unix_time_from_system())
	started = started.duplicate(true)
	started["interval"] = max(
		_MIN_DEVICE_POLL_SECONDS,
		int(started.get("interval", _MIN_DEVICE_POLL_SECONDS))
	)
	started["expires_at_unix"] = now_unix + max(30, int(started.get("expires_in", 300)))
	login_started.emit(started)
	return started


func poll_device_authorization_once(started: Dictionary) -> Dictionary:
	if _discovery.is_empty() or _runtime_config.is_empty():
		return _error("auth_not_configured")
	var device_code := str(started.get("device_code", ""))
	if device_code == "":
		return _error("missing_device_code")

	var response: Dictionary = await _request_json(
		HTTPClient.METHOD_POST,
		str(_discovery["token_endpoint"]),
		{
			"client_id": _runtime_config["client_id"],
			"grant_type": OIDCClientScript.DEVICE_GRANT_TYPE,
			"device_code": device_code,
			"resource": _runtime_config["audience"],
		}
	)
	var body: Variant = response.get("json", {})
	var state: Dictionary = OIDCClientScript.classify_token_response(
		int(response.get("http_code", 0)),
		body
	)
	if state.get("state") == "complete":
		var applied := _apply_token_response(body)
		if not applied.get("ok", false):
			return applied
		if not _access_token_targets_runtime_api():
			var exchanged: Dictionary = await refresh()
			if (
				not exchanged.get("ok", false)
				or not _access_token_targets_runtime_api()
			):
				clear_session()
				return {
					"state": "api_access_token_unavailable",
					"retryable": false,
				}
		await _load_user_info()
		state["session"] = get_session()
	return state


func login(open_browser: bool = true) -> Dictionary:
	if has_session():
		var fresh: Dictionary = await ensure_fresh()
		if fresh.get("ok", false):
			login_completed.emit(get_session())
			return {"ok": true, "cached": true, "session": get_session()}

	var loaded: Dictionary = await load_configuration()
	if not loaded.get("ok", false):
		login_failed.emit(loaded)
		return loaded
	if str(_runtime_config.get("flow", "")) == "authorization_code_pkce":
		return await _login_authorization_code_pkce(open_browser)
	return await _login_device_authorization(open_browser)


func _login_authorization_code_pkce(open_browser: bool) -> Dictionary:
	var redirect_uri: String = str(_runtime_config.get("redirect_uri", ""))
	var verifier: String = OIDCClientScript.pkce_verifier()
	var challenge: String = OIDCClientScript.pkce_challenge(verifier)
	var state: String = OIDCClientScript.random_state()
	if verifier == "" or challenge == "" or state == "":
		return _fail_login("pkce_generation_failed")

	var receiver: Node = null
	if not _callback_receiver.is_valid():
		receiver = OAuthLoopbackReceiverScript.new()
		add_child(receiver)
		var listen_result: Dictionary = receiver.start(redirect_uri)
		if not listen_result.get("ok", false):
			receiver.queue_free()
			return _fail_login(str(listen_result.get("error", "callback_listener_unavailable")), listen_result)

	var authorization_url: String = OIDCClientScript.authorization_url(
		str(_discovery["authorization_endpoint"]),
		str(_runtime_config["client_id"]),
		redirect_uri,
		_runtime_config["scopes"],
		str(_runtime_config["audience"]),
		state,
		challenge
	)
	login_started.emit({"flow": "authorization_code_pkce"})
	if open_browser:
		var open_error: int = _open_browser(authorization_url)
		if open_error != OK:
			if receiver != null:
				receiver.cancel()
				receiver.queue_free()
			return _fail_login("could_not_open_browser", {"code": open_error})

	var timeout_seconds: int = int(_runtime_config.get("callback_timeout_seconds", 180))
	var callback: Dictionary
	if _callback_receiver.is_valid():
		var callback_value: Variant = await _callback_receiver.call(
			redirect_uri,
			timeout_seconds
		)
		callback = callback_value if typeof(callback_value) == TYPE_DICTIONARY else {}
	else:
		callback = await receiver.wait_for_callback(timeout_seconds)
		receiver.queue_free()
	if not callback.get("ok", false):
		return _fail_login(str(callback.get("error", "authorization_callback_failed")), callback)
	if str(callback.get("state", "")) != state:
		return _fail_login("authorization_state_mismatch")

	var response: Dictionary = await _request_json(
		HTTPClient.METHOD_POST,
		str(_discovery["token_endpoint"]),
		OIDCClientScript.authorization_code_token_fields(
			str(_runtime_config["client_id"]),
			str(callback.get("code", "")),
			redirect_uri,
			verifier,
			str(_runtime_config["audience"])
		)
	)
	if not response.get("ok", false):
		return _fail_login("authorization_code_exchange_failed", response)
	var applied: Dictionary = _apply_token_response(response.get("json", {}))
	if not applied.get("ok", false):
		return _fail_login(str(applied.get("error", "invalid_token_response")), applied)
	if not _access_token_targets_runtime_api():
		var exchanged: Dictionary = await refresh()
		if not exchanged.get("ok", false) or not _access_token_targets_runtime_api():
			clear_session()
			return _fail_login("api_access_token_unavailable")
	await _load_user_info()
	var completed: Dictionary = {"ok": true, "session": get_session()}
	login_completed.emit(completed["session"])
	return completed


func _login_device_authorization(open_browser: bool) -> Dictionary:
	var started: Dictionary = await start_device_authorization()
	if started.has("ok") and not started.get("ok", false):
		login_failed.emit(started)
		return started

	if open_browser:
		var login_url := str(started.get(
			"verification_uri_complete",
			started.get("verification_uri", "")
		))
		var open_error := _open_browser(login_url)
		if open_error != OK:
			var browser_error := _error("could_not_open_browser", {"code": open_error})
			login_failed.emit(browser_error)
			return browser_error

	var interval := int(started.get("interval", _MIN_DEVICE_POLL_SECONDS))
	var expires_at := int(started.get("expires_at_unix", 0))
	while int(Time.get_unix_time_from_system()) < expires_at:
		await get_tree().create_timer(interval).timeout
		var polled: Dictionary = await poll_device_authorization_once(started)
		match str(polled.get("state", "")):
			"complete":
				var completed := {"ok": true, "session": get_session()}
				login_completed.emit(completed["session"])
				return completed
			"pending":
				continue
			"slow_down":
				interval += _MIN_DEVICE_POLL_SECONDS
				continue
			_:
				var polling_error := _error(
					str(polled.get("state", "device_authorization_failed")),
					polled
				)
				login_failed.emit(polling_error)
				return polling_error

	var expired := _error("expired")
	login_failed.emit(expired)
	return expired


func _open_browser(url: String) -> int:
	if _browser_opener.is_valid():
		return int(_browser_opener.call(url))
	return OS.shell_open(url)


func _fail_login(code: String, details: Dictionary = {}) -> Dictionary:
	var error := _error(code, details)
	login_failed.emit(error)
	return error


func refresh() -> Dictionary:
	var refresh_token := str(_tokens.get("refresh_token", ""))
	if refresh_token == "":
		return _error("missing_refresh_token")
	if _session_kind == "internal":
		return await _refresh_internal(refresh_token)
	if _runtime_config.is_empty() or _discovery.is_empty():
		var loaded: Dictionary = await load_configuration()
		if not loaded.get("ok", false):
			return loaded

	var response: Dictionary = await _request_json(
		HTTPClient.METHOD_POST,
		str(_discovery["token_endpoint"]),
		{
			"client_id": _runtime_config["client_id"],
			"grant_type": "refresh_token",
			"refresh_token": refresh_token,
			"resource": _runtime_config["audience"],
			"scope": " ".join(_runtime_config["scopes"]),
		}
	)
	if not response.get("ok", false):
		var body: Dictionary = response.get("json", {})
		if str(body.get("error", "")) in ["invalid_grant", "invalid_token"]:
			clear_session()
		return _error("refresh_failed", response)
	return _apply_token_response(response.get("json", {}))


func ensure_fresh(min_valid_seconds: int = 30) -> Dictionary:
	if not has_session():
		return _error("missing_session")
	var expires_at := int(_tokens.get("expires_at_unix", 0))
	var now_unix := int(Time.get_unix_time_from_system())
	if expires_at - now_unix > min_valid_seconds:
		return {"ok": true, "session": get_session()}
	return await refresh()


func has_session() -> bool:
	return str(_tokens.get("access_token", "")) != ""


func get_access_token() -> String:
	return str(_tokens.get("access_token", ""))


func get_auth_headers() -> Dictionary:
	if not has_session():
		return {}
	return {"Authorization": "Bearer %s" % get_access_token()}


func get_user_info() -> Dictionary:
	return _user_info.duplicate(true)


func get_session() -> Dictionary:
	var provider_id := str(_runtime_config.get("provider_id", ""))
	if _session_kind == "internal":
		provider_id = _internal_provider_id
	return {
		"auth_provider": provider_id,
		"access_token": get_access_token(),
		"refresh_token": str(_tokens.get("refresh_token", "")),
		"user_info": get_user_info(),
	}


func clear_session() -> void:
	_tokens.clear()
	_user_info.clear()
	_session_kind = "oidc"
	_internal_provider_id = ""
	session_cleared.emit()


func apply_internal_token_pair(
	payload: Dictionary,
	provider_id: String = "internal"
) -> Dictionary:
	var normalized_provider := provider_id.strip_edges()
	if normalized_provider == "":
		return _error("invalid_auth_provider")
	var previous_user_info := _user_info.duplicate(true)
	var merged: Dictionary = OIDCClientScript.merge_token_response(_tokens, payload)
	if merged.is_empty():
		return _error("invalid_token_response")

	_tokens = merged
	_session_kind = "internal"
	_internal_provider_id = normalized_provider
	var user: Variant = payload.get("user", {})
	if typeof(user) == TYPE_DICTIONARY and not user.is_empty():
		_user_info = user.duplicate(true)
	elif not previous_user_info.is_empty():
		_user_info = previous_user_info
	else:
		_user_info = OIDCClientScript.decode_jwt_claims(get_access_token())
	return {"ok": true, "session": get_session()}


func _refresh_internal(refresh_token: String) -> Dictionary:
	var endpoint := _resolve_url(_api_root, "/api/auth/refresh")
	if endpoint == "":
		return _error("auth_not_configured")
	var response: Dictionary = await _request_json(
		HTTPClient.METHOD_POST,
		endpoint,
		{"refresh_token": refresh_token},
		PackedStringArray(),
		true
	)
	if not response.get("ok", false):
		var body: Dictionary = response.get("json", {})
		if int(response.get("http_code", 0)) in [401, 403] or str(
			body.get("error", "")
		) in ["invalid_grant", "invalid_token"]:
			clear_session()
		return _error("refresh_failed", response)
	return apply_internal_token_pair(
		response.get("json", {}),
		_internal_provider_id
	)


func _apply_token_response(payload: Variant) -> Dictionary:
	if typeof(payload) != TYPE_DICTIONARY:
		return _error("invalid_token_response")
	var merged: Dictionary = OIDCClientScript.merge_token_response(_tokens, payload)
	if merged.is_empty():
		return _error("invalid_token_response")
	_tokens = merged
	var claims := OIDCClientScript.decode_jwt_claims(str(_tokens.get("id_token", "")))
	if not claims.is_empty():
		_user_info = claims
	return {"ok": true, "session": get_session()}


func _load_user_info() -> Dictionary:
	var endpoint := str(_discovery.get("userinfo_endpoint", "")).strip_edges()
	if endpoint == "" or not has_session():
		return {"ok": true, "skipped": true}
	var response: Dictionary = await _request_json(
		HTTPClient.METHOD_GET,
		endpoint,
		{},
		PackedStringArray(["Authorization: Bearer %s" % get_access_token()])
	)
	if not response.get("ok", false):
		return _error("userinfo_unavailable", response)
	var payload: Variant = response.get("json", {})
	if typeof(payload) != TYPE_DICTIONARY:
		return _error("invalid_userinfo_response")
	var current_sub := str(_user_info.get("sub", "")).strip_edges()
	var returned_sub := str(payload.get("sub", "")).strip_edges()
	if current_sub != "" and returned_sub != "" and current_sub != returned_sub:
		return _error("userinfo_subject_mismatch")
	var merged := _user_info.duplicate(true)
	merged.merge(payload, true)
	_user_info = merged
	return {"ok": true, "user_info": get_user_info()}


func _access_token_targets_runtime_api() -> bool:
	var claims := OIDCClientScript.decode_jwt_claims(get_access_token())
	if claims.is_empty():
		return false
	if (
		str(claims.get("iss", "")).trim_suffix("/")
		!= str(_runtime_config.get("issuer", "")).trim_suffix("/")
	):
		return false
	var expected := str(_runtime_config.get("audience", ""))
	var audience: Variant = claims.get("aud")
	if typeof(audience) == TYPE_STRING:
		return str(audience) == expected
	if typeof(audience) == TYPE_ARRAY:
		return expected in audience
	return false


func _request_json(
	method: int,
	url: String,
	fields: Dictionary = {},
	headers: PackedStringArray = PackedStringArray(),
	encode_json: bool = false
) -> Dictionary:
	var request_headers := headers.duplicate()
	request_headers.append("Accept: application/json")
	if method == HTTPClient.METHOD_POST:
		request_headers.append(
			"Content-Type: application/json"
			if encode_json
			else "Content-Type: application/x-www-form-urlencoded"
		)
	if _transport.is_valid():
		var mocked: Variant = _transport.call(method, url, fields, request_headers)
		return mocked if typeof(mocked) == TYPE_DICTIONARY else _error("invalid_transport_response")
	if not AuthRuntimeConfigScript._is_safe_url(url):
		return _error("unsafe_auth_url")

	var request := HTTPRequest.new()
	request.timeout = _REQUEST_TIMEOUT_SECONDS
	request.max_redirects = 0
	add_child(request)
	var body := ""
	if method == HTTPClient.METHOD_POST:
		body = JSON.stringify(fields) if encode_json else OIDCClientScript.form_encode(fields)
	var start_error := request.request(url, request_headers, method, body)
	if start_error != OK:
		request.queue_free()
		return _error("network_start_failed", {"code": start_error})

	var completed: Array = await request.request_completed
	request.queue_free()
	var result := int(completed[0])
	var http_code := int(completed[1])
	var response_body: PackedByteArray = completed[3]
	if response_body.size() > _MAX_JSON_BYTES:
		return _error("auth_response_too_large", {"http_code": http_code})
	var text := response_body.get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		parsed = {}
	return {
		"ok": result == HTTPRequest.RESULT_SUCCESS and http_code >= 200 and http_code < 300,
		"result": result,
		"http_code": http_code,
		"json": parsed,
	}


func _resolve_url(root_url: String, endpoint: String) -> String:
	if endpoint.begins_with("http://") or endpoint.begins_with("https://"):
		return endpoint if AuthRuntimeConfigScript._is_safe_url(endpoint) else ""
	if not endpoint.begins_with("/"):
		return ""
	var resolved := root_url.trim_suffix("/") + endpoint
	return resolved if AuthRuntimeConfigScript._is_safe_url(resolved) else ""


func _error(code: String, details: Dictionary = {}) -> Dictionary:
	var result := {"ok": false, "error": code}
	if not details.is_empty():
		result["details"] = details
	return result
