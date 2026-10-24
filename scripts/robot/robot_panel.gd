class_name RobotPanel
extends Control
## The robot part of the Export window.
##
## Three screens, laid out like the Simulations editor:
##   Robots   the robots found nearby, as cards; one click connects
##   Build    the robot seen from above with a checklist on the right, one step
##            after another, each saying what to do: put the distance sensors
##            where they are on the robot; when the network takes more than
##            its rays, say where that comes from (gyro or wheels, the field);
##            check the wheels one motor at a time; set the robot's length;
##            start. The network's inputs and outputs are listed in the steps
##            that feed them, under Brain Mapping's names.
##   Drive    the room as the robot's sensors see it, as a lidar
##            (RobotLidarView), while the robot drives; a big Stop
##
## Every conversion between the training world and the room is taken from the
## robot's length: one simulation unit is the robot's length over the rover's.
## Everything the robot needs happens in a Python process (RobotSessionClient);
## this panel only asks it things and draws the answers. Questions are asked in
## the window itself, not in nested windows (see neuralese-nested-windows).

signal busy_changed(busy: bool)

enum Screen { ROBOTS, BUILD, DRIVE }

const BaseTheme = preload("res://resources/theme_base.tres")
const SliderTheme = preload("res://resources/theme.tres")
## Simulations runtime bar (simulation_editor.gd).
const RUNTIME_BUTTON_MATERIAL := "res://resources/button_mat.tres"
const RUNTIME_BUTTON_CONFIG := "res://resources/lite_config.tres"
const PLAY_BUTTON_COLOR := Color("39c98a")
const STOP_BUTTON_COLOR := Color("e65d5d")
const BAR_HEIGHT := 50.0
const BAR_GAP := 12.0
const PALETTE_WIDTH := 300.0
## Text colours of the ready-made projects window (builtin_projects_window.tscn).
const INTRO_COLOR := Color(0.72, 0.74, 0.79, 1)
const OK_COLOR := Color("77dfa2")
const BAD_COLOR := Color("ef795f")
const SENSOR_ACCENT := Color("62d8d2")      # registry accent of the ray sensor
## The block shader draws a button's outline in its colour; the Simulations
## "Return" button meant this grey for its outline (simulation_editor.gd).
const SECONDARY_COLOR := Color(0.6, 0.6, 0.6)

const FIRST_SCAN_S := 1.0
const FULL_SCAN_S := 8.0
const COUNTDOWN_S := 3
const READ_INTERVAL_S := 0.4
const SPIN_POWER := 35
const SPIN_SECONDS := 1.0
const TIME_LIMIT_S := 60.0
## The simulation (SimulationKernelAgent): a ray's reach, and the rover's length.
const RAY_DISTANCE_UNITS := 320.0
const ROVER_LENGTH_UNITS := 72.0
const WHEEL_SIZES_CM := [5.6, 4.3, 8.1]

var client: RobotSessionClient = null
var screen: int = Screen.ROBOTS
var contract: Dictionary = {}      # RobotModelContract.collect()
var model: Dictionary = {}         # describe_model answer
var robots: Array = []             # robots of the last scan, as IR dicts
var robot: Dictionary = {}         # the connected robot (IR, with the child's geometry)
var geometry: Dictionary = {}      # the child's drawing of the robot (IR "geometry")
var mapping: Dictionary = {}       # per model: the field (start, goal) and whether it was set
static var debug_model_path := ""  # tests and the harness: run this model instead of the project's
static var connect_extra := {}     # tests and the harness: extra arguments of "connect" (a Dummy world)
static var debug_dataset := {}     # tests and the harness: describe this dataset (and its world) instead of the project's
var scanning := false
var connecting := false
var driving := false
var counting_down := false

var _robots_screen: VBoxContainer
var _scan_label: Label
var _message_label: Label
var _grid: RobotGrid
var _robot_scroll: ScrollContainer
var _refresh_button: BlockComponent
var _workspace: Control
var _world: RobotWorld
var _lidar: RobotLidarView
var _lidar_ports: Array = []        # the sensors' ports, in the order the lidar takes their ranges
var _field: RobotField
var _palette: RobotPartsPalette
var _hint: Label
var _countdown: Label
var _bar: HBoxContainer
var _buttons: Dictionary = {}       # id -> BlockComponent
var _slider_box: HBoxContainer
var _slider: HSlider
var _slider_value: Label
var _indicators: HBoxContainer
var _steer_indicator: HSlider
var _throttle_indicator: HSlider
var _opened := false
var _session_failed := false
var _save_timer: Timer
var _read_timer: Timer
var _reading := false
var _bar_mode := "step"
var _step := "sensors"              # the checklist's open step (see _steps)
var _show_field := false
var _check_queue: Array = []        # motor ports still to check
var _check_port := ""
var _check_sides := {"left": [], "right": []}
var _check_side := ""               # the wheel the child said the motor turned
## The least room over the drawing for the hint, two lines; a longer hint
## pushes the drawing down.
const HINT_HEIGHT := 44.0
var _hint_texts: Dictionary = {}
var _hint_args: Array = []
var _hint_full := ""                # the hint before its lines are broken


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = BaseTheme
	_build()
	glob.language_changed.connect(_on_language_changed)


## Everything this panel words itself is said again; Loc nodes do the rest.
func _on_language_changed() -> void:
	if not _hint_texts.is_empty():
		_hint_set(_hint_texts, _hint.get_theme_color("font_color"), _hint_args)
	if _bar_mode == "field":
		_update_field_caption()    # its words ("ahead", "to the left") are picked by language
	elif _bar_mode == "drive":
		_set_bar("drive")
	_slider_value.text = _cm_text(_slider.value)
	_refresh_build()
	_field.queue_redraw()


# -- opening and closing ---------------------------------------------------------------

## Called each time the window is shown in robot mode.
func open() -> void:
	if _opened:
		return
	_opened = true
	robot = {}
	geometry = {}
	_show(Screen.ROBOTS)
	_start_session_and_scan()


## Called when the window goes away or leaves robot mode: nothing may keep driving.
func close() -> void:
	if not _opened:
		return
	_opened = false
	halt()
	if client != null:
		var old := client
		client = null
		await old.shutdown()
		old.queue_free()
	_grid.clear_robots()
	_set_message("")


func is_driving() -> bool:
	return driving or counting_down


func is_busy() -> bool:
	return connecting or is_driving() or not _check_port.is_empty()


static func say(texts: Dictionary) -> String:
	var lang := str(glob.get_lang())
	return str(texts.get(lang, texts.get("en", "")))


# -- layout ------------------------------------------------------------------------------

