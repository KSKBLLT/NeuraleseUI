extends "res://scripts/language_models/dummy_language_backend.gd"

static var _loaded_tokens: Array = []
static var _loaded_map: Dictionary = {}
static var _max_token_len: int = 1

func _init(options: Dictionary = {}) -> void:
	super._init(options)
	_ensure_vocab_loaded()

static func _ensure_vocab_loaded() -> void:
	if not _loaded_tokens.is_empty():
		return
	if FileAccess.file_exists("res://resources/tokenizers/vocab_tokens.json"):
		var text := FileAccess.get_file_as_string("res://resources/tokenizers/vocab_tokens.json")
		var parsed = JSON.parse_string(text)
		if parsed is Array:
			_loaded_tokens = parsed
			for i in range(_loaded_tokens.size()):
				if i >= 256 and i < 512:
					continue
				var tok = _loaded_tokens[i]
				if tok is String and not _loaded_map.has(tok):
					_loaded_map[tok] = i
					if tok.length() > _max_token_len:
						_max_token_len = tok.length()

func piece(id: int) -> String:
	_ensure_vocab_loaded()
	if id >= 256 and id < 512:
		return _byte_pieces[id - 256]
	if id >= 0 and id < _loaded_tokens.size():
		return str(_loaded_tokens[id])
	return super.piece(id)

func vocab_piece(id: int) -> String:
	_ensure_vocab_loaded()
	if id >= 256 and id < 512:
		var b := id - 256
		if b >= 33 and b <= 126:
			return String.chr(b)
		if b == 32:
			return "·"
		if b == 10:
			return "↵"
		if b == 9:
			return "⇥"
		return _generated_piece(id + 65536)
	if id >= 0 and id < _loaded_tokens.size():
		var p: String = str(_loaded_tokens[id])
		return p.replace("\n", "↵").replace("\t", "⇥").replace(" ", "·")
	return super.vocab_piece(id)

func tokenize(text: String) -> Dictionary:
	_ensure_vocab_loaded()
	if text == _last_tok_text and vocab_size == _last_tok_vocab and not _last_tok_result.is_empty():
		return _last_tok_result
	var tokens: Array = []
	var ids: Array = []
	var pos := 0
	var text_len := text.length()

	while pos < text_len:
		var matched := false
		var max_l := mini(_max_token_len, text_len - pos)
		for l in range(max_l, 0, -1):
			var sub := text.substr(pos, l)
			if _loaded_map.has(sub):
				var tid: int = _loaded_map[sub]
				if tid < vocab_size:
					ids.append(tid)
					tokens.append({
						"id": tid,
						"piece": sub,
						"start": pos,
						"end": pos + l,
						"position": tokens.size()
					})
					pos += l
					matched = true
					break
		if not matched:
			var code := text.unicode_at(pos)
			if code < 0x80:
				var tok_id := 256 + code
				ids.append(tok_id)
				tokens.append({"id": tok_id, "piece": _byte_pieces[code], "start": pos, "end": pos + 1, "position": tokens.size()})
				pos += 1
			elif code < 0x800:
				var b0 := 0xC0 | (code >> 6)
				var b1 := 0x80 | (code & 0x3F)
				var id0 := 256 + b0
				var id1 := 256 + b1
				var idx := tokens.size()
				ids.append(id0)
				ids.append(id1)
				tokens.append({"id": id0, "piece": _byte_pieces[b0], "start": pos, "end": pos + 1, "position": idx})
				tokens.append({"id": id1, "piece": _byte_pieces[b1], "start": pos, "end": pos + 1, "position": idx + 1})
				pos += 1
			else:
				var utf8 := text.substr(pos, 1).to_utf8_buffer()
				for byte in utf8:
					var tok_id := 256 + byte
					ids.append(tok_id)
					tokens.append({"id": tok_id, "piece": _byte_pieces[byte], "start": pos, "end": pos + 1, "position": tokens.size()})
				pos += 1

	var res := {"text": text, "tokens": tokens, "ids": ids, "vocabulary_id": "vocab-v1-%d" % vocab_size}
	_last_tok_text = text
	_last_tok_vocab = vocab_size
	_last_tok_result = res
	return res

func decode(ids: Array) -> String:
	_ensure_vocab_loaded()
	var bytes := PackedByteArray()
	for id in ids:
		if id >= 256 and id < 512:
			bytes.append(id - 256)
		elif id != 2:
			bytes.append_array(piece(id).to_utf8_buffer())
	return bytes.get_string_from_utf8()

func vocabulary_page(query: String, offset: int, limit: int) -> Dictionary:
	_ensure_vocab_loaded()
	var entries: Array = []
	var count := 0
	var q := query.strip_edges().to_lower()
	for id in vocab_size:
		if id >= 256 and id < 512 and q != str(id):
			continue
		var sym := vocab_piece(id)
		if q != "" and not q in sym.to_lower() and q != str(id):
			continue
		if count >= maxi(0, offset) and entries.size() < clampi(limit, 1, 50):
			entries.append({"id": id, "piece": sym})
		count += 1
	return {"entries": entries, "total": count, "offset": maxi(0, offset)}
