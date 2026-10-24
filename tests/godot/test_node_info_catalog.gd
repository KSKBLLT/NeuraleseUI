extends SceneTree

const NodeInfoCatalog = preload("res://scripts/node_info_catalog.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var input_info := NodeInfoCatalog.get_info("input", "ru")
	var run_info := NodeInfoCatalog.get_info("run_model", "ru")
	_expect(bool(input_info.get("available", false)), "input docs are available")
	_expect(bool(run_info.get("available", false)), "run_model docs are available")
	_expect(input_info.get("title") != run_info.get("title"), "node-specific titles")
	_expect_equal(input_info.get("title"), "Input2D", "canonical node title")
	_expect_equal(NodeInfoCatalog.get_info("input", "de").get("title"), "Input2D", "English fallback")

	_expect_equal(NodeInfoCatalog.action_label("en"), "Ask Axon", "English action")
	_expect_equal(NodeInfoCatalog.action_label("ru"), "Спросить Аксона", "Russian action")
	_expect_equal(NodeInfoCatalog.action_label("kz"), "Аксоннан сұрау", "Kazakh action")

	var en_request := NodeInfoCatalog.make_axon_request(run_info, "en", "req-en")
	_expect_equal(
		en_request.get("question"),
		"What does %s do in this context and overall?" % run_info.get("title"),
		"English question",
	)
	_expect_equal(en_request.get("source_label"), "From %s info" % run_info.get("title"), "English source")

	var ru_request := NodeInfoCatalog.make_axon_request(run_info, "ru", "req-ru")
	_expect_equal(
		ru_request.get("question"),
		"Что делает %s в этом контексте и в целом?" % run_info.get("title"),
		"Russian question",
	)
	_expect_equal(ru_request.get("source_label"), "Из описания %s" % run_info.get("title"), "Russian source")

	var kz_info := NodeInfoCatalog.get_info("run_model", "kz")
	var kz_request := NodeInfoCatalog.make_axon_request(kz_info, "kz", "req-kz")
	_expect_equal(
		kz_request.get("question"),
		"%s осы контексте және жалпы не істейді?" % kz_info.get("title"),
		"Kazakh question",
	)
	_expect_equal(kz_request.get("source_label"), "%s сипаттамасынан" % kz_info.get("title"), "Kazakh source")

	var escaped := NodeInfoCatalog.render_bbcode({
		"available": true,
		"title": "Unsafe [title]",
		"summary": "Text [bad]",
		"operation": "Operation",
		"ports": [],
		"settings": [],
		"headings": {"operation": "Operation", "ports": "Ports", "settings": "Settings"},
	})
	_expect(escaped.contains("[lb]title[rb]"), "title BBCode is escaped")
	_expect(escaped.contains("[lb]bad[rb]"), "body BBCode is escaped")

	var missing := NodeInfoCatalog.get_info("does_not_exist", "ru")
	_expect(not bool(missing.get("available", true)), "unknown node is unavailable")
	_expect_equal(missing.get("message"), "Информация об этом узле недоступна.", "localized missing message")
	_expect(NodeInfoCatalog.make_axon_request(missing, "ru", "missing").is_empty(), "unavailable node cannot create request")

	if failures.is_empty():
		print("PASS test_node_info_catalog")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
