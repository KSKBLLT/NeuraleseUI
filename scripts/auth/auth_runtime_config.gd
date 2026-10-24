extends RefCounted
class_name AuthRuntimeConfig

const _ENVELOPE_FIELDS := ["ok", "auth"]
const _AUTH_FIELDS := [
	"schema_version",
	"provider_id",
	"protocol",
	"issuer",
	"audience",
	"client_id",
	"scopes",
	"flow",
	"fallback_flow",
	"redirect_uri",
	"callback_timeout_seconds",
	"discovery_url",
]
const _FLOWS := ["authorization_code_pkce", "device_authorization"]
const _DEFAULT_CALLBACK_TIMEOUT_SECONDS := 180


static func parse(payload: Variant) -> Dictionary:
	if typeof(payload) != TYPE_DICTIONARY:
		return {}
	var envelope: Dictionary = payload
	if not _has_only_fields(envelope, _ENVELOPE_FIELDS):
		return {}
	if envelope.get("ok") != true or typeof(envelope.get("auth")) != TYPE_DICTIONARY:
		return {}

	var raw: Dictionary = envelope["auth"]
	if not _has_only_fields(raw, _AUTH_FIELDS):
		return {}
	if int(raw.get("schema_version", 0)) != 1:
		return {}
	if str(raw.get("protocol", "")) != "oidc":
		return {}

	for field in ["provider_id", "issuer", "audience", "client_id", "flow", "discovery_url"]:
		if typeof(raw.get(field)) != TYPE_STRING or str(raw[field]).strip_edges() == "":
			return {}

	var issuer := str(raw["issuer"]).trim_suffix("/")
	var discovery_url := str(raw["discovery_url"])
	if not _is_safe_url(issuer) or not _is_safe_url(discovery_url):
		return {}
	if discovery_url != issuer + "/.well-known/openid-configuration":
		return {}

	var flow := str(raw["flow"])
	if flow not in _FLOWS:
		return {}
	var fallback_flow := str(raw.get("fallback_flow", ""))
	if fallback_flow != "" and fallback_flow != "device_authorization":
		return {}
	var redirect_uri: String = str(raw.get("redirect_uri", "")).strip_edges()
	var callback_timeout_seconds: int = int(raw.get(
		"callback_timeout_seconds",
		_DEFAULT_CALLBACK_TIMEOUT_SECONDS
	))
	if flow == "authorization_code_pkce":
		if not _is_loopback_callback_url(redirect_uri):
			return {}
		if callback_timeout_seconds < 30 or callback_timeout_seconds > 600:
			return {}
	elif redirect_uri != "" and not _is_loopback_callback_url(redirect_uri):
		return {}

	var raw_scopes: Variant = raw.get("scopes")
	if typeof(raw_scopes) != TYPE_ARRAY or raw_scopes.is_empty():
		return {}
	var scopes: Array[String] = []
	for item in raw_scopes:
		if typeof(item) != TYPE_STRING:
			return {}
		var scope := str(item).strip_edges()
		if scope == "" or scope.find(" ") != -1 or scope in scopes:
			return {}
		scopes.append(scope)

	var parsed: Dictionary = {
		"schema_version": 1,
		"provider_id": str(raw["provider_id"]),
		"protocol": "oidc",
		"issuer": issuer,
		"audience": str(raw["audience"]),
		"client_id": str(raw["client_id"]),
		"scopes": scopes,
		"flow": flow,
		"fallback_flow": fallback_flow,
		"discovery_url": discovery_url,
	}
	if redirect_uri != "":
		parsed["redirect_uri"] = redirect_uri
		parsed["callback_timeout_seconds"] = callback_timeout_seconds
	return parsed


static func _has_only_fields(value: Dictionary, allowed: Array) -> bool:
	for key in value.keys():
		if str(key) not in allowed:
			return false
	return true


static func _is_safe_url(url: String) -> bool:
	if url.begins_with("https://"):
		return _authority(url, "https://") != ""
	if not url.begins_with("http://"):
		return false
	var authority := _authority(url, "http://")
	var host := authority
	if host.begins_with("["):
		var closing := host.find("]")
		if closing == -1:
			return false
		host = host.substr(1, closing - 1)
	elif host.find(":") != -1:
		host = host.get_slice(":", 0)
	host = host.to_lower()
	return host in ["127.0.0.1", "localhost", "::1"]


static func _authority(url: String, scheme: String) -> String:
	var rest := url.substr(scheme.length())
	var slash := rest.find("/")
	var authority := rest if slash == -1 else rest.substr(0, slash)
	if authority == "" or authority.find("@") != -1:
		return ""
	return authority


static func _is_loopback_callback_url(url: String) -> bool:
	const PREFIX := "http://127.0.0.1:"
	if not url.begins_with(PREFIX) or url.find("?") != -1 or url.find("#") != -1:
		return false
	var rest: String = url.substr(PREFIX.length())
	var slash: int = rest.find("/")
	if slash <= 0:
		return false
	var port_text: String = rest.substr(0, slash)
	if not port_text.is_valid_int():
		return false
	var port: int = int(port_text)
	return port >= 1024 and port <= 65535 and rest.substr(slash) == "/auth/callback"
