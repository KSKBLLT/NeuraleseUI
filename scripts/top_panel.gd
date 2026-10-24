extends ColorRect
class_name TopBar

const WorkspaceHistoryControllerScript = preload("res://scripts/workspace_history_controller.gd")
const HeaderPixel = preload("res://scripts/ui/header_pixel.gd")

enum WorkslistRoute {
	STARTUP,
	OPEN_LOCAL,
	CLOSE_ACTIVE,
	OPEN_REMOTE,
}

@export var menus: Dictionary[StringName, SubMenu] = {}

var _history_controller: WorkspaceHistoryController
var _history_language := ""
var _pixel_layout_dirty: bool = true


static func workslist_route(
	local_save: bool,
	startup_active: bool,
	splash_active: bool
) -> WorkslistRoute:
	if startup_active:
		return WorkslistRoute.STARTUP
	if splash_active:
		return WorkslistRoute.CLOSE_ACTIVE
	return WorkslistRoute.OPEN_LOCAL if local_save else WorkslistRoute.OPEN_REMOTE

func _enter_tree() -> void:
	glob.fg = self

func show_back():
	material.set_shader_parameter("use_bg", true)
	$back.show()

func hide_back():
	material.set_shader_parameter("use_bg", false)
	$back.hide()


# Keep High's live-screen blur local: copy only the top-bar strip instead of
# letting the screen-texture path copy the entire framebuffer.
const _BACKBUFFER_MARGIN := Vector2(24, 24)
var _backbuffer_strip: BackBufferCopy


func _install_backbuffer_strip() -> void:
	_backbuffer_strip = BackBufferCopy.new()
	_backbuffer_strip.copy_mode = BackBufferCopy.COPY_MODE_RECT
	_backbuffer_strip.name = "BackBufferStrip"
	get_parent().add_child.call_deferred(_backbuffer_strip)
	_place_backbuffer_strip.call_deferred()
	item_rect_changed.connect(_place_backbuffer_strip)


func _place_backbuffer_strip() -> void:
	if not is_instance_valid(_backbuffer_strip) or not _backbuffer_strip.is_inside_tree():
		return
	var parent := get_parent()
	if _backbuffer_strip.get_index() >= get_index():
		parent.move_child(_backbuffer_strip, get_index())
	_backbuffer_strip.rect = Rect2(position - _BACKBUFFER_MARGIN, size + _BACKBUFFER_MARGIN * 2.0)


func _ready() -> void:
	_install_backbuffer_strip()
	glob.space_begin.y = size.y + position.y
	_history_controller = WorkspaceHistoryControllerScript.new(glob.undo_redo)
	set_active_window("graph")
	name_resize()
	if design.pixel:
		_apply_pixel_bar()
		glob.language_changed.connect(_on_pixel_language_changed)
		$Label.text_changed.connect(_on_project_name_text_changed)


