extends PanelContainer
class_name NodePaletteItem

const NodePaletteCatalog = preload("res://scripts/node_palette_catalog.gd")

signal drag_started(type_id: StringName)
signal drag_finished

var type_id: StringName = StringName()
var _title := ""
var _preview_texture: Texture2D = null
var _hovered := false
var _dragging := false

@export var hover_scale := 1.04
@export var hover_lerp_speed := 14.0


func _ready() -> void:
	mouse_entered.connect(set_hovered.bind(true))
	mouse_exited.connect(set_hovered.bind(false))
	resized.connect(_sync_pivot)
	_sync_pivot()
	set_process(false)


func setup(entry: Dictionary) -> void:
	type_id = StringName(entry.get("type_id", ""))
	_title = str(entry.get("title", type_id))
	var fallback_color: Color = entry.get("outline_color", Color("6aa7ff"))

	var preview: TextureRect = get_node("Margin/Preview")
	var fallback: ColorRect = get_node("Margin/Fallback")
	var fallback_label: Label = get_node("Margin/Fallback/Label")
	tooltip_text = _title

	var path := str(entry.get("icon_path", ""))
	var resource_exists := false
	if not path.is_empty():
		if ResourceLoader.exists(path):
			resource_exists = true
		elif FileAccess.file_exists(path + ".import"):
			resource_exists = true
		elif FileAccess.file_exists(path + ".remap"):
			resource_exists = true

	if resource_exists:
		_preview_texture = load(path) as Texture2D
	else:
		_preview_texture = null

	preview.texture = _preview_texture
	preview.visible = _preview_texture != null
	fallback.visible = _preview_texture == null
	fallback.color = fallback_color.darkened(0.78)
	fallback_label.text = _title


## Pixel design dock: a small preview with the node name under it.
func set_compact() -> void:
	custom_minimum_size = Vector2(98, 112)
	var margin: MarginContainer = get_node("Margin")
	margin.add_theme_constant_override(&"margin_left", 4)
	margin.add_theme_constant_override(&"margin_right", 4)
	margin.add_theme_constant_override(&"margin_top", 2)
	margin.add_theme_constant_override(&"margin_bottom", 40)
	(get_node("Margin/Preview") as Control).custom_minimum_size = Vector2(0, 68)
	var caption := Label.new()
	caption.text = _title
	caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	caption.size_flags_vertical = Control.SIZE_SHRINK_END
	caption.custom_minimum_size = Vector2(94, 0)
	caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	# Long glued names («ГоловаВнимания») break inside the word rather than vanish.
	caption.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	caption.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	caption.max_lines_visible = 2
	caption.add_theme_font_size_override(&"font_size", 13)
	add_child(caption)


func set_hovered(value: bool) -> void:
	_hovered = value
	set_process(true)


func _process(delta: float) -> void:
	var target_scale := Vector2.ONE * (hover_scale if _hovered and not _dragging else 1.0)
	var weight := 1.0 - exp(-hover_lerp_speed * delta)
	scale = scale.lerp(target_scale, weight)
	if scale.distance_to(target_scale) < 0.001:
		scale = target_scale
		set_process(false)


func _sync_pivot() -> void:
	pivot_offset = size * 0.5


func _get_drag_data(_at_position: Vector2) -> Variant:
	if type_id.is_empty():
		return null
	_dragging = true
	set_hovered(false)
	drag_started.emit(type_id)
	set_drag_preview(_build_drag_preview())
	return NodePaletteCatalog.drag_payload(type_id)


func _notification(what: int) -> void:
	if what == NOTIFICATION_DRAG_END:
		_dragging = false
		_hovered = get_global_rect().has_point(get_global_mouse_position())
		set_process(true)
		drag_finished.emit()


func _build_drag_preview() -> Control:
	if _preview_texture != null:
		var a = Control.new()
		var texture := TextureRect.new()
		texture.custom_minimum_size = Vector2(180, 116)
		texture.texture = _preview_texture
	#	texture.set_anchors_preset(Control.PRESE)
		texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		texture.mouse_filter = Control.MOUSE_FILTER_IGNORE
		a.add_child(texture)
		print(texture.size)
		texture.position = -Vector2(180, 116) / 2
		print(texture.position)
		return a

	var label := Label.new()
	label.custom_minimum_size = Vector2(180, 72)
	label.text = _title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label
