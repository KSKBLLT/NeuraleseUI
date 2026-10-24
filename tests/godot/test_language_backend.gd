extends SceneTree

var failures: Array[String] = []
var replies: Array[Dictionary] = []

func _initialize() -> void:
	call_deferred("_run")

func check(value: bool, message: String) -> void:
	if not value: failures.append(message)

func _run() -> void:
	var script = load("res://scripts/language_models/dummy_language_backend.gd")
	if script == null:
		push_error("Language backend has not been implemented")
		quit(1)
		return
	var backend = script.new()
	backend.response_ready.connect(func(r: Dictionary): replies.append(r))
	backend.submit({"schema_version":1,"request_id":1,"session_id":"","graph_revision":1,"method":"open_session","params":{}})
	await process_frame
	check(replies.size() == 1, "asynchronous open returns exactly once")
	if replies.is_empty(): quit(1); return
	var sid: String = replies[-1].result.session_id
	for text in ["The cat sat on the", "Привет, әлем! 🙂", " the  cat\ncat "]:
		var result: Dictionary = backend.tokenize(text)
		check(backend.decode(result.ids) == text, "Unicode/spaces roundtrip: " + text)
		for token in result.tokens:
			check(token.start >= 0 and token.end <= text.length(), "token spans are bounded")
	var ids: Array = backend.tokenize("The cat sat on the").ids
	var a: Dictionary = backend.preview(ids, [], [])
	var b: Dictionary = backend.preview(ids, [], [])
	check(a == b, "dummy previews are deterministic")
	var depth: Dictionary=backend.preview([16,17,16],[],[{"id":"embed","op":"embedding"}]).nodes.embed.preview
	var depth_range: Array=depth.get("z_range",[])
	check(depth_range.size()==2,"embedding preview supplies a fixed third-component color range")
	for point in depth.points:
		var z: float=float(point.get("z",NAN))
		check(is_finite(z),"every embedding point supplies a finite third projection coordinate")
		if depth_range.size()==2: check(z>=depth_range[0] and z<=depth_range[1],"dummy third coordinates fit their color scale")
	check(depth.points[0].get("z",NAN)==depth.points[2].get("z",NAN),"same token has the same third coordinate at another position")
	check(depth.points[0].get("z",0)!=depth.points[1].get("z",0),"third projection coordinate distinguishes tokens")
	var continued: Dictionary=backend.preview([16,17,16],[21],[{"id":"embed","op":"embedding"}]).nodes.embed.preview
	check(depth_range==continued.get("z_range",[]) and depth.points[0].get("z",NAN)==continued.points[0].get("z",NAN),"appending tokens preserves the projection basis and color scale")
	check(a.scores.size() == 8192, "full vocabulary distribution")
	var total: float = 0.0
	for score in a.scores: total += score
	check(absf(total - 1.0) < 0.00001, "scores normalize over full vocabulary")
	for head in range(4):
		var matrix: Array = backend.attention(ids.size(), head)
		check(is_equal_approx(matrix[0][0], 1.0), "first causal row is one for every head")
		for row in range(matrix.size()):
			var mass: float = 0.0
			for col in range(matrix.size()):
				mass += matrix[row][col]
				if col > row: check(matrix[row][col] == 0.0, "future positions masked")
			check(absf(mass - 1.0) < 0.00001, "causal attention normalized")
	check(backend.attention(5, 0) != backend.attention(5, 1), "heads differ")
	backend.submit({"schema_version":1,"request_id":2,"session_id":sid,"graph_revision":1,"method":"no_such_method","params":{}})
	await process_frame
	check(not replies[-1].ok, "unsupported methods fail explicitly")
	check(replies[-1].is_dummy and replies[-1].provider_id == "dummy-v1", "every response marks dummy")
	var large = script.new({"vocab_size":65536})
	var page: Dictionary = large.vocabulary_page("65535", 0, 50)
	check(page.entries.size() == 1 and page.entries[0].id == 65535, "lookup any vocabulary ID")
	check(large.vocabulary_page("", 0, 100000).entries.size() == 50, "bounded vocabulary pages")
	var sessions_before: int = backend.sessions.size()
	backend.submit({"schema_version":1,"request_id":70,"session_id":"","graph_revision":1,"method":"open_session","params":{}})
	backend.submit({"schema_version":1,"request_id":71,"session_id":"","graph_revision":1,"method":"cancel","params":{"target_request_id":70}})
	await process_frame
	check(backend.sessions.size()==sessions_before,"cancel before open response releases the session")
	backend.dispose()
	large.dispose()
	if failures.is_empty():
		print("PASS test_language_backend")
		quit(0)
	else:
		for message in failures: push_error(message)
		quit(1)
