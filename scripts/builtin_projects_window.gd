extends SplashMenu

const PlatformInput = preload("res://scripts/platform_input.gd")
const Repository = preload("res://scripts/builtin_projects_repository.gd")
const CARD_SCENE := preload("res://scenes/builtin_project_card.tscn")

const DESIGN_SIZE := Vector2(860.0, 620.0)
const WINDOW_INSET := Vector2(32.0, 32.0)
const MIN_PANEL_SIZE := Vector2(650.0, 440.0)
const CARD_HEIGHT := 150.0
const CARD_MIN_WIDTH := 560.0
const CARD_MAX_WIDTH := 700.0
const GALLERY_HORIZONTAL_INSET := 30.0
const SCROLLBAR_RESERVE := 18.0
const SECONDARY_COLOR := Color(0.43, 0.59, 0.90, 0.0)

@onready var scroll: ScrollContainer = $ColorRect/Margin/Content/GalleryArea/Scroll
@onready var cards: VBoxContainer = $ColorRect/Margin/Content/GalleryArea/Scroll/Center/Cards
@onready var loading_state: CenterContainer = $ColorRect/Margin/Content/GalleryArea/LoadingState
@onready var empty_state: CenterContainer = $ColorRect/Margin/Content/GalleryArea/EmptyState
@onready var header_actions: HBoxContainer = $ColorRect/Margin/Content/Header/Actions
@onready var footer_actions: HBoxContainer = $ColorRect/Margin/Content/Footer/Actions

var repository := Repository.new()
var project_cards: Array[BlockComponent] = []
var _action_buttons: Array[BlockComponent] = []
var _opening_project := false


func _process(delta: float) -> void:
	super(delta)
	_apply_extents()


func _apply_extents() -> void:
	if not is_instance_valid(scroll) or not scroll.visible:
		return
	var sb := scroll.get_v_scroll_bar()
	if not is_instance_valid(sb):
		return
	var o := scroll.global_position.y + 6.0
	var i := scroll.global_position.y + scroll.size.y - 8.0
	var maxval := sb.max_value - sb.page - 5.0
	var top := o if sb.value > 5.0 else 0.0
	var bot := i if sb.value < maxval else 0.0
	var ext := Vector4(top, bot, 0.0, 0.0)

	for card in project_cards:
		if is_instance_valid(card) and card.has_method("apply_extents"):
			card.apply_extents(ext)


func _ready() -> void:
	get_viewport().size_changed.connect(_fit_to_window)
	_fit_to_window()
	_apply_copy()
	_build_actions()
	scroll.hide()
	empty_state.hide()
	loading_state.show()
	super()
	await get_tree().process_frame
	await _populate_gallery()


func _fit_to_window() -> void:
	var logical_window_size := get_viewport().get_visible_rect().size
	if logical_window_size.x <= 1.0 or logical_window_size.y <= 1.0:
		logical_window_size = PlatformInput.logical_window_size(
			Vector2(DisplayServer.window_get_size()),
			get_tree().root.content_scale_factor
		)
	if logical_window_size.x <= WINDOW_INSET.x or logical_window_size.y <= WINDOW_INSET.y:
		return
	var available := logical_window_size - WINDOW_INSET
	set_base_size(Vector2(
		minf(DESIGN_SIZE.x, maxf(MIN_PANEL_SIZE.x, available.x)),
		minf(DESIGN_SIZE.y, maxf(MIN_PANEL_SIZE.y, available.y))
	))
	call_deferred("_fit_card_widths")


func _fit_card_widths() -> void:
	if not is_instance_valid(scroll) or not is_instance_valid(cards):
		return
	var available_width := maxf(
		CARD_MIN_WIDTH,
		scroll.size.x - GALLERY_HORIZONTAL_INSET - SCROLLBAR_RESERVE
	)
	var card_width := clampf(available_width, CARD_MIN_WIDTH, CARD_MAX_WIDTH)
	cards.custom_minimum_size.x = card_width
	for card in project_cards:
		if not is_instance_valid(card):
			continue
		card.resize(Vector2(card_width, CARD_HEIGHT))


func _populate_gallery() -> void:
	var definitions := repository.load_catalog()
	for error in repository.errors:
		push_warning(error)
	if definitions.is_empty():
		loading_state.hide()
		empty_state.show()
		return

	var language := str(glob.get_lang())
	for index in definitions.size():
		var card := CARD_SCENE.instantiate() as BlockComponent
		card.configure(definitions[index], language)
		card.open_requested.connect(_open_project)
		cards.add_child(card)
		project_cards.append(card)
		# Rich cards contain large textures. Yielding keeps the splash entrance smooth
		# when the data catalog grows beyond the current built-in set.
		if index % 2 == 1:
			await get_tree().process_frame

	loading_state.hide()
	empty_state.hide()
	scroll.show()
	await get_tree().process_frame
	await get_tree().process_frame
	_fit_card_widths()


