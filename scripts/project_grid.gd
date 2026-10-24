class_name ProjectGrid
extends GridVisualiser

signal project_open_requested(project_id: String)
signal project_delete_requested(project_id: String)

const CARD_SCENE = preload("res://scenes/project_card.tscn")
const ThumbnailStore = preload("res://scripts/project_thumbnail_store.gd")

var _generation := 0
var _preview_queue: Array[Dictionary] = []
var _loading_previews := false


func _ready() -> void:
	super()
	batch_size = 2
	if is_instance_valid(_loading_overlay):
		_loading_overlay.hide()


func set_projects(projects: Dictionary, current_project_id: String, language: String) -> void:
	_generation += 1
	var generation := _generation
	_preview_queue.clear()
	_recycle_cards()

	var ordered_ids: Array = projects.keys()
	ordered_ids.sort_custom(func(a, b):
		return float(projects[a].get("modified", 0.0)) > float(projects[b].get("modified", 0.0))
	)
	var created := 0
	for value in ordered_ids:
		if generation != _generation:
			return
		var project_id := str(value)
		var card := _get_project_card()
		add_child(card)
		_connect_card(card)
		card.configure(project_id, projects[value], project_id == current_project_id, language)
		card.show()
		_tile_index[project_id] = card
		var thumbnail_path := str(projects[value].get("thumbnail_path", ""))
		if not thumbnail_path.is_empty():
			_preview_queue.append({
				"generation": generation,
				"card": card,
				"path": thumbnail_path,
			})
		created += 1
		if created % batch_size == 0:
			await get_tree().process_frame

	if not _loading_previews and not _preview_queue.is_empty():
		_drain_preview_queue.call_deferred()
	refreshed.emit()


func _get_project_card() -> ProjectCard:
	if not _tile_pool.is_empty():
		return _tile_pool.pop_back() as ProjectCard
	return CARD_SCENE.instantiate() as ProjectCard


func _recycle_cards() -> void:
	_tile_index.clear()
	_clear_selection()
	for child in get_children():
		if child is ProjectCard:
			child.prepare_for_pool()
			_recycle_tile(child)


func _connect_card(card: ProjectCard) -> void:
	if not card.open_requested.is_connected(_on_card_open_requested):
		card.open_requested.connect(_on_card_open_requested)
	if not card.delete_requested.is_connected(_on_card_delete_requested):
		card.delete_requested.connect(_on_card_delete_requested)


func _drain_preview_queue() -> void:
	if _loading_previews:
		return
	_loading_previews = true
	while not _preview_queue.is_empty():
		var item: Dictionary = _preview_queue.pop_front()
		var texture: Texture2D = await ThumbnailStore.load_thumbnail_async(str(item["path"]))
		var card := item["card"] as ProjectCard
		if (
			int(item["generation"]) == _generation
			and is_instance_valid(card)
			and card.is_inside_tree()
		):
			card.set_preview(texture)
		await get_tree().process_frame
	_loading_previews = false


func _on_card_open_requested(project_id: String) -> void:
	project_open_requested.emit(project_id)


func _on_card_delete_requested(project_id: String) -> void:
	project_delete_requested.emit(project_id)
