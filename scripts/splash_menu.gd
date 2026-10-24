extends Control
class_name SplashMenu

const AuthFlowPolicy = preload("res://scripts/auth/auth_flow_policy.gd")

const SCALE_START_ENTER: float = 0.96
const SCALE_END_EXIT: float = 0.97
const DURATION_ENTER: float = 0.16
const DURATION_EXIT: float = 0.12
const BLUR_MAX_ALPHA: float = 0.8

var splashed: bool = false
var indexed = []
@export var typename: String = "login"
@export var accept: BlockComponent = null
@export var first_line: Control = null
@export var persistent: bool = false
@export var show_on_ready: bool = true
@export var dismiss_on_escape: bool = true
@export var dismiss_on_outside_click: bool = true
## A docked menu stays open beside the work, like the Axon side panel of the
## Pixel design: no backdrop, the camera keeps moving and the canvas stays live.
var docked := false

var t: float = 0.0
var target_mod: float = 0.0
var from_scale: Vector2 = Vector2.ONE
var to_scale: Vector2 = Vector2.ONE
var _splash_ready: bool = false

var anim_time: float = 0.0
var from_scale_val: float = SCALE_START_ENTER
var to_scale_val: float = 1.0
var from_alpha: float = 0.0
var to_alpha: float = 1.0


func _enter_tree() -> void:
	if show_on_ready:
		_splash_ready = false
		hide()


func _ready() -> void:
	if show_on_ready:
		readys()

func _is_any_other_splash_active() -> bool:
	if not is_instance_valid(ui) or not ("splashed" in ui):
		return false
	for s in ui.splashed.keys():
		if is_instance_valid(s) and s != self and s.visible and s.splashed:
			return true
	return false


func readys():
	_splash_ready = true
	RenderingServer.global_shader_parameter_set("_view_scale", 1.0)
	if first_line:
		first_line.grab_focus()
		first_line.grab_click_focus()
	if (inner or _is_any_other_splash_active()) and not docked:
		ui.blur.self_modulate.a = BLUR_MAX_ALPHA
	else:
		ui.blur.self_modulate.a = 0.0
	show()
	
	if has_node("ColorRect"):
		$ColorRect.scale = Vector2.ONE * SCALE_START_ENTER
		$ColorRect.modulate.a = 0.0
	from_scale_val = SCALE_START_ENTER
	to_scale_val = 1.0
	from_alpha = 0.0
	to_alpha = 1.0
	anim_time = 0.0
	tick()
	#indexed = glob.rget_children(self)
	#await get_tree().process_frame
	splash()

var emitter: ui.ResultEmitter = null
signal quitting

func quit(data: Dictionary = {}):
	quitting.emit()
	if can_go:
		hide()
		if can_tween_zero and not _is_any_other_splash_active():
			ui.blur.self_modulate.a = 0
		if emitter and emitter.res:
			emitter.res.emit(data)
		queue_free()

var res: Callable
func resultate(data: Dictionary):
	_resultate(data)

var passed_data: Dictionary = {}

var splashed_from: BlockComponent
var can_go: bool = true
func _resultate(data: Dictionary):
	go_away()
	return
	if "go_signup" in data:
		can_go = false
		go_away()
		await quitting
		queue_free()
		ui.splash_and_get_result("signup", splashed_from, emitter, true)
	else:
		ui.hourglass_on()
		var result = await glob.login(data["user"], data["pass"])
		ui.hourglass_off()

		if result.ok:
			if emitter and emitter.res:
				emitter.res.emit(data)
			go_away()
		else:
			match result.error:
				"auth":
					ui.error("Username or password is wrong. :(")
				"network":
					ui.error("Either your internet or the server itself is down. Sorry!")
				_:
					ui.error("Unexpected server error.")


func set_base_size(sz: Vector2):
	target_size = sz
	$ColorRect.size = sz

func tick():
	if not has_node("ColorRect"):
		return
	$ColorRect.position = glob.window_size / 2.0 - ($ColorRect.size * $ColorRect.scale) / 2.0
	if is_instance_valid(ui) and is_instance_valid(ui.blur):
		ui.blur.size = glob.window_size + Vector2(50, 50)

func _quit_request():
	pass

func _notification(what: int) -> void:
	if what == NOTIFICATION_PREDELETE:
		ui.splashed_in.erase(self)