func _build() -> void:
	_robots_screen = VBoxContainer.new()
	_robots_screen.name = "Robots"
	_robots_screen.add_theme_constant_override("separation", 10)
	_robots_screen.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_robots_screen)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 12)
	header.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_robots_screen.add_child(header)
	_scan_label = _text_label("Looking for robots...", 15, INTRO_COLOR, {
		"looking for robots": "Поиск роботов…",
		"no robots nearby turn the robot on and press refresh": "Роботы не найдены. Включите робота и нажмите «Обновить».",
		"pick your robot": "Выберите робота",
	}, {
		"looking for robots": "Роботтарды іздеу…",
		"no robots nearby turn the robot on and press refresh": "Роботтар табылмады. Роботты қосып, «Жаңарту» түймесін басыңыз.",
		"pick your robot": "Роботты таңдаңыз",
	})
	_scan_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scan_label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_scan_label)
	_refresh_button = _runtime_button("robot_refresh", "   Refresh", SECONDARY_COLOR, Vector2(150, 50), header,
		{"refresh": "   Обновить"}, {"refresh": "   Жаңарту"}, "res://game_assets/icons/refresh.png")
	_refresh_button.released.connect(_on_refresh_pressed)
	_message_label = Label.new()
	_message_label.add_theme_font_size_override("font_size", 14)
	_message_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_message_label.visible = false
	_robots_screen.add_child(_message_label)
	var scroll := ScrollContainer.new()
	scroll.clip_contents = false
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	_robot_scroll = scroll
	_robots_screen.add_child(scroll)
	_grid = RobotGrid.new()
	_grid.name = "RobotGrid"
	_grid.robot_chosen.connect(_on_robot_chosen)
	scroll.add_child(_grid)

	_workspace = Control.new()
	_workspace.name = "Workspace"
	_workspace.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_workspace)
	_world = RobotWorld.new()
	_world.name = "World"
	_world.changed.connect(_on_world_changed)
	_world.wheel_picked.connect(_on_wheel_picked)
	_workspace.add_child(_world)
	_lidar = RobotLidarView.new()
	_lidar.name = "Lidar"
	_lidar.visible = false
	_workspace.add_child(_lidar)
	_field = RobotField.new()
	_field.name = "Field"
	_field.visible = false
	_field.changed.connect(_on_field_changed)
	_workspace.add_child(_field)
	_palette = RobotPartsPalette.new()
	_palette.name = "Palette"
	_palette.part_requested.connect(_on_part_requested)
	_palette.row_pressed.connect(_on_row_pressed)
	_workspace.add_child(_palette)
	_hint = Label.new()
	_hint.add_theme_font_size_override("font_size", 15)
	_hint.add_theme_color_override("font_color", INTRO_COLOR)
	_hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hint.clip_text = true
	_hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_workspace.add_child(_hint)
	_countdown = Label.new()
	_countdown.add_theme_font_size_override("font_size", 64)
	_countdown.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_countdown.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_countdown.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_countdown.visible = false
	_workspace.add_child(_countdown)

	_bar = HBoxContainer.new()
	_bar.name = "RuntimeBar"
	_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_bar.add_theme_constant_override("separation", 12)
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_bar)
	_add_outline_button("back", "   Robots", {"robots": "   Роботы"}, {"robots": "   Роботтар"}, "res://game_assets/icons/undo.png", _on_back_pressed)
	_add_outline_button("cancel", "Cancel", {"cancel": "Отмена"}, {"cancel": "Болдырмау"}, "", _on_cancel_pressed)
	_add_outline_button("again", "Again", {"again": "Повторить"}, {"again": "Қайталау"}, "", _on_again_pressed)
	_add_outline_button("not_wheel", "Skip", {"skip": "Пропустить"}, {"skip": "Өткізу"}, "", _on_not_wheel_pressed)
	_add_outline_button("forward", "Forward", {"forward": "Вперёд"}, {"forward": "Алға"}, "", func(): _on_direction(true))
	_add_outline_button("backward", "Back", {"back": "Назад"}, {"back": "Артқа"}, "", func(): _on_direction(false))
	_slider_box = _slider_control()
	_bar.add_child(_slider_box)
	_buttons["start_check"] = _runtime_button("robot_start_check", "▶ Check the wheels", PLAY_BUTTON_COLOR, Vector2(160, 50), _bar,
		{"check the wheels": "▶ Проверить колёса"}, {"check the wheels": "▶ Доңғалақтарды тексеру"})
	_buttons["start_check"].released.connect(_on_start_check_pressed)
	_buttons["done"] = _runtime_button("robot_done", "✓ Done", PLAY_BUTTON_COLOR, Vector2(116, 50), _bar,
		{"done": "✓ Готово"}, {"done": "✓ Дайын"})
	_buttons["done"].released.connect(_on_done_pressed)
	_buttons["next"] = _runtime_button("robot_next", "Next", PLAY_BUTTON_COLOR, Vector2(116, 50), _bar,
		{"next": "Далее"}, {"next": "Келесі"})
	_buttons["next"].released.connect(_on_next_pressed)
	_buttons["go"] = _runtime_button("robot_go", "▶ Start", PLAY_BUTTON_COLOR, Vector2(116, 50), _bar,
		{"start": "▶ Запустить"}, {"start": "▶ Іске қосу"})
	_buttons["go"].released.connect(_on_go_pressed)
	_indicators = _indicator_control()
	_bar.add_child(_indicators)
	_buttons["stop"] = _runtime_button("robot_stop", "■ Stop", STOP_BUTTON_COLOR, Vector2(116, 50), _bar,
		{"stop": "■ Стоп"}, {"stop": "■ Тоқтату"})
	_buttons["stop"].released.connect(_on_stop_pressed)

	_save_timer = Timer.new()
	_save_timer.one_shot = true
	_save_timer.wait_time = 0.6
	_save_timer.timeout.connect(_save_now)
	add_child(_save_timer)
	_read_timer = Timer.new()
	_read_timer.wait_time = READ_INTERVAL_S
	_read_timer.timeout.connect(_read_tick)
	add_child(_read_timer)
	resized.connect(_layout)
	_layout()


## A label whose English text is translated by a Loc node, as everywhere in the project.
func _text_label(english: String, font_size: int, color: Color, ru: Dictionary, kz: Dictionary) -> Label:
	var label := Label.new()
	label.text = english
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.add_child(_loc(ru, kz))
	return label


func _loc(ru: Dictionary, kz: Dictionary) -> Loc:
	var loc := Loc.new()
	loc.name = "Localization"
	loc.auto = true
	var ru_typed: Dictionary[String, String] = {}
	var kz_typed: Dictionary[String, String] = {}
	ru_typed.assign(ru)
	kz_typed.assign(kz)
	loc.localizations_ru = ru_typed
	loc.localizations_kz = kz_typed
	return loc


## A button of the Simulations runtime bar (simulation_editor.gd _create_runtime_button).
func _runtime_button(id: String, text: String, color: Color, button_size: Vector2, host: Container, ru: Dictionary, kz: Dictionary, icon: String = "") -> BlockComponent:
	var definition := {
		"type": "block",
		"material": RUNTIME_BUTTON_MATERIAL,
		"config": RUNTIME_BUTTON_CONFIG,
		"static": true,
		"top": true,
		"scale": [0.8, 0.8],
		"alignment": [0.5, 0.5],
		"scale_affects_layout": true,
		"auto_fit": "x",
		"fit_shrink": true,
		"fit_padding": [22, 10],
		"fit_min_size": [72, 50],
		"fit_max_size": [300, 50],
		"id": id,
		"text": text,
		"size": [button_size.x, button_size.y],
		"color": color,
	}
	if not icon.is_empty():
		definition["icon"] = icon
	var button := UIAdapter.build(definition)
	button.in_splash = true
	if not ru.is_empty():
		button.add_child(_loc(ru, kz))
	UIAdapter.mount(host, button)
	return button


## The Simulations "Return" button: no fill, a grey outline.
func _add_outline_button(id: String, text: String, ru: Dictionary, kz: Dictionary, icon: String, handler: Callable) -> void:
	var button := _runtime_button("robot_" + id, text, SECONDARY_COLOR, Vector2(140, 50), _bar, ru, kz, icon)
	button.released.connect(handler)
	_buttons[id] = button


