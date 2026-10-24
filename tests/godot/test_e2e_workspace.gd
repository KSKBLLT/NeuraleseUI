extends "res://tests/godot/support/e2e_app_test.gd"
## End-to-end pass over the workspace without the Python runtime: create a
## project from the "new project" menu, build the lesson 1 (eco_ai) and lesson 3
## (MNIST) graphs from palette drops and wires, undo/redo, save, rename,
## reopen, export/import a .nls file, copy a built-in project, delete,
## datasets (create, CSV import, save and reload), the simulations tab (objects,
## run/pause/stop, dataset generation) and the language switch.

const Repository = preload("res://scripts/builtin_projects_repository.gd")


func _ready() -> void:
	marker = "PASS test_e2e_workspace"
	_run.call_deferred()


func _run() -> void:
	if not await _begin(300.0):
		return
	_step = "create project"
	var project_id := await _create_project_from_menu("E2E урок 1")
	if project_id < 0:
		_finish()
		return
	_step = "lesson 1 graph"
	var lesson1 := await _build_lesson1()
	_check_training_job(lesson1, "eco_ai", 4)
	print("E2E lesson 1 graph: ", graphs._graphs.size(), " nodes")
	_step = "undo/redo"
	await _check_undo_redo(lesson1)
	_step = "save, rename, reopen"
	await _check_save_rename_reopen(project_id)
	_step = "project file export/import"
	await _check_project_file_round_trip()
	_step = "lesson 3 graph"
	await _check_lesson3()
	_step = "built-in copy and delete"
	await _check_builtin_copy_and_delete(project_id)
	_step = "datasets"
	await _check_datasets()
	_step = "simulations"
	await _check_simulation()
	_step = "language"
	await _check_language_switch()
	_finish()


# --- projects ---------------------------------------------------------------

func _create_project_from_menu(project_name: String) -> int:
	var before: Dictionary = (await glob.request_projects()).duplicate()
	var menu: SplashMenu = ui.splash("project_create")
	await _frames(5)
	var line: ValidInput = menu.get_node("ColorRect/Label")
	line.set_line(project_name)
	menu._on_trainn_released()
	var created := -1
	var deadline := Time.get_ticks_msec() + 10000
	while created < 0 and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
		for id in glob.parsed_projects:
			if not before.has(id) and str(glob.parsed_projects[id].get("name", "")) == project_name:
				created = int(id)
	_expect(created >= 0, "the new-project menu creates a project")
	if created < 0:
		return -1
	while glob.get_project_id() != created and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_expect(glob.get_project_id() == created, "the new project becomes the open one")
	_expect(FileAccess.file_exists("user://local_projects/%d.scn" % created), "the new project is written to disk")
	_expect(glob.fg.get_scene_name() == project_name, "the top bar shows the new project's name")
	print("E2E project created: ", created)
	return created


func _check_save_rename_reopen(project_id: int) -> void:
	var expected := _graph_signature()
	glob.fg.set_scene_name("E2E урок 1 (переименован)")
	await glob.fg._on__released()
	var index: Dictionary = await glob.request_projects()
	_expect(str(index.get(str(project_id), {}).get("name", "")) == "E2E урок 1 (переименован)", "save stores the renamed title in the project list")
	await graphs.delete_all()
	_expect(graphs._graphs.is_empty(), "the workspace is cleared before reopening")
	var loaded: bool = await glob.load_scene(str(project_id), true)
	_expect(loaded, "the saved project opens again")
	await _frames(10)
	var actual := _graph_signature()
	_expect(actual == expected, "the reopened project has the same nodes, settings and wires: %s != %s" % [JSON.stringify(actual), JSON.stringify(expected)])
	_expect(glob.fg.get_scene_name() == "E2E урок 1 (переименован)", "the reopened project keeps its new name")
	print("E2E save/rename/reopen: ", actual.size(), " nodes")


