extends "res://scripts/language_models/language_backend.gd"
var _disposed := false
var _queue: Array[Dictionary] = []
var _sending := false

func submit(request: Dictionary) -> void:
	if _disposed: return
	_queue.append(request)
	_flush.call_deferred()

func _flush() -> void:
	if _disposed or _sending or _queue.is_empty(): return
	_sending=true
	while not _queue.is_empty() and not _disposed:
		await Engine.get_main_loop().root.get_node("nn").submit_runtime_request(Engine.get_main_loop().root.get_node("language_models"),_queue.pop_front(),_receive)
	_sending=false

func _receive(packet: Dictionary) -> void:
	if not _disposed: response_ready.emit(packet)

func poll() -> void:
	pass

func dispose() -> void:
	_disposed=true
	_queue.clear()
	var manager=Engine.get_main_loop().root.get_node_or_null("nn")
	var owner=Engine.get_main_loop().root.get_node_or_null("language_models")
	if manager!=null and owner!=null: manager.close_runtime_channel(owner)
