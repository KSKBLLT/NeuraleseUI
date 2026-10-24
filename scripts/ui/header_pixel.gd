extends RefCounted
## Pixel design: what the Bento header adds to the top bar (scripts/top_panel.gd):
## line icons in the three tabs, a save dot and a ⌄ menu next to the project
## name, and «⋯ Actions» on the right, where «Download» now lives. The bar's
## own nodes (folder, name, undo, tabs, Axon, profile) stay where they are and
## keep their tour targets; the old Download button becomes «Actions».
##
## Autoloads are looked up at run time, so tests can load this with --script.

const TAB_ICONS := {
	"env": "M12 3l9 5v9l-9 5-9-5V8zM3 8l9 5 9-5M12 13v9",
	"graph": "M7 7l10 5-10 5M7 7a2 2 0 1 0 0.01 0M17 12a2 2 0 1 0 .01 0M7 17a2 2 0 1 0 .01 0",
	"ds": "M3 5h18v15H3zM3 10h18M9 10v10",
}
const MORE_ICON := "M4 12h1M11 12h1M18 12h1"
const CHEVRON_ICON := "M6 9l6 6 6-6"
## Tab icon side and its gap to the name, in the tab button's own units.
const TAB_ICON := 17.0
const TAB_ICON_GAP := 6.0

enum ProjectItem { PROJECTS, RENAME, SAVE, DOWNLOAD }
enum ActionItem { DOWNLOAD, PROFILE }

const TEXT := {
	"actions": {"ru": "     Действия", "kz": "     Әрекеттер", "en": "     Actions"},
	"download": {"ru": "Скачать модель", "kz": "Модельді жүктеу", "en": "Download the model"},
	"profile": {"ru": "Профиль и настройки", "kz": "Профиль және баптаулар", "en": "Profile and settings"},
	"projects": {"ru": "Проекты", "kz": "Жобалар", "en": "Projects"},
	"rename": {"ru": "Переименовать", "kz": "Атын өзгерту", "en": "Rename"},
	"save": {"ru": "Сохранить", "kz": "Сақтау", "en": "Save"},
	"download_short": {"ru": "Скачать", "kz": "Жүктеу", "en": "Download"},
	"menu": {"ru": "Меню проекта", "kz": "Жоба мәзірі", "en": "Project menu"},
	"saved": {"ru": "Всё сохранено", "kz": "Бәрі сақталды", "en": "Everything is saved"},
	"saved_at": {"ru": "Сохранено в %s", "kz": "Сақталды: %s", "en": "Saved at %s"},
	"pending": {"ru": "Есть несохранённые изменения", "kz": "Сақталмаған өзгерістер бар", "en": "Some changes are not saved yet"},
	"saving": {"ru": "Сохраняю…", "kz": "Сақтап жатырмын…", "en": "Saving…"},
	"failed": {"ru": "Не сохранилось", "kz": "Сақталмады", "en": "Could not save"},
}

## Save state of the open project: saved, pending, saving or failed.
var save_state := &"saved"
## When the project was last saved in this session ("12:41"), or "".
var saved_at := ""
var project_menu: PopupMenu
var actions_menu: PopupMenu
var dot: Panel
var chevron: Button

var _bar: Control
var _design: Node
var _glob: Node
var _name_field: Control
var _history: Control
var _actions_button: Control
var _tab_buttons := {}
var _tab_icons := {}
var _lang := ""
var _project_id := -1


func _init(bar: Control) -> void:
	_bar = bar
	var root := (Engine.get_main_loop() as SceneTree).root
	_design = root.get_node_or_null("design")
	_glob = root.get_node_or_null("glob")