## Pixel design: the team's light top bar. A pale blue band; the project
## folder, name, save dot and ⌄ menu share one white pill; the tabs, each
## with a line icon, sit on a white track with the active one in a near-black
## pill; Axon is the deep violet button; «⋯ Actions» holds Download
## (scripts/ui/header_pixel.gd).
func _apply_pixel_bar() -> void:
	# Block buttons move into wrappers after their first frame, which breaks
	# their paths, so keep the nodes themselves.
	_folder = $works
	_tab_buttons = {"graph": $Control3/minigames, "env": $Control3/graphs, "ds": $Control3/datasets}
	self_modulate.a = 0.0
	var band := ColorRect.new()
	band.color = design.BAR_BG
	band.mouse_filter = Control.MOUSE_FILTER_IGNORE
	band.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(band)
	move_child(band, 0)
	_project_pill = _pixel_pill(design.SC_LOWEST)
	add_child(_project_pill)
	move_child(_project_pill, 1)
	design.set_role($works, design.Role.TONAL)
	design.set_colour($works, &"design_fill", design.PROJECT_ICON_BG)
	design.set_icon_tint($works/i, design.CATEGORY[&"train"].accent)
	# The project name reads as a title until it is clicked for editing.
	var plain := StyleBoxEmpty.new()
	plain.content_margin_left = 6.0
	$Label.add_theme_stylebox_override(&"normal", plain)
	$Label.add_theme_font_override(&"font", design.sans_title)
	var tabs: Control = $Control3
	for divider in [$Control3/ColorRect, $Control3/ColorRect2]:
		divider.hide()
	var first: Control = $Control3/graphsbg
	var last: Control = $Control3/dsbg
	_tab_track = _pixel_pill(design.SC_LOWEST)
	_tab_track.position = Vector2(first.position.x, 4.0)
	_tab_track.size = Vector2(last.position.x + last.size.x - first.position.x, first.size.y - 8.0)
	tabs.add_child(_tab_track)
	tabs.move_child(_tab_track, 0)
	# In screen order: Simulations, Graphs, Datasets.
	_tab_segments = [
		[first, $Control3/graphs], [$Control3/minigamesbg, $Control3/minigames], [last, $Control3/datasets],
	]
	_right_buttons = [$Control/ai, $Control/export, $Control/login]
	for active_bg: Control in [$Control3/minigamesbg, first, last]:
		active_bg.self_modulate.a = 0.0
		var pill := _pixel_pill(design.TAB_ACTIVE)
		pill.set_anchors_preset(Control.PRESET_FULL_RECT)
		pill.offset_left = 4.0
		pill.offset_top = 8.0
		pill.offset_right = -4.0
		pill.offset_bottom = -8.0
		active_bg.add_child(pill)
	for button: Control in [$Control/ai, $Control/export, $Control/login]:
		design.set_role(button, design.Role.TONAL)
		design.set_colour(button, &"design_fill", design.SC_LOWEST)
	design.set_colour($Control/ai, &"design_fill", design.AXON)
	design.set_text_role($Control/ai/Label, 1)
	design.set_icon_tint($Control/ai/i, Color.WHITE)
	_header = HeaderPixel.new(self)
	_header.build(_tab_buttons, $Control/export)
	b_texts[1] = $Control/export.text
	_mark_active_tab(glob.curr_window if glob.curr_window != "" else "graph")


## The active tab's name turns white on its dark pill.
func _mark_active_tab(window_name: String) -> void:
	for key in _tab_buttons:
		design.set_text_role(_tab_buttons[key].get_node("Label"), 1 if key == window_name else 0)
	if _header:
		_header.mark_active(window_name)


func _on_pixel_language_changed() -> void:
	_history_language = ""
	if _header:
		_header.refresh_language()
	_pixel_layout_dirty = true


func _on_project_name_text_changed(_text: String) -> void:
	_pixel_layout_dirty = true


## Bento header: the three tabs share the free middle of the bar equally.
func _layout_pixel_tabs() -> void:
	var tabs: Control = $Control3
	var to_local := tabs.get_global_transform().affine_inverse()
	var left: float = (to_local * Vector2($HistoryControls.get_global_rect().end.x + 24.0, 0.0)).x
	var right: float = (to_local * Vector2(_right_buttons[0].get_global_rect().position.x - 24.0, 0.0)).x
	var segment := (right - left) / 3.0
	if segment < 60.0:
		return
	if not is_equal_approx(_tab_track.position.x, left):
		_tab_track.position.x = left
	if not is_equal_approx(_tab_track.size.x, right - left):
		_tab_track.size.x = right - left
	for index in _tab_segments.size():
		var bg: Control = _tab_segments[index][0]
		var button: BlockComponent = _tab_segments[index][1]
		var bg_x := left + segment * index
		if not is_equal_approx(bg.position.x, bg_x):
			bg.position.x = bg_x
		if not is_equal_approx(bg.size.x, segment):
			bg.size.x = segment
		if absf(button.size.x - segment) > 0.5:
			button.resize(Vector2(segment, button.size.y))
		# Centre the button over its segment, whatever its alignment.
		var shift: float = bg.get_global_rect().get_center().x - button.get_global_rect().get_center().x
		if absf(shift) > 0.5:
			button._wrapped_in.position.x += shift / tabs.get_global_transform().get_scale().x


