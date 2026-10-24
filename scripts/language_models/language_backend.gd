extends RefCounted
## Transport-neutral boundary. Responses are asynchronous, including demo responses.
signal response_ready(response: Dictionary)
signal progress_ready(response: Dictionary)

func submit(_request: Dictionary) -> void:
	push_error("LanguageBackend.submit must be implemented")

func dispose() -> void:
	pass