## The export dialog's "project" button writes export_project() to a .nls file;
## the works list imports one through import_project_from_file().
func _check_project_file_round_trip() -> void:
	var source_id := glob.get_project_id()
	var expected := _type_counts()
	var bytes: PackedByteArray = await glob.export_project()
	_expect(bytes.size() > 0, "the project exports to a .nls container")
	var path := ProjectSettings.globalize_path("user://e2e_project.nls")
	var file := FileAccess.open(path, FileAccess.WRITE)
	file.store_buffer(bytes)
	file.close()
	await glob.import_project_from_file(path)
	var imported_id := glob.get_project_id()
	_expect(imported_id != source_id, "the import opens as a new project")
	await _frames(60)
	_expect(_type_counts() == expected, "the imported project shows the exported graph: %s" % _type_counts())
	var stored = glob._local_load_project_blob(str(imported_id))
	var stored_count: int = stored.get("graphs", {}).size() if stored is Dictionary else -1
	_expect(stored_count == graphs._graphs.size(), "the imported project is saved with its graph: %d of %d nodes on disk" % [stored_count, graphs._graphs.size()])
	DirAccess.remove_absolute(path)
	await glob.load_scene(str(source_id), true)
	await _frames(10)
	print("E2E .nls export/import: ", stored_count, " nodes on disk")


func _check_builtin_copy_and_delete(own_project_id: int) -> void:
	var repository := Repository.new()
	var projects := repository.load_catalog()
	_expect(projects.size() >= 3 and repository.errors.is_empty(), "the built-in catalog lists its projects: %s" % repository.errors)
	var result: Dictionary = await repository.create_user_copy(&"digits", "ru")
	_expect(bool(result.get("ok", false)), "a built-in project copies into the user's projects: %s" % result)
	var copy_id := str(result.get("project_id", ""))
	if copy_id.is_empty():
		return
	var loaded: bool = await glob.load_scene(copy_id, true)
	_expect(loaded, "the built-in copy opens")
	await _frames(10)
	var types := _type_counts()
	_expect(int(types.get(&"layer", 0)) == 2 and int(types.get(&"classifier", 0)) == 1, "the Digits copy has its two dense layers and answer node: %s" % types)
	_expect(int(types.get(&"output_map", 0)) == 0, "the legacy output map is migrated away on load")

	# The open project cannot be deleted from the list; open the copy, delete ours.
	var deleted: bool = await glob.delete_project(own_project_id)
	_expect(deleted, "deleting a closed project succeeds")
	_expect(not FileAccess.file_exists("user://local_projects/%d.scn" % own_project_id), "the deleted project file is gone")
	var index: Dictionary = await glob.request_projects()
	_expect(not index.has(str(own_project_id)), "the deleted project leaves the project list")
	_expect(index.has(copy_id), "the other project stays in the list")
	print("E2E built-in copy ", copy_id, " opened; project ", own_project_id, " deleted")


# --- graphs -----------------------------------------------------------------

func _check_lesson3() -> void:
	await graphs.delete_all()
	var nodes := await _build_lesson3()
	var input: Graph = nodes["input"]
	_expect(graphs._graphs.size() == 12, "lesson 3 has the plan's twelve nodes: %d" % graphs._graphs.size())
	_expect(input.image_dims == Vector2i(28, 28), "Input2D reads 28 x 28 MNIST pictures: %s" % input.image_dims)
	# 3 x 3 convolution keeps 28 x 28, pooling by 2 gives 14 x 14, eight filters.
	_expect(int(nodes["flat"].display_count) == 14 * 14 * 8, "Flatten counts the pooled feature map: %d" % int(nodes["flat"].display_count))
	_check_training_job(nodes, "mnist", 10)
	print("E2E lesson 3 graph: flatten=", nodes["flat"].display_count)