func _fit_project_pill() -> void:
	var folder := _folder.get_global_rect()
	var pill_end: float = _header.layout() + global_position.x
	var next_position := Vector2(folder.position.x - 4.0, folder.position.y - 3.0) - global_position
	var next_size := Vector2(pill_end - (folder.position.x - 4.0), folder.size.y + 6.0)
	if _project_pill.position != next_position:
		_project_pill.position = next_position
	if _project_pill.size != next_size:
		_project_pill.size = next_size


func _pixel_pill(colour: Color) -> Panel:
	var box := StyleBoxFlat.new()
	box.bg_color = colour
	box.set_corner_radius_all(999)
	var pill := Panel.new()
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_theme_stylebox_override(&"panel", box)
	return pill


func set_active_window(window_name: String) -> void:
	$Control3/dsbg.visible = window_name == "ds"
	$Control3/graphsbg.visible = window_name == "env"
	$Control3/minigamesbg.visible = window_name == "graph"
	$HistoryControls.visible = window_name in ["graph", "env"]
	if design.pixel:
		_pixel_layout_dirty = true
		_mark_active_tab(window_name)
	_update_history_buttons(window_name)


func name_resize():
	$Label.size.x = clamp((glob.window_size.x - 700) * 0.6, 100, 189) / $Label.scale.x
	#savebut.global_position.x = $Label.get_global_rect().end.x + 10
	$Label.resize_after = $Label.size.x - 30
	$Label._resize_label.call_deferred()



func _process(delta: float) -> void:
	_update_history_buttons(glob.curr_window)
	if size.x != glob.window_size.x-position.x*2:
		size.x = glob.window_size.x-position.x*2
		for m in menus:
			var menu = menus[m]
			menu.attachement_x = size.x - menu.size.x + 30
			#if glob.window_size.x < 50:
		name_resize()
		_pixel_layout_dirty = true
	if (glob.window_size.x) < 899:
		#(1300-glob.window_size.x)
		if not in_small_mode:
			var idx: int = -1
			for i in buts:
				idx += 1; i.text = ""
				i.resize(Vector2(41, i.base_size.y))
			buts[1]._wrapped_in.position = buts[2]._wrapped_in.position - Vector2(48,0)
			buts[0]._wrapped_in.position = buts[1]._wrapped_in.position - Vector2(48,0)
			buts[0].get_node("i").position.x = 20.921
			_pixel_layout_dirty = true
		in_small_mode = true
	else:
		if in_small_mode:
			buts[0].get_node("i").position.x = 22.921

			for i in len(buts):
				#i.resize_after = 20
				buts[i].text = b_texts[i]
				buts[i].resize(b_szs[i])
				buts[i]._wrapped_in.position = b_poss[i]
			_pixel_layout_dirty = true
		in_small_mode = false
	if design.pixel:
		if _pixel_layout_dirty:
			_fit_project_pill()
			_layout_navigation()
			_layout_pixel_tabs()
			_pixel_layout_dirty = false
	else:
		_layout_navigation()
	#if Input.is_action_just_pressed("ui_accept"):
		#menus["a"].expand()
	#elif Input.is_action_just_pressed("down"):
		#menus["a"].close()
	#(glob.window_size.x)
