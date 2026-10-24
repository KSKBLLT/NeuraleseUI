extends "res://scripts/language_models/language_backend.gd"
const PIECES := ["The", "cat", "sat", "on", "the", "mat", ".", "rug", "floor", "grass", "bed", " "]
const MODEL_WIDTH := 256
const HEAD_COUNT := 4
var vocab_size := 8192
var sessions: Dictionary = {}
var _serial := 0
var _disposed := false
var _cancelled: Dictionary = {}
var _byte_pieces: PackedStringArray = PackedStringArray()
var _point_cache: Dictionary = {}
var _last_tok_text := ""
var _last_tok_vocab := -1
var _last_tok_result: Dictionary = {}
func _init(options: Dictionary = {}) -> void:
	vocab_size = clampi(int(options.get("vocab_size", 8192)), 1024, 65536)
	_byte_pieces.resize(256)
	for b in 256:
		_byte_pieces[b] = "<0x%02X>" % b

func submit(request: Dictionary) -> void:
	if _disposed: return
	var result: Dictionary = {}
	var error: Variant = null
	var params: Dictionary = request.get("params", {})
	var sid := str(request.get("session_id", ""))
	var method := str(request.get("method", ""))
	if int(request.get("schema_version", 0)) != 1:
		error = _error("schema_version", "Unsupported language protocol")
	elif method not in ["capabilities", "open_session", "cancel", "close_session", "vocabulary_page", "tokenize"] and not sessions.has(sid):
		error = _error("unknown_session", "Session has been closed")
	else:
		match method:
			"capabilities": result = {"vocab_size":vocab_size,"model_width":MODEL_WIDTH,"head_count":HEAD_COUNT,"max_context":512,"max_new_tokens":32,"training":"dummy","export":false}
			"open_session":
				_serial += 1
				sid = "demo-%d" % _serial
				sessions[sid] = {"graph":params.get("graph", {}),"last":{},"open_request_id":request.get("request_id",0)}
				result = {"session_id":sid}
			"tokenize": result = tokenize(str(params.get("text", "")))
			"run_step", "preview", "preview_node":
				var ids: Array = params.get("prefix_ids", [])
				var generated: Array = params.get("generated_ids", [])
				if ids.is_empty() or ids.size() + generated.size() > 512 or generated.size() >= 32:
					error = _error("context_limit", "Use between 1 and 512 tokens")
				elif not _valid_ids(ids) or not _valid_ids(generated):
					error = _error("invalid_token", "Token is outside the vocabulary")
				else:
					result = preview(ids, generated, params.get("graph", sessions[sid].graph).get("nodes", []))
					if method != "run_step":
						result.generated_ids = generated.duplicate()
						result.decoded_text = decode(generated)
						result.finished = false
						result.stop_reason = ""
					if method == "preview_node":
						var target := str(params.get("target_id", ""))
						result.nodes = {target:result.nodes[target]} if result.nodes.has(target) else {}
					for trace in result.nodes.values(): trace.preview.decoded_text = result.decoded_text
					sessions[sid].last = result
			"inspect":
				var last: Dictionary = sessions[sid].last
				var count := clampi(int(params.get("count", 16)), 1, 16)
				var start := clampi(int(params.get("start", 0)), 0, maxi(0, int(last.get("token_count", 1)) - 1))
				result = {"matrix":attention(int(last.get("token_count", 1)), int(params.get("head_index", 0)), start, count),"start":start}
			"vocabulary_page": result = vocabulary_page(str(params.get("query", "")), int(params.get("offset", 0)), int(params.get("limit", 50)))
			"train": result = {"event":"completed","progress":1.0,"example_count":params.get("example_count", 0),"weights_written":false}
			"cancel":
				var target := int(params.get("target_request_id", -1))
				_cancelled[target] = true
				for session in sessions.keys():
					if sessions[session].get("open_request_id",-2)==target: sessions.erase(session)
				result = {"cancelled":true}
			"close_session":
				sessions.erase(sid)
				result = {"closed":true}
			_: error = _error("unsupported_method", "Unknown language method: " + method)
	var response := {"schema_version":1,"request_id":request.get("request_id", 0),"session_id":request.get("session_id", ""),"graph_revision":request.get("graph_revision", 0),"provider_id":"dummy-v1","is_dummy":true,"ok":error == null,"result":result if error == null else null,"error":error}
	_deliver.call_deferred(response)