## Adds the header's controls. `tab_buttons` maps a window ("graph", "env",
## "ds") to its tab button; the nodes are kept, since buttons move into
## wrappers after their first frame.
func build(tab_buttons: Dictionary, actions_button: Control) -> void:
	_tab_buttons = tab_buttons
	_name_field = _bar.get_node("Label")
	_history = _bar.get_node("HistoryControls")
	_actions_button = actions_button
	for key in tab_buttons:
		var icon := TextureRect.new()
		icon.name = &"TabIcon"
		icon.texture = line_icon(TAB_ICONS[key], 48)
		icon.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		icon.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		icon.size = Vector2(TAB_ICON, TAB_ICON)
		icon.mouse_filter = Control.MOUSE_FILTER_IGNORE
		tab_buttons[key].add_child(icon)
		_tab_icons[key] = icon
	_build_actions_button()
	dot = Panel.new()
	dot.name = &"SaveDot"
	dot.size = Vector2(10, 10)
	dot.mouse_filter = Control.MOUSE_FILTER_PASS
	dot.hide()
	_bar.add_child(dot)
	chevron = Button.new()
	chevron.name = &"ProjectMenu"
	chevron.flat = true
	chevron.focus_mode = Control.FOCUS_NONE
	chevron.icon = line_icon(CHEVRON_ICON, 40)
	chevron.expand_icon = true
	chevron.custom_minimum_size = Vector2(30, 30)
	chevron.size = Vector2(30, 30)
	chevron.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	for colour_name in [&"icon_normal_color", &"icon_hover_color", &"icon_pressed_color", &"icon_focus_color"]:
		chevron.add_theme_color_override(colour_name, _design.ON_SURFACE_VAR)
	for state in [&"normal", &"hover", &"pressed", &"focus"]:
		var face := StyleBoxFlat.new()
		face.bg_color = Color(0, 0, 0, 0) if state in [&"normal", &"focus"] else _design.SC_HIGH
		face.set_corner_radius_all(999)
		face.set_content_margin_all(7)
		chevron.add_theme_stylebox_override(state, face)
	chevron.pressed.connect(open_project_menu)
	_bar.add_child(chevron)
	project_menu = _menu()
	project_menu.id_pressed.connect(_on_project_item)
	_bar.add_child(project_menu)
	actions_menu = _menu()
	actions_menu.id_pressed.connect(_on_action_item)
	_bar.add_child(actions_menu)
	_glob.autosave_status_changed.connect(_on_autosave_status)
	_glob.project_saved.connect(_on_project_saved)
	# Opening a project queues an autosave of what was just read; that is not
	# the student's unsaved work.
	_glob.project_opened.connect(func(_who): _set_state(&"saved", ""))
	_apply_texts()
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with("--design-preview-header="):
			_preview.call_deferred(argument.trim_prefix("--design-preview-header="))


## Places the icons, the dot and the ⌄ after a relevant layout change. Returns
## where the project pill ends (bar coordinates).
func layout() -> float:
	if str(_glob.get_lang()) != _lang:
		_apply_texts()
	if _glob.get_project_id() != _project_id:
		_project_id = _glob.get_project_id()
		_set_state(&"saved", "")
	for key in _tab_buttons:
		_place_tab_icon(_tab_buttons[key], _tab_icons[key])
	var field: Rect2 = _name_field.get_global_rect()
	var origin: Vector2 = _bar.global_position
	var middle := field.get_center().y - origin.y
	var x := field.end.x - origin.x
	var dot_position := Vector2(x + 2.0, middle - dot.size.y * 0.5)
	var chevron_position := Vector2(x + 14.0, middle - chevron.size.y * 0.5)
	if dot.position != dot_position:
		dot.position = dot_position
	if chevron.position != chevron_position:
		chevron.position = chevron_position
	var end := chevron.position.x + chevron.size.x
	if not is_equal_approx(_history.position.x, end + 12.0):
		_history.position.x = end + 12.0
	return end + 2.0


func refresh_language() -> void:
	_apply_texts()


## The tab of `window_name` is active: its icon turns white like its name.
func mark_active(window_name: String) -> void:
	for key in _tab_icons:
		_design.set_icon_tint(_tab_icons[key], Color.WHITE if key == window_name else _design.ON_SURFACE_VAR)


func open_actions() -> void:
	_open_under(actions_menu, _actions_button, true)


func open_project_menu() -> void:
	project_menu.set_item_disabled(project_menu.get_item_index(ProjectItem.RENAME), not _glob.loaded_project_once)
	_open_under(project_menu, chevron, false)


