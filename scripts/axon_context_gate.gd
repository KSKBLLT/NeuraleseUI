extends RefCounted
class_name AxonContextGate

var _consumed: Dictionary = {}


func consume(request: Dictionary) -> bool:
	var request_id := str(request.get("request_id", "")).strip_edges()
	if request_id.is_empty() or _consumed.has(request_id):
		return false
	_consumed[request_id] = true
	return true


static func presentation(request: Dictionary) -> Dictionary:
	var question := str(request.get("question", ""))
	return {
		"api_text": question,
		"message": {
			"user": true,
			"text": question,
			"source_label": str(request.get("source_label", "")),
		},
	}