func _deliver(response: Dictionary) -> void:
	if _cancelled.has(response.request_id):
		_cancelled.erase(response.request_id)
		return
	if not _disposed: response_ready.emit(response)

func dispose() -> void:
	_disposed = true
	sessions.clear()
	_cancelled.clear()

func _error(code: String, message: String) -> Dictionary:
	return {"code":code,"message":message,"node_id":""}

func _valid_ids(ids: Array) -> bool:
	for id in ids:
		if not id is int or id < 0 or id >= vocab_size: return false
	return true

const BASE_SYMBOLS := [
	"[pad]", "[bos]", "[end]", ".", ",", "!", "?", ":", ";", "-", "'", "\"", "(", ")", "[", "]",
]
const READABLE_PIECES := [
	"a", "b", "c", "d", "e", "f", "g", "h", "i", "j", "k", "l", "m",
	"n", "o", "p", "q", "r", "s", "t", "u", "v", "w", "x", "y", "z",
	"A", "B", "C", "D", "E", "F", "G", "H", "I", "J", "K", "L", "M",
	"N", "O", "P", "Q", "R", "S", "T", "U", "V", "W", "X", "Y", "Z",
	"а", "б", "в", "г", "д", "е", "ё", "ж", "з", "и", "й", "к", "л", "м",
	"н", "о", "п", "р", "с", "т", "у", "ф", "х", "ц", "ч", "ш", "щ", "ъ", "ы", "ь", "э", "ю", "я",
	"А", "Б", "В", "Г", "Д", "Е", "Ж", "З", "И", "Й", "К", "Л", "М",
	"Н", "О", "П", "Р", "С", "Т", "У", "Ф", "Х", "Ц", "Ч", "Ш", "Щ", "Э", "Ю", "Я",
	"/", "+", "=", "*", "&", "%", "$", "#", "@", "_", "~", "<", ">",
	"ing", "ed", "er", "es", "ly", "tion", "ment", "ness", "able", "ful", "less", "ous", "ive",
	"re", "un", "in", "im", "dis", "en", "non", "pre", "pro", "sub", "inter", "trans", "super",
	"th", "he", "an", "nd", "ha", "at", "ou", "ea", "hi", "is", "or", "ti", "as", "te", "et",
	"ng", "of", "al", "de", "se", "le", "sa", "si", "ar", "ve", "ra", "ld", "ur", "st", "ch", "sh", "wh",
	"and", "for", "are", "but", "not", "you", "all", "any", "can", "had", "her", "was", "one", "our", "out",
	"day", "get", "has", "him", "his", "how", "man", "new", "now", "old", "see", "two", "way", "who", "boy",
	"did", "its", "let", "put", "say", "she", "too", "use", "dog", "bird", "fish", "tree", "book", "word",
	"time", "year", "work", "life", "hand", "part", "child", "eye", "place", "week", "case", "point", "world",
	"house", "water", "light", "night", "sound", "voice", "music", "color", "paper", "table", "chair", "window",
	"model", "layer", "graph", "node", "token", "text", "data", "train", "input", "output", "class", "score",
	"ст", "но", "то", "на", "ен", "ов", "ни", "ра", "во", "ко", "со", "по", "пе", "ри", "ли", "не",
	"пр", "ор", "ро", "па", "ка", "ла", "ма", "та", "да", "ва", "за", "ве", "де", "ме", "ре", "се",
	"те", "бе", "ге", "же", "ке", "ле", "че", "ше", "ще", "ть", "ся", "ый", "ий", "ая", "ое", "ые",
	"дом", "кот", "сад", "лес", "мир", "свет", "день", "ночь", "вода", "окно", "стол", "стул", "книга",
	"слово", "текст", "сеть", "слой", "токен", "ответ", "класс", "число", "буква", "звук", "цвет", "форма",
]
const SYLLABLES_A := [
	"ba", "be", "bi", "bo", "bu", "ca", "ce", "ci", "co", "cu", "da", "de", "di", "do", "du",
	"fa", "fe", "fi", "fo", "fu", "ga", "ge", "gi", "go", "gu", "ka", "ke", "ki", "ko", "ku",
	"la", "le", "li", "lo", "lu", "ma", "me", "mi", "mo", "mu", "na", "ne", "ni", "no", "nu",
	"pa", "pe", "pi", "po", "pu", "ra", "re", "ri", "ro", "ru", "sa", "se", "si", "so", "su",
	"ta", "te", "ti", "to", "tu", "va", "ve", "vi", "vo", "vu", "za", "ze", "zi", "zo", "zu",
]
const SYLLABLES_B := [
	"l", "n", "r", "s", "t", "m", "d", "k", "p", "v", "z", "ck", "nd", "nt", "st", "rt", "rk", "lm",
	"ln", "rm", "rn", "sp", "sk", "ft", "lt", "mp", "nk", "lp", "ld", "ct", "pt", "xt",
]