func quit(data: Dictionary = {}) -> void:
	if not visible:
		return
	if not can_go:
		hide()
		if can_tween_zero:
			ui.blur.self_modulate.a = 0.0
	super(data)


func _open_project(project_id: StringName) -> void:
	if _opening_project:
		return
	_opening_project = true
	# Opening a graph is a terminal transition, so let SplashMenu release the
	# shared blur just like workslist._open_project(). Splash-to-splash
	# transitions below deliberately keep it alive.
	await _hide_for_transition(false)
	await glob.capture_current_project_thumbnail()
	ui.hourglass_on()
	var result: Dictionary = await repository.create_user_copy(project_id, str(glob.get_lang()))
	if not bool(result.get("ok", false)):
		ui.hourglass_off()
		ui.error(_copy(
			"Не удалось создать копию готового проекта.",
			"Could not create a copy of the ready-made project.",
			"Дайын жобаның көшірмесін жасау мүмкін болмады."
		))
		_opening_project = false
		_restore_after_transition()
		return

	var new_project_id := str(result.get("project_id", ""))
	var loaded := bool(result.get("already_loaded", false))
	if not loaded and not new_project_id.is_empty():
		loaded = bool(await glob.load_scene(new_project_id, true))
	ui.hourglass_off()
	if not loaded:
		ui.error(_copy(
			"Копия создана, но проект не удалось открыть.",
			"The copy was created, but the project could not be opened.",
			"Көшірме жасалды, бірақ жобаны ашу мүмкін болмады."
		))
		_opening_project = false
		_restore_after_transition()
		return
	queue_free()


func _on_my_projects() -> void:
	await _hide_for_transition()
	queue_free()
	ui.splash("workslist", splashed_from, emitter, true)


func _on_close() -> void:
	go_away()
	await _quit_request()


func _quit_request() -> void:
	if not passed_data.has("created_parent"):
		return
	can_tween_zero = false
	can_go = false
	await quitting
	queue_free()
	ui.splash(str(passed_data["created_parent"]), splashed_from, emitter, true)


func _hide_for_transition(preserve_blur: bool = true) -> void:
	can_tween_zero = not preserve_blur
	can_go = false
	go_away(false)
	await quitting


func _restore_after_transition() -> void:
	can_go = true
	can_tween_zero = true
	splash()


func _apply_copy() -> void:
	$ColorRect/Margin/Content/Header/Title.text = _copy(
		"Готовые ИИ-проекты", "Ready-made AI projects", "Дайын ЖИ жобалары"
	)
	$ColorRect/Margin/Content/Intro/Text.text = _copy(
		"Выбери проект и посмотри, чему уже научился ИИ",
		"Choose a project and see what its AI has learned",
		"Жобаны таңдап, ЖИ нені үйренгенін көр"
	)
	$ColorRect/Margin/Content/GalleryArea/LoadingState/Copy.text = _copy(
		"Готовим проекты...", "Preparing projects...", "Жобаларды дайындап жатырмыз..."
	)
	$ColorRect/Margin/Content/GalleryArea/EmptyState/Copy.text = _copy(
		"Готовые проекты пока не установлены.",
		"No ready-made projects are installed yet.",
		"Әзірге дайын жобалар орнатылмаған."
	)


func _build_actions() -> void:
	_action_buttons.append(_mount_action(
		header_actions,
		"my_projects",
		_copy("Мои проекты", "My projects", "Менің жобаларым"),
		SECONDARY_COLOR,
		_on_my_projects
	))
	_action_buttons.append(_mount_action(
		footer_actions,
		"close",
		_copy("Закрыть", "Close", "Жабу"),
		SECONDARY_COLOR,
		_on_close
	))


func _mount_action(
	host: Container,
	id: String,
	label: String,
	color: Color,
	handler: Callable
) -> BlockComponent:
	var button := UIAdapter.build({
		"type": "block",
		"id": id,
		"text": label,
		"size": [150, 50],
		"scale": [0.9, 0.9],
		"alignment": [0.5, 0.5],
		"scale_affects_layout": true,
		"auto_fit": "x",
		"fit_shrink": true,
		"fit_padding": [22, 10],
		"fit_min_size": [92, 50],
		"fit_max_size": [230, 50],
		"static": true,
		"top": true,
		"mouse_open": false,
		"color": color,
	})
	button.in_splash = true
	button.released.connect(handler)
	UIAdapter.mount(host, button)
	return button


func _copy(ru: String, en: String, kz: String) -> String:
	match str(glob.get_lang()):
		"en": return en
		"kz": return kz
		_: return ru
