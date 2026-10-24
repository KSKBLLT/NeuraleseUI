class_name RobotCard
extends BlockComponent
## One robot of the robot window, drawn like a ready-made project card
## (builtin_project_card.gd, whose structure and styling this follows): a
## picture, the name, what it is, small tags, and a button-like badge.

signal chosen(robot_id: String)

const NEAR_M := 1.5

@onready var surface: ColorRect = $Surface
@onready var preview: TextureRect = $Surface/Margin/Row/PreviewFrame/PreviewMargin/PreviewStack/Preview
@onready var art: Control = $Surface/Margin/Row/PreviewFrame/PreviewMargin/PreviewStack/Art
@onready var preview_frame: PanelContainer = $Surface/Margin/Row/PreviewFrame
@onready var title_label: Label = $Surface/Margin/Row/Info/Title
@onready var description_label: RichTextLabel = $Surface/Margin/Row/Info/Description
@onready var tags: HFlowContainer = $Surface/Margin/Row/Info/Tags
@onready var open_badge: PanelContainer = $Surface/Margin/Row/Info/OpenRow/OpenBadge
@onready var open_label: Label = $Surface/Margin/Row/Info/OpenRow/OpenBadge/OpenLabel

var robot: Dictionary = {}
var robot_id := ""
var _accent := RobotStyle.ACCENT
var _display_outline := RobotStyle.ACCENT
## "", "busy", "connected", "error"
var mode := ""
var stage_text := ""
var error_text := ""
var indexed_nodes: Array[CanvasItem] = []


func configure(value: Dictionary) -> void:
	robot = value
	robot_id = str(value.get("robot_id", ""))
	if is_node_ready():
		_apply()


func _ready() -> void:
	super()
	released.connect(_on_released)
	_apply()
	_init_extents_nodes()


func _init_extents_nodes() -> void:
	indexed_nodes.clear()
	if is_instance_valid(surface):
		indexed_nodes.append(surface)
	if is_instance_valid(preview_frame):
		preview_frame.material = preload("res://resources/card_alphamult.tres")
		indexed_nodes.append(preview_frame)
	if is_instance_valid(preview):
		preview.material = preload("res://resources/card_alphamult.tres")
		indexed_nodes.append(preview)
	if is_instance_valid(art):
		art.material = preload("res://resources/card_alphamult.tres")
		indexed_nodes.append(art)
	if is_instance_valid(title_label):
		title_label.material = preload("res://resources/card_alphamult.tres")
		indexed_nodes.append(title_label)
	if is_instance_valid(description_label):
		description_label.material = preload("res://resources/card_alphamult.tres")
		indexed_nodes.append(description_label)
	if is_instance_valid(open_badge):
		open_badge.material = preload("res://resources/card_alphamult.tres")
		indexed_nodes.append(open_badge)
	if is_instance_valid(open_label):
		open_label.material = preload("res://resources/card_alphamult.tres")
		indexed_nodes.append(open_label)


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


func _process(delta: float) -> void:
	super(delta)
	var target := _accent
	if mode == "error":
		target = RobotStyle.BAD
	elif mode == "connected":
		target = RobotStyle.OK
	if state.pressing:
		target = target.lightened(0.24)
	elif state.hovering:
		target = target.lightened(0.16)
	_display_outline = _display_outline.lerp(target, minf(1.0, delta * 12.0))
	surface.set_instance_shader_parameter("outline_color", _display_outline)


func set_mode(new_mode: String, text: String = "") -> void:
	mode = new_mode
	stage_text = text if new_mode == "busy" else ""
	error_text = text if new_mode == "error" else ""
	if is_node_ready():
		_apply()


func _apply() -> void:
	if robot.is_empty() or not is_node_ready():
		return
	title_label.text = str(robot.get("name", "Robot"))
	var platform := str(robot.get("platform", ""))
	var transport := str(robot.get("transport", ""))
	# The robot's kind as the window draws it (the same drawing as on its build screen).
	preview.texture = null
	art.platform = platform
	art.queue_redraw()
	art.show()
	_apply_frame_style()
	var model_key := "model_dummy"
	if platform == "ev3_direct" or platform == "ev3":
		model_key = "model_ev3"
	elif transport == "replay":
		model_key = "model_replay"
	match mode:
		"busy":
			description_label.text = stage_text
		"error":
			description_label.text = error_text
		_:
			var line := RobotText.t(model_key)
			description_label.text = line + " · " + RobotText.t("tag_bluetooth") if transport == "bluetooth" else line
	match mode:
		"busy":
			open_label.text = RobotText.t("stage_connecting")
		"connected":
			open_label.text = RobotText.t("use_this")
		_:
			open_label.text = RobotText.t("connect")
	var accent := _accent
	if mode == "error":
		accent = RobotStyle.BAD
	elif mode == "connected":
		accent = RobotStyle.OK
	open_badge.material = preload("res://resources/card_alphamult.tres")
	open_badge.add_theme_stylebox_override(
		"panel", RobotStyle.panel_style(accent, Color(accent.r, accent.g, accent.b, 0.10), 1, Vector2(16, 6))
	)
	_build_tags()
	tooltip_text = "%s — %s" % [title_label.text, RobotText.t(model_key)]


func _apply_frame_style() -> void:
	preview_frame.material = preload("res://resources/card_alphamult.tres")
	preview_frame.add_theme_stylebox_override(
		"panel", RobotStyle.panel_style(_accent, Color(0.05, 0.05, 0.08, 0.52), 1)
	)


## Only what helps to pick a robot: how far it is, when that was really
## measured, and a battery that is running out.
## How far the robot is: what tells two robots of the same kind apart. A low
## battery is said when connecting, not here.
func _build_tags() -> void:
	for child in tags.get_children():
		child.queue_free()
	if str(robot.get("transport", "")) == "bluetooth":
		tags.add_child(_distance_tag(robot.get("proximity")))


## Only a distance that was really measured is shown; an unknown one says so.
func _distance_tag(proximity: Variant) -> Label:
	var meters: Variant = null
	if proximity is Dictionary:
		meters = proximity.get("distance_m")
	if meters == null:
		var tag := RobotStyle.tag(RobotText.t("distance_unknown"), RobotStyle.DIM)
		tag.material = preload("res://resources/card_alphamult.tres")
		return tag
	var shown := "%.1f" % float(meters)
	var key := "distance_near" if float(meters) < NEAR_M else "distance_far"
	var tag := RobotStyle.tag(RobotText.tf(key, [shown]), _accent)
	tag.material = preload("res://resources/card_alphamult.tres")
	return tag


func _on_released() -> void:
	if mode == "busy" or robot_id.is_empty():
		return
	chosen.emit(robot_id)