func _generated_piece(id: int) -> String:
	if id >= 0 and id < BASE_SYMBOLS.size():
		return BASE_SYMBOLS[id]
	if id >= 16 and id < 16 + PIECES.size():
		return PIECES[id - 16]
	var idx := id - 28 if id < 256 else id - 512 + 228
	if idx >= 0 and idx < READABLE_PIECES.size():
		return READABLE_PIECES[idx]
	var comb := maxi(0, idx - READABLE_PIECES.size())
	var a: String = SYLLABLES_A[comb % SYLLABLES_A.size()]
	var b: String = SYLLABLES_B[(comb / SYLLABLES_A.size()) % SYLLABLES_B.size()]
	var c_idx := comb / (SYLLABLES_A.size() * SYLLABLES_B.size())
	if c_idx <= 0:
		return a + b
	var c: String = SYLLABLES_A[c_idx % SYLLABLES_A.size()]
	return a + b + c

func piece(id: int) -> String:
	if id == 2: return "[end]"
	if id >= 16 and id < 16 + PIECES.size(): return PIECES[id - 16]
	if id >= 256 and id < 512: return _byte_pieces[id - 256]
	return _generated_piece(id)

func vocab_piece(id: int) -> String:
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
	return piece(id)

func tokenize(text: String) -> Dictionary:
	if text == _last_tok_text and vocab_size == _last_tok_vocab and not _last_tok_result.is_empty():
		return _last_tok_result
	var tokens: Array = []
	var ids: Array = []
	var pos := 0
	var text_len := text.length()
	while pos < text_len:
		var code := text.unicode_at(pos)
		var matched := -1
		var length := 0
		for i in PIECES.size():
			var p_str: String = PIECES[i]
			var p_len: int = p_str.length()
			if p_len > length and pos + p_len <= text_len and text.substr(pos, p_len) == p_str:
				matched = 16 + i
				length = p_len
		if matched >= 0:
			ids.append(matched)
			tokens.append({"id":matched,"piece":PIECES[matched - 16],"start":pos,"end":pos+length,"position":tokens.size()})
			pos += length
		elif code < 0x80:
			var tok_id := 256 + code
			ids.append(tok_id)
			tokens.append({"id":tok_id,"piece":_byte_pieces[code],"start":pos,"end":pos+1,"position":tokens.size()})
			pos += 1
		elif code < 0x800:
			var b0 := 0xC0 | (code >> 6)
			var b1 := 0x80 | (code & 0x3F)
			var id0 := 256 + b0
			var id1 := 256 + b1
			var idx := tokens.size()
			ids.append(id0)
			ids.append(id1)
			tokens.append({"id":id0,"piece":_byte_pieces[b0],"start":pos,"end":pos+1,"position":idx})
			tokens.append({"id":id1,"piece":_byte_pieces[b1],"start":pos,"end":pos+1,"position":idx + 1})
			pos += 1
		else:
			for byte in text.substr(pos,1).to_utf8_buffer():
				var tok_id := 256 + byte
				ids.append(tok_id)
				tokens.append({"id":tok_id,"piece":_byte_pieces[byte],"start":pos,"end":pos+1,"position":tokens.size()})
			pos += 1
	var res := {"text":text,"tokens":tokens,"ids":ids,"vocabulary_id":"dummy-v1-%d" % vocab_size}
	_last_tok_text = text
	_last_tok_vocab = vocab_size
	_last_tok_result = res
	return res

