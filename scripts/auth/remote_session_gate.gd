class_name RemoteSessionGate
extends RefCounted

const EndpointPolicy = preload("res://scripts/auth/remote_endpoint_policy.gd")

const ERROR_TEXT := {
	"ru": "Подключение к Neuralese ещё устанавливается. Попробуйте ещё раз через несколько секунд.",
	"en": "Neuralese is still connecting. Please try again in a few seconds.",
	"kz": "Neuralese жүйесіне қосылу әлі аяқталған жоқ. Бірнеше секундтан кейін қайталап көріңіз.",
}


static func has_bearer(headers: Variant) -> bool:
	if headers is Dictionary:
		for key in headers.keys():
			if str(key).to_lower() == "authorization":
				return _is_bearer_value(str(headers[key]))
		return false
	if headers is PackedStringArray or headers is Array:
		for header in headers:
			var line := str(header)
			var separator := line.find(":")
			if separator > 0 and line.substr(0, separator).strip_edges().to_lower() == "authorization":
				return _is_bearer_value(line.substr(separator + 1).strip_edges())
		return false
	return false


static func error_text(language: String) -> String:
	return str(ERROR_TEXT.get(language.to_lower(), ERROR_TEXT["en"]))


static func require_ready(
	bearer: Dictionary,
	language: String,
	show_error: bool,
	error_sink: Callable = Callable()
) -> bool:
	if has_bearer(bearer):
		return true
	if show_error and error_sink.is_valid():
		error_sink.call(error_text(language))
	return false


static func inference_ready(
	fully_local: bool,
	local_model_exists: bool,
	remote_ready: bool
) -> bool:
	return local_model_exists if fully_local else remote_ready


static func prepare_headers(access: int, supplied: Dictionary, bearer: Dictionary) -> Dictionary:
	if access == EndpointPolicy.Access.UNKNOWN:
		return {"ok": false, "error": "unclassified_endpoint", "headers": {}}
	if access == EndpointPolicy.Access.AUTH_REQUIRED:
		var prepared := _without_authorization(supplied)
		if not has_bearer(bearer):
			return {"ok": false, "error": "auth_not_ready", "headers": {}}
		for key in bearer.keys():
			prepared[key] = bearer[key]
		return {"ok": true, "headers": prepared}
	return {"ok": true, "headers": _without_authorization(supplied)}


static func _is_bearer_value(value: String) -> bool:
	var normalized := value.strip_edges()
	if not normalized.to_lower().begins_with("bearer "):
		return false
	return not normalized.substr(7).strip_edges().is_empty()


static func _without_authorization(headers: Dictionary) -> Dictionary:
	var result := {}
	for key in headers.keys():
		if str(key).to_lower() == "authorization":
			continue
		result[key] = headers[key]
	return result
