extends Control
class_name DynamicGraphUnit

@export var for_conn_size: Vector2 = Vector2()
@export var connections: Array[Connection] = []
@export var weight_lerp_speed: float = 12.0
@export var weight_snap_epsilon: float = 0.001
@export var weight_actual_path: NodePath = NodePath("actual")
@export var weight_backline_path: NodePath = NodePath("backline")
@export var weight_label_path: NodePath = NodePath("Label2")

var id: int = 0
var connect_position: float = 0.0
var low = {"edit_graph": true}
var _target_weight: float = 0.0
var _visual_weight: float = 0.0
var _weight_initialized: bool = false


func _get_weight_actual() -> Line2D:
	return get_node_or_null(weight_actual_path) as Line2D


func _get_weight_backline() -> Line2D:
	return get_node_or_null(weight_backline_path) as Line2D


func _get_weight_label() -> Label:
	return get_node_or_null(weight_label_path) as Label


func _has_weight_bar() -> bool:
	return _get_weight_actual() != null and _get_weight_backline() != null


func _ensure_weight_initialized() -> void:
	if _weight_initialized:
		return
	_visual_weight = 0.0
	_target_weight = 0.0
	_weight_initialized = true
	if _has_weight_bar():
		_apply_weight(_visual_weight)


func _apply_weight(weight: float) -> void:
	var actual := _get_weight_actual()
	var backline := _get_weight_backline()
	if actual == null or backline == null:
		return
	var points: PackedVector2Array = actual.points
	var back_points: PackedVector2Array = backline.points
	if points.size() < 2 or back_points.size() < 2:
		return
	points[1] = Vector2(lerpf(back_points[0].x, back_points[1].x, clampf(weight, 0.0, 1.0)), points[0].y)
	actual.points = points


func _request_weight_frame() -> void:
	var owner := get_parent()
	if owner and owner.has_method("hold_for_frame"):
		owner.hold_for_frame()


func _ready() -> void:
	_ensure_weight_initialized()


func set_weight(weight: float, text: String):
	_ensure_weight_initialized()
	_target_weight = clampf(weight, 0.0, 1.0)
	var label := _get_weight_label()
	if label != null:
		label.text = text
	if not _has_weight_bar():
		_visual_weight = _target_weight
		return
	if weight_lerp_speed <= 0.0:
		_visual_weight = _target_weight
		_apply_weight(_visual_weight)
	elif absf(_visual_weight - _target_weight) > weight_snap_epsilon:
		_request_weight_frame()

func _process(delta: float) -> void:
	if _weight_initialized and _has_weight_bar() and absf(_visual_weight - _target_weight) > weight_snap_epsilon:
		_visual_weight = lerpf(_visual_weight, _target_weight, clampf(delta * weight_lerp_speed, 0.0, 1.0))
		if absf(_visual_weight - _target_weight) <= weight_snap_epsilon:
			_visual_weight = _target_weight
		_apply_weight(_visual_weight)
		if absf(_visual_weight - _target_weight) > weight_snap_epsilon:
			_request_weight_frame()

	var loc = get_local_mouse_position()
	var inside: bool = Rect2(0,0,size.x,size.y).has_point(loc)
	#(inside)
	#if graphs.conns_active.has($o) or Rect2(0,0,for_conn_size.x,for_conn_size.y).has_point(loc):
	#	$o.process_mode = Node.PROCESS_MODE_INHERIT
	#	get_parent().hold_for_frame()
	#else:
	#	$o.process_mode = Node.PROCESS_MODE_DISABLED
	if not (get_parent() and get_parent().get("disable_unit_delete")):
		if inside:
			glob.set_menu_type(self, &"delete_i", low)
			if glob.mouse_alt_just_pressed:
				glob.menus[&"delete_i"].show_up($Label.text, get_parent().remove_unit.bind(id))
		else:
			glob.reset_menu_type(self, &"delete_i")
