extends RefCounted

const VERSION := 1
const ACCENT := Color("7f9eff")
const EXCLUSIVE_LANGUAGE_TYPES := [&"text_input", &"tokenizer", &"embedding", &"attention_head", &"autoregression"]
const NEW_TYPES := [&"text_input", &"tokenizer", &"embedding", &"attention_head", &"token_labels", &"autoregression"]
const OPS := [&"text_input", &"tokenizer", &"embedding", &"attention_head", &"layer", &"concat", &"softmax", &"token_labels", &"top_output", &"autoregression"]
const INPUT_TYPES := {"tokenizer":"language_text","embedding":"language_tokens","attention_head":"language_vectors","layer":"language_vectors","concat":"language_vectors","softmax":"language_vectors","token_labels":"language_scores","top_output":"language_scores","autoregression":"autoregression"}
const OUTPUT_TYPES := {"text_input":"language_text","tokenizer":"language_tokens","embedding":"language_vectors","attention_head":"language_vectors","layer":"language_vectors","concat":"language_vectors","softmax":"language_scores","token_labels":"autoregression","top_output":"autoregression"}
const DTYPES := {"language_text":"utf8","language_tokens":"int32","language_vectors":"float32","language_scores":"float32","autoregression":"autoregression"}

static func make_request(method: StringName, params: Dictionary, request_id: int, session_id: String, graph_revision: int) -> Dictionary:
	return {"schema_version":VERSION,"method":str(method),"params":params,"request_id":request_id,"session_id":session_id,"graph_revision":graph_revision}

static func validate_response(response: Dictionary) -> Array[String]:
	var errors: Array[String] = []
	for key in ["schema_version", "request_id", "session_id", "graph_revision", "provider_id", "is_dummy", "ok", "result", "error"]:
		if not response.has(key): errors.append("missing_" + key)
	if response.get("schema_version") != VERSION: errors.append("schema_version")
	if response.get("ok", false):
		if response.get("error") != null or not response.get("result") is Dictionary: errors.append("invalid_result")
	else:
		if not response.get("error") is Dictionary: errors.append("invalid_error")
	var result: Dictionary = response.get("result", {}) if response.get("result") is Dictionary else {}
	if result.has("scores"):
		var mass := 0.0
		for value in result.scores:
			if not (value is float or value is int) or not is_finite(float(value)) or value < 0:
				errors.append("invalid_probability")
				break
			mass += value
		if absf(mass - 1.0) > 0.00001: errors.append("invalid_probability_sum")
		if result.scores.size() != int(result.get("vocab_size", result.scores.size())): errors.append("invalid_vocabulary_size")
	return errors