func _check_undo_redo(nodes: Dictionary) -> void:
	glob.go_window("graph")
	await _frames(30)
	var count := graphs._graphs.size()
	var version := glob.undo_redo.get_version()
	_drop(&"dropout")
	await _frames(3)
	_expect(graphs._graphs.size() == count + 1, "a palette drop adds a node")
	var dropped_version := glob.undo_redo.get_version()
	glob.fg._on_undo_pressed()
	await _frames(5)
	_expect(graphs._graphs.size() == count, "undo removes the dropped node (history %d -> %d -> %d)" % [version, dropped_version, glob.undo_redo.get_version()])
	glob.fg._on_redo_pressed()
	await _frames(5)
	_expect(graphs._graphs.size() == count + 1, "redo brings the dropped node back")
	for graph in graphs._graphs.values():
		if is_instance_valid(graph) and str(graph.get_meta("created_with", "")) == "dropout":
			graph.delete_call()
	await _frames(5)
	_expect(graphs._graphs.size() == count, "deleting the node removes it")
	glob.fg._on_undo_pressed()
	await _frames(5)
	_expect(graphs._graphs.size() == count + 1, "undo restores the deleted node")
	for graph in graphs._graphs.values():
		if is_instance_valid(graph) and str(graph.get_meta("created_with", "")) == "dropout":
			graph.delete_call()
	await _frames(5)
	var wires_before := _wire_count()
	var hidden: Graph = nodes["hidden"]
	var answer_layer: Graph = nodes["answer_layer"]
	hidden.output_keys[0].disconnect_from(answer_layer.input_keys[1], false, true)
	await _frames(3)
	_expect(_wire_count() == wires_before - 1, "a wire can be removed")
	_wire(hidden, "layer_out", answer_layer, "layer_in")
	await _frames(3)
	_expect(_wire_count() == wires_before, "the wire can be drawn again")
	glob.fg._on_undo_pressed()
	await _frames(5)
	_expect(_wire_count() == wires_before - 1, "undo removes the redrawn wire")
	glob.fg._on_redo_pressed()
	await _frames(5)
	_expect(_wire_count() == wires_before, "redo restores the wire")
	glob.fg._on_undo_pressed()
	await _frames(5)
	_expect(_wire_count() == wires_before - 1, "undo after redo removes the wire again")
	glob.fg._on_redo_pressed()
	await _frames(5)
	_expect(_wire_count() == wires_before, "and redo puts it back")
	print("E2E undo/redo: nodes and wires")


# --- datasets ---------------------------------------------------------------

func _check_datasets() -> void:
	glob.go_window("ds")
	await _frames(5)
	var menu: SplashMenu = ui.splash("dataset_create")
	await _frames(5)
	menu.get_node("ColorRect/Label").set_line("e2e_empty")
	menu._on_trainn_released()
	await _frames(10)
	_expect(glob.ds_dump.has("e2e_empty"), "the dataset menu creates an empty dataset")

	var csv_path := ProjectSettings.globalize_path("user://e2e_sensors.csv")
	var csv := FileAccess.open(csv_path, FileAccess.WRITE)
	csv.store_string("weight;transparency;magnetic;hardness;material\n0.9;0.1;1;0.8;1\n0.2;0.9;0;0.7;0\n0.1;0.0;0;0.1;2\n")
	csv.close()
	var importer: SplashMenu = ui.splash("dataset_create", null, null, false, {"path": csv_path})
	await _frames(5)
	importer.get_node("ColorRect/Label").set_line("e2e_csv")
	importer._on_trainn_released()
	var deadline := Time.get_ticks_msec() + 10000
	while not glob.dataset_datas.has("e2e_csv") and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	await _frames(5)
	var imported: Dictionary = glob.dataset_datas.get("e2e_csv", {})
	_expect(imported.get("arr", []).size() == 3, "CSV import keeps every data row: %d" % imported.get("arr", []).size())
	_expect(imported.get("col_names", []).size() == 5, "CSV import keeps the header columns: %s" % imported.get("col_names", []))
	var as_training: Dictionary = nn._local_dataset_to_training_json("e2e_csv")
	_expect(bool(as_training.get("ok", false)) and as_training.get("x", []).size() == 3, "the imported CSV converts into training rows: %s" % as_training.get("error_code", ""))

	await glob.save_datasets()
	await glob.join_ds_save()
	_expect(FileAccess.file_exists("user://datasets/%s.ds" % glob.sha1("e2e_csv")), "the imported dataset is written to disk")
	glob.dataset_datas.erase("e2e_csv")
	glob.ds_dump.erase("e2e_csv")
	glob.load_datasets()
	await glob.join_ds_processing()
	await _frames(5)
	_expect(glob.dataset_datas.has("e2e_csv"), "a saved dataset loads again after restart")
	DirAccess.remove_absolute(csv_path)
	glob.go_window("graph")
	print("E2E datasets: created, CSV imported, saved and reloaded")


