class_name BuiltinProjectCard
extends BlockComponent

signal open_requested(project_id: StringName)

const FALLBACK_TEXTURE := preload("res://neuralese.png")

@onready var surface: ColorRect = $Surface
@onready var preview: TextureRect = $Surface/Margin/Row/PreviewFrame/PreviewMargin/Preview
@onready var preview_frame: PanelContainer = $Surface/Margin/Row/PreviewFrame
@onready var emoji_label: Label = $Surface/Margin/Row/Info/Header/Emoji
@onready var title_label: Label = $Surface/Margin/Row/Info/Header/Title
@onready var description_label: RichTextLabel = $Surface/Margin/Row/Info/Description
@onready var tags: HFlowContainer = $Surface/Margin/Row/Info/Tags
@onready var open_badge: PanelContainer = $Surface/Margin/Row/Info/OpenRow/OpenBadge
@onready var open_label: Label = $Surface/Margin/Row/Info/OpenRow/OpenBadge/OpenLabel

var definition: Resource
var language := "ru"
var _accent := Color(0.49, 0.83, 0.61, 1.0)
var _subtle_outline := Color(0.49, 0.83, 0.61, 0.45)
var _display_outline := _subtle_outline
var indexed_nodes: Array[CanvasItem] = []


func configure(value: Resource, current_language: String) -> void:
	definition = value
	language = current_language
	if definition != null:
		hint = definition.id
		metadata["builtin_project_id"] = String(definition.id)
	if is_node_ready():
		_apply_definition()


func _ready() -> void:
	super()
	released.connect(_on_released)
	_apply_definition()
	_init_extents_nodes()


func _process(delta: float) -> void:
	super(delta)
	if definition == null:
		return
	var target := _subtle_outline
	if state.pressing:
		target = Color(_accent.r, _accent.g, _accent.b, 0.85)
	elif state.hovering:
		target = Color(_accent.r, _accent.g, _accent.b, 0.65)
	_display_outline = _display_outline.lerp(target, minf(1.0, delta * 12.0))
	surface.set_instance_shader_parameter("outline_color", _display_outline)


func _init_extents_nodes() -> void:
	indexed_nodes.clear()
	if is_instance_valid(surface):
		indexed_nodes.append(surface)
	if is_instance_valid(preview_frame):
		indexed_nodes.append(preview_frame)
	if is_instance_valid(preview):
		indexed_nodes.append(preview)
	if is_instance_valid(title_label):
		indexed_nodes.append(title_label)
	if is_instance_valid(description_label):
		indexed_nodes.append(description_label)
	if is_instance_valid(open_badge):
		indexed_nodes.append(open_badge)
	if is_instance_valid(open_label):
		indexed_nodes.append(open_label)
	if is_instance_valid(emoji_label):
		indexed_nodes.append(emoji_label)


func apply_extents(ext: Vector4) -> void:
	if indexed_nodes.is_empty():
		_init_extents_nodes()
	for node in indexed_nodes:
		if is_instance_valid(node):
			glob.inst_uniform(node, "extents", ext)
	if is_instance_valid(tags):
		for tag in tags.get_children():
			if tag is CanvasItem:
				glob.inst_uniform(tag, "extents", ext)


func _apply_definition() -> void:
	if definition == null or not is_node_ready():
		return
	_accent = definition.accent_color
	_subtle_outline = Color(_accent.r, _accent.g, _accent.b, 0.45)
	_display_outline = _subtle_outline
	surface.set_instance_shader_parameter("outline_color", _display_outline)
	preview.texture = definition.preview if definition.preview != null else FALLBACK_TEXTURE
	preview.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	emoji_label.text = definition.emoji
	title_label.text = definition.localized_title(language)
	description_label.text = definition.localized_description(language)
	open_label.text = _copy("Сделать копию  →", "Make a copy  →", "Көшірме жасау  →")
	_apply_accent_style(preview_frame, _accent, Color(0.05, 0.05, 0.08, 0.52), 1)
	_apply_accent_style(
		open_badge, _accent, Color(_accent.r, _accent.g, _accent.b, 0.12), 1, Vector2(14, 6)
	)
	_build_tags(definition.localized_tags(language))
	tooltip_text = "%s — %s" % [title_label.text, description_label.text]
	_init_extents_nodes()


func _build_tags(values: PackedStringArray) -> void:
	for child in tags.get_children():
		child.queue_free()
	for value in values:
		var tag := Label.new()
		tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tag.text = value
		tag.add_theme_font_size_override("font_size", 11)
		tag.add_theme_color_override("font_color", Color(0.86, 0.87, 0.91, 0.92))
		var style := StyleBoxFlat.new()
		style.bg_color = Color(_accent.r, _accent.g, _accent.b, 0.10)
		style.border_color = Color(_accent.r, _accent.g, _accent.b, 0.30)
		style.set_border_width_all(1)
		style.set_corner_radius_all(6)
		style.content_margin_left = 8
		style.content_margin_right = 8
		style.content_margin_top = 3
		style.content_margin_bottom = 3
		tag.add_theme_stylebox_override("normal", style)
		tag.material = preload("res://resources/card_alphamult.tres")
		tags.add_child(tag)


func _apply_accent_style(
	target: PanelContainer,
	accent: Color,
	background: Color,
	border_width: int,
	content_padding: Vector2 = Vector2.ZERO
) -> void:
	target.material = preload("res://resources/card_alphamult.tres")
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_color = Color(accent.r, accent.g, accent.b, 0.42)
	style.set_border_width_all(border_width)
	style.set_corner_radius_all(8)
	style.content_margin_left = content_padding.x
	style.content_margin_right = content_padding.x
	style.content_margin_top = content_padding.y
	style.content_margin_bottom = content_padding.y
	target.add_theme_stylebox_override("panel", style)


func _on_released() -> void:
	if definition != null:
		open_requested.emit(definition.id)


func _copy(ru: String, en: String, kz: String) -> String:
	match language:
		"en": return en
		"kz": return kz
		_: return ru