func decode(ids: Array) -> String:
	var bytes := PackedByteArray()
	for id in ids:
		if id >= 256 and id < 512: bytes.append(id - 256)
		elif id != 2: bytes.append_array(piece(id).to_utf8_buffer())
	return bytes.get_string_from_utf8()

func vocabulary_page(query: String, offset: int, limit: int) -> Dictionary:
	var entries: Array = []
	var count := 0
	var q := query.strip_edges().to_lower()
	for id in vocab_size:
		if id >= 256 and id < 512 and q != str(id):
			continue
		var sym := vocab_piece(id)
		if q != "" and not q in sym.to_lower() and q != str(id): continue
		if count >= maxi(0,offset) and entries.size() < clampi(limit,1,50): entries.append({"id":id,"piece":sym})
		count += 1
	return {"entries":entries,"total":count,"offset":maxi(0,offset)}

var _att_prefix_cache: Dictionary = {}
var _zero_row: Array = []

func attention(count: int, head: int, start: int = 0, limit: int = -1) -> Array:
	var actual_limit := count if limit < 0 else limit
	var end_idx := mini(count, start + actual_limit)
	var row_len := maxi(0, end_idx - start)
	if _zero_row.size() < row_len:
		_zero_row.resize(maxi(512, row_len))
		_zero_row.fill(0.0)
	var rows: Array = []
	rows.resize(row_len)
	var h2 := head + 2
	var h7 := head * 7
	var head_cache: Dictionary = {}
	if start == 0:
		if not _att_prefix_cache.has(head):
			_att_prefix_cache[head] = {}
		head_cache = _att_prefix_cache[head]
	var w_mod := PackedFloat64Array()
	w_mod.resize(13)
	for idx in row_len:
		var i := start + idx
		var max_col := mini(end_idx, i + 1) - start
		var prefix: Array
		if start == 0 and head_cache.has(i):
			prefix = head_cache[i]
			if prefix.size() > max_col:
				prefix = prefix.slice(0, max_col)
		else:
			var a := (i + 1) * h2
			var period_sum := 0.0
			for m in 13:
				var w := 1.0 + float((a * m + h7) % 13)
				w_mod[m] = w
				period_sum += w
			var total_j := i + 1
			var full_periods := total_j / 13
			var rem := total_j % 13
			var mass := float(full_periods) * period_sum
			var m_idx := 3
			for _r in rem:
				mass += w_mod[m_idx]
				m_idx += 1
				if m_idx == 13: m_idx = 0
			var inv_mass := 1.0 / mass
			var p13: Array = []
			p13.resize(13)
			var cm := (start + 3) % 13
			for c in 13:
				p13[c] = w_mod[cm] * inv_mass
				cm += 1
				if cm == 13: cm = 0
			if max_col <= 13:
				prefix = p13.slice(0, max_col)
			else:
				var p52 := p13 + p13 + p13 + p13
				if max_col <= 52:
					prefix = p52.slice(0, max_col)
				else:
					var p208 := p52 + p52 + p52 + p52
					if max_col <= 208:
						prefix = p208.slice(0, max_col)
					else:
						var p624 := p208 + p208 + p208
						prefix = p624.slice(0, max_col)
			if start == 0 and max_col == i + 1:
				head_cache[i] = prefix
		var pad := row_len - max_col
		if pad <= 0:
			rows[idx] = prefix.duplicate()
		else:
			rows[idx] = prefix + _zero_row.slice(0, pad)
	return rows

