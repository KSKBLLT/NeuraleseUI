extends HBoxContainer
## Pixel design: the Datasets tab as the Dataset Bento design (Claude Design,
## «Dataset Bento v9»). Left, the project's datasets. In the middle, the
## selected one: its size, rows that look like mistakes, what the network sees
## and does, a likeness map, situations of alike rows, and every row as a card
## (or the editable table under «Числа»). Right, one row up close.
## It sits over the tab's own list and table, which keep doing the real work:
## loading, saving, removing and restoring rows.

const UI := preload("res://scripts/ui/dataset_bento_ui.gd")
const Draw := preload("res://scripts/ui/dataset_bento_draw.gd")
const Analysis := preload("res://scripts/ui/dataset_bento_analysis.gd")
const Situations := preload("res://scripts/ui/dataset_bento_situations.gd")
const DatasetList := preload("res://scripts/ui/dataset_bento_list.gd")
const Preview := preload("res://scripts/ui/dataset_bento_preview.gd")
const Cards := preload("res://scripts/ui/dataset_bento_cards.gd")
const Words := preload("res://scripts/ui/dataset_bento_words.gd")

var _tab: Node
var _code: Control
var _list: Node
var _preview: Node
var cards: Control
var _center: Array[Control] = []

## The selected dataset, read once per load.
var data := {}
var analysis := {}
var _signature: Variant = null
var _lang := ""
var _task := -1
var _task_signature: Variant = null
var _task_result := {}
var _textures := {}

var cluster := -1
var mistakes_only := false
var numbers := false
var shown := PackedInt32Array()
var current := 0
var kept := {}
var deleted := 0
var _undo: Array = []


func _init(tab: Node) -> void:
	_tab = tab
	_code = tab.get_node("Control/CodeEdit")


func _ready() -> void:
	add_theme_constant_override(&"separation", 10)
	var left := UI.card(UI.CARD, 10.0)
	(left.get_theme_stylebox(&"panel") as StyleBoxFlat).content_margin_top = 14.0
	left.custom_minimum_size.x = 236
	_list = DatasetList.new()
	_list.chosen.connect(_choose)
	_list.create_pressed.connect(func(): _tab._on_plus_released())
	_list.delete_pressed.connect(_delete_dataset)
	left.add_child(_list)
	add_child(left)
	cards = Cards.new(self)
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	add_child(cards)
	var right := UI.card(UI.CARD, 12.0)
	(right.get_theme_stylebox(&"panel") as StyleBoxFlat).content_margin_top = 14.0
	right.custom_minimum_size.x = 280
	_preview = Preview.new()
	_preview.step.connect(func(delta: int): pick_row(current + delta))
	_preview.delete_pressed.connect(func(): if not shown.is_empty(): delete_rows(PackedInt32Array([shown[current]])))
	_preview.keep_pressed.connect(_keep)
	right.add_child(_preview)
	add_child(right)
	_center = [cards, right]


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var ds: Variant = _code.get(&"dataset_obj")
	var signature: Variant = null
	if ds is Dictionary and ds.has("name"):
		signature = [ds["name"], _rows().size()]
	var lang := str(glob.get_lang())
	if signature != _signature:
		var same_dataset: bool = signature != null and _signature != null and signature[0] == _signature[0]
		_signature = signature
		if signature != null:
			_load(ds, same_dataset)
		_list.refresh(str(ds.get("name", "")) if ds is Dictionary else "")
	elif lang != _lang:
		_list.refresh(str(data.get("name", "")))
		refresh()
	_lang = lang
	if _task >= 0 and WorkerThreadPool.is_task_completed(_task):
		WorkerThreadPool.wait_for_task_completion(_task)
		_task = -1
		if _task_signature == _signature:
			analysis = _task_result
			refresh()
		else:
			_analyse()


## ← and → step through the rows while the cards are shown.
func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or numbers or not event.is_pressed() or shown.is_empty():
		return
	if event.is_action_pressed(&"ui_left"):
		pick_row(current - 1)
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed(&"ui_right"):
		pick_row(current + 1)
		get_viewport().set_input_as_handled()


func has_dataset() -> bool:
	return not glob.ds_dump.is_empty()


## The tab's table is shown under «Числа», inside the rows card.
func wants_table() -> bool:
	return numbers and has_dataset()


func table_rect(space: Control) -> Rect2:
	var body: Control = cards.rows_body
	var origin := space.get_global_transform().affine_inverse() * body.global_position
	return Rect2(origin, body.size)


## The middle and right columns, where the empty state goes without datasets.
func content_rect(space: Control) -> Rect2:
	var origin := space.get_global_transform().affine_inverse() * cards.global_position
	return Rect2(origin, Vector2(size.x - (cards.position.x - position.x), size.y))


