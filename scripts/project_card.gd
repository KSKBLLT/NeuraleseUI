class_name ProjectCard
extends PanelContainer

signal open_requested(project_id: String)
signal delete_requested(project_id: String)

const FALLBACK_TEXTURE = preload("res://neuralese.png")
const CURRENT_OUTLINE := Color(0.47, 0.84, 0.64, 1.0)
const DEFAULT_OUTLINE := Color(0.43, 0.59, 0.90, 0.72)
const HOVER_OUTLINE := Color(0.55, 0.70, 1.0, 0.95)

@onready var surface: ColorRect = $Surface
@onready var preview: TextureRect = $Surface/Margin/Content/Preview
@onready var title_label: Label = $Surface/Margin/Content/TitleRow/Title
@onready var delete_button: Button = $Surface/Margin/Content/TitleRow/Delete
@onready var current_label: Label = $Surface/Margin/Content/Current
@onready var modified_label: Label = $Surface/Margin/Content/Modified

var project_id := ""
var _is_current := false
var indexed_nodes: Array[CanvasItem] = []


func _ready() -> void:
	delete_button.pressed.connect(_on_delete_pressed)
	mouse_entered.connect(_set_hovered.bind(true))
	mouse_exited.connect(_set_hovered.bind(false))
	focus_entered.connect(_set_hovered.bind(true))
	focus_exited.connect(_set_hovered.bind(false))
	_init_extents_nodes()


func _init_extents_nodes() -> void:
	indexed_nodes.clear()
	if is_instance_valid(surface):
		indexed_nodes.append(surface)
	if is_instance_valid(preview):
		indexed_nodes.append(preview)
	if is_instance_valid(title_label):
		indexed_nodes.append(title_label)
	if is_instance_valid(delete_button):
		indexed_nodes.append(delete_button)
	if is_instance_valid(current_label):
		indexed_nodes.append(current_label)
	if is_instance_valid(modified_label):
		indexed_nodes.append(modified_label)


func apply_extents(ext: Vector4) -> void:
	if indexed_nodes.is_empty():
		_init_extents_nodes()
	for node in indexed_nodes:
		if is_instance_valid(node):
			# Same call as glob.inst_uniform, without the autoload: the gallery is
			# compiled by --script tests before autoloads exist.
			RenderingServer.canvas_item_set_instance_shader_parameter(node.get_canvas_item(), "extents", ext)


func configure(id: String, metadata: Dictionary, is_current: bool, language: String) -> void:
	project_id = id
	_is_current = is_current
	set_meta("key", id)
	set_meta("project_id", id)
	set_meta("meta", metadata)
	title_label.text = _project_name(metadata, language)
	current_label.text = _copy(language, "Открыт сейчас", "Open now", "Қазір ашық")
	modified_label.text = _modified_text(float(metadata.get("modified", 0.0)), language)
	current_label.visible = is_current
	modified_label.visible = not is_current
	delete_button.tooltip_text = _copy(language, "Удалить проект", "Delete project", "Жобаны жою")
	set_preview(null)
	_apply_outline()


func set_preview(texture: Texture2D) -> void:
	if texture == null:
		preview.texture = FALLBACK_TEXTURE
		preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		preview.self_modulate = Color(0.78, 0.82, 0.88, 0.42)
		return
	preview.texture = texture
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	preview.self_modulate = Color.WHITE


func prepare_for_pool() -> void:
	project_id = ""
	_is_current = false
	set_preview(null)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		open_requested.emit(project_id)
		accept_event()
	elif event is InputEventKey and event.pressed and event.keycode in [KEY_ENTER, KEY_SPACE]:
		open_requested.emit(project_id)
		accept_event()


func _on_delete_pressed() -> void:
	delete_requested.emit(project_id)


func _set_hovered(hovered: bool) -> void:
	if not is_instance_valid(surface):
		return
	surface.set_instance_shader_parameter(
		"outline_color",
		HOVER_OUTLINE if hovered and not _is_current else _base_outline()
	)


func _apply_outline() -> void:
	if is_instance_valid(surface):
		surface.set_instance_shader_parameter("outline_color", _base_outline())


func _base_outline() -> Color:
	return CURRENT_OUTLINE if _is_current else DEFAULT_OUTLINE


func _project_name(metadata: Dictionary, language: String) -> String:
	var value := str(metadata.get("name", "")).strip_edges()
	return value if not value.is_empty() else _copy(language, "Безымянный", "Untitled", "Атаусыз")


func _modified_text(timestamp: float, language: String) -> String:
	if timestamp <= 0.0:
		return _copy(
			language,
			"Дата изменения неизвестна",
			"Modification date unavailable",
			"Өзгертілген күні белгісіз"
		)
	var date := Time.get_datetime_dict_from_unix_time(int(timestamp))
	var formatted := "%02d.%02d.%04d · %02d:%02d" % [date.day, date.month, date.year, date.hour, date.minute]
	return "%s %s" % [_copy(language, "Изменён", "Modified", "Өзгертілді"), formatted]


func _copy(language: String, ru: String, en: String, kz: String) -> String:
	match language:
		"en": return en
		"kz": return kz
		_: return ru
