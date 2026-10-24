extends SceneTree
## The Bento header in the pixel design: tab icons, «⋯ Actions» holding
## Download, the project's save dot and ⌄ menu. The tour's targets keep
## their nodes, and the classic bar (--classic-ui) gets none of it.

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var design: Node = root.get_node("design")
	var glob: Node = root.get_node("glob")
	_expect(design.pixel, "the pixel design is on by default")
	var foreground: Node = load("res://scenes/fg.tscn").instantiate()
	root.add_child(foreground)
	for i in 3:
		await process_frame
	var bar: Control = foreground.get_node("ColorRect")
	var header = bar.get("_header")
	_expect(header != null, "the pixel bar builds the header")
	if header == null:
		_finish()
		return

	var targets := {}
	for node in get_nodes_in_group("tutorial_ui_target"):
		targets[str(node.get_meta("tutorial_target_id", ""))] = node
	for id in ["projects", "simulations", "graphs", "datasets", "axon", "export"]:
		_expect(targets.has(id) and (targets[id] as Control).is_visible_in_tree(), "tour target %s is still shown" % id)
	_expect((targets.get("projects") as Node).get_node("i") is Sprite2D, "the folder button keeps its icon")

	for key in ["env", "graph", "ds"]:
		var button: Control = bar.get("_tab_buttons")[key]
		var icon: TextureRect = button.get_node_or_null("TabIcon")
		var label: Label = button.get_node("Label")
		_expect(icon != null and icon.texture != null, "%s tab has an icon" % key)
		if icon:
			_expect(icon.visible, "%s tab icon is shown" % key)
			_expect(icon.position.x + icon.size.x <= label.position.x + 0.5, "%s tab icon sits before its name" % key)
	var active: TextureRect = bar.get("_tab_buttons")["graph"].get_node("TabIcon")
	var idle: TextureRect = bar.get("_tab_buttons")["ds"].get_node("TabIcon")
	_expect(active.self_modulate == Color.WHITE, "the active tab's icon is white like its name")
	_expect(idle.self_modulate != Color.WHITE, "an idle tab's icon is dark")

	var actions: Control = bar.get("export")
	# The bar restores this text when the window is wide enough; the localiser
	# turns it into the bar's language.
	_expect(str(bar.get("b_texts")[1]).strip_edges() == "Actions", "the old Download button reads Actions")
	var loc: Node = actions.get_node("Loc")
	_expect(loc.localizations_ru.values() == [header.TEXT["actions"]["ru"]], "Actions has its Russian name")
	_expect(loc.localizations_kz.values() == [header.TEXT["actions"]["kz"]], "Actions has its Kazakh name")
	bar._on_export_released()
	await process_frame
	var actions_menu: PopupMenu = header.actions_menu
	_expect(actions_menu.visible, "Actions opens its menu")
	_expect(actions_menu.get_item_index(header.ActionItem.DOWNLOAD) == 0, "Download comes first in Actions")
	_expect(actions_menu.get_item_text(0) == header._t("download"), "Download is named in the bar's language")
	actions_menu.hide()
	_expect(bar.has_method("export_model"), "downloading keeps its own entry point")

	header.open_project_menu()
	await process_frame
	var project_menu: PopupMenu = header.project_menu
	_expect(project_menu.visible, "⌄ opens the project menu")
	_expect(project_menu.item_count == 4, "the project menu has Projects, Rename, Save and Download")
	var save_index: int = project_menu.get_item_index(header.ProjectItem.SAVE)
	_expect(project_menu.get_item_accelerator(save_index) == ((KEY_MASK_CMD_OR_CTRL | KEY_S) as Key), "Save shows Ctrl+S")
	project_menu.hide()
	_expect(bar.get_node("HistoryControls").position.x >= header.chevron.position.x + header.chevron.size.x, "undo stays on the bar, after the project pill")

	_expect(not header.dot.visible, "a freshly opened project shows no unsaved mark")
	glob.autosave_status_changed.emit(&"queued", 1, "test")
	_expect(header.dot.visible and header.dot.tooltip_text == header._t("pending"), "a change shows the unsaved dot")
	glob.autosave_status_changed.emit(&"saving", 1, "test")
	_expect(header.dot.visible and header.dot.tooltip_text == header._t("saving"), "the dot stays while saving")
	glob.autosave_status_changed.emit(&"saved", 1, "test")
	_expect(not header.dot.visible, "a save clears the dot")
	glob.autosave_status_changed.emit(&"saving", 2, "test")
	_expect(not header.dot.visible, "saving alone does not show the dot")
	glob.autosave_status_changed.emit(&"deferred", 2, "lesson")
	_expect(not header.dot.visible, "a lesson's skipped save shows no dot")
	glob.autosave_status_changed.emit(&"saved", 2, "test")
	_expect(header.status_text() == header._t("saved_at") % header.saved_at and header.saved_at.length() == 5, "the tooltip says when it was saved")
	glob.project_saved.emit(false)
	_expect(header.dot.visible and header.dot.tooltip_text == header._t("failed"), "a failed save shows the dot and says so")
	glob.project_saved.emit(true)
	_expect(not header.dot.visible, "a manual save clears the dot")
	glob.autosave_status_changed.emit(&"queued", 3, "load")
	glob.project_opened.emit("test")
	_expect(not header.dot.visible and header.status_text() == header._t("saved"), "an opened project starts as saved")
	foreground.free()

	# The classic bar stays as it was.
	design.pixel = false
	var classic: Node = load("res://scenes/fg.tscn").instantiate()
	root.add_child(classic)
	for i in 2:
		await process_frame
	var classic_bar: Control = classic.get_node("ColorRect")
	_expect(classic_bar.get("_header") == null, "the classic bar gets no pixel header")
	_expect(classic_bar.find_child("TabIcon", true, false) == null, "classic tabs have no icons")
	_expect(not str(classic_bar.get("export").get("text")).contains("Actions"), "the classic Download button keeps its name")
	classic.free()
	design.pixel = true
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_header_pixel")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)