func _rows() -> Array:
	var rows: Variant = _code.get(&"adapter_data")
	if rows is Array:
		return rows
	var ds: Variant = _code.get(&"dataset_obj")
	return ds.get("arr", []) if ds is Dictionary else []


func _load(ds: Dictionary, same_dataset: bool) -> void:
	var names: Array = ds.get("col_names", [])
	var split: int = clampi(int(ds.get("outputs_from", names.size())), 0, names.size())
	var columns: Array[String] = []
	for column in names:
		columns.append(str(column).get_slice(":", 0))
	var rows := _rows()
	data = {
		"name": str(ds.get("name", "")),
		"columns": columns,
		"split": split,
		"image": names.slice(0, split).any(func(column): return str(column).ends_with(":image")),
		"car": Situations.car_columns(columns, range(split), range(split, names.size()), rows),
		"ranges": _ranges(rows, split),
	}
	_textures.clear()
	if not same_dataset:
		cluster = -1
		mistakes_only = false
		current = 0
		kept.clear()
		deleted = 0
		_undo.clear()
	analysis = {}
	_analyse()
	refresh()


func _ranges(rows: Array, split: int) -> Array:
	var ranges: Array = []
	for c in split:
		var low := INF
		var high := -INF
		for row in rows:
			if row is Array and row.size() > c:
				var value := Situations.cell_number(row[c])
				if not is_nan(value):
					low = minf(low, value)
					high = maxf(high, value)
		ranges.append(Vector2(low, high))
	return ranges


func _analyse() -> void:
	if _task >= 0 or _signature == null:
		return
	var ds: Dictionary = _code.dataset_obj
	var snapshot := {
		"col_names": ds.get("col_names", []).duplicate(),
		"outputs_from": ds.get("outputs_from", 0),
		"arr": _rows().duplicate(),
	}
	_task_signature = _signature
	_task = WorkerThreadPool.add_task(func(): _task_result = Analysis.analyze(snapshot))


## Rows the current filter shows: a situation, the mistakes, or all of them.
func _filtered() -> PackedInt32Array:
	var errors: Dictionary = analysis.get("errors", {})
	if mistakes_only:
		var rows := PackedInt32Array()
		for row in errors:
			if not kept.has(row):
				rows.append(row)
		rows.sort()
		return rows
	if cluster >= 0 and cluster < analysis.get("clusters", []).size():
		return analysis["clusters"][cluster]["members"]
	var all := PackedInt32Array()
	all.resize(_rows().size())
	for i in all.size():
		all[i] = i
	return all


func mistakes() -> PackedInt32Array:
	var rows := PackedInt32Array()
	for row in analysis.get("errors", {}):
		if not kept.has(row):
			rows.append(row)
	rows.sort()
	return rows


func refresh() -> void:
	var with_data := has_dataset()
	for part in _center:
		part.visible = with_data
	if not with_data or data.is_empty():
		return
	shown = _filtered()
	current = clampi(current, 0, maxi(0, shown.size() - 1))
	UI.retranslate(self)
	cards.show_dataset()
	_show_preview()


func pick_row(position_in_list: int) -> void:
	if shown.is_empty():
		return
	current = posmod(position_in_list, shown.size())
	cards.grid.current = current
	cards.grid.show_current()
	_show_preview()


func pick_cluster(index: int) -> void:
	cluster = -1 if cluster == index else index
	mistakes_only = false
	current = 0
	cards.grid.scroll = 0.0
	refresh()


func toggle_mistakes() -> void:
	mistakes_only = not mistakes_only
	cluster = -1
	current = 0
	cards.grid.scroll = 0.0
	refresh()


func clear_filter() -> void:
	cluster = -1
	mistakes_only = false
	current = 0
	refresh()


func set_numbers(value: bool) -> void:
	numbers = value
	refresh()


## Removes rows through the table, which saves the dataset; they can be undone.
func delete_rows(rows: PackedInt32Array) -> void:
	if rows.is_empty():
		return
	var sorted := rows.duplicate()
	sorted.sort()
	var table_rows := _rows()
	var batch: Array = []
	for row in sorted:
		batch.append([row, table_rows[row].duplicate(true)])
	for i in range(sorted.size() - 1, -1, -1):
		_code.remove_row(sorted[i])
	_undo.append(batch)
	deleted += sorted.size()
	_shift_analysis(sorted)
	_signature = [data["name"], _rows().size()]
	_textures.clear()
	refresh()


