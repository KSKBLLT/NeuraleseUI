extends SplashMenu

const PlatformInput = preload("res://scripts/platform_input.gd")

@onready var gallery: ProjectGallery = $ColorRect/Margin/Content/Gallery
@onready var header_actions: HBoxContainer = $ColorRect/Margin/Content/Header/Actions
@onready var footer_actions: HBoxContainer = $ColorRect/Margin/Content/Footer/Actions

const PRIMARY_COLOR := Color(0.49, 0.83, 0.61, 1.0)
const SECONDARY_COLOR := Color(0.43, 0.59, 0.90, 0.0)
const DESIGN_SIZE := Vector2(990.0, 620.0)
const WINDOW_INSET := Vector2(32.0, 32.0)
const MIN_PANEL_SIZE := Vector2(610.0, 330.0)
const PANEL_HORIZONTAL_MARGIN := 48.0
const PANEL_VERTICAL_CHROME := 137.0
const GRID_GAP := 16.0
const MAX_GRID_COLUMNS := 3

var parsed: Dictionary = {}
var _action_buttons: Array[BlockComponent] = []


func _ready() -> void:
	gallery.project_open_requested.connect(_open_project)
	gallery.project_delete_requested.connect(_request_delete_project)
	get_viewport().size_changed.connect(_fit_to_window)
	_fit_to_window()
	_apply_copy()
	_build_actions()
	gallery.set_loading(true)
	super()
	# Let the splash animation and initial layout settle before building cards.
	await get_tree().process_frame
	parsed = await glob.request_projects()
	await gallery.set_projects(parsed, glob.get_project_id())
	_fit_to_window()


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
	var project_count := maxi(1, parsed.size())
	var card_size := gallery.grid.cell_size
	var gallery_chrome := gallery.horizontal_chrome()
	var available_grid_width := maxf(card_size.x, available.x - PANEL_HORIZONTAL_MARGIN - gallery_chrome)
	var available_columns := maxi(1, int(
		(available_grid_width + GRID_GAP) / (card_size.x + GRID_GAP)
	))
	var columns := mini(project_count, mini(MAX_GRID_COLUMNS, available_columns))
	var rows := ceili(float(project_count) / float(columns))
	var grid_width := card_size.x * columns + GRID_GAP * maxi(0, columns - 1)
	var grid_height := card_size.y * rows + GRID_GAP * maxi(0, rows - 1)
	var desired := Vector2(
		maxf(MIN_PANEL_SIZE.x, grid_width + PANEL_HORIZONTAL_MARGIN + gallery_chrome),
		maxf(MIN_PANEL_SIZE.y, grid_height + PANEL_VERTICAL_CHROME)
	)
	# Keep the responsive decision and the applied GridContainer state atomic.
	# The gallery may still be at its narrow loading size while cards are being
	# created, so it must not infer a different column count from that transient
	# geometry.
	gallery.set_column_count(columns)
	set_base_size(Vector2(
		minf(desired.x, minf(DESIGN_SIZE.x, available.x)),
		minf(desired.y, minf(DESIGN_SIZE.y, available.y))
	))


func quit(data: Dictionary = {}) -> void:
	if not visible:
		return
	if not can_go:
		hide()
		if can_tween_zero:
			ui.blur.self_modulate.a = 0.0
	super(data)


func _open_project(project_id: String) -> void:
	if project_id == str(glob.get_project_id()):
		go_away()
		return
	if not glob.LocalSave and not glob.require_remote_session():
		return
	can_go = false
	go_away()
	await quitting
	await glob.capture_current_project_thumbnail()
	ui.hourglass_on()
	var loaded = await glob.load_scene(project_id, true)
	ui.hourglass_off()
	queue_free()
	if not loaded:
		ui.error(_copy("Не удалось открыть проект.", "Could not open the project.", "Жобаны ашу мүмкін болмады."))


