extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene_path := "res://scenes/simulations/simulation_editor.tscn"
	_expect(ResourceLoader.exists(scene_path), "simulation editor scene must exist")
	if not ResourceLoader.exists(scene_path):
		_finish()
		return

	var packed := load(scene_path) as PackedScene
	_expect(packed != null, "simulation editor scene must load")
	if packed == null:
		_finish()
		return

	var editor = packed.instantiate()
	_expect(editor != null, "simulation editor scene must instantiate")
	if editor == null:
		_finish()
		return
	get_root().add_child(editor)
	await process_frame
	await process_frame

	for node_path in [
		"WorldRoot",
		"Camera2D",
		"ModelRunner",
		"TrainingBridge",
		"UI/Root/DropSurface",
		"UI/Root/Palette",
		"UI/Root/BrainMappingPanel",
		"UI/Root/DatasetGeneration",
		"UI/Root/DatasetGeneration/EnvironmentView",
		"UI/Root/DatasetGeneration/Dashboard",
		"UI/Root/Inspector",
		"UI/Root/RuntimeBar",
		"UI/Root/RuntimeBar/Background",
		"UI/Root/RuntimeBar/Margin/Controls",
		"UI/Root/GenerationOverlay",
		"UI/Root/GenerationOverlay/Margin/Content/Count",
		"UI/Root/GenerationOverlay/Margin/Content/Progress",
	]:
		_expect(editor.get_node_or_null(node_path) != null, "editor must expose %s" % node_path)
	var runtime_controls := editor.get_node(
		"UI/Root/RuntimeBar/Margin/Controls"
	) as HBoxContainer
	var runtime_buttons := runtime_controls.find_children("*", "BlockComponent", true, false)
	_expect(runtime_buttons.size() == 3, "runtime bar must contain exactly three UIAdapter buttons")
	for button_name in ["simulation_play", "simulation_pause", "simulation_generate"]:
		var runtime_button := runtime_controls.find_child(button_name, true, false)
		_expect(runtime_button != null, "runtime bar must expose %s" % button_name)
		if runtime_button != null:
			_expect(
				runtime_button.released.get_connections().size() > 0,
				"%s must be connected to an action" % button_name
			)
			_expect(
				runtime_button.base_scale.is_equal_approx(Vector2(0.8, 0.8)),
				"%s must render twenty percent smaller" % button_name
			)
	_expect(
		runtime_controls.get_theme_constant("separation") == 12,
		"button scaling must preserve the absolute spacing between controls"
	)
	var generation_overlay := editor.get_node("UI/Root/GenerationOverlay") as Control
	editor._generation_progress_current = 3
	editor._generation_progress_total = 10
	editor._refresh_generation_overlay()
	_expect(
		generation_overlay.get_node("Margin/Content/Progress").value == 3,
		"generation overlay must reflect generated sample progress"
	)
	editor._set_generation_mode(true)
	_expect(generation_overlay.visible, "generation mode must show the top progress overlay")
	var play_control = runtime_controls.find_child("simulation_play", true, false)
	var pause_control = runtime_controls.find_child("simulation_pause", true, false)
	_expect(play_control.is_blocking, "generation must block Play through BlockComponent")
	_expect(pause_control.is_blocking, "generation must block Pause through BlockComponent")
	editor._set_generation_mode(false)
	_expect(not generation_overlay.visible, "leaving generation mode must hide the progress overlay")
	_expect(
		runtime_controls.find_children("*", "Button", true, false).is_empty(),
		"runtime bar must not fall back to default Godot buttons"
	)
	_expect(editor.find_child("ModelStrip", true, false) == null, "editor must not create a model mapping strip")
	_expect(editor.get_node_or_null("DemoPilot") == null, "runtime must not include a hidden demo controller")
	var editor_source := FileAccess.get_file_as_string("res://scripts/simulations/simulation_editor.gd")
	_expect(
		not editor_source.contains("demo_pilot"),
		"Run must never fall back to an expert or scripted controller"
	)
	var dataset_mode := editor.get_node_or_null("UI/Root/DatasetGeneration") as Control
	_expect(dataset_mode != null and not dataset_mode.visible, "dataset generation mode must start hidden")
	if dataset_mode != null:
		var environment_view: Node = dataset_mode.get_node("EnvironmentView")
		var dashboard := dataset_mode.get_node("Dashboard") as Control
		_expect(
			environment_view.has_method("environment_count")
			and environment_view.environment_count() == 1,
			"integrated dataset generation mode must contain only the real live environment"
		)
		_expect(
			dashboard.anchor_top == 0.0 and dashboard.anchor_bottom == 1.0,
			"dataset dashboard must fill the right rail without a blank upper half"
		)
	var palette_panel := editor.get_node_or_null("UI/Root/Palette") as PanelContainer
	if palette_panel != null:
		_expect(
			absf(palette_panel.offset_left) <= 232.0,
			"reference palette must stay narrow enough to preserve the large canvas"
		)
		var palette_style := palette_panel.get_theme_stylebox("panel") as StyleBoxEmpty
		_expect(
			palette_style != null,
			"reference palette must let its shared blur background draw the rail"
		)
		var palette_background := palette_panel.get_node_or_null("Background") as ColorRect
		_expect(
			palette_background != null and palette_background.material is ShaderMaterial,
			"reference palette must reuse the project blur shader"
		)
		var groups_node := palette_panel.find_child("Groups", true, false)
		if groups_node != null:
			var first_entry: Button = null
			# Entries sit in the group, or in its grid of tiles in the pixel design.
			for group in groups_node.get_children():
				var entries := group.find_children("*", "Button", true, false)
				if not entries.is_empty():
					first_entry = entries[0]
					break
			_expect(first_entry != null, "reference palette must contain object entries")
			# The pixel design shows objects as tiles, as in the team's light theme.
			var design_ui: Node = root.get_node_or_null(^"design")
			if first_entry != null and design_ui != null and design_ui.pixel:
				_expect(first_entry.get(&"tile") == true, "pixel palette entries must be tiles")
			elif first_entry != null:
				_expect(
					first_entry.custom_minimum_size.y <= 48.0,
					"reference palette entries must be compact rows rather than cards"
				)
				var entry_style := first_entry.get_theme_stylebox("normal") as StyleBoxFlat
				_expect(
					entry_style != null and entry_style.bg_color.a <= 0.25,
					"reference palette rows must not use opaque card backgrounds"
				)

	_expect(editor.has_method("create_object"), "editor must expose create_object")
	_expect(editor.has_method("delete_selection"), "editor must expose delete_selection")
	_expect(editor.has_method("duplicate_selection"), "editor must expose duplicate_selection")
	_expect(editor.has_method("set_selected_transform"), "editor must expose transform editing")
	_expect(editor.has_method("undo_last"), "editor must expose native UndoRedo undo")
	_expect(editor.has_method("redo_last"), "editor must expose native UndoRedo redo")
	_expect(editor.has_method("start_dataset_generation"), "editor must expose dataset generation mode")
	_expect(
		editor.has_method("recommended_sample_count")
		and editor.recommended_sample_count() >= 1024,
		"dataset generation must automatically choose a safe sample count"
	)
	var grid := editor.get_node_or_null("Grid")
	_expect(
		grid != null and grid.has_method("estimated_visible_dot_count"),
		"simulation grid must expose its visible drawing budget"
	)
	if grid != null and grid.has_method("estimated_visible_dot_count"):
		_expect(
			grid.estimated_visible_dot_count(Vector2(1920.0, 1080.0), Vector2.ONE) < 3000,
			"simulation grid must draw only visible dots instead of the full world grid"
		)
		_expect(
			grid.estimated_visible_dot_count(
				Vector2(1920.0, 1080.0),
				Vector2(0.25, 0.25)
			) < 3500,
			"simulation grid must stay within its drawing budget while zoomed out"
		)

	if editor.has_method("create_object"):
		var block = editor.create_object(&"block", Vector2(180.0, 220.0))
		_expect(block != null, "editor must create a block")
		if block != null:
			_expect(block.get_definition().get("body_kind") == "static", "block must compile as native static physics")
		_expect(
			editor.get_world_state().has_object(block.object_id),
			"virtual objects must be backed by the data-oriented world state"
		)
		editor.select_object(block)
		editor.set_selected_transform(Vector2(210.0, 240.0), 0.3, Vector2(1.2, 0.8))
		_expect(block.position == Vector2(210.0, 240.0), "inspector transform must update position")
		_expect(is_equal_approx(block.rotation, 0.3), "inspector transform must update rotation")
		_expect(block.scale == Vector2(1.2, 0.8), "inspector transform must update scale")

		_expect(
			editor.has_method("object_at_world_position")
			and editor.has_method("begin_object_drag")
			and editor.has_method("update_object_drag")
			and editor.has_method("end_object_drag"),
			"editor must expose one continuous native object drag gesture"
		)
		if (
			editor.has_method("object_at_world_position")
			and editor.has_method("begin_object_drag")
			and editor.has_method("update_object_drag")
			and editor.has_method("end_object_drag")
		):
			await physics_frame
			_expect(
				editor.object_at_world_position(block.global_position) == block,
				"canvas picking must resolve the simulation object before marquee selection"
			)
			var drag_start: Vector2 = block.global_position
			var drag_target := drag_start + Vector2(72.0, -36.0)
			_expect(
				editor.begin_object_drag(block, drag_start),
				"pressing a simulation object must begin dragging it"
			)
			editor.update_object_drag(drag_target)
			editor.end_object_drag()
			_expect(
				block.global_position == drag_target,
				"dragging must move the selected simulation object with the pointer"
			)
			_expect(
				editor.get_world_state().object_data(block.object_id).get("position")
				== block.position,
				"dragging must persist the new object position in the simulation world"
			)
			editor.undo_last()
			editor.select_id(block.object_id)
			block = editor.selected_object
			_expect(
				block.global_position == drag_start,
				"one undo must restore the whole object drag gesture"
			)
			editor.select_object(block)

		editor.duplicate_selection()
		_expect(editor.get_world_state().object_count() == 2, "duplicate must copy the selected object")
		editor.delete_selection()
		_expect(editor.get_world_state().object_count() == 1, "delete must remove the selected object")

		var car = editor.create_object(&"car", Vector2(0.0, 0.0))
		var car_id: String = car.object_id if car != null else ""
		var mapping_panel: Node = editor.get_node_or_null("UI/Root/BrainMappingPanel")
		_expect(mapping_panel != null, "editor must expose the brain mapping rail")
		if mapping_panel == null:
			editor.free()
			_finish()
			return
		_expect(mapping_panel.visible, "selecting a car must open the brain mapping rail")
		_expect(not palette_panel.visible, "brain mapping must replace the object palette without covering it")
		_expect(
			mapping_panel.find_child("ConnectionSummary", true, false) == null,
			"brain mapping must not render the Sensors to Model to Actuators strip"
		)
		var mapping_header := mapping_panel.find_child("Header", true, false)
		_expect(
			mapping_header != null and mapping_header.get_child_count() == 2,
			"brain mapping header must contain only its title and close button"
		)
		_expect(
			mapping_panel.has_method("mapped_input_width")
			and mapping_panel.mapped_input_width() == 9,
			"brain mapping rail must display all nine schema inputs"
		)
		_expect(
			mapping_panel.has_method("mapped_output_width")
			and mapping_panel.mapped_output_width() == 3,
			"brain mapping rail must display steering, throttle, and brake"
		)
		mapping_panel.show_for_agent(car.get_agent(), "Compact model", {
			"input_width": 5,
			"output_width": 2,
		})
		await process_frame
		_expect(
			mapping_panel.mapped_input_width() == 5
			and mapping_panel.mapped_output_width() == 2,
			"brain mapping must auto-map a compatible model shape"
		)
		var car_state: Dictionary = editor.get_world_state().object_data(car.object_id)
		var stored_binding: Dictionary = car_state.get("properties", {}).get("model_binding", {})
		_expect(
			stored_binding.get("input_width") == 5
			and stored_binding.get("output_width") == 2,
			"auto-mapped model bindings must persist in SimulationWorld"
		)
		if mapping_panel.has_method("request_close"):
			mapping_panel.request_close()
			await process_frame
			_expect(not mapping_panel.visible, "closing brain mapping must hide the mapping rail")
			_expect(palette_panel.visible, "closing brain mapping must restore the object palette")
		var incompatible_rover = editor.create_object(&"rover", Vector2(40.0, 0.0))
		_expect(
			incompatible_rover == null,
			"editor must reject a top-down rover in a side-view scene"
		)
		editor.select_object(car)
		editor.delete_selection()
		await process_frame
		_expect(
			editor.get_world_state().perspective_mode == &"auto",
			"removing the last perspective-locked agent must reset the scene"
		)
		var rover = editor.create_object(&"rover", Vector2(40.0, 0.0))
		_expect(rover != null, "editor must create a top-down rover")
		_expect(mapping_panel.visible, "selecting any registered agent must open brain mapping")
		_expect(
			mapping_panel.mapped_input_width() == 11,
			"brain mapping must render the rover binding instead of a fixed car schema"
		)
		_expect(
			mapping_panel.mapped_output_width() == 3,
			"brain mapping must render all rover outputs"
		)
		editor.delete_selection()
		await process_frame
		_expect(
			editor.get_world_state().perspective_mode == &"auto",
			"removing the rover must allow a side-view agent again"
		)
		car = editor.create_object(&"car", Vector2.ZERO)
		car_id = car.object_id if car != null else ""
		_expect(car != null, "editor must recreate the side-view car after rover mapping")
		var flyer = editor.create_object(&"flying_agent", Vector2(80.0, 0.0))
		_expect(flyer != null, "editor must create a flying agent")
		_expect(
			mapping_panel.mapped_input_width() == 13,
			"brain mapping must render the flying-agent input contract"
		)
		_expect(
			mapping_panel.mapped_output_width() == 2,
			"brain mapping must render horizontal and vertical thrust outputs"
		)
		var finish = editor.create_object(&"finish", Vector2(120.0, 0.0))
		var finish_id: String = finish.object_id if finish != null else ""
		var runtime = editor.get_node("Runtime")
		runtime.play()
		var kernel = runtime.kernel()
		_expect(kernel != null, "Play must compile a live simulation kernel")
		if kernel != null:
			var id_to_index: Dictionary = kernel.blueprint().get("id_to_index", {})
			var car_index := int(id_to_index.get(car_id, -1))
			var finish_index := int(id_to_index.get(finish_id, -1))
			_expect(car_index >= 0 and finish_index >= 0, "runtime kernel must preserve stable editor object ids")
			if car_index >= 0 and finish_index >= 0:
				kernel._set_position(car_index, kernel.position_for(finish_index))
				runtime._profiled_physics_process(1.0 / 60.0)
		_expect(
			runtime.current_state() == &"running",
			"finish must defer state changes until the kernel event callback is complete"
		)
		await process_frame
		_expect(runtime.current_state() == &"paused", "finish must pause the compiled simulation")
		runtime.play()
		var live_object_count: int = editor.get_world_state().object_count()
		var live_block = editor.create_object(&"block", Vector2.ZERO)
		_expect(
			live_block != null
			and editor.get_world_state().object_count() == live_object_count + 1,
			"live editing must allow adding world objects while physics is active"
		)
		editor.select_id(live_block.object_id)
		editor.duplicate_selection()
		_expect(
			editor.get_world_state().object_count() == live_object_count + 2,
			"live editing must allow duplicating world objects"
		)
		editor.delete_selection()
		_expect(
			editor.get_world_state().object_count() == live_object_count + 1,
			"live editing must allow deleting world objects"
		)
		editor.select_id(car_id)
		car = editor.selected_object
		_expect(
			editor.begin_gizmo_transform(&"rotate", car.global_position),
			"agents must support live transform gestures while physics is active"
		)
		editor.end_gizmo_transform()
		editor.select_id(finish_id)
		finish = editor.selected_object
		_expect(
			editor.begin_gizmo_transform(&"rotate", finish.global_position),
			"static zones must remain editable while the simulation is running"
		)
		editor.end_gizmo_transform()
		runtime.stop()

		editor.select_id(car_id)
		car = editor.selected_object
		var persisted_car_id: String = car_id
		var persisted_binding: Dictionary = car.get_agent().get_model_binding()
		var saved_world: Dictionary = editor.get_state_dictionary()
		editor.load_state_dictionary(saved_world)
		await process_frame
		editor.select_id(persisted_car_id)
		var reloaded_car: Node = editor.selected_object
		_expect(
			is_instance_valid(reloaded_car) and is_instance_valid(reloaded_car.get_agent()),
			"saved simulation agents must be rebuilt when the world is reloaded"
		)
		if is_instance_valid(reloaded_car) and is_instance_valid(reloaded_car.get_agent()):
			_expect(
				reloaded_car.get_agent().get_model_binding() == persisted_binding,
				"custom sensor and actuator mappings must survive a full world reload"
			)
		var sync_error: String = editor._synchronize_agent_bindings_to_project_model(11, 2)
		var synchronized_binding: Dictionary = editor.get_world_state().object_data(
			persisted_car_id
		).get("properties", {}).get("model_binding", {})
		_expect(sync_error.is_empty(), "model launch must auto-map a compatible changed graph shape")
		_expect(
			synchronized_binding.get("input_width") == 11
			and synchronized_binding.get("output_width") == 2,
			"model launch must replace stale 8-input agent mappings before runtime compilation"
		)

	var palette = editor.get_node_or_null("UI/Root/Palette")
	if palette != null and palette.has_method("displayed_groups"):
		var catalog = load("res://scripts/simulations/simulation_object_catalog.gd")
		_expect(
			palette.displayed_groups() == catalog.grouped_types(),
			"palette must be generated from the catalog without a second hardcoded list"
		)
	else:
		_expect(false, "palette must expose its generated groups")

	var drop_surface = editor.get_node_or_null("UI/Root/DropSurface")
	if drop_surface != null:
		_expect(
			drop_surface._can_drop_data(Vector2(240.0, 180.0), {
				"simulation_type_id": "circle",
			}),
			"canvas must accept native simulation palette drag data"
		)
		_expect(
			not drop_surface._can_drop_data(Vector2.ZERO, {"unexpected": true}),
			"canvas must reject unrelated drag data"
		)
		var count_before_drop: int = editor.get_world_state().object_count()
		drop_surface._drop_data(Vector2(240.0, 180.0), {
			"simulation_type_id": "circle",
		})
		_expect(
			editor.get_world_state().object_count() == count_before_drop + 1,
			"dropping a palette item must create exactly one simulation object"
		)

	if editor.has_method("undo_last") and editor.has_method("redo_last"):
		var count_before_history: int = editor.get_world_state().object_count()
		editor.create_object(&"block", Vector2(300.0, 180.0))
		_expect(
			editor.get_world_state().object_count() == count_before_history + 1,
			"history test object must be created"
		)
		editor.undo_last()
		_expect(
			editor.get_world_state().object_count() == count_before_history,
			"undo must restore the world before the editor action"
		)
		editor.redo_last()
		_expect(
			editor.get_world_state().object_count() == count_before_history + 1,
			"redo must restore the world after the editor action"
		)

	if editor.has_method("load_default_world") and editor.has_method("set_content_top"):
		get_root().size = Vector2i(576, 360)
		editor.load_default_world()
		editor.set_content_top(48.0)
		await process_frame
		await process_frame
		var compact_actions := editor.get_node(
			"UI/Root/RuntimeBar/Margin/Controls"
		) as Control
		_expect(
			compact_actions.size.x <= 560.0,
			"runtime controls must fit without clipping in a compact desktop window"
		)
		var editor_camera := editor.get_node("Camera2D") as Camera2D
		var compact_zoom := editor_camera.zoom.x
		get_root().size = Vector2i(960, 540)
		editor.set_content_top(48.0)
		await process_frame
		await process_frame
		var narrow_actions := editor.get_node(
			"UI/Root/RuntimeBar/Margin/Controls"
		) as Control
		_expect(
			narrow_actions.size.x <= 944.0,
			"runtime controls must fit a Retina-scaled 1080p desktop without clipping"
		)
		get_root().size = Vector2i(1200, 800)
		editor.set_content_top(48.0)
		await process_frame
		await process_frame
		_expect(
			editor_camera.zoom.x > compact_zoom and editor_camera.zoom.x > 0.5,
			"editor must reframe the default world after the viewport grows"
		)

	var glob_node: Node = get_root().get_node_or_null("glob")
	_expect(glob_node != null, "simulation dataset integration requires the existing dataset store")
	var dataset_names_before: Array = glob_node.dataset_datas.keys() if glob_node != null else []
	await editor.start_dataset_generation(10)
	var generated_names: Array[String] = []
	var current_dataset_names: Array = glob_node.dataset_datas.keys() if glob_node != null else []
	for dataset_name in current_dataset_names:
		if not dataset_names_before.has(dataset_name):
			generated_names.append(str(dataset_name))
	_expect(
		generated_names.size() == 1,
		"world generation must register exactly one dataset in the existing Neuralese dataset store"
	)
	if generated_names.size() == 1:
		var generated_dataset: Dictionary = glob_node.dataset_datas[generated_names[0]]
		_expect(
			PackedNumericDataset.row_count(generated_dataset) == 10,
			"the dataset store must receive every requested physics sample"
		)
		_expect(
			generated_dataset.get("outputs_from", 0) > 0,
			"the registered simulation dataset must retain the standard Neuralese schema"
		)
		var training_bridge := editor.get_node("TrainingBridge")
		_expect(
			training_bridge.configured_dataset() == generated_names[0],
			"Train must target the simulation dataset that was just generated"
		)
		glob_node.dataset_datas.erase(generated_names[0])
		glob_node.dirty_datasets.erase(generated_names[0])

	editor.free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_editor")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_editor: %d failure(s)" % failures.size())
	quit(1)
