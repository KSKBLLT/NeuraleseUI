class_name RobotGrid
extends GridVisualiser
## The robots as a grid of cards, updated in place.
##
## Built on GridVisualiser (the project's grid base: a GridContainer with a
## key-to-tile index). Its generic tile is an icon with a caption, too small for
## a robot, so each tile here holds a RobotCard instead (the card of a
## ready-made project, see robot_card.gd). Robots are keyed by ``robot_id``: a
## new scan updates the card that is already there (distance, battery) instead
## of rebuilding the grid under the child's pointer.

signal robot_chosen(robot_id: String)

const CARD_SCENE := preload("res://scenes/robot_card.tscn")
const CARD_SIZE := Vector2(410, 204)
const GAP := 14

var _cards: Dictionary = {}   # robot_id -> RobotCard


func _ready() -> void:
	super()
	columns = 2
	add_theme_constant_override("h_separation", GAP)
	add_theme_constant_override("v_separation", GAP)


## Shows exactly these robots, in this order.
func set_robots(robots: Array) -> void:
	var wanted := {}
	for robot in robots:
		wanted[str(robot.get("robot_id", ""))] = true
	for robot_id in _cards.keys():
		if not wanted.has(robot_id):
			_remove(robot_id)
	var order := 0
	for robot in robots:
		var card := _upsert(robot)
		if card.get_parent() != null:
			# The card moves itself into wrapper nodes: order the outermost one.
			var holder: Node = card
			while holder.get_parent() != self and holder.get_parent() != null:
				holder = holder.get_parent()
			if holder.get_parent() == self:
				move_child(holder, order)
		order += 1


func card_for(robot_id: String) -> RobotCard:
	return _cards.get(robot_id)


func cards() -> Array:
	return _cards.values()


func clear_robots() -> void:
	for robot_id in _cards.keys():
		_remove(robot_id)


func _upsert(robot: Dictionary) -> RobotCard:
	var robot_id := str(robot.get("robot_id", ""))
	var card: RobotCard = _cards.get(robot_id)
	if card == null:
		card = CARD_SCENE.instantiate() as RobotCard
		card.configure(robot)
		card.chosen.connect(func(id: String): robot_chosen.emit(id))
		add_child(card)
		card.resize(CARD_SIZE)
		_cards[robot_id] = card
		_tile_index[robot_id] = card
	else:
		card.configure(robot)
	return card


func _remove(robot_id: String) -> void:
	var card: RobotCard = _cards.get(robot_id)
	_cards.erase(robot_id)
	_tile_index.erase(robot_id)
	if is_instance_valid(card):
		var holder: Node = card
		while holder.get_parent() != self and holder.get_parent() != null:
			holder = holder.get_parent()
		holder.queue_free()