func _request_delete_project(project_id: String) -> void:
	if not glob.LocalSave and not glob.require_remote_session():
		return
	if project_id == str(glob.get_project_id()):
		ui.error(_copy(
			"Сначала откройте другой проект, затем удалите этот.",
			"Open another project before deleting this one.",
			"Бұл жобаны жоймас бұрын басқа жобаны ашыңыз."
		))
		return
	var project_name := str(parsed.get(project_id, {}).get("name", ""))
	if project_name.strip_edges().is_empty():
		project_name = _copy("Безымянный", "Untitled", "Атаусыз")
	await _hide_for_child_menu()
	var dialog = ui.show_dialog({
		"id": "delete_project_%s" % project_id,
		"inner": true,
		"title": _copy("Удалить проект?", "Delete project?", "Жобаны жою керек пе?"),
		"body": project_name,
		"buttons": [
			{
				"id": "cancel",
				"text": _copy("Отмена", "Cancel", "Бас тарту"),
				"style": "secondary",
				"can_go": false,
			},
			{
				"id": "delete",
				"text": _copy("Удалить", "Delete", "Жою"),
				"style": "danger",
				"can_go": false,
			},
		],
	})
	if not is_instance_valid(dialog):
		_restore_from_child_menu()
		return
	dialog.can_tween_zero = false
	var result: Dictionary = await dialog.wait_for_result()
	if is_instance_valid(dialog):
		await dialog.tree_exited
	if str(result.get("action", "")) == "delete":
		await glob.delete_project(int(project_id))
		parsed = await glob.request_projects()
		await gallery.set_projects(parsed, glob.get_project_id())
		_fit_to_window()
	_restore_from_child_menu()


func _on_add() -> void:
	await _hide_for_child_menu()
	await glob.capture_current_project_thumbnail()
	queue_free()
	ui.splash("project_create", splashed_from, emitter, true, {"created_parent": "workslist"})


func _on_import_released() -> void:
	_resultate({"go_path": true})


func _on_lessons_released() -> void:
	inner = true
	can_tween_zero = false
	go_away(false)
	await quitting
	ui.splash("lessonslist", splashed_from, emitter, true, {"created_parent": "workslist"})


func _on_builtin_projects_released() -> void:
	await _hide_for_child_menu()
	queue_free()
	ui.splash("builtin_projects", splashed_from, emitter, true, {"created_parent": "workslist"})


func _resultate(data: Dictionary) -> void:
	if "go_path" in data:
		await _hide_for_child_menu()
		await glob.capture_current_project_thumbnail()
		queue_free()
		ui.splash_and_get_result("path_open", splashed_from, emitter, true, {
			"filter": ["nls"],
			"from_proj": splashed_from,
		})
	elif "go_setts" in data:
		await _hide_for_child_menu()
		queue_free()
		ui.splash("settings", splashed_from, emitter, true, {"from_but": splashed_from})
	else:
		emitter.res.emit(data)
		go_away()


func _hide_for_child_menu() -> void:
	can_tween_zero = false
	can_go = false
	go_away(false)
	await quitting


func _restore_from_child_menu() -> void:
	can_go = true
	can_tween_zero = true
	splash()


func _apply_copy() -> void:
	$ColorRect/Margin/Content/Header/Title.text = _copy("Проекты", "Projects", "Жобалар")
	gallery.get_node("LoadingState/Copy").text = _copy(
		"Загрузка проектов...", "Loading projects...", "Жобалар жүктелуде..."
	)
	gallery.get_node("EmptyState/Copy/Title").text = _copy(
		"Здесь пока нет проектов", "No projects yet", "Әзірге жобалар жоқ"
	)
	gallery.get_node("EmptyState/Copy/Body").text = _copy(
		"Создайте первый проект, чтобы начать работу.",
		"Create your first project to get started.",
		"Жұмысты бастау үшін алғашқы жобаңызды жасаңыз."
	)


func _build_actions() -> void:
	_action_buttons.append(_mount_action(
		header_actions,
		"builtin_projects",
		_copy("Готовые проекты", "Ready-made", "Дайын жобалар"),
		SECONDARY_COLOR,
		_on_builtin_projects_released
	))
	_action_buttons.append(_mount_action(
		header_actions,
		"tutorials",
		_copy("Туториалы", "Tutorials", "Сабақтар"),
		SECONDARY_COLOR,
		_on_lessons_released
	))
	_action_buttons.append(_mount_action(
		header_actions,
		"import",
		_copy("Импорт", "Import", "Импорт"),
		SECONDARY_COLOR,
		_on_import_released
	))
	_action_buttons.append(_mount_action(
		header_actions,
		"new_project",
		_copy("+ Новый проект", "+ New project", "+ Жаңа жоба"),
		PRIMARY_COLOR,
		_on_add
	))
	_action_buttons.append(_mount_action(
		footer_actions,
		"close",
		_copy("Закрыть", "Close", "Жабу"),
		SECONDARY_COLOR,
		go_away
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
		"scale": [0.75, 0.75],
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
