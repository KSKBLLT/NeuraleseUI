extends RefCounted
class_name OIDCClient

const AuthRuntimeConfigScript = preload("res://scripts/auth/auth_runtime_config.gd")
const DEVICE_GRANT_TYPE := "urn:ietf:params:oauth:grant-type:device_code"


static func pkce_verifier() -> String:
	var random := Crypto.new().generate_random_bytes(48)
	return _base64url_encode(random)


static func random_state() -> String:
	return _base64url_encode(Crypto.new().generate_random_bytes(32))


static func pkce_challenge(verifier: String) -> String:
	var hashing := HashingContext.new()
	if hashing.start(HashingContext.HASH_SHA256) != OK:
		return ""
	if hashing.update(verifier.to_utf8_buffer()) != OK:
		return ""
	return _base64url_encode(hashing.finish())


static func authorization_url(
	endpoint: String,
	client_id: String,
	redirect_uri: String,
	scopes: Array,
	audience: String,
	state: String,
	challenge: String
) -> String:
	var fields := {
		"client_id": client_id,
		"redirect_uri": redirect_uri,
		"response_type": "code",
		"scope": " ".join(scopes),
		"resource": audience,
		"state": state,
		"code_challenge": challenge,
		"code_challenge_method": "S256",
		"prompt": "login",
		"first_screen": "identifier:sign_in",
		"identifier": "username",
	}
	return "%s?%s" % [endpoint, form_encode(fields)]


static func authorization_code_token_fields(
	client_id: String,
	code: String,
	redirect_uri: String,
	verifier: String,
	audience: String
) -> Dictionary:
	return {
		"client_id": client_id,
		"grant_type": "authorization_code",
		"code": code,
		"redirect_uri": redirect_uri,
		"code_verifier": verifier,
		"resource": audience,
	}


static func parse_discovery(payload: Variant, expected_issuer: String) -> Dictionary:
	if typeof(payload) != TYPE_DICTIONARY:
		return {}
	var raw: Dictionary = payload
	var issuer := expected_issuer.trim_suffix("/")
	if str(raw.get("issuer", "")).trim_suffix("/") != issuer:
		return {}

	var required := [
		"authorization_endpoint",
		"token_endpoint",
		"device_authorization_endpoint",
		"jwks_uri",
	]
	var parsed := {"issuer": issuer}
	for field in required:
		var endpoint := str(raw.get(field, "")).strip_edges()
		if endpoint == "" or not AuthRuntimeConfigScript._is_safe_url(endpoint):
			return {}
		parsed[field] = endpoint
	var userinfo_endpoint := str(raw.get("userinfo_endpoint", "")).strip_edges()
	if userinfo_endpoint != "":
		if not AuthRuntimeConfigScript._is_safe_url(userinfo_endpoint):
			return {}
		parsed["userinfo_endpoint"] = userinfo_endpoint
	return parsed


static func form_encode(fields: Dictionary) -> String:
	var keys := fields.keys()
	keys.sort()
	var parts: PackedStringArray = []
	for key in keys:
		var value: Variant = fields[key]
		if value == null or str(value) == "":
			continue
		parts.append("%s=%s" % [str(key).uri_encode(), str(value).uri_encode()])
	return "&".join(parts)


static func classify_token_response(http_code: int, payload: Variant) -> Dictionary:
	if typeof(payload) != TYPE_DICTIONARY:
		return {"state": "invalid_response", "retryable": false}
	var body: Dictionary = payload
	if http_code >= 200 and http_code < 300 and str(body.get("access_token", "")) != "":
		return {"state": "complete", "retryable": false}
	match str(body.get("error", "")):
		"authorization_pending":
			return {"state": "pending", "retryable": true}
		"slow_down":
			return {"state": "slow_down", "retryable": true}
		"access_denied":
			return {"state": "access_denied", "retryable": false}
		"expired_token":
			return {"state": "expired", "retryable": false}
		"invalid_grant":
			return {"state": "invalid_grant", "retryable": false}
		_:
			return {"state": "error", "retryable": false}


static func merge_token_response(
	current: Dictionary,
	response: Dictionary,
	now_unix: int = -1
) -> Dictionary:
	if str(response.get("access_token", "")) == "":
		return {}
	if now_unix < 0:
		now_unix = int(Time.get_unix_time_from_system())
	var next := current.duplicate(true)
	next["access_token"] = str(response["access_token"])
	next["refresh_token"] = str(
		response.get("refresh_token", current.get("refresh_token", ""))
	)
	next["id_token"] = str(response.get("id_token", current.get("id_token", "")))
	next["token_type"] = str(response.get("token_type", "Bearer"))
	next["scope"] = str(response.get("scope", current.get("scope", "")))
	next["expires_at_unix"] = now_unix + max(0, int(response.get("expires_in", 0)))
	return next


static func decode_jwt_claims(token: String) -> Dictionary:
	var segments := token.split(".")
	if segments.size() != 3:
		return {}
	var encoded := str(segments[1]).replace("-", "+").replace("_", "/")
	while encoded.length() % 4 != 0:
		encoded += "="
	var decoded := Marshalls.base64_to_raw(encoded).get_string_from_utf8()
	var parsed: Variant = JSON.parse_string(decoded)
	return parsed if typeof(parsed) == TYPE_DICTIONARY else {}


static func _base64url_encode(value: PackedByteArray) -> String:
	return Marshalls.raw_to_base64(value).replace("+", "-").replace("/", "_").trim_suffix("=")
