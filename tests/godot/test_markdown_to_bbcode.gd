extends SceneTree

const MarkdownToBBCode = preload("res://scripts/markdown_to_bbcode.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	_test_supported_markdown()
	_test_unsafe_input_stays_text()

	if failures.is_empty():
		print("PASS test_markdown_to_bbcode: 2 cases")
		quit(0)
		return

	for failure in failures:
		push_error(failure)
	quit(1)


func _test_supported_markdown() -> void:
	var result: String = MarkdownToBBCode.convert(
		"First paragraph with **bold**, *italic* and `code`.\n\n- one\n- two\n\n[Docs](https://example.com/docs)."
	)
	_expect_contains(result, "[b]bold[/b]", "bold")
	_expect_contains(result, "[i]italic[/i]", "italic")
	_expect_contains(result, "[code]code[/code]", "inline code")
	_expect_contains(result, "• one\n• two", "unordered list")
	_expect_contains(result, "[url=https://example.com/docs]Docs[/url]", "safe link")
	_expect_contains(result, "\n\n", "paragraph break")


func _test_unsafe_input_stays_text() -> void:
	var result: String = MarkdownToBBCode.convert(
		"[color=red]raw[/color] [Bad](javascript:alert(1)) [Local](file:///tmp/x)"
	)
	_expect_not_contains(result, "[color=red]", "raw BBCode")
	_expect_not_contains(result, "[url=javascript:", "javascript link")
	_expect_not_contains(result, "[url=file:", "file link")
	_expect_contains(result, "[lb]color=red]raw[lb]/color]", "escaped BBCode remains visible")
	_expect_contains(result, "Bad (javascript:alert(1))", "unsafe URL remains visible")


func _expect_contains(value: String, part: String, label: String) -> void:
	if not value.contains(part):
		failures.append("%s: expected %s in %s" % [label, part, value])


func _expect_not_contains(value: String, part: String, label: String) -> void:
	if value.contains(part):
		failures.append("%s: did not expect %s in %s" % [label, part, value])
