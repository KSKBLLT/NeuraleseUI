extends SplashMenu
class_name AIHelpMenu

const AxonContextGateCore := preload("res://scripts/axon_context_gate.gd")

enum SendRoute {
	BUSY,
	STOP_RECORDING,
	STOP_STREAM,
	REMOTE_ACTION,
}

func _enter_tree() -> void:
	glob.ai_help_menu = self

@export var _user_message: HBoxContainer
@export var _ai_message: HBoxContainer

var chat_id: int = 0
## Pixel design: the side panel built around this chat (scripts/ui/axon_panel.gd),
## loaded at run time so script-mode tests can load this file without autoloads.
var _panel = null
var _context_gate = AxonContextGateCore.new()
var _transcribing := false

@onready var user_message = _user_message.duplicate()
@onready var ai_message = _ai_message.duplicate()

static var cached_scroller = null


static func send_route(
	recording: bool,
	transcribing: bool,
	pending_stream_stop: bool
) -> SendRoute:
	if transcribing:
		return SendRoute.BUSY
	if recording:
		return SendRoute.STOP_RECORDING
	if pending_stream_stop:
		return SendRoute.STOP_STREAM
	return SendRoute.REMOTE_ACTION

#func reparent_stuff():
	##(scroller)
	#scroller.set_meta("mlist", _message_list)
	#AIHelpMenu.cached_scroller = scroller
	#remove_child(scroller)
	##scroller.tree_exiting.connect(print.bind("hello"))
#
#func get_stuff():
	##(AIHelpMenu.cached_scroller)
	#if AIHelpMenu.cached_scroller:
		##var p = scroller.get_parent()
		#scroller.queue_free()
		##p.add_child(AIHelpMenu.cached_scroller)
		#scroller = AIHelpMenu.cached_scroller
		#get_node("ColorRect").add_child(AIHelpMenu.cached_scroller)
		#_message_list = scroller.get_meta("mlist")

func quit(data: Dictionary = {}):
	quitting.emit()
	if rec:
		web.transcriber.end_recording()
		rec = false
		$ColorRect/Label2.enable()
		$ColorRect/Label2.text = ""
		_on_label_2_text_changed()
	if can_go:
		hide()
		$ColorRect/Label2.release_focus()
		ui.blur.self_modulate.a = 0
		emitter.res.emit(data)
		#get_parent().remove_child(self)

func re_recv():
	if not glob.remote_session_ready(): return
	var received = await glob.request_chat(str(chat_id))
	if received:
		for i in received:
			if !i.has("role"): continue
			if i["role"] == "user":
				i.user = true
			elif i["role"] != "system":
				i.text = parser.clean_message(i.text)
				i.user = false
			i.erase("role")
		var new_recv = []
		for i in range(len(_message_list), len(received)):
		#	new_recv.append(received[i])
			add_message(received[i])
	
	
	if get_last_message() and get_last_message().user:
		if glob.message_sockets.has(chat_id):
			var got = glob.get_my_message_state(chat_id, text_receive)
			trect.texture = stop
			if got[0]:
				$ColorRect/Label2.disable()
				got[0].kill.connect(func():
						get_last_message().erase("_pending")
						
						#("ff")
						#glob.update_chat_cache(str(chat_id), get_last_message())
						trect.texture = mic_texture
						$ColorRect/Label2.enable())
				#(got[1])
				add_message({"user": false, "text": got[1]})
	await get_tree().process_frame
	#scroller.queue_sort()
	scroller.force_update_transform()
	#ui.force_layout_update(scroller)
	$ColorRect/ScrollContainer.set("scroll_vertical", $ColorRect/ScrollContainer.get_v_scroll_bar().max_value)




func _ready() -> void:
	hide()
	super()
	hide()
	if design.pixel:
		docked = true
		dismiss_on_outside_click = false
		_panel = load("res://scripts/ui/axon_panel.gd").new()
		_panel.build(self)
	if passed_data.has("away"):
		go_away()
	#get_stuff()
	#quitting.connect(reparent_stuff)
	_user_message.queue_free()
	_ai_message.queue_free()
	#set_messages([
	#	{"user": false, "text": "Hi! My name is Axon. I'm here to help & teach you Neural Networks!"},
	#	])
	re_recv()

var last_recv = null
func text_receive(arr):
	if not get_last_message(): return
	if arr[1].get("change_nodes", ""):
		ui.set_ai_building()
		get_last_message().object.set_thinking(false)
		if not get_last_message().get("marked_building", false):
			get_last_message().object.set_building(true)
		get_last_message()["marked_building"] = true
	else:
		ui.stop_ai_building()
		get_last_message().object.set_building(false)
		get_last_message()["marked_building"] = false

	if arr[1].get("thinking", ""):
		if not get_last_message().get("marked_thinking", false):
			get_last_message().object.set_thinking(true)
		get_last_message()["marked_thinking"] = true
	else:
		get_last_message().object.set_thinking(false)
		get_last_message()["marked_thinking"] = false
	
	get_last_message().text += arr[0]
	get_last_message().object.push_text(arr[0])