## The slider of the graph's Dropout node, with its theme: the robot's length.
func _slider_control() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(180, BAR_HEIGHT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(holder)
	_slider = HSlider.new()
	_slider.theme = SliderTheme
	_slider.min_value = 5.0
	_slider.max_value = 40.0
	_slider.step = 0.5
	_slider.focus_mode = Control.FOCUS_NONE
	_slider.scale = Vector2(2, 2)
	_slider.size = Vector2(90, 16)
	_slider.position = Vector2(0, BAR_HEIGHT * 0.5 - 16)
	_slider.value_changed.connect(_on_length_changed)
	holder.add_child(_slider)
	_slider_value = Label.new()
	_slider_value.add_theme_font_size_override("font_size", 15)
	_slider_value.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_slider_value.size_flags_vertical = Control.SIZE_FILL
	_slider_value.custom_minimum_size.x = 70
	box.add_child(_slider_value)
	return box


## What the network decides right now, on two read-only Dropout sliders.
func _indicator_control() -> HBoxContainer:
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_steer_indicator = _indicator(box, "steering", -1.0, 1.0)
	_throttle_indicator = _indicator(box, "throttle", 0.0, 1.0)
	return box


func _indicator(box: HBoxContainer, actuator_id: String, low: float, high: float) -> HSlider:
	var caption := Label.new()
	caption.name = actuator_id
	caption.add_theme_font_size_override("font_size", 14)
	caption.add_theme_color_override("font_color", INTRO_COLOR)
	caption.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	caption.size_flags_vertical = Control.SIZE_FILL
	box.add_child(caption)
	var holder := Control.new()
	holder.custom_minimum_size = Vector2(110, BAR_HEIGHT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_child(holder)
	var slider := HSlider.new()
	slider.theme = SliderTheme
	slider.min_value = low
	slider.max_value = high
	slider.step = 0.01
	slider.editable = false
	slider.focus_mode = Control.FOCUS_NONE
	slider.mouse_filter = Control.MOUSE_FILTER_IGNORE
	slider.scale = Vector2(2, 2)
	slider.size = Vector2(55, 16)
	slider.position = Vector2(0, BAR_HEIGHT * 0.5 - 16)
	holder.add_child(slider)
	return slider


func _layout() -> void:
	if _workspace == null or _bar == null:
		return
	var area := size
	var bar_top := area.y - BAR_HEIGHT
	_robots_screen.position = Vector2.ZERO
	_robots_screen.size = area
	_workspace.position = Vector2.ZERO
	_workspace.size = Vector2(area.x, bar_top - BAR_GAP)
	var palette_width := minf(PALETTE_WIDTH, area.x * 0.38) if screen == Screen.BUILD else 0.0
	_palette.position = Vector2(area.x - palette_width, 0)
	_palette.size = Vector2(palette_width, _workspace.size.y)
	var world_width := area.x - palette_width - (BAR_GAP if palette_width > 0.0 else 0.0)
	# The hint takes the lines it needs and the drawing starts under it.
	_hint.position = Vector2(4, 0)
	_hint.size = Vector2(world_width - 8, HINT_HEIGHT)
	_hint.text = RobotText.fit(_hint_full, _hint, _hint.size.x)
	_hint.size.y = maxf(HINT_HEIGHT, _hint.get_line_count() * _hint.get_line_height())
	var top := _hint.size.y + 2.0
	_world.position = Vector2(0, top)
	_world.size = Vector2(world_width, _workspace.size.y - top)
	_lidar.position = _world.position
	_lidar.size = _world.size
	_field.position = _world.position
	_field.size = _world.size
	if screen == Screen.DRIVE and _show_field:
		# While driving, the field is a small map in the corner.
		_field.size = Vector2(minf(world_width * 0.42, 300.0), minf(_world.size.y * 0.5, 190.0))
		_field.position = Vector2(world_width - _field.size.x, _workspace.size.y - _field.size.y)
	_countdown.position = _world.position
	_countdown.size = _world.size
	_bar.position = Vector2(0, bar_top)
	_bar.size = Vector2(area.x, BAR_HEIGHT)


# -- screens -------------------------------------------------------------------------------

func _show(new_screen: int) -> void:
	screen = new_screen
	_robots_screen.visible = screen == Screen.ROBOTS
	_workspace.visible = screen != Screen.ROBOTS
	_bar.visible = screen != Screen.ROBOTS
	_palette.visible = screen == Screen.BUILD
	_lidar.visible = screen == Screen.DRIVE
	if screen != Screen.DRIVE:
		_lidar.finish()
	if screen == Screen.BUILD:
		_read_timer.start()
		_set_bar("step")
	else:
		_read_timer.stop()
		_world.live = {}
	if screen == Screen.DRIVE:
		_world.mode = "drive"
		_set_bar("drive")
	_layout()
	_refresh_build()


## Which buttons the bar shows: the open step's (Robots, the step's own action,
## Next or Go), or those of what is going on (a wheel's question, the field,
## driving).
func _set_bar(mode: String) -> void:
	_bar_mode = mode
	var shown: Array = {
		"wheels_question": ["cancel", "again", "not_wheel"],
		"wheels_direction": ["cancel", "again", "forward", "backward"],
		"field": ["done"],
		"countdown": ["stop"],
		"drive": ["stop"],
	}.get(mode, [])
	if mode == "step":
		shown = {
			"wheels": ["back", "start_check", "next"],
			"go": ["back", "go"],
		}.get(_step, ["back", "next"])
	for id in _buttons:
		_show_button(_buttons[id], shown.has(id))
	_order_bar()
	_slider_box.visible = mode == "step" and _step == "size"
	_indicators.visible = mode == "drive"
	if mode == "drive":
		for caption in _indicators.get_children():
			if caption is Label:
				caption.text = RobotLabels.actuator(str(caption.name))
	if mode != "step":
		_hint.add_theme_color_override("font_color", INTRO_COLOR)
	_world.mode = "wheels" if mode.begins_with("wheels_") else ("drive" if mode in ["drive", "countdown"] else "build")
	_show_field = (mode == "field") or (screen == Screen.DRIVE and _needs("field"))
	_field.visible = _show_field
	_field.editable = mode == "field"
	_world.visible = mode != "field" and screen != Screen.DRIVE
	_layout()


## A block button moves into a wrapper at the end of the bar once it is mounted,
## so the length slider and the indicators are put back between the buttons:
## the slider after "Robots", the indicators before Stop.
func _order_bar() -> void:
	var back: Control = _buttons["back"]._wrapped_in
	var stop: Control = _buttons["stop"]._wrapped_in
	if back.get_parent() == _bar:
		_bar.move_child(_slider_box, -1)
		_bar.move_child(_slider_box, back.get_index() + 1)
	if stop.get_parent() == _bar:
		_bar.move_child(_indicators, -1)
		_bar.move_child(stop, -1)


## A mounted block button lives in a wrapper (UIAdapter.mount): the wrapper is
## what takes room in the bar, so it is hidden with the button.
func _show_button(button: BlockComponent, shown: bool) -> void:
	button.visible = shown
	if button._wrapped_in != button and is_instance_valid(button._wrapped_in):
		button._wrapped_in.visible = shown


## One decimal, with the decimal comma Russian and Kazakh use.
static func decimal(value: float) -> String:
	return ("%.1f" % value).replace(".", "," if glob.get_lang() != "en" else ".")


static func metres(value: float) -> String:
	return say({"en": "%s m", "ru": "%s м", "kz": "%s м"}) % decimal(value)


func _cm_text(size_cm: float) -> String:
	return say({"en": "%s cm", "ru": "%s см", "kz": "%s см"}) % decimal(size_cm)


func _hint_set(texts: Dictionary, color: Color = INTRO_COLOR, args: Array = []) -> void:
	_hint_texts = texts
	_hint_args = args
	_hint_show(say(texts) % args if not args.is_empty() else say(texts), color)


## Says a text over the drawing, in as many lines as it needs at this width.
func _hint_show(text: String, color: Color = INTRO_COLOR) -> void:
	_hint_full = text
	_hint.text = text
	_hint.add_theme_color_override("font_color", color)
	_layout()


func set_button_enabled(button: BlockComponent, enabled: bool) -> void:
	if not is_instance_valid(button):
		return
	if enabled:
		button.unblock_input()
		button.modulate = Color.WHITE
		button.scaler.modulate = Color.WHITE
	else:
		button.block_input()
		button.modulate = Color(1.0, 1.0, 1.0, 0.42)
		button.scaler.modulate = Color(1.0, 1.0, 1.0, 0.42)


func _set_message(text: String, color: Color = INTRO_COLOR) -> void:
	_message_label.visible = not text.is_empty()
	_message_label.text = text
	_message_label.add_theme_color_override("font_color", color)


# -- the model -------------------------------------------------------------------------------

func _blocked() -> bool:
	return model.has("blocked") and model["blocked"] != null


func _issue_texts(code: String) -> Dictionary:
	for issue in model.get("issues", []):
		if str(issue.get("code", "")) == code:
			return issue.get("texts", {})
	return {}


func _unsupported_inputs() -> Array:
	for issue in model.get("issues", []):
		if str(issue.get("code", "")) == "unsupported_inputs":
			return issue.get("neurons", [])
	return []


func _output_index(actuator: String) -> int:
	for neuron in model.get("outputs", []):
		if str(neuron.get("actuator_id", "")) == actuator:
			return int(neuron["index"])
	return -1


func _needs(need: String) -> bool:
	return model.get("needs", []).has(need)


## The network's inputs are all ones a robot can feed, and it steers and drives.
func _can_drive() -> bool:
	return not model.is_empty() and not _blocked() and _unsupported_inputs().is_empty() \
		and _output_index("steering") >= 0 and _output_index("throttle") >= 0


func _load_model() -> void:
	contract = RobotModelContract.collect()
	if not debug_model_path.is_empty():
		contract["model_path"] = debug_model_path
		contract["model_ready"] = true
	if not debug_dataset.is_empty():
		contract["dataset_meta"] = RobotModelContract.slim_meta(debug_dataset)
		contract["input_width"] = int(debug_dataset.get("inputs", {}).get("x", 0))
		contract["output_width"] = int(debug_dataset.get("outputs", [{}])[0].get("x", 0))
		contract["world"] = debug_dataset.get("metadata", {}).get("world", {})
		contract["world_source"] = "dataset"
	var answer: Dictionary = await client.call_command("describe_model", {
		"dataset_meta": contract["dataset_meta"],
		"input_width": contract["input_width"],
		"output_width": contract["output_width"],
		"model_ready": contract["model_ready"],
		"model_path": contract["model_path"],
	})
	model = answer.get("result", {}) if answer.get("ok", false) else {}
	_show_model_message()


func _show_model_message() -> void:
	if _blocked():
		_set_message(RobotText.pick(model["blocked"].get("texts")), BAD_COLOR)
		return
	for issue in model.get("issues", []):
		_set_message(RobotText.pick(issue.get("texts")), BAD_COLOR)
		return
	_set_message("")


# -- the scale: everything from the robot's length ------------------------------------------------

func robot_length_cm() -> float:
	var saved: Variant = geometry.get("length_cm")
	if saved != null and float(saved) > 0.0:
		return float(saved)
	return float(RobotArtData.base(str(robot.get("platform", ""))).get("length_cm", 14.0))


func _world_info() -> Dictionary:
	return contract.get("world", {})


func _agent_length_units() -> float:
	var agent_size: Variant = _world_info().get("agent_size")
	if agent_size is Array and agent_size.size() >= 1 and float(agent_size[0]) > 0.0:
		return float(agent_size[0])
	return ROVER_LENGTH_UNITS


## Centimetres in the room per simulation unit: the rover is as long as the robot.
func cm_per_unit() -> float:
	return robot_length_cm() / _agent_length_units()


func ray_reach_cm() -> float:
	return RAY_DISTANCE_UNITS * cm_per_unit()


func _wheel_diameter_cm() -> float:
	var saved: Variant = geometry.get("wheel_diameter_cm")
	if saved != null and float(saved) > 0.0:
		return float(saved)
	return float(RobotArtData.base(str(robot.get("platform", ""))).get("wheel_diameter_cm", 5.6))


func _track_cm() -> float:
	var saved: Variant = geometry.get("track_cm")
	if saved != null and float(saved) > 0.0:
		return float(saved)
	return float(RobotArtData.base(str(robot.get("platform", ""))).get("track_cm", 12.0))


func _gyro_port() -> String:
	for port in robot.get("ports", []):
		if str(port.get("device", "")) == "gyro":
			return str(port.get("id", ""))
	return ""


func _heading_source() -> String:
	var saved := str(geometry.get("heading", ""))
	if saved == "wheels" or (not saved.is_empty() and saved == _gyro_port()):
		return saved
	return _gyro_port() if not _gyro_port().is_empty() else "wheels"


func _drive_sides() -> Dictionary:
	var sides: Variant = geometry.get("drive_sides")
	if sides is Dictionary and not sides.get("left", []).is_empty() and not sides.get("right", []).is_empty():
		return sides
	return {}


# -- robots ------------------------------------------------------------------------------------

func _start_session_and_scan() -> void:
	_scan_label.text = "Looking for robots..."
	if client == null:
		client = RobotSessionClient.new()
		client.name = "RobotSessionClient"
		add_child(client)
		client.event_received.connect(_on_event)
		_session_failed = not await client.start()
		if _session_failed:
			_set_message(client.last_error, BAD_COLOR)
			return
	await _load_model()
	await _scan(FIRST_SCAN_S)
	if _opened and not connecting:
		await _scan(FULL_SCAN_S)


func _scan(seconds: float) -> void:
	if scanning or client == null:
		return
	scanning = true
	_scan_label.text = "Looking for robots..."
	var answer: Dictionary = await client.call_command("scan", {"seconds": seconds, "profiles": true}, seconds + 30.0)
	scanning = false
	if not _opened or client == null:
		return
	if not answer.get("ok", false):
		_set_message(str(answer.get("error", {}).get("message", "")), BAD_COLOR)
		return
	var result: Dictionary = answer["result"]
	robots = result.get("robots", [])
	_grid.set_robots(_visible_robots())
	if seconds >= FULL_SCAN_S:
		_scan_label.text = "Pick your robot" if not robots.is_empty() else "No robots nearby. Turn the robot on and press Refresh."
	if not robot.is_empty():
		var card := _grid.card_for(str(robot.get("robot_id", "")))
		if card != null:
			card.set_mode("connected")


## Last used first, then nearest; robots without a measured distance after those.
func _visible_robots() -> Array:
	var list := robots.duplicate()
	list.sort_custom(func(a, b):
		var last_a := bool(a.get("last_used", false))
		var last_b := bool(b.get("last_used", false))
		if last_a != last_b:
			return last_a
		var da := _distance_of(a)
		var db := _distance_of(b)
		if da != db:
			return da < db
		return str(a.get("name", "")) < str(b.get("name", "")))
	return list


func _distance_of(item: Dictionary) -> float:
	var proximity: Variant = item.get("proximity")
	if proximity is Dictionary and proximity.get("distance_m") != null:
		return float(proximity["distance_m"])
	return 999.0


func _on_refresh_pressed() -> void:
	if connecting or scanning or client == null:
		return
	_scan(FULL_SCAN_S)


func _on_robot_chosen(robot_id: String) -> void:
	if connecting:
		return
	if not robot.is_empty() and str(robot.get("robot_id", "")) == robot_id:
		_open_build()
		return
	if not robot.is_empty():
		await _disconnect()
	_connect(robot_id)


func _connect(robot_id: String) -> void:
	var chosen := {}
	for item in robots:
		if str(item.get("robot_id", "")) == robot_id:
			chosen = item
	if chosen.is_empty():
		return
	var card := _grid.card_for(robot_id)
	var pin := "1234"
	if str(chosen.get("platform", "")) == "ev3_direct" and not bool(chosen.get("paired", false)):
		var answer: Dictionary = await _ask_in_place(_pin_dialog_spec(str(chosen.get("name", ""))))
		if str(answer.get("action", "")) != "connect":
			return
		pin = str(answer.get("values", {}).get("pin", "1234")).strip_edges()
		if pin.is_empty():
			pin = "1234"
	connecting = true
	busy_changed.emit(true)
	_set_message("")
	if card != null:
		card.set_mode("busy", RobotText.t("stage_connecting"))
	# The session does one thing at a time: let a scan that is still going finish.
	while scanning and _opened:
		await get_tree().process_frame
	if not _opened or client == null:
		connecting = false
		return
	var args := {"robot_id": robot_id, "pin": pin}
	args.merge(connect_extra)
	var reply: Dictionary = await client.call_command("connect", args, 180.0)
	connecting = false
	busy_changed.emit(false)
	if not _opened or client == null:
		return
	if not reply.get("ok", false):
		var message := _error_text(reply.get("error", {}))
		if card != null:
			card.set_mode("error", message)
		_set_message(message, BAD_COLOR)
		return
	robot = reply["result"]["robot"]
	geometry = robot.get("geometry", {}).duplicate(true)
	if card != null:
		card.set_mode("connected")
	for warning in reply["result"].get("warnings", []):
		if str(warning) == "low_battery":
			_set_message(RobotText.t("low_battery"), BAD_COLOR)
	await _load_mapping()
	_open_build()


## The PIN dialog, opened the way the app opens a window from inside another:
## the Export window steps aside keeping the blur, the dialog is nested, and the
## Export window comes back (workslist.gd, _hide_for_child_menu).
func _ask_in_place(spec: Dictionary) -> Dictionary:
	var host := _host_window()
	if host != null:
		host.hide_for_child()
		await host.quitting
	spec["inner"] = true
	for button in spec.get("buttons", []):
		button["can_go"] = false
	var dialog = ui.show_dialog(spec)
	if not is_instance_valid(dialog):
		if host != null:
			host.restore_from_child()
		return {}
	dialog.can_tween_zero = false
	var result: Dictionary = await dialog.wait_for_result()
	if is_instance_valid(dialog):
		await dialog.tree_exited
	if host != null:
		host.restore_from_child()
	return result


func _host_window() -> SplashMenu:
	var node := get_parent()
	while node != null and not node is SplashMenu:
		node = node.get_parent()
	return node as SplashMenu


func _open_build() -> void:
	_world.platform = str(robot.get("platform", ""))
	_field.platform = _world.platform
	_world.load_geometry(geometry)
	_world.wheels = _wheel_ports(_drive_sides())
	_world.reach_cm = ray_reach_cm()
	_field.load_world(_world_info(), cm_per_unit(), mapping.get("field", {}))
	_show(Screen.BUILD)
	_go_step(_first_open_step())


func _wheel_ports(sides: Dictionary) -> Dictionary:
	var result := {}
	for side in sides:
		result[side] = sides[side].map(func(m): return str(m["port"]))
	return result


func _disconnect() -> void:
	halt()
	if client != null:
		await client.call_command("disconnect", {}, 20.0)
	var old_id := str(robot.get("robot_id", ""))
	robot = {}
	geometry = {}
	var card := _grid.card_for(old_id)
	if card != null:
		card.set_mode("")


func _on_back_pressed() -> void:
	if not is_driving():
		_show(Screen.ROBOTS)


func _error_text(error: Dictionary) -> String:
	var texts: Variant = error.get("texts")
	if texts is Dictionary:
		var code := RobotText.lang()
		var entry: Dictionary = texts.get(code, texts.get("ru", texts.get("en", {})))
		var message := str(entry.get("message", error.get("message", "")))
		var fix := str(entry.get("fix", ""))
		return message if fix.is_empty() else message + " " + fix
	return str(error.get("message", ""))


func _pin_dialog_spec(robot_name: String) -> Dictionary:
	return {
		"id": "robot_pin",
		"title": {"ru": RobotText.tf("pin_title", [robot_name]), "en": RobotText.tf("pin_title", [robot_name]), "kz": RobotText.tf("pin_title", [robot_name])},
		"body": RobotText.t("pin_body"),
		"icon_path": "res://game_assets/icons/lock.png",
		"size": {"width": 520, "height": 330},
		"fields": [{"id": "pin", "type": "text", "label": RobotText.t("pin_field"), "value": "1234", "required": true}],
		"buttons": [
			{"id": "cancel", "text": RobotText.t("cancel"), "style": "secondary"},
			{"id": "connect", "text": RobotText.t("pin_go"), "style": "primary"},
		],
	}


# -- the checklist -----------------------------------------------------------------------------

const DEVICE_NAMES := {
	"ultrasonic": {"en": "Distance sensor", "ru": "Датчик расстояния", "kz": "Қашықтық датчигі"},
	"gyro": {"en": "Gyro", "ru": "Гироскоп", "kz": "Гироскоп"},
}
const WHEELS_WORD := {"en": "wheels", "ru": "колёса", "kz": "доңғалақтар"}
const STEP_TITLES := {
	"sensors": {"en": "Sensors", "ru": "Датчики", "kz": "Датчиктер"},
	"settings": {"en": "Settings", "ru": "Настройки", "kz": "Баптаулар"},
	"wheels": {"en": "Wheels", "ru": "Колёса", "kz": "Доңғалақтар"},
	"size": {"en": "Size", "ru": "Размер", "kz": "Өлшем"},
	"go": {"en": "Start", "ru": "Запуск", "kz": "Іске қосу"},
}
## What to do in a step, under its title. The palette breaks the lines to its
## width; the sentences name what the child sees: the buttons, the drawing, and
## the real robot on the table.
const STEP_NOTES := {
	"sensors": {
		"en": "In the simulation the car saw obstacles. A real robot sees them with distance sensors. Drag the sensor pictures onto the robot drawing, to the same places the sensors sit on your robot. The number is the port the sensor's cable is plugged into.",
		"ru": "В симуляции машинка видела препятствия. Настоящий робот видит их датчиками расстояния. Перетащите картинки датчиков на рисунок робота — туда же, где датчики стоят на вашем роботе. Цифра — это порт, в который вставлен провод датчика.",
		"kz": "Симуляцияда машина кедергілерді көрді. Нақты робот оларды қашықтық датчиктерімен көреді. Датчик суреттерін робот суретіне сүйреңіз — датчиктер сіздің роботыңызда қай жерде тұрса, сол жерге. Сан — датчик сымы қосылған порт.",
	},
	"settings": {
		"en": "Below is what else the car knew in the simulation. A real robot works it out itself, without sensors: it counts how many turns its wheels have made.",
		"ru": "Ниже написано, что ещё машинка знала в симуляции. Настоящий робот узнаёт это сам, без датчиков: он считает, сколько оборотов сделали его колёса.",
		"kz": "Төменде машинаның симуляцияда тағы не білгені жазылған. Нақты робот мұны датчиксіз өзі біледі: доңғалақтарының қанша айналғанын санайды.",
	},
	"wheels": {
		"en": "Lift your robot so its wheels are off the table and press “Check the wheels”. The motors will turn a little one by one, and you will show on the drawing which wheel turned and which way.",
		"ru": "Поднимите вашего робота, чтобы колёса не касались стола, и нажмите «Проверить колёса». Моторы по очереди немного покрутятся, а вы покажете на рисунке, какое колесо крутилось и в какую сторону.",
		"kz": "Доңғалақтары үстелге тимейтіндей етіп роботыңызды көтеріп, «Доңғалақтарды тексеру» түймесін басыңыз. Моторлар кезекпен сәл айналады, ал сіз суретте қай доңғалақ қай жаққа айналғанын көрсетесіз.",
	},
	"size": {
		"en": "Measure your robot with a ruler, from its front edge to its back edge, and set the length with the slider below.",
		"ru": "Измерьте линейкой длину вашего робота — от переднего края до заднего — и выставьте её ползунком внизу.",
		"kz": "Роботыңыздың ұзындығын сызғышпен алдыңғы шетінен артқы шетіне дейін өлшеп, төмендегі жүгірткімен қойыңыз.",
	},
}
## Sentences added to a step's note when the step shows the button they name
## (%s is the button's words).
const STEP_EXTRA := {
	"field": {
		"en": "The robot cannot know by itself where the goal is. Press the “%s” button and show on the field where the robot starts from.",
		"ru": "Где цель, робот сам не знает. Нажмите кнопку «%s» и покажите на поле, откуда робот поедет к цели.",
		"kz": "Мақсаттың қай жерде екенін робот өзі білмейді. «%s» түймесін басып, робот мақсатқа қайдан жүретінін алаңда көрсетіңіз.",
	},
	"gyro": {
		"en": "Right now the robot notices its turns with the gyro. Press the “%s” button to count them by the wheels instead.",
		"ru": "Повороты робот сейчас замечает гироскопом. Нажмите кнопку «%s», если хотите, чтобы он считал их по колёсам.",
		"kz": "Қазір робот бұрылыстарын гироскоппен біледі. Оларды доңғалақтар арқылы санасын десеңіз, «%s» түймесін басыңыз.",
	},
	"wheels_heading": {
		"en": "Right now the robot counts its turns by the wheels. Press the “%s” button to notice them with the gyro instead.",
		"ru": "Повороты робот сейчас считает по колёсам. Нажмите кнопку «%s», если хотите, чтобы он замечал их гироскопом.",
		"kz": "Қазір робот бұрылыстарын доңғалақтар арқылы санайды. Гироскоппен білсін десеңіз, «%s» түймесін басыңыз.",
	},
	"nothing": {
		"en": "There is nothing to do here: press “Next”.",
		"ru": "Здесь ничего делать не нужно — нажмите «Далее».",
		"kz": "Мұнда ештеңе істеудің қажеті жоқ — «Келесі» түймесін басыңыз.",
	},
	"wheel_size": {
		"en": "If your robot's wheels are a different size, press the “%s” button until the right size shows.",
		"ru": "Если колёса у робота другого размера, нажимайте кнопку «%s», пока не появится нужный.",
		"kz": "Роботтың доңғалақтары басқа өлшемде болса, керекті өлшем шыққанша «%s» түймесін басыңыз.",
	},
	"go_field": {
		"en": "Put the robot on the floor the way it stands on the field and press “Start”.",
		"ru": "Поставьте робота на пол так же, как он стоит на поле, и нажмите «Запустить».",
		"kz": "Роботты алаңда қалай тұрса, еденге солай қойып, «Іске қосу» түймесін басыңыз.",
	},
	"go": {
		"en": "Put the robot on the floor and press “Start”.",
		"ru": "Поставьте робота на пол и нажмите «Запустить».",
		"kz": "Роботты еденге қойып, «Іске қосу» түймесін басыңыз.",
	},
	"stop": {
		"en": "To stop the robot, press “Stop” or Space.",
		"ru": "Чтобы остановить робота, нажмите «Стоп» или пробел.",
		"kz": "Роботты тоқтату үшін «Тоқтату» түймесін немесе бос орын пернесін басыңыз.",
	},
}
const WHEEL_SIZE_WORDS := {"en": "Wheel size", "ru": "Диаметр колёс", "kz": "Доңғалақ диаметрі"}
const CANNOT_DRIVE := {
	"en": "This model cannot drive the robot: the car in Brain Mapping needs “%s” and “%s” turned on.",
	"ru": "Эта модель не умеет вести робота: у машинки в Brain Mapping должны быть включены «%s» и «%s».",
	"kz": "Бұл модель роботты жүргізе алмайды: Brain Mapping-те машинаның «%s» және «%s» қосулы болуы керек.",
}


## A step's note: what to do, with the sentences about the buttons it shows.
func _step_note(step: String) -> String:
	var parts: Array = []
	if STEP_NOTES.has(step):
		parts.append(say(STEP_NOTES[step]))
	match step:
		"settings":
			var pressable := false
			for group in _step_groups(step):
				if not bool(group.get("supported", false)):
					continue
				var needs: Array = group.get("needs", [])
				var words := RobotLabels.group(group, false)
				if needs.has("field"):
					parts.append(say(STEP_EXTRA["field"]) % words)
					pressable = true
				elif needs.has("heading") and not _gyro_port().is_empty():
					parts.append(say(STEP_EXTRA["gyro" if _heading_source() != "wheels" else "wheels_heading"]) % words)
					pressable = true
			if not pressable:
				parts.append(say(STEP_EXTRA["nothing"]))
		"size":
			if _needs("wheels") or _needs("field"):
				parts.append(say(STEP_EXTRA["wheel_size"]) % say(WHEEL_SIZE_WORDS))
		"go":
			parts.append(say(STEP_EXTRA["go_field" if _needs("field") else "go"]))
			parts.append(say(STEP_EXTRA["stop"]))
	return "\n".join(parts)


func _refresh_build() -> void:
	if screen != Screen.BUILD:
		return
	_palette.show_rows(_checklist())
	set_button_enabled(_buttons["go"], _missing().is_empty())
	set_button_enabled(_buttons["next"], _step_done(_step) or _step == "size")
	if _bar_mode == "step":
		_show_missing()


## The steps of getting a robot ready, in the order they are done. The sensors
## step is there when the network has rays (or inputs no robot can feed), the
## settings step when it takes anything else: speed, rotation, its place, the goal.
func _steps() -> Array:
	var steps: Array = []
	if not _step_groups("sensors").is_empty():
		steps.append("sensors")
	if not _step_groups("settings").is_empty():
		steps.append("settings")
	steps.append_array(["wheels", "size", "go"])
	return steps


## The network's input groups listed in a step.
func _step_groups(step: String) -> Array:
	var result: Array = []
	for group in model.get("input_groups", []):
		var from_sensors: bool = group.get("needs", []).has("sensors") or not bool(group.get("supported", false))
		if (step == "sensors") == from_sensors:
			result.append(group)
	return result


func _step_done(step: String) -> bool:
	match step:
		"sensors":
			return not _world.sensors.is_empty()
		"settings":
			return not _needs("field") or bool(mapping.get("field_set", false))
		"wheels":
			return not _drive_sides().is_empty()
		"size":
			return geometry.get("length_cm") != null
	return false


func _first_open_step() -> String:
	for step in _steps():
		if not _step_done(step):
			return step
	return "go"


func _go_step(step: String) -> void:
	_step = step if _steps().has(step) else _first_open_step()
	if _step == "size":
		_slider.set_value_no_signal(robot_length_cm())
		_slider_value.text = _cm_text(robot_length_cm())
	_hint_set({})
	_set_bar("step")
	_refresh_build()


## The checklist: every step's title with a tick once it is done; the open step
## also says what to do and lists what it is about.
func _checklist() -> Array:
	var sections: Array = []
	var steps := _steps()
	for index in steps.size():
		var step: String = steps[index]
		var done := _step_done(step)
		var current: bool = step == _step
		var accent := SENSOR_ACCENT if current else (OK_COLOR if done else RobotPaletteRow.DIM_COLOR)
		sections.append({
			"id": "step:" + step,
			"title": "%d. %s" % [index + 1, say(STEP_TITLES[step])],
			"accent": accent,
			"state": "ok" if done else "",
			"current": current,
			"note": _step_note(step) if current else "",
			"rows": _step_rows(step) if current else [],
		})
	return sections


func _step_rows(step: String) -> Array:
	var rows: Array = []
	match step:
		"sensors", "settings":
			for group in _step_groups(step):
				rows.append(_input_row(group))
				if str(group.get("sensor_id", "")) == "ray_distance":
					rows.append(_sensor_tiles())
		"wheels":
			for group in model.get("output_groups", []):
				var state := "off"
				if bool(group.get("supported", false)) and not bool(group.get("ignored", false)):
					state = "ok" if _step_done("wheels") else "missing"
				rows.append({
					"id": "output:%d" % int(group.get("start", 0)),
					"text": RobotLabels.group(group, true),
					"accent": RobotLabels.group_accent(group, true),
					"count": int(group.get("length", 1)),
					"state": state,
				})
		"size":
			if _needs("wheels") or _needs("field"):
				rows.append({
					"id": "wheel_size",
					"text": say(WHEEL_SIZE_WORDS) + " " + _cm_text(_wheel_diameter_cm()),
					"accent": RobotArtData.tint(),
					"pressable": true,
				})
	return rows


## A network input under its Brain Mapping name. Where the robot gets it from
## is added when a press changes it (gyro or wheels); a press on a goal input
## opens the field, which the step's note says.
func _input_row(group: Dictionary) -> Dictionary:
	var needs: Array = group.get("needs", [])
	var text := RobotLabels.group(group, false)
	var state := "off"
	var pressable := false
	if bool(group.get("supported", false)):
		state = "ok"
		if needs.has("sensors") and _world.sensors.is_empty():
			state = "missing"
		if needs.has("field"):
			pressable = true
			if not bool(mapping.get("field_set", false)):
				state = "missing"
		elif needs.has("heading") and not _gyro_port().is_empty():
			text += " · " + (say(DEVICE_NAMES["gyro"]) if _heading_source() != "wheels" else say(WHEELS_WORD))
			pressable = true
	return {
		"id": "input:%d" % int(group.get("start", 0)),
		"text": text,
		"accent": RobotLabels.group_accent(group, false),
		"count": int(group.get("length", 1)),
		"state": state,
		"pressable": pressable,
	}


## The robot's distance sensors, to drag onto the drawing; a press puts one on
## the first free spot or takes it off.
func _sensor_tiles() -> Dictionary:
	var platform := str(robot.get("platform", ""))
	var parts: Array = []
	for port in robot.get("ports", []):
		if str(port.get("device", "")) != "ultrasonic":
			continue
		var id := str(port.get("id", ""))
		parts.append({
			"id": "part:" + id,
			"text": "",
			"picture": RobotArtData.sensor_texture(platform, true),
			"port": RobotWorld._port_label(id),
			"state": "ok" if _world.sensors.has(id) else "",
			"part": {"port": id, "kind": "sensor", "device": "ultrasonic"},
			"pressable": true,
		})
	if parts.is_empty():
		return {"id": "no_sensors", "text": say({"en": "The robot has no distance sensors", "ru": "У робота нет датчиков расстояния", "kz": "Роботта қашықтық датчиктері жоқ"}), "state": "missing"}
	return {"id": "parts:sensors", "parts": parts}


## What still has to be done before Go, first thing first.
func _missing() -> Array:
	var result: Array = []
	if not _can_drive():
		result.append("model")
		return result
	if _needs("sensors") and _world.sensors.is_empty():
		result.append("sensors")
	if _needs("field") and not bool(mapping.get("field_set", false)):
		result.append("settings")
	if _drive_sides().is_empty():
		result.append("wheels")
	return result


## The hint over the drawing says why Go cannot be pressed: the network cannot
## drive at all, or (on the last step) which step is not done yet.
func _show_missing() -> void:
	var missing := _missing()
	if missing.has("model") and _blocked():
		_hint_set(model["blocked"].get("texts", {}), BAD_COLOR)
	elif missing.has("model") and not _unsupported_inputs().is_empty():
		_hint_set(_issue_texts("unsupported_inputs"), BAD_COLOR)
	elif missing.has("model"):
		_hint_set(CANNOT_DRIVE, BAD_COLOR, [RobotLabels.actuator("steering"), RobotLabels.actuator("throttle")])
	elif _step == "go" and not missing.is_empty():
		_hint_set({"en": "Step “%s” is not done", "ru": "Сначала пройдите шаг «%s»", "kz": "«%s» қадамы орындалмады"}, BAD_COLOR, [say(STEP_TITLES[missing[0]])])


func _on_part_requested(part: Dictionary) -> void:
	if str(part.get("kind", "")) == "sensor":
		if _world.sensors.has(str(part["port"])):
			_world.remove_sensor(str(part["port"]))
		else:
			_world.put_sensor_default(str(part["port"]))


func _on_row_pressed(id: String) -> void:
	if is_driving() or not _check_port.is_empty() or _bar_mode != "step":
		return
	if id.begins_with("step:"):
		_go_step(id.substr(5))
	elif id == "wheel_size":
		var at := WHEEL_SIZES_CM.find(_wheel_diameter_cm())
		geometry["wheel_diameter_cm"] = WHEEL_SIZES_CM[(at + 1) % WHEEL_SIZES_CM.size()]
		_save_timer.start()
		_refresh_build()
	elif id.begins_with("input:"):
		var needs: Array = _input_group(int(id.substr(6))).get("needs", [])
		if needs.has("field"):
			_open_field()
		elif needs.has("heading") and not _gyro_port().is_empty():
			geometry["heading"] = "wheels" if _heading_source() != "wheels" else _gyro_port()
			_save_timer.start()
			_refresh_build()


func _input_group(start: int) -> Dictionary:
	for group in model.get("input_groups", []):
		if int(group.get("start", -1)) == start:
			return group
	return {}


func _on_world_changed() -> void:
	geometry["sensors"] = _world.sensors_geometry()
	_refresh_build()
	_save_timer.start()


func _save_now() -> void:
	if client == null or not client.alive or robot.is_empty():
		return
	geometry["wheel_diameter_cm"] = _wheel_diameter_cm()
	geometry["track_cm"] = _track_cm()
	var answer: Dictionary = await client.call_command("save_profile", {"robot": {"geometry": geometry}}, 15.0)
	if answer.get("ok", false):
		robot = answer["result"]["robot"]


func _read_tick() -> void:
	if _reading or client == null or screen != Screen.BUILD or _world.sensors.is_empty() or not _check_port.is_empty():
		return
	var channels: Array = []
	for port in _world.sensors:
		channels.append(str(port) + ".distance_mm")
	_reading = true
	var answer: Dictionary = await client.call_command("read", {"channels": channels}, 10.0)
	_reading = false
	if screen != Screen.BUILD or not answer.get("ok", false):
		return
	var live := {}
	var values: Dictionary = answer["result"].get("values", {})
	for channel in values:
		live[str(channel).get_slice(".", 0)] = int(values[channel])
	_world.live = live
	_world.queue_redraw()


# -- the robot's length, Next, the wheel check -------------------------------------------------------

func _on_length_changed(value: float) -> void:
	_slider_value.text = _cm_text(value)
	if _bar_mode == "step" and _step == "size":
		geometry["length_cm"] = value
		_world.reach_cm = ray_reach_cm()
		_field.load_world(_world_info(), cm_per_unit(), _field.to_saved())
		_world.queue_redraw()
		_save_timer.start()
		_refresh_build()


## Next: the open step is done, on to the one after it. On the size step it
## also keeps the length the slider shows, even if it was not moved.
func _on_next_pressed() -> void:
	if _step == "size" and geometry.get("length_cm") == null:
		geometry["length_cm"] = _slider.value
		_save_timer.start()
	if not _step_done(_step):
		return
	var steps := _steps()
	_go_step(steps[mini(steps.find(_step) + 1, steps.size() - 1)])


func _on_done_pressed() -> void:
	if _bar_mode == "field":
		mapping["field"] = _field.to_saved()
		mapping["field_set"] = true
		save_mapping()
	_go_step(_step)


func _on_cancel_pressed() -> void:
	_check_queue = []
	_check_port = ""
	_check_side = ""
	_world.picked_side = ""
	_go_step(_step)


## The wheel check: every motor turns a little, one at a time, and for each
## the child answers two plain questions: which wheel turned (press it on the
## drawing), and would it take the robot forward or back (two buttons). That
## gives which motors drive, on which side, and which are mounted the other way.
func _on_start_check_pressed() -> void:
	_check_queue = []
	for port in robot.get("ports", []):
		if str(port.get("device", "")).ends_with("motor"):
			_check_queue.append(str(port.get("id", "")))
	_check_sides = {"left": [], "right": []}
	_next_motor()


func _next_motor() -> void:
	if _check_queue.is_empty():
		_finish_wheel_check()
		return
	_check_port = str(_check_queue.pop_front())
	_spin_current()


func _spin_current() -> void:
	_check_side = ""
	_world.picked_side = ""
	_hint_set({
		"en": "Motor %s has just turned a wheel. Press that wheel on the robot drawing. If nothing turned, press “Skip”.",
		"ru": "Мотор %s только что покрутил колесо. Нажмите на это колесо на рисунке робота. Если ничего не крутилось, нажмите «Пропустить».",
		"kz": "%s моторы жаңа ғана бір доңғалақты айналдырды. Робот суретінде сол доңғалақты басыңыз. Ештеңе айналмаса, «Өткізу» түймесін басыңыз.",
	}, INTRO_COLOR, [RobotWorld._port_label(_check_port)])
	_set_bar("wheels_question")
	_spin()


func _spin() -> void:
	if client != null and not _check_port.is_empty():
		client.call_command("spin_motor", {"channel": _check_port + ".power", "power": SPIN_POWER, "seconds": SPIN_SECONDS}, 30.0)


func _on_again_pressed() -> void:
	_spin()


func _on_not_wheel_pressed() -> void:
	_next_motor()


func _on_wheel_picked(side: String) -> void:
	if _check_port.is_empty():
		return
	_check_side = side
	_world.picked_side = side
	_hint_set({
		"en": "If the robot stood on the floor, would this wheel take it forwards or backwards?",
		"ru": "Если поставить робота на пол, это колесо повезёт его вперёд или назад?",
		"kz": "Робот еденде тұрса, бұл доңғалақ оны алға апарар ма еді, әлде артқа ма?",
	})
	_set_bar("wheels_direction")


func _on_direction(forward: bool) -> void:
	if _check_port.is_empty() or _check_side.is_empty():
		return
	_check_sides[_check_side].append({"port": _check_port, "invert": not forward})
	_next_motor()


func _finish_wheel_check() -> void:
	_check_port = ""
	_check_side = ""
	_world.picked_side = ""
	if _check_sides["left"].is_empty() or _check_sides["right"].is_empty():
		_go_step("wheels")
		_hint_set({
			"en": "There must be a wheel with a motor on the left and on the right. Check the wheels again.",
			"ru": "Колёса с моторами должны быть и слева, и справа. Проверьте колёса ещё раз.",
			"kz": "Моторлы доңғалақтар сол жақта да, оң жақта да болуы керек. Доңғалақтарды қайта тексеріңіз.",
		}, BAD_COLOR)
		return
	geometry["drive_sides"] = _check_sides.duplicate(true)
	geometry["drive"] = {
		"left_port": _check_sides["left"][0]["port"],
		"right_port": _check_sides["right"][0]["port"],
		"invert_left": _check_sides["left"][0]["invert"],
		"invert_right": _check_sides["right"][0]["invert"],
	}
	_world.wheels = _wheel_ports(_check_sides)
	_save_timer.start()
	var steps := _steps()
	_go_step(steps[steps.find("wheels") + 1])


# -- the field ------------------------------------------------------------------------------------

func _open_field() -> void:
	_field.load_world(_world_info(), cm_per_unit(), mapping.get("field", {}))
	_set_bar("field")
	_update_field_caption()


func _on_field_changed() -> void:
	_update_field_caption()


func _update_field_caption() -> void:
	if not _field.has_goal:
		_hint_set({"en": "Drag the robot on the field to where it starts.", "ru": "Перетащите робота на поле туда, откуда он поедет.", "kz": "Роботты алаңда ол жүретін жерге сүйреңіз."})
		return
	var to_goal := _field.goal_from_start_m()
	var ahead := absf(to_goal.x)
	var side := absf(to_goal.y)
	var ahead_word := say({"en": "ahead", "ru": "вперёд", "kz": "алға"}) if to_goal.x >= 0.0 else say({"en": "behind", "ru": "назад", "kz": "артқа"})
	var side_word := say({"en": "to the right", "ru": "вправо", "kz": "оңға"}) if to_goal.y >= 0.0 else say({"en": "to the left", "ru": "влево", "kz": "солға"})
	# A way that rounds to 0,0 m is left out rather than said.
	var ways := PackedStringArray()
	if ahead >= 0.05 or side < 0.05:
		ways.append(metres(ahead) + " " + ahead_word)
	if side >= 0.05:
		ways.append(metres(side) + " " + side_word)
	_hint_set({
		"en": "The goal is %s of the robot. Drag the robot to change where it starts.",
		"ru": "Цель — %s от робота. Перетащите робота, чтобы поменять, откуда он поедет.",
		"kz": "Мақсат — роботтан %s. Робот қайдан жүретінін өзгерту үшін оны сүйреңіз.",
	}, INTRO_COLOR, [say({"en": " and ", "ru": " и ", "kz": " және "}).join(ways)])


# -- mapping persistence (per model) ------------------------------------------------------------------

func model_key() -> String:
	var name := str(model.get("dataset_name", ""))
	return name if not name.is_empty() else str(contract.get("model_name", "model"))


func _load_mapping() -> void:
	mapping = {}
	if client == null:
		return
	var answer: Dictionary = await client.call_command("load_mapping", {"key": model_key()}, 15.0)
	if answer.get("ok", false) and answer["result"].get("mapping") is Dictionary:
		mapping = answer["result"]["mapping"]


func save_mapping() -> void:
	if client != null and client.alive:
		client.call_command("save_mapping", {"key": model_key(), "mapping": mapping}, 15.0)


# -- drive ------------------------------------------------------------------------------------------

func _on_go_pressed() -> void:
	if is_driving() or not _missing().is_empty():
		return
	counting_down = true
	busy_changed.emit(true)
	_field.trail = PackedVector2Array()
	_show(Screen.DRIVE)
	_start_lidar()
	_set_bar("countdown")
	_hint_set({"en": "Get ready", "ru": "Приготовьтесь", "kz": "Дайындалыңыз"})
	_countdown.visible = true
	for second in range(COUNTDOWN_S, 0, -1):
		_countdown.text = str(second)
		await get_tree().create_timer(1.0).timeout
		if not counting_down:
			_countdown.visible = false
			return
	_countdown.visible = false
	counting_down = false
	var reply: Dictionary = await client.call_command("start", {
		"model_path": str(contract.get("model_path", "")),
		"config": build_config(),
		"max_seconds": TIME_LIMIT_S,
	}, 60.0)
	if not reply.get("ok", false):
		busy_changed.emit(false)
		_show(Screen.BUILD)
		_hint_show(_error_text(reply.get("error", {})), BAD_COLOR)
		return
	driving = true
	_set_bar("drive")
	_hint_set(STATUS_TEXTS["forward"])


func _on_stop_pressed() -> void:
	halt()


## Motors off now: the emergency stop goes around the request queue.
func halt() -> void:
	if counting_down:
		counting_down = false
		_countdown.visible = false
		busy_changed.emit(false)
		_show(Screen.BUILD)
		return
	if not driving:
		return
	if client != null:
		client.estop()


func _input(event: InputEvent) -> void:
	if not is_driving() or not is_visible_in_tree():
		return
	if event is InputEventKey and event.pressed and not event.echo and (event.keycode == KEY_SPACE or event.keycode == KEY_ESCAPE):
		halt()
		get_viewport().set_input_as_handled()


func _on_event(event: Dictionary) -> void:
	match str(event.get("event", "")):
		"stage":
			var key := "stage_" + str(event.get("stage", ""))
			var text := RobotText.t(key)
			for card in _grid.cards():
				if card.mode == "busy" and text != key:
					card.set_mode("busy", text)
		"telemetry":
			_on_telemetry(event)
		"drive_stopped":
			driving = false
			busy_changed.emit(false)
			_world.drive_powers = [0.0, 0.0]
			_show(Screen.BUILD)
			if str(event.get("reason", "")) == "time_limit":
				_hint_set({"en": "Time is up", "ru": "Время вышло", "kz": "Уақыт бітті"})
			elif str(event.get("reason", "")) == "error":
				_hint_show(_error_text(event.get("error", {})), BAD_COLOR)
		"link_lost":
			driving = false
			counting_down = false
			_check_port = ""
			busy_changed.emit(false)
			var old_id := str(robot.get("robot_id", ""))
			robot = {}
			_show(Screen.ROBOTS)
			_set_message(RobotText.t("link_lost") + " " + _error_text(event.get("error", {})), BAD_COLOR)
			var card := _grid.card_for(old_id)
			if card != null:
				card.set_mode("error", RobotText.t("link_lost"))


const STATUS_TEXTS := {
	"forward": {"en": "Driving forward", "ru": "Едет вперёд", "kz": "Алға жүріп барады"},
	"steer_left": {"en": "Turning left", "ru": "Поворачивает влево", "kz": "Солға бұрылып жатыр"},
	"steer_right": {"en": "Turning right", "ru": "Поворачивает вправо", "kz": "Оңға бұрылып жатыр"},
	"spin_left": {"en": "Spinning left", "ru": "Разворачивается влево", "kz": "Солға айналып жатыр"},
	"spin_right": {"en": "Spinning right", "ru": "Разворачивается вправо", "kz": "Оңға айналып жатыр"},
	"stop": {"en": "Standing still", "ru": "Стоит", "kz": "Тұр"},
}


func _on_telemetry(event: Dictionary) -> void:
	if screen != Screen.DRIVE:
		return
	var readings: Dictionary = event.get("readings", {})
	var live := {}
	for channel in readings:
		if str(channel).ends_with(".distance_mm"):
			live[str(channel).get_slice(".", 0)] = int(readings[channel])
	_world.live = live
	var motors: Dictionary = event.get("motors", {})
	var sides := _drive_sides()
	if not sides.is_empty():
		var left: Dictionary = sides["left"][0]
		var right: Dictionary = sides["right"][0]
		var left_power := float(motors.get(str(left["port"]) + ".power", 0.0))
		var right_power := float(motors.get(str(right["port"]) + ".power", 0.0))
		_world.drive_powers = [-left_power if bool(left["invert"]) else left_power, -right_power if bool(right["invert"]) else right_power]
	var outputs: Array = event.get("model_output", [])
	if _output_index("steering") >= 0 and _output_index("steering") < outputs.size():
		_steer_indicator.value = float(outputs[_output_index("steering")])
	if _output_index("throttle") >= 0 and _output_index("throttle") < outputs.size():
		_throttle_indicator.value = float(outputs[_output_index("throttle")])
	var pose: Variant = event.get("pose")
	if pose is Dictionary and _show_field:
		_field.trail.append(Vector2(float(pose["x"]), float(pose["y"])))
		_field.queue_redraw()
	if pose is Dictionary:
		var ranges := PackedFloat64Array()
		for port in _lidar_ports:
			ranges.append(float(readings.get(str(port) + ".distance_mm", RobotWorld.NO_ECHO_MM)) / 1000.0)
		# The odometry's pose is the simulation's (y down, turns clockwise);
		# the lidar's is the usual maths frame (y up, counter-clockwise).
		_lidar.add_frame(float(event.get("timestamp_s", 0.0)), float(pose["x_cm"]) / 100.0, -float(pose["y_cm"]) / 100.0,
				-float(pose["heading"]), ranges)
	var infos: Array = event.get("drive", [])
	if not infos.is_empty():
		_hint_set(STATUS_TEXTS.get(str(infos[0].get("status", "")), STATUS_TEXTS["forward"]))
	_world.queue_redraw()


## A new map for the lidar: the placed sensors in port order (as build_config
## lists them), each where it sits on the drawing, at the robot's length, and
## the robot's own size.
func _start_lidar() -> void:
	var metres := robot_length_cm() / _world.length_cm() / 100.0   # drawing centimetres -> metres in the room
	_lidar_ports = _world.sensors.keys()
	_lidar_ports.sort()
	var sensors: Array = []
	for port in _lidar_ports:
		var pose: Dictionary = _world.sensors[port]
		sensors.append({
			"angle": deg_to_rad(float(pose["angle_deg"])),
			"x": float(pose["x_cm"]) * metres,
			"y": float(pose["y_cm"]) * metres,
			"label": RobotWorld._port_label(str(port)),
		})
	_lidar.start(sensors, robot_length_cm() / 200.0, _world.width_cm() * metres / 2.0)


## The configuration of the session's "start" command.
##
## Rays: filled in between the placed sensors by their angles, as far as the
## rover's rays reach at the robot's size. Speed, rotation, place and goal: the
## robot's movement (wheels, gyro) in the training world shrunk to the robot's
## size. Steering and throttle drive the wheels through the conversion that
## drove the EV3 "KIRISIMA".
func build_config() -> Dictionary:
	var sources: Array = []
	var ports := _world.sensors.keys()
	ports.sort()
	for port in ports:
		sources.append({"channel": "%s.distance_mm" % port, "angle_deg": float(_world.sensors[port].get("angle_deg", 0.0))})
	var scale := {"kind": "linear", "in_min": 0, "in_max": ray_reach_cm() * 10.0, "out_min": 0.0, "out_max": 1.0}
	var angles: Array = model.get("ray_angles_deg", [])
	var inputs: Array = []
	var ray := 0
	for neuron in model.get("inputs", []):
		if str(neuron.get("sensor_id", "")) == "ray_distance":
			var angle := float(angles[ray]) if ray < angles.size() else 0.0
			ray += 1
			inputs.append({"derive": "ray", "angle_deg": angle, "sources": sources.duplicate(true), "scale": scale})
		else:
			inputs.append({"derive": "pose", "quantity": str(neuron.get("quantity", ""))})
	var sides := _drive_sides()
	var channels := [[], []]
	var invert := [[], []]
	for index in 2:
		for motor in sides.get(["left", "right"][index], []):
			channels[index].append(str(motor["port"]) + ".power")
			invert[index].append(bool(motor["invert"]))
	var output := {
		"mode": "drive",
		"channels": channels,
		"invert": invert,
		"steer_index": _output_index("steering"),
		"throttle_index": _output_index("throttle"),
		"throttle_scale": 100.0,
	}
	if _output_index("brake") >= 0:
		output["brake_index"] = _output_index("brake")
	var config := {
		"schema_version": 1,
		"rate_hz": 20,
		"watchdog_ms": 400,
		"inputs": inputs,
		"outputs": [output],
		"robot": {"geometry": geometry},
	}
	# The wheels always travel with the run: the lidar draws the room from where
	# they say the robot is, and a network that takes its movement reads them.
	if not sides.is_empty():
		var field := _field.to_saved()
		var world := {"cm_per_unit": cm_per_unit(), "bounds": _world_info().get("bounds", [-480.0, -260.0, 960.0, 520.0]),
				"start": field.get("start", [0.0, 0.0, 0.0])}
		if field.has("goal"):
			world["goal"] = field["goal"]
		config["world"] = world
		var heading := {"source": "wheels"}
		if _heading_source() != "wheels":
			heading = {"source": "gyro", "channel": _heading_source() + ".angle_deg"}
		config["odometry"] = {
			"left": sides.get("left", []).map(func(m): return {"channel": str(m["port"]) + ".position_deg", "invert": bool(m["invert"])}),
			"right": sides.get("right", []).map(func(m): return {"channel": str(m["port"]) + ".position_deg", "invert": bool(m["invert"])}),
			"wheel_diameter_cm": _wheel_diameter_cm(),
			"track_cm": _track_cm(),
			"heading": heading,
		}
	return config


func _process(_delta: float) -> void:
	_apply_scroll_extents()


func _apply_scroll_extents() -> void:
	if not is_instance_valid(_robot_scroll) or not _robot_scroll.visible or _grid == null:
		return
	var sb := _robot_scroll.get_v_scroll_bar()
	if not is_instance_valid(sb):
		return
	var o := _robot_scroll.global_position.y + 6.0
	var i := _robot_scroll.global_position.y + _robot_scroll.size.y - 8.0
	var maxval := sb.max_value - sb.page - 5.0
	var top := o if sb.value > 5.0 else 0.0
	var bot := i if sb.value < maxval else 0.0
	var ext := Vector4(top, bot, 0.0, 0.0)

	for card in _grid.cards():
		if is_instance_valid(card) and card.has_method("apply_extents"):
			card.apply_extents(ext)