var inner: bool = false
func _process(delta: float) -> void:
	if show_on_ready and not _splash_ready:
		return
	if not has_node("ColorRect"):
		return
	if not visible and not splashed:
		return
	$ColorRect.size = $ColorRect.size.lerp(target_size, minf(1.0, delta * 20.0))
	var has = $ColorRect.get_global_rect().has_point(get_global_mouse_position())
	if has and visible:
		ui.splashed_in[self] = true
	else:
		ui.splashed_in.erase(self)
	if dismiss_on_escape and Input.is_action_just_pressed("ui_esc"):
		go_away()
		_quit_request()
	if Input.is_action_just_pressed("ui_enter"):
		if accept:
			accept.press(0.02)
	elif dismiss_on_outside_click and splashed and (glob.mouse_just_pressed or glob.mouse_alt_just_pressed) and \
	!has and\
	!glob.is_occupied(self, "block_button_inside"):
		go_away()
		_quit_request()
	#(glob.get_occupied("block_button_inside"))

	if splashed:
		show()
		anim_time += delta
		var progress: float = clampf(anim_time / DURATION_ENTER, 0.0, 1.0)
		var ease_out: float = 1.0 - pow(1.0 - progress, 3.0)
		var cur_scale: float = lerpf(from_scale_val, to_scale_val, ease_out)
		$ColorRect.scale = Vector2(cur_scale, cur_scale)
		$ColorRect.modulate.a = lerpf(from_alpha, to_alpha, progress)

		if docked:
			pass
		elif can_go:
			if not inner:
				if can_tween_zero:
					ui.blur.self_modulate.a = lerpf(ui.blur.self_modulate.a, BLUR_MAX_ALPHA, minf(1.0, delta * 25.0))
			else:
				ui.blur.self_modulate.a = BLUR_MAX_ALPHA
		else:
			ui.blur.self_modulate.a = BLUR_MAX_ALPHA

		if progress >= 1.0:
			$ColorRect.scale = Vector2.ONE * to_scale_val
			$ColorRect.modulate.a = to_alpha
			if not ticked:
				ticked = true
				stable.emit()
	else:
		anim_time += delta
		var progress: float = clampf(anim_time / DURATION_EXIT, 0.0, 1.0)
		var ease_in: float = progress * progress * progress
		var cur_scale: float = lerpf(from_scale_val, to_scale_val, ease_in)
		$ColorRect.scale = Vector2(cur_scale, cur_scale)
		$ColorRect.modulate.a = lerpf(from_alpha, to_alpha, progress)

		if can_go and can_tween_zero and not _is_any_other_splash_active():
			ui.blur.self_modulate.a = lerpf(ui.blur.self_modulate.a, 0.0, minf(1.0, delta * 25.0))

		if progress >= 1.0 or $ColorRect.modulate.a <= 0.02:
			$ColorRect.modulate.a = 0.0
			if visible:
				quit({})
			return

	tick()
var ticked: bool = false
signal stable

@onready var target_size: Vector2 = $ColorRect.size

func _just_splash():
	ui.blur.set_tuning(ui.blur.base_tuning)

func _just_go_away():
	pass

func _splash():
	pass

@onready var base_size = $ColorRect.size

func splash() -> void:
	ticked = false
	_splash()
	accept_event()
	from_scale_val = $ColorRect.scale.x if has_node("ColorRect") else SCALE_START_ENTER
	to_scale_val = 1.0
	from_alpha = $ColorRect.modulate.a if has_node("ColorRect") else 0.0
	to_alpha = 1.0
	anim_time = 0.0
	target_mod = 1.0
	splashed = true
	show()
	ui.add_splashed(self)
	
	if glob.cam is GraphViewport and not docked:
		glob.cam.stop()
	_set_environment_process_mode(Node.PROCESS_MODE_DISABLED)
	_just_splash()

var can_tween_zero: bool = true
func go_away(mod_zero: bool = true) -> void:
	from_scale_val = $ColorRect.scale.x if has_node("ColorRect") else 1.0
	to_scale_val = SCALE_END_EXIT
	from_alpha = $ColorRect.modulate.a if has_node("ColorRect") else 1.0
	to_alpha = 0.0
	anim_time = 0.0
	
	target_mod = 0.0
	splashed = false
	ui.rem_splashed(self)


	if glob.cam is GraphViewport and not docked:
		glob.cam.resume()
	_set_environment_process_mode(Node.PROCESS_MODE_ALWAYS)

	_just_go_away()


func _set_environment_process_mode(mode: ProcessMode) -> void:
	var environment = glob.tree_windows.get("env")
	if not is_instance_valid(environment):
		return
	var content: Node = environment.get_node_or_null("Control")
	if content:
		content.process_mode = mode

func _on_train_2_released() -> void:
	resultate({"go_signup": true})


func _on_train_released() -> void:
	ui.hourglass_on()
	var result: Dictionary = await cookies.login_cached_or_browser(true)
	ui.hourglass_off()
	if not result.get("ok", false):
		ui.error(str(result.get("error", "Authentication failed.")))
		return
	if is_instance_valid(accept):
		accept.text = login_success_text(str(glob.get_lang()))
	await get_tree().create_timer(0.45).timeout
	resultate({})
	#$ColorRect/Label2.update_valid()
	#$ColorRect/Label.update_valid()
	#if $ColorRect/Label2.is_valid and $ColorRect/Label.is_valid:
	#	resultate({"user": $ColorRect/Label.text, "pass": $ColorRect/Label2.text})


static func login_success_text(language: String) -> String:
	return AuthFlowPolicy.login_success_text(language)
