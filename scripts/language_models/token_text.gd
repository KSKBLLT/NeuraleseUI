extends RefCounted

# Byte fallback is a backend detail. One source character can occupy several
# token positions; keep those positions/IDs while displaying the character once.
static func groups(tokens: Array, source: String) -> Array:
	var result: Array = []
	for i in tokens.size():
		var token: Dictionary = tokens[i]
		var piece := str(token.get("piece", ""))
		var start := int(token.get("start", -1))
		var end := int(token.get("end", -1))
		var source_byte := start >= 0 and end > start and end <= source.length() and (not piece.begins_with("<0x") or _is_byte(piece))
		var position := int(token.get("position", i))
		if source_byte and not result.is_empty() and result[-1].source_byte and start < result[-1].end and end > result[-1].start:
			result[-1].ids.append(int(token.id))
			result[-1].positions.append(position)
			result[-1].start = mini(start, result[-1].start)
			result[-1].end = maxi(end, result[-1].end)
			result[-1].piece = source.substr(result[-1].start, result[-1].end-result[-1].start)
		else:
			result.append({
				"piece": source.substr(start, end-start) if source_byte else piece,
				"ids": [int(token.id)], "positions": [position],
				"start": start, "end": end, "source_byte": source_byte,
			})
	return result

static func visible(piece: String) -> String:
	var text := piece.replace("\n", "↵").replace("\t", "⇥").replace(" ", "·")
	return "·" if text.is_empty() else text

static func ids_text(ids: Array) -> String:
	var values := PackedStringArray()
	for id in ids: values.append(str(id))
	return " ".join(values)

static func _is_byte(piece: String) -> bool:
	if piece.length() != 6 or piece.unicode_at(0) != 60 or piece.unicode_at(5) != 62 or piece.unicode_at(1) != 48 or piece.unicode_at(2) != 120:
		return false
	var c0 := piece.unicode_at(3)
	var c1 := piece.unicode_at(4)
	var h0 := (c0 >= 48 and c0 <= 57) or (c0 >= 65 and c0 <= 70) or (c0 >= 97 and c0 <= 102)
	var h1 := (c1 >= 48 and c1 <= 57) or (c1 >= 65 and c1 <= 70) or (c1 >= 97 and c1 <= 102)
	return h0 and h1
