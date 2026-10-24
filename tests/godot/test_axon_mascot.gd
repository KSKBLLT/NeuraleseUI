extends SceneTree
## The hand-drawn Axon: finite reactions that return exactly to rest, no
## per-frame work, and the three screens that show it use the component.

const AxonMascot = preload("res://scripts/ui/axon_mascot.gd")
const USERS := [
	"res://scripts/ui/axon_panel.gd",
	"res://scripts/ui/home.gd",
	"res://scripts/ui/dataset_empty_state.gd",
]

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var mascot: AxonMascot = AxonMascot.new()
	mascot.size = Vector2(240, 128)
	root.add_child(mascot)
	await process_frame

	_expect(mascot.texture == AxonMascot.ART, "the mascot shows the hand-drawn Axon")
	_expect(mascot.texture.get_size().x >= 1000.0, "the drawing is the full-size original, not the screenshot cut")
	_expect(not mascot.is_processing(), "an idle mascot does no per-frame work")
	_expect(not mascot.is_reacting(), "the mascot starts at rest")
	_expect(mascot.pivot_offset.x == 120.0, "reactions turn around the middle of the drawing")

	for kind in [&"blink", &"joy", &"think"]:
		mascot._last_reaction = -100000
		mascot.react(kind)
		_expect(mascot.reaction == kind and mascot.is_reacting(), "%s starts" % kind)
		_finish(mascot)
		_expect(_at_rest(mascot), "%s returns exactly to rest" % kind)

	mascot._last_reaction = -100000
	mascot.react(&"wave at the moon")
	_expect(mascot.reaction == &"blink", "an unknown reaction falls back to a blink")
	_finish(mascot)

	mascot._last_reaction = -100000
	mascot.react(&"joy")
	mascot.react(&"think")
	_expect(mascot.reaction == &"joy", "a reaction right after another is ignored")
	_finish(mascot)

	mascot._last_reaction = -100000
	mascot.reactions_enabled = false
	mascot.react(&"joy")
	_expect(not mascot.is_reacting(), "with reactions off the mascot stays at rest")
	mascot.reactions_enabled = true

	mascot._last_reaction = -100000
	mascot.react(&"joy")
	_step(mascot, 0.12)
	mascot.hide()
	_expect(_at_rest(mascot), "hiding stops a reaction and puts the drawing back")
	mascot._last_reaction = -100000
	mascot.react(&"joy")
	_expect(not mascot.is_reacting(), "a hidden mascot does not react")

	mascot.greet_on_show = true
	mascot.show()
	await process_frame
	_expect(mascot.reaction == &"joy", "a greeting mascot waves when it comes into view")
	mascot.rest()

	mascot.pokeable = true
	_expect(mascot.mouse_filter == Control.MOUSE_FILTER_STOP, "a pokeable mascot takes the mouse")
	var click := InputEventMouseButton.new()
	click.button_index = MOUSE_BUTTON_LEFT
	click.pressed = true
	mascot._gui_input(click)
	_expect(mascot.reaction == &"joy", "a click waves")
	mascot.rest()
	mascot.pokeable = false
	_expect(mascot.mouse_filter == Control.MOUSE_FILTER_IGNORE, "a plain mascot lets the mouse through")
	mascot.queue_free()

	for path in USERS:
		var source := FileAccess.get_file_as_string(path)
		_expect(source.contains("res://scripts/ui/axon_mascot.gd"), "%s uses the mascot component" % path)
		_expect(not source.contains("axon_mascot.png"), "%s no longer uses the screenshot placeholder" % path)

	if failures.is_empty():
		print("PASS test_axon_mascot")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


## Plays the running reaction to its end, as the frames would.
func _finish(mascot: Node) -> void:
	_step(mascot, 5.0)


func _step(mascot: Node, seconds: float) -> void:
	var tween: Tween = mascot.get("_tween")
	if tween and tween.is_valid():
		tween.custom_step(seconds)


func _at_rest(mascot: Control) -> bool:
	return not mascot.call("is_reacting") and mascot.scale == Vector2.ONE and is_zero_approx(mascot.rotation)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