func set_last_id(last_id: int):
	get_last_message().id = last_id

func get_last_id():
	if get_last_message():
		return get_last_message().id
	return 0

func send_message(text: String, source_label: String = ""):
	if not glob.require_remote_session():
		return null
	var user_id: int = randi_range(0,999999)
	var ai_id: int = randi_range(0,999999)
	add_message({"user": true, "text": text, "source_label": source_label, "id": user_id})
	glob.update_chat_cache(str(chat_id), _message_list[-1])
	$ColorRect/Label2.disable()
	fixed_mode = true
	add_message({"user": false, "text": "", "_pending": true, "id": ai_id})
	$ColorRect/Label2._guard = false
	$ColorRect/Label2._clear_text_and_reset()
	var sock = await glob.update_message_stream(text, chat_id, text_receive, glob.def, false, user_id, ai_id)
	$ColorRect/Label2._clear_text_and_reset()
	if sock:
		await sock.kill
	if get_last_message() and not get_last_message().user:
		get_last_message().object.set_thinking(false)
		get_last_message().object.set_building(false)
		get_last_message().erase("_pending")
		
		get_last_message().object.actual_text = ""
		get_last_message().object.push_text(get_last_message().text)
	ui.stop_ai_building()
	first_line.grab_focus()
	first_line.grab_click_focus()
	trect.texture = mic_texture
	#(get_last_message())
	#glob.update_chat_cache(str(chat_id), get_last_message())
	$ColorRect/Label2.enable()
	#await get_tree().process_frame
	#$ColorRect/ScrollContainer.set_deferred("scroll_vertical", $ColorRect/ScrollContainer.get_v_scroll_bar().max_value)

var _message_list: Array[Dictionary] = []

@onready var scroller = $ColorRect/ScrollContainer/MarginContainer2/MarginContainer/VBoxContainer
func set_messages(messages: Array):
	for message in messages:
		add_message(message)

func add_message(message: Dictionary):
	_message_list.append(message)
	var new = null
	if message.user:
		new = user_message.duplicate()
	else:
		new = ai_message.duplicate()
	scroller.add_child(new)
	var text_node: RichTextLabel
	if message.user:
		text_node = new.get_node("Content/txt")
		var source_label: Label = new.get_node("Content/source")
		var source_text := str(message.get("source_label", "")).strip_edges()
		source_label.visible = not source_text.is_empty()
		# Google Sans has no "↳", so the pixel design marks the source with an arrow.
		var marker := "→" if design.pixel else "↳"
		source_label.text = "%s %s" % [marker, source_text] if not source_text.is_empty() else ""
	else:
		text_node = new.get_node("txt")
	if not message.user:
		text_node.actual_text = message.text
	text_node.set_txt(message.text)
	message.object = text_node
	message.root = new


func queue_context_request(request: Dictionary) -> bool:
	if not _context_gate.consume(request):
		return false
	var prepared: Dictionary = AxonContextGateCore.presentation(request)
	call_deferred("_send_context_presentation", prepared)
	return true


func _send_context_presentation(prepared: Dictionary) -> void:
	var message: Dictionary = prepared.get("message", {})
	send_message(str(prepared.get("api_text", "")), str(message.get("source_label", "")))


func _just_splash():
	ui.blur.set_tuning(Color(0,0,0,0.5))
	if _panel:
		_panel.set_open(true)
	#("A")
	if get_last_message():
		get_last_message().object.actual_text = ""
		get_last_message().object.push_text(get_last_message().text)

var fixed_mode: bool = false
@onready var bs = $ColorRect/ScrollContainer.size.y
func _process(delta: float) -> void:
	
	if not visible: return
	super(delta)
	if _panel:
		_panel.update()
	var tr = $ColorRect/root/TextureRect
	var bar: VScrollBar = $ColorRect/ScrollContainer.get_v_scroll_bar()
	#bar.offset_left = -3
	$ColorRect/root/TextureRect2.visible = bar.value > 0.1
	#($ColorRect/ScrollContainer.get_v_scroll_bar().max_value )
	#($ColorRect/ScrollContainer.get_v_scroll_bar().value )
	#(fixed_mode)
	if get_last_message():
		get_last_message().get_or_add("timing", [0.0])[0] += delta
	if get_last_message() and get_last_message().get("_pending") and fixed_mode:
		$ColorRect/ScrollContainer.set("scroll_vertical", bar.max_value)
	if glob.mouse_scroll == -1:
		fixed_mode = false
	tr.visible = bar.max_value - bar.page > bar.value or $ColorRect/Label2.size.y > 46.5
	
	var scrolling = bar.max_value - bar.page > bar.value
	#if !scrolling:
		
	#if scrolling:
	#	$ColorRect/ScrollContainer.size.y = bs + 6
	#else:
	#$ColorRect/ScrollContainer.size.y = bs - 90
		
	
	if $ColorRect/Label2.size.y > 46.5:
		if scrolling:
			tr.position = $ColorRect/Label2.position + Vector2(0,-1)
		else:
			tr.position = $ColorRect/Label2.position + Vector2(0,-1)
			
	else:
		if scrolling:
			tr.position = $ColorRect/Label2.position + Vector2(0,-0)
		else:
			tr.position = $ColorRect/Label2.position + Vector2(0,-1)
		