## A white line icon drawn from SVG path data, `pixels` wide, with mipmaps;
## tint it with modulate.
static func line_icon(path_data: String, pixels: int) -> ImageTexture:
	var svg := '<svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24"><path d="%s" fill="none" stroke="#ffffff" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>' % path_data
	var image := Image.new()
	if image.load_svg_from_string(svg, pixels / 24.0) != OK:
		return null
	image.generate_mipmaps()
	return ImageTexture.create_from_image(image)


func _build_actions_button() -> void:
	var button := _actions_button
	var icon := button.get_node_or_null("i") as Sprite2D
	if icon:
		# A little smaller than the old download arrow: the dots are wide.
		var side: float = (icon.texture.get_size().x * icon.scale.x if icon.texture else 27.0) * 0.85
		icon.texture = line_icon(MORE_ICON, 48)
		icon.scale = Vector2.ONE * side / 48.0
		_design.set_icon_tint(icon, _design.ON_SURFACE_VAR)
	# The button's localiser keys its one translation to the button's text.
	var loc := button.get_node_or_null("Loc")
	if loc:
		var ru: Dictionary[String, String] = {"actions": TEXT["actions"]["ru"]}
		var kz: Dictionary[String, String] = {"actions": TEXT["actions"]["kz"]}
		loc.set(&"localizations_ru", ru)
		loc.set(&"localizations_kz", kz)
	button.set(&"text", TEXT["actions"]["en"])


func _place_tab_icon(button: Control, icon: TextureRect) -> void:
	var label := button.get_node_or_null("Label") as Label
	if label == null:
		return
	var text_width := label.get_minimum_size().x * label.scale.x
	var fits := text_width + TAB_ICON + TAB_ICON_GAP + 16.0 <= button.size.x
	var shift := (TAB_ICON + TAB_ICON_GAP) * 0.5 if fits else 0.0
	if not is_equal_approx(float(button.get(&"text_offset").x), shift):
		button.set(&"text_offset", Vector2(shift, 0.0))
		button.call(&"_align_label")
	if icon.visible != fits:
		icon.visible = fits
	var middle := label.position.y + label.size.y * label.scale.y * 0.5
	var icon_position := Vector2(label.position.x - TAB_ICON_GAP - TAB_ICON, middle - TAB_ICON * 0.5)
	if icon.position != icon_position:
		icon.position = icon_position


func _menu() -> PopupMenu:
	var menu := PopupMenu.new()
	var panel := StyleBoxFlat.new()
	panel.bg_color = _design.SC_LOWEST
	panel.border_color = _design.OUTLINE_VAR
	panel.set_border_width_all(1)
	panel.set_corner_radius_all(16)
	panel.set_content_margin_all(8)
	panel.shadow_color = Color(0, 0, 0, 0.12)
	panel.shadow_size = 10
	panel.shadow_offset = Vector2(0, 3)
	menu.add_theme_stylebox_override(&"panel", panel)
	var hover := StyleBoxFlat.new()
	hover.bg_color = _design.SC_HIGH
	hover.set_corner_radius_all(10)
	menu.add_theme_stylebox_override(&"hover", hover)
	var line := StyleBoxLine.new()
	line.color = _design.OUTLINE_VAR
	line.grow_begin = -8.0
	line.grow_end = -8.0
	menu.add_theme_stylebox_override(&"separator", line)
	menu.add_theme_font_override(&"font", _design.sans)
	menu.add_theme_font_size_override(&"font_size", 15)
	menu.add_theme_color_override(&"font_color", _design.ON_SURFACE)
	menu.add_theme_color_override(&"font_hover_color", _design.ON_SURFACE)
	menu.add_theme_color_override(&"font_disabled_color", _design.OUTLINE)
	menu.add_theme_color_override(&"font_accelerator_color", _design.ON_SURFACE_VAR)
	menu.add_theme_constant_override(&"v_separation", 14)
	menu.add_theme_constant_override(&"item_start_padding", 14)
	menu.add_theme_constant_override(&"item_end_padding", 14)
	return menu