func undo() -> void:
	if _undo.is_empty():
		return
	for entry in _undo.pop_back():
		_code.add_row(entry[1], entry[0])
		deleted -= 1
	_after_restore()


func reset() -> void:
	while not _undo.is_empty():
		for entry in _undo.pop_back():
			_code.add_row(entry[1], entry[0])
	deleted = 0
	kept.clear()
	cluster = -1
	mistakes_only = false
	current = 0
	_after_restore()


func can_undo() -> bool:
	return not _undo.is_empty()


func _after_restore() -> void:
	_code.dirtify(null, true, false)
	cluster = -1
	mistakes_only = false
	# Restored rows have no place in the situations yet: look again.
	_signature = [data["name"], _rows().size()]
	_textures.clear()
	analysis = {}
	_analyse()
	refresh()


## Row numbers after `removed` (ascending) are gone: shift what the analysis knows.
func _shift_analysis(removed: PackedInt32Array) -> void:
	var gone := {}
	for row in removed:
		gone[row] = true
	var shift := func(row: int) -> int:
		return row - removed.bsearch(row)
	for group in analysis.get("clusters", []):
		var members := PackedInt32Array()
		for row in group["members"]:
			if not gone.has(row):
				members.append(shift.call(row))
		group["members"] = members
	var errors := {}
	var old_errors: Dictionary = analysis.get("errors", {})
	for row in old_errors:
		if not gone.has(row):
			errors[shift.call(row)] = old_errors[row]
	if not analysis.is_empty():
		analysis["errors"] = errors
		var point_rows: PackedInt32Array = analysis["point_rows"]
		for p in point_rows.size():
			point_rows[p] = -1 if gone.has(point_rows[p]) else shift.call(point_rows[p])
		analysis["point_rows"] = point_rows
	var still_kept := {}
	for row in kept:
		if not gone.has(row):
			still_kept[shift.call(row)] = true
	kept = still_kept


func _keep() -> void:
	if shown.is_empty():
		return
	var row := shown[current]
	if analysis.get("errors", {}).has(row) and not kept.has(row):
		kept[row] = true
		if mistakes_only:
			refresh()
			return
		cards.show_dataset()
	pick_row(current + 1)


func _choose(dataset_name: String) -> void:
	for button in _tab.list._contained:
		if is_instance_valid(button) and str(button.metadata.get("content", {}).get("name", "")) == dataset_name:
			numbers = false
			_tab._on_list_child_button_release(button)
			return


func _delete_dataset() -> void:
	_code.delete_myself()
	_tab.reload_scenes()


## What a card or the preview draws for a row: rays, an image or input bars.
func describe(row: int) -> Dictionary:
	var rows := _rows()
	if row < 0 or row >= rows.size() or not rows[row] is Array:
		return {}
	var cells: Array = rows[row]
	var car: Dictionary = data["car"]
	if not car.is_empty():
		var rays := PackedFloat32Array()
		for c in car["rays"]:
			rays.append(Situations.finite(Situations.cell_number(cells[c])) / maxf(car["ray_max"], 0.000001))
		var gas := 1.0 if car["throttle"] < 0 else Situations.finite(Situations.cell_number(cells[car["throttle"]]))
		return {"rays": rays, "steer": Situations.finite(Situations.cell_number(cells[car["steer"]])), "gas": gas}
	if data["image"]:
		if not _textures.has(row):
			var image := Situations.cell_image(cells[0])
			_textures[row] = ImageTexture.create_from_image(image) if image and not image.is_empty() else null
		return {"texture": _textures[row]} if _textures[row] else {}
	var bars := PackedFloat32Array()
	for c in mini(data["split"], 12):
		var value := Situations.cell_number(cells[c])
		var span: Vector2 = data["ranges"][c]
		bars.append(0.5 if is_nan(value) or span.y <= span.x else (value - span.x) / (span.y - span.x))
	return {"bars": bars}


func _show_preview() -> void:
	var info := {"total": UI.short(_rows().size()), "warn": str(_tab.get_node("Control/view/warn").text)}
	if shown.is_empty():
		_preview.show_row(info)
		return
	var row := shown[current]
	var image: bool = data["image"]
	info["title"] = "%s #%04d" % [UI.t("frame" if image else "row"), row]
	info["sub"] = "%s · %d %s %s" % [cards.selection_title(), current + 1, UI.t("of"), UI.group_digits(shown.size())]
	info["picture"] = describe(row)
	info["legend"] = "car" if not data["car"].is_empty() else ("" if image else "table")
	var facts: Array = Words.row_facts(self, row)
	info["see"] = facts[0]
	info["do"] = facts[1]
	info["why"] = Words.why(self, row)
	_preview.show_row(info)