func _quit_request():
	pass


func go_away(mod_zero: bool = true) -> void:
	super(mod_zero)
	if _panel:
		_panel.set_open(false)


## Docked, the panel takes the right column of the workspace instead of the
## middle of the screen.
func tick():
	if not _panel:
		super()
		return
	var place: Rect2 = _panel.rect()
	$ColorRect.position = place.position
	target_size = place.size

func _on_train_hovering() -> void:
	pass # Replace with function body.


func get_last_message():
	return _message_list[-1] if _message_list else null

func get_my_ws():
	return glob.message_sockets.get(chat_id)

var rec: bool = false
func on_send(txt: String) -> void:
	#if get_last_message().has("_pending"):
	#	return
	#(get_last_message())


	var pending_stream_stop := false
	var last_message: Variant = get_last_message()
	if last_message is Dictionary:
		pending_stream_stop = (
			trect.texture == stop
			and last_message.has("_pending")
			and is_instance_valid(get_my_ws())
			and not txt
			and last_message.get("timing", [0.0])[0] > 0.1
		)
	match send_route(rec, _transcribing, pending_stream_stop):
		SendRoute.BUSY:
			return
		SendRoute.STOP_RECORDING:
			web.transcriber.end_recording()
			trect.texture = mic_texture
			rec = false
			if not glob.require_remote_session():
				$ColorRect/Label2.enable()
				$ColorRect/Label2.text = ""
				return
			_transcribing = true
			if web.transcriber.t_record > 0.1:
				var handle = await web.transcriber.send_recording().completed
				print(handle.body)
				if handle and handle.body and "text" in handle.body:
					$ColorRect/Label2.text = handle.body.text
					_on_label_2_text_changed()
				else:
					$ColorRect/Label2.text = ""
			else:
				$ColorRect/Label2.text = ""
			_transcribing = false
			$ColorRect/Label2.enable()
			return
		SendRoute.STOP_STREAM:
			get_my_ws().send(glob.compress_dict_zstd({"stop": true}))
			return
		SendRoute.REMOTE_ACTION:
			if not glob.require_remote_session():
				return
		#get_last_message().object.queue_free()
		#_message_list.remove_at(-1)
		#glob.rem_chat_cache(str(chat_id))
		
		#("ff")

	if (not get_last_message() or not get_last_message().has("_pending")) and $ColorRect/Label2.text:
		send_message($ColorRect/Label2.text)
		trect.texture = stop
		return

	if !$ColorRect/Label2.text and not (get_last_message() and get_last_message().has("_pending")):
		rec = true
		trect.texture = stop
		$ColorRect/Label2.disable()
		match glob.get_lang():
			"ru":
				$ColorRect/Label2.text = "Говорите..."
			"kz":
				$ColorRect/Label2.text = "Сөйле..."
			_:
				$ColorRect/Label2.text = "Speak..."
		web.transcriber.begin_recording(40.0, func(): trect.texture = mic_texture)
			#(len(web.transcriber.buf))
			
		return
var can_enter: bool = false

@onready var trect = $ColorRect/Label2/train/TextureRect
@onready var mic_texture = $ColorRect/Label2/train/TextureRect.texture
@onready var stop = glob.stop_icon
var def_texture = preload("res://game_assets/icons/send.png")
func _on_label_2_text_changed() -> void:
	if $ColorRect/Label2.text:
		trect.texture = def_texture
	else:
		trect.texture = mic_texture

func clear_all():
	for i in range(len(_message_list)):
		_free_message_root(_message_list[i])
	_message_list.clear()
	$ColorRect/ScrollContainer.set("scroll_vertical", 0)

func _on_cl_released() -> void:
	if not glob.require_remote_session():
		return
	for i in range(len(_message_list)):
		_free_message_root(_message_list[i])
	_message_list.clear()
	glob.clear_chat(chat_id)
	$ColorRect/ScrollContainer.set("scroll_vertical", 0)


func _free_message_root(message: Dictionary) -> void:
	var message_root = message.get("root")
	if is_instance_valid(message_root):
		message_root.queue_free()
		return
	var object = message.get("object")
	if is_instance_valid(object) and is_instance_valid(object.get_parent()):
		object.get_parent().queue_free()