func _open_under(menu: PopupMenu, anchor: Control, right_aligned: bool) -> void:
	if menu.visible:
		menu.hide()
		return
	menu.reset_size()
	# Where the anchor is on screen, as a menu button places its popup.
	var rect: Rect2 = anchor.get_screen_transform() * Rect2(Vector2.ZERO, anchor.size)
	var x: float = rect.end.x - menu.size.x if right_aligned else rect.position.x
	menu.position = Vector2i(roundi(x), roundi(rect.end.y + 6.0))
	menu.popup()


func _on_project_item(id: int) -> void:
	match id:
		ProjectItem.PROJECTS:
			_bar.call(&"_on_workslist")
		ProjectItem.RENAME:
			_name_field.grab_focus()
			_name_field.call(&"select_all")
		ProjectItem.SAVE:
			_bar.call(&"_on__released")
		ProjectItem.DOWNLOAD:
			_bar.call(&"export_model")


func _on_action_item(id: int) -> void:
	match id:
		ActionItem.DOWNLOAD:
			_bar.call(&"export_model")
		ActionItem.PROFILE:
			_bar.call(&"_on_login_released")


## `deferred` is skipped: during a lesson the project is not saved at all,
## so a dot there would never go away.
func _on_autosave_status(state: StringName, _revision: int, _reason: String) -> void:
	match state:
		&"queued":
			_set_state(&"pending", saved_at)
		&"saving":
			_set_state(&"saving", saved_at)
		&"saved":
			_set_state(&"saved", Time.get_time_string_from_system().substr(0, 5))
		&"failed":
			_set_state(&"failed", saved_at)


func _on_project_saved(ok: bool) -> void:
	if ok:
		_set_state(&"saved", Time.get_time_string_from_system().substr(0, 5))
	else:
		_set_state(&"failed", saved_at)


## The dot shows unsaved work; a save in progress keeps it as it was.
func _set_state(state: StringName, time: String) -> void:
	save_state = state
	saved_at = time
	if state != &"saving":
		dot.visible = state != &"saved"
	var face := StyleBoxFlat.new()
	face.bg_color = _design.STOP if state == &"failed" else _design.ON_SURFACE_VAR
	face.set_corner_radius_all(999)
	dot.add_theme_stylebox_override(&"panel", face)
	var status := status_text()
	dot.tooltip_text = status
	_name_field.tooltip_text = status


## What the save dot's tooltip says.
func status_text() -> String:
	match save_state:
		&"pending":
			return _t("pending")
		&"saving":
			return _t("saving")
		&"failed":
			return _t("failed")
	return _t("saved_at") % saved_at if not saved_at.is_empty() else _t("saved")


func _apply_texts() -> void:
	_lang = str(_glob.get_lang())
	chevron.tooltip_text = _t("menu")
	project_menu.clear()
	project_menu.add_item(_t("projects"), ProjectItem.PROJECTS)
	project_menu.add_item(_t("rename"), ProjectItem.RENAME)
	project_menu.add_item(_t("save"), ProjectItem.SAVE, (KEY_MASK_CMD_OR_CTRL | KEY_S) as Key)
	project_menu.add_item(_t("download_short"), ProjectItem.DOWNLOAD)
	actions_menu.clear()
	actions_menu.add_item(_t("download"), ActionItem.DOWNLOAD)
	actions_menu.add_separator()
	actions_menu.add_item(_t("profile"), ActionItem.PROFILE)
	_set_state(save_state, saved_at)


## Dev only, for screenshots with --design-preview-shot: opens a menu
## (`actions`, `project`) or shows the unsaved dot (`dirty`) a few seconds
## after launch, once the preview project is open.
func _preview(what: String) -> void:
	await _bar.get_tree().create_timer(6.0).timeout
	match what:
		"actions":
			open_actions()
		"project":
			open_project_menu()
		"dirty":
			_set_state(&"pending", saved_at)


func _t(key: String) -> String:
	var variants: Dictionary = TEXT[key]
	return variants.get(_lang, variants["ru"])
