extends TextureRect
## Axon, the hand-drawn mascot (game_assets/axon/axon-frog.png; authorship in
## game_assets/axon/PROVENANCE.txt), with short finite reactions. A reaction
## sways or squashes the drawing for a moment and returns it exactly to rest,
## so an idle mascot does no work per frame.
##
##   blink   a quick squash               noticed something (a picked node, a hover)
##   joy     a hop with a wiggle          hello, well done
##   think   tilts its head and holds     thinking about a question
##
## It uses no autoloads, so scripts that tests load with --script can build it.

const ART := preload("res://game_assets/axon/axon-frog.png")
const REACTIONS: Array[StringName] = [&"blink", &"joy", &"think"]
## A new reaction is ignored this soon after the last one, so moving over
## several cards in a row does not make Axon twitch.
const COOLDOWN_MSEC := 700

## Waves each time it comes into view (the panel opens, the tab is shown).
var greet_on_show := false
## Takes the mouse: moving over it blinks, a click waves.
var pokeable := false:
	set(value):
		pokeable = value
		mouse_filter = Control.MOUSE_FILTER_STOP if value else Control.MOUSE_FILTER_IGNORE
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if value else Control.CURSOR_ARROW
## Off: the mascot stays at rest whatever is asked.
var reactions_enabled := true
## The reaction playing now, or &"" at rest.
var reaction: StringName = &""

var _tween: Tween
var _last_reaction := -100000


func _init() -> void:
	texture = ART
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	resized.connect(_place_pivot)
	mouse_entered.connect(_on_mouse_entered)


func _ready() -> void:
	set_process(false)
	_place_pivot()
	if greet_on_show:
		_greet.call_deferred()


## Plays a reaction (`blink`, `joy`, `think`) once and returns to rest.
func react(kind: StringName) -> void:
	if not reactions_enabled or not is_inside_tree() or not is_visible_in_tree():
		return
	var now := Time.get_ticks_msec()
	if now - _last_reaction < COOLDOWN_MSEC:
		return
	_last_reaction = now
	rest()
	reaction = kind if kind in REACTIONS else &"blink"
	_tween = create_tween()
	match reaction:
		&"joy":
			_tween.tween_property(self, ^"scale", Vector2(1.06, 0.94), 0.07)
			_tween.tween_property(self, ^"scale", Vector2(0.97, 1.07), 0.1)
			_tween.parallel().tween_property(self, ^"rotation", deg_to_rad(-6.0), 0.1)
			_tween.tween_property(self, ^"rotation", deg_to_rad(5.0), 0.12)
			_tween.parallel().tween_property(self, ^"scale", Vector2.ONE, 0.12)
			_tween.tween_property(self, ^"rotation", deg_to_rad(-3.0), 0.1)
			_tween.tween_property(self, ^"rotation", 0.0, 0.1)
		&"think":
			_tween.tween_property(self, ^"rotation", deg_to_rad(-7.0), 0.18).set_trans(Tween.TRANS_SINE)
			_tween.parallel().tween_property(self, ^"scale", Vector2(0.98, 1.02), 0.18)
			_tween.tween_interval(0.35)
			_tween.tween_property(self, ^"rotation", 0.0, 0.2).set_trans(Tween.TRANS_SINE)
			_tween.parallel().tween_property(self, ^"scale", Vector2.ONE, 0.2)
		_:
			_tween.tween_property(self, ^"scale", Vector2(1.03, 0.9), 0.06)
			_tween.tween_property(self, ^"scale", Vector2.ONE, 0.1)
	_tween.finished.connect(rest)


## Stops any reaction and puts the drawing back at rest.
func rest() -> void:
	if _tween:
		_tween.kill()
		_tween = null
	reaction = &""
	scale = Vector2.ONE
	rotation = 0.0


func is_reacting() -> bool:
	return reaction != &""


func _notification(what: int) -> void:
	if what != NOTIFICATION_VISIBILITY_CHANGED:
		return
	if not is_visible_in_tree():
		rest()
	elif greet_on_show:
		_greet.call_deferred()


func _gui_input(event: InputEvent) -> void:
	var click := event as InputEventMouseButton
	if pokeable and click and click.pressed and click.button_index == MOUSE_BUTTON_LEFT:
		_last_reaction = -100000
		react(&"joy")
		accept_event()


func _on_mouse_entered() -> void:
	if pokeable:
		react(&"blink")


func _greet() -> void:
	react(&"joy")


## Reactions turn and squash the drawing around its lower middle, where the
## body sits, so it hops on the spot rather than swinging from a corner.
func _place_pivot() -> void:
	pivot_offset = Vector2(size.x * 0.5, size.y * 0.62)