func _point_template(id: int) -> Dictionary:
	if _point_cache.has(id):
		return _point_cache[id]
	var components: Array = []
	components.resize(8)
	for j in 8:
		components[j] = sin(float((id + 1) * (j + 1))) * 0.3
	var tpl := {
		"vector": components,
		"id": id,
		"piece": piece(id).strip_edges(),
		"x": sin(float(id) * 1.37),
		"y": cos(float(id) * 0.73),
		"z": sin(float(id) * 0.51 + 0.8)
	}
	_point_cache[id] = tpl
	return tpl

func preview(prefix: Array, generated: Array, nodes: Array) -> Dictionary:
	var ids := prefix + generated
	var schedule := [21,22,2]
	var selected: int = schedule[mini(generated.size(),2)]
	var best: Array = [selected]
	for candidate in [23,24,25,26,21]:
		if not best.has(candidate) and best.size() < 5: best.append(candidate)
	var scores: Array = []
	scores.resize(vocab_size)
	scores.fill(0.17 / float(vocab_size-5))
	for i in 5: scores[best[i]] = [0.42,0.18,0.12,0.07,0.04][i]
	var labels: Dictionary = {}
	for id in best: labels[str(id)] = piece(id)
	var n_ids := ids.size()
	var n_prefix := prefix.size()
	var vis_count := n_prefix if n_prefix > 0 else n_ids
	var point_source: Array = prefix if n_prefix > 0 else ids
	var points: Array = []
	points.resize(vis_count)
	for i in vis_count:
		var tpl := _point_template(int(point_source[i]))
		points[i] = {
			"vector": tpl.vector,
			"id": tpl.id,
			"position": i,
			"piece": tpl.piece,
			"x": tpl.x,
			"y": tpl.y,
			"z": tpl.z
		}
	var input_text := decode(prefix)
	var input_tokens: Array = tokenize(input_text).tokens
	var source_text := input_text if n_prefix > 0 else decode(ids)
	var token_list: Array = input_tokens if n_prefix > 0 else tokenize(source_text).tokens
	var base_vector: Array = []
	if not ids.is_empty():
		for j in 16: base_vector.append(sin(float((ids[0]+1)*(j+1)))*0.3)
	var traces: Dictionary = {}
	for node in nodes:
		var config: Dictionary = node.get("config", {})
		var op := str(node.op)
		var mat: Array = attention(vis_count,int(config.get("head_index",0))) if op=="attention_head" else []
		var data := {"source_text":source_text,"tokens":token_list,"points":points,"basis_id":"dummy-fixed","z_range":[-1.0,1.0],"width":int(MODEL_WIDTH/HEAD_COUNT) if op=="attention_head" else MODEL_WIDTH,"scores":scores,"labels":labels,"selected_id":selected,"matrix":mat,"head_index":config.get("head_index",0),"start":0,"total":vis_count,"vector":base_vector}
		traces[str(node.id)] = {"kind":op,"input_shape":node.get("input_shape",[]),"output_shape":node.get("output_shape",[]),"preview":data}
		for key in ["input_type","output_type","input_dtype","output_dtype"]:
			if node.has(key): traces[str(node.id)][key]=node[key]
	return {"scores":scores,"vocab_size":vocab_size,"labels":labels,"selected_id":selected,"next_token_id":selected,"generated_ids":generated + ([selected] if selected != 2 else []),"decoded_text":decode(generated + ([selected] if selected != 2 else [])),"finished":selected == 2,"stop_reason":"eos" if selected == 2 else "","token_count":n_ids,"nodes":traces}
