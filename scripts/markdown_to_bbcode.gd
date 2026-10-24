extends RefCounted
class_name MarkdownToBBCode

const PLACEHOLDER_OPEN := "\uE000"
const PLACEHOLDER_CLOSE := "\uE001"


static func convert(markdown: String) -> String:
	var extracted := _extract_links(markdown)
	var text: String = _escape_bbcode(extracted["text"])
	text = _convert_lists(text)
	text = _replace_regex(text, "`([^`\\n]+)`", "[code]$1[/code]")
	text = _replace_regex(text, "\\*\\*([^*\\n]+)\\*\\*", "[b]$1[/b]")
	text = _replace_regex(text, "\\*([^*\\n]+)\\*", "[i]$1[/i]")

	var links: Array = extracted["links"]
	for index in links.size():
		text = text.replace(_placeholder(index), links[index])
	return text


static func _extract_links(source: String) -> Dictionary:
	var text := ""
	var links: Array[String] = []
	var cursor := 0

	while cursor < source.length():
		var label_start := source.find("[", cursor)
		if label_start < 0:
			text += source.substr(cursor)
			break
		var label_end := source.find("](", label_start + 1)
		if label_end < 0:
			text += source.substr(cursor)
			break
		var first_closing_bracket := source.find("]", label_start + 1)
		if first_closing_bracket != label_end:
			text += source.substr(cursor, label_start - cursor + 1)
			cursor = label_start + 1
			continue

		var url_start := label_end + 2
		var url_end := _find_closing_parenthesis(source, url_start)
		if url_end < 0:
			text += source.substr(cursor, label_start - cursor + 1)
			cursor = label_start + 1
			continue

		text += source.substr(cursor, label_start - cursor)
		var label := source.substr(label_start + 1, label_end - label_start - 1)
		var url := source.substr(url_start, url_end - url_start)
		links.append(_render_link(label, url))
		text += _placeholder(links.size() - 1)
		cursor = url_end + 1

	return {"text": text, "links": links}


static func _find_closing_parenthesis(source: String, start: int) -> int:
	var depth := 1
	for index in range(start, source.length()):
		var character := source[index]
		if character == "(":
			depth += 1
		elif character == ")":
			depth -= 1
			if depth == 0:
				return index
	return -1


static func _render_link(label: String, url: String) -> String:
	var safe_label := _escape_bbcode(label)
	var safe_url := url.strip_edges()
	if safe_url.begins_with("https://") or safe_url.begins_with("http://"):
		safe_url = safe_url.replace("[", "%5B").replace("]", "%5D")
		return "[url=%s]%s[/url]" % [safe_url, safe_label]
	return "%s (%s)" % [safe_label, _escape_bbcode(safe_url)]


static func _convert_lists(source: String) -> String:
	var lines := source.split("\n", true)
	for index in lines.size():
		var line: String = lines[index]
		var indentation_length := line.length() - line.lstrip(" \t").length()
		var indentation := line.left(indentation_length)
		var content := line.substr(indentation_length)
		if content.begins_with("- ") or content.begins_with("* "):
			lines[index] = "%s• %s" % [indentation, content.substr(2)]
	return "\n".join(lines)


static func _replace_regex(source: String, pattern: String, replacement: String) -> String:
	var regex := RegEx.new()
	if regex.compile(pattern) != OK:
		return source
	return regex.sub(source, replacement, true)


static func _escape_bbcode(value: String) -> String:
	return value.replace("[", "[lb]")


static func _placeholder(index: int) -> String:
	return "%s%d%s" % [PLACEHOLDER_OPEN, index, PLACEHOLDER_CLOSE]