var in_small_mode: bool = false
## Pixel design: the white pill behind the project folder and name.
var _project_pill: Panel = null
var _folder: Control = null
var _tab_buttons := {}
var _tab_track: Panel = null
var _tab_segments: Array = []
var _right_buttons: Array = []
var _header: HeaderPixel = null
@onready var buts: Array[BlockComponent] = [$Control/ai, $Control/export, $Control/login]
@onready var b_texts = [buts[0].text, buts[1].text, buts[2].text]
@onready var b_szs = [buts[0].size, buts[1].size, buts[2].size]
@onready var b_poss = [buts[0].position, buts[1].position, buts[2].position]

const NAVIGATION_LEFT := -180.37042
const NAVIGATION_RIGHT := 211.0


static func navigation_layout(title_end: float, actions_start: float) -> Dictionary:
	var left_boundary := title_end + 8.0
	var right_boundary := actions_start - 8.0
	var natural_width := NAVIGATION_RIGHT - NAVIGATION_LEFT
	var available_width := maxf(0.0, right_boundary - left_boundary)
	var navigation_scale := clampf(available_width / natural_width, 0.58, 1.0)
	var desired_center := (left_boundary + right_boundary) * 0.5
	var local_center := (NAVIGATION_LEFT + NAVIGATION_RIGHT) * 0.5
	return {
		"scale": navigation_scale,
		"position_x": desired_center - local_center * navigation_scale,
		"left": desired_center - natural_width * navigation_scale * 0.5,
		"right": desired_center + natural_width * navigation_scale * 0.5,
	}


func _layout_navigation() -> void:
	var action_start := glob.window_size.x
	for button in buts:
		action_start = minf(action_start, button.get_global_rect().position.x)
	var title_end: float = $Label.get_global_rect().end.x
	if $HistoryControls.visible:
		title_end = maxf(title_end, $HistoryControls.get_global_rect().end.x)
	var layout := navigation_layout(title_end, action_start)
	var navigation_scale: float = layout["scale"]
	$Control3.scale = Vector2(navigation_scale, navigation_scale)
	$Control3.global_position.x = layout["position_x"]

func get_scene_name():
	return $Label.text

func set_scene_name(name: String):
	if $Label.text == name:
		return
	$Label.text = name
	_pixel_layout_dirty = true


var game_icon = preload("res://game_assets/icons/game.png")
var build_icon = preload("res://game_assets/icons/splines.png")
@onready var play = get_node_or_null("Control/play")
func _on_play_released() -> void:
	if not is_instance_valid(play):
		return
	if play.hint == "play_tab": 
	#	play.hint = "build_tab"
	#	play.text_offset = Vector2(7,0)
#		play.text = " Make"
		#play.get_node("i").texture = build_icon
		#play.get_node("i").offset.x = -3
		glob.go_window("env")
	else:
		go_into_graph()

func go_into_graph():
#	play.hint = "play_tab"
#	play.text_offset = Vector2(7,0)
#	play.text = " Test"
#	play.get_node("i").texture = game_icon
	glob.go_window("graph")
	set_def()

var logged_in: bool = false

func set_login_state(name: String):
	logged_in = len(name) > 0
	pass
	#if name:
	#	login_btn.text = name
	#else:
	#	login_btn.text = "Login"


@onready var login_btn = $Control/login
func _on_login_released() -> void:
	#if !ui.is_splashed("login"):
	#	login_btn.in_splash = true
	
	if !glob.logged_in():
		var a = await ui.splash_and_get_result("login", login_btn)
		if a:
			set_login_state("Works")
		else:
			set_login_state("")
		#if !glob.loaded_project_once:
		#	glob.open_last_project()
	else:
		ui.splash("settings", login_btn)
	#else:
	#	login_btn.in_splash = false
	#	ui.get_splash("login").go_away()

@onready var savebut = get_node_or_null("9")
func _on__released() -> void:
	if glob.LocalSave:
		ui.hourglass_on()
		await glob.save(str(glob.get_project_id()))
		ui.hourglass_off()
		return
	if not await glob.require_remote_session_for_action(savebut):
		return
	ui.hourglass_on()
	await glob.save(str(glob.get_project_id()))
	ui.hourglass_off()