# --- simulations ------------------------------------------------------------

func _check_simulation() -> void:
	glob.go_window("env")
	await _frames(10)
	var tab = glob.tree_windows.get("env")
	var editor = tab.get_node_or_null("SimulationEditor") if is_instance_valid(tab) else null
	_expect(editor != null, "the simulations tab has its editor")
	if editor == null:
		return
	editor.load_example(&"side_view_car")
	await _frames(5)
	var objects := _world_object_count(editor)
	editor._on_palette_object_dropped(&"block", Vector2(500, 300))
	await _frames(3)
	_expect(_world_object_count(editor) == objects + 1, "an object dropped from the palette joins the world")
	editor.undo_last()
	await _frames(3)
	_expect(_world_object_count(editor) == objects, "undo takes the dropped object out again")

	var runtime = editor.runtime
	runtime.play()
	await _frames(10)
	_expect(runtime.current_state() == &"running", "the car world starts running")
	editor._on_pause_requested()
	await _frames(3)
	_expect(runtime.current_state() == &"paused", "pause pauses it")
	editor._on_pause_requested()
	await _frames(3)
	_expect(runtime.current_state() == &"running", "pause again resumes it")
	runtime.stop()
	await _frames(3)
	_expect(runtime.current_state() == &"stopped", "stop stops it")

	await editor.start_dataset_generation(40)
	var generated: Dictionary = glob.dataset_datas.get("generated", {})
	_expect(PackedNumericDataset.row_count(generated) == 40, "the car world generates the requested rows: %d" % PackedNumericDataset.row_count(generated))
	_expect(PackedNumericDataset.column_count(generated) == 10, "each row is eight rays plus steer and throttle: %d" % PackedNumericDataset.column_count(generated))
	_expect(FileAccess.file_exists("user://datasets/%s.ds" % glob.sha1("generated")), "the generated dataset is saved")
	glob.go_window("graph")
	print("E2E simulations: objects, run/pause/stop, generated ", PackedNumericDataset.row_count(generated), " rows")


func _world_object_count(editor: Node) -> int:
	return editor.get_state_dictionary().get("objects", {}).get("ids", []).size()


# --- language -----------------------------------------------------------------

func _check_language_switch() -> void:
	var original := str(glob.get_lang())
	var tabs := {
		"ru": ["Графы", "Датасеты"],
		"kz": ["Графтар", "Датасеттер"],
		"en": ["Graphs", "Datasets"],
	}
	for language in ["kz", "en", "ru"]:
		glob.change_lang(language)
		await _frames(10)
		# Block buttons move into runtime wrappers, so look them up by name.
		var graphs_tab := str(glob.fg.find_child("minigames", true, false).text).strip_edges()
		var data_tab := str(glob.fg.find_child("datasets", true, false).text).strip_edges()
		_expect([graphs_tab, data_tab] == tabs[language], "the top bar is in %s: %s" % [language, [graphs_tab, data_tab]])
		_expect(str(glob.get_var("lang", "")) == language, "the chosen language %s is remembered" % language)
	glob.change_lang(original)
	await _frames(5)
	print("E2E language: ru/kz/en")
