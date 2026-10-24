extends Control
const S = preload("res://scripts/language_models/language_style.gd")
const Layout = preload("res://scripts/language_models/language_layout.gd")
var rows: Array[Control] = []
var other_mass := 0.0
var count := 5
var scores: Array = []
var labels: Dictionary = {}
var selected_id := -1
var token_ids: Array = []

class CandidateRow extends Control:
	var token_id := -1
	var piece := ""
	var probability := 0.0
	var selected := false
	var background: Control
	func _ready() -> void:
		background=S.button("",Callable())
		background.base_size=size
		background.custom_minimum_size=Vector2.ZERO
		background.show_behind_parent=true
		background.mouse_filter=Control.MOUSE_FILTER_IGNORE
		add_child(background)
		background.freeze_input()
		background.set_process(false)
		background.set_instance_shader_parameter("outline_color",Color(S.ACCENT,0.18))
		background.set_instance_shader_parameter("tuning",Color(0.12,0.14,0.23,0.24))
		resized.connect(func(): background.size=size; background.base_size=size)
	func _draw() -> void:
		var name := piece.strip_edges()
		if name.length()>18: name = name.left(17)+"…"
		draw_string(S.FONT,Vector2(7,12),name,HORIZONTAL_ALIGNMENT_LEFT,size.x-55,10,S.INK)
		draw_string(S.FONT,Vector2(size.x-43,12),"%.1f%%" % (probability*100),HORIZONTAL_ALIGNMENT_RIGHT,36,9,S.ACCENT if selected else S.MUTED)
		draw_line(Vector2(7,19),Vector2(size.x-7,19),Color(S.MUTED,0.2),2,true)
		draw_line(Vector2(7,19),Vector2(7+(size.x-14)*probability,19),S.ACCENT,2,true)

func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_layout_rows)

func set_distribution(values: Array, selected_token_id: int, token_labels: Dictionary) -> void:
	token_ids=[]
	scores = values
	selected_id = selected_token_id
	labels = token_labels
	_refresh()

func set_candidates(candidates: Array, selected_token_id: int) -> void:
	token_ids=[]; scores=[]; labels={}; selected_id=selected_token_id
	for candidate in candidates:
		token_ids.append(int(candidate.id))
		scores.append(float(candidate.probability))
		labels[str(candidate.id)]=str(candidate.piece)
	_refresh()

func set_visible_count(value: int) -> void:
	count = value if value in [5,10,20] else 5
	_refresh()

func clear_preview() -> void:
	scores = []
	_refresh()

func _layout_rows() -> void:
	for row in rows:
		row.size.x=maxf(size.x,1)
		row.queue_redraw()

func _refresh() -> void:
	var top: Array = []
	var total := 0.0
	for id in scores.size():
		var value: float = scores[id]
		total += value
		if top.size() >= count and value <= scores[top[-1]]: continue
		var at := 0
		while at < top.size() and (scores[top[at]] > value or (scores[top[at]] == value and top[at] < id)): at += 1
		top.insert(at,id)
		if top.size() > count: top.pop_back()
	while rows.size() > top.size():
		var row = rows.pop_back(); remove_child(row); row.free()
	while rows.size() < top.size():
		var row := CandidateRow.new(); row.modulate.a=0.0; rows.append(row); add_child(row)
	other_mass = total if token_ids.is_empty() else 1.0
	for i in top.size():
		var row = rows[i]
		row.position = Vector2(0,i*(24+Layout.row_gap()))
		row.size = Vector2(maxf(size.x,180),24)
		row.token_id = top[i] if token_ids.is_empty() else token_ids[top[i]]
		row.probability = scores[top[i]]
		row.piece = str(labels.get(str(row.token_id),"token_%d" % row.token_id))
		row.selected = row.token_id == selected_id
		row.tooltip_text = "#%d · %s" % [row.token_id,row.piece]
		other_mass -= row.probability
		row.queue_redraw()
	custom_minimum_size.y = maxf(0,top.size()*(24+Layout.row_gap())-Layout.row_gap())
	queue_redraw()

func advance_reveal(delta: float, available: Vector2) -> void:
	for row in rows:
		if row.position.y+row.size.y<=available.y:
			row.modulate.a=lerpf(row.modulate.a,1.0,minf(1,delta*15))

func is_revealing() -> bool:
	for row in rows:
		if row.modulate.a<0.995: return true
	return false