@onready var axon = $Control/ai
func _on_ai_released() -> void:
	# Pixel design: the panel opens without a session and says what it needs.
	if not design.pixel and not await glob.require_remote_session_for_action(axon):
		return
	ui.splash("ai_help", axon)


func _on_ds_released() -> void:
	pass # Replace with function body.


func _on_graphs_released() -> void:
	glob.go_window("env")
func set_def():
	set_active_window("graph")

func _on_datasets_released() -> void:
	glob.go_window("ds")


func _on_minigames_released() -> void:
	go_into_graph()

@onready var export = $Control/export
func _on_export_released() -> void:
	# Pixel design: this button is «⋯ Actions»; Download is one of its items.
	if _header:
		_header.open_actions()
		return
	await export_model()


func export_model() -> void:
	if nn.FULLY_LOCAL_TRAINING:
		await ui.splash_and_get_result("model_export", export)
		return
	if not await glob.require_remote_session_for_action(export):
		return
	await ui.splash_and_get_result("model_export", export)

@onready var workslist_but = $works
func _on_workslist() -> void:
	var startup_active := is_instance_valid(glob.startup_flow)
	match workslist_route(glob.LocalSave, startup_active, ui.active_splashed()):
		WorkslistRoute.STARTUP:
			var folder_menu_id := str(glob.startup_flow.folder_menu_id())
			print(workslist_but.in_splash)
			if folder_menu_id != "startup_main_menu":
				ui.splash(folder_menu_id, workslist_but)
				return
			ui.hide_splash()
			await get_tree().process_frame
			await glob.startup_flow.show_main_menu(workslist_but)
			return
		WorkslistRoute.CLOSE_ACTIVE:
			ui.hide_splash()
			return
		WorkslistRoute.OPEN_LOCAL:
			ui.splash("workslist", workslist_but)
			return
		WorkslistRoute.OPEN_REMOTE:
			if not await glob.require_remote_session_for_action(workslist_but):
				return
			ui.splash("workslist" if !learner.active() else "lessonslist", workslist_but)


func _resolve_simulation_history() -> Object:
	var simulation_window = glob.tree_windows.get("env")
	if not is_instance_valid(simulation_window):
		return null
	return simulation_window.get_node_or_null("SimulationEditor")


func _update_history_buttons(window_name: String) -> void:
	if not is_instance_valid(_history_controller):
		return
	var language := str(glob.get_lang())
	if language != _history_language:
		_history_language = language
		match language:
			"en":
				$HistoryControls/Undo.tooltip_text = "Undo"
				$HistoryControls/Redo.tooltip_text = "Redo"
			"kz":
				$HistoryControls/Undo.tooltip_text = "Болдырмау"
				$HistoryControls/Redo.tooltip_text = "Қайталау"
			_:
				$HistoryControls/Undo.tooltip_text = "Отменить"
				$HistoryControls/Redo.tooltip_text = "Повторить"
	_history_controller.set_simulation_editor(_resolve_simulation_history())
	var supported := window_name in ["graph", "env"]
	$HistoryControls.visible = supported
	$HistoryControls/Undo.disabled = not supported or not _history_controller.can_undo(window_name)
	$HistoryControls/Redo.disabled = not supported or not _history_controller.can_redo(window_name)
	$HistoryControls/Undo.modulate.a = 0.38 if $HistoryControls/Undo.disabled else 1.0
	$HistoryControls/Redo.modulate.a = 0.38 if $HistoryControls/Redo.disabled else 1.0


func _on_undo_pressed() -> void:
	if is_instance_valid(_history_controller):
		_history_controller.undo(glob.curr_window)
	_update_history_buttons(glob.curr_window)


func _on_redo_pressed() -> void:
	if is_instance_valid(_history_controller):
		_history_controller.redo(glob.curr_window)
	_update_history_buttons(glob.curr_window)
