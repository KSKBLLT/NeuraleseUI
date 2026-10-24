class_name SimulationEditor
extends Node2D

const WorldStateScript = preload("res://scripts/simulations/simulation_world_state.gd")
const HistoryScript = preload("res://scripts/simulations/simulation_command_history.gd")
const SpatialIndexScript = preload("res://scripts/simulations/simulation_spatial_index.gd")
const RendererScript = preload("res://scripts/simulations/simulation_world_renderer.gd")
const VirtualObjectScript = preload("res://scripts/simulations/simulation_virtual_object.gd")
const IOSchema = preload("res://scripts/simulations/simulation_io_schema.gd")
const DatasetSavePolicy = preload("res://scripts/simulations/simulation_dataset_save_policy.gd")
const TransformGizmoScript = preload("res://scripts/simulations/simulation_transform_gizmo.gd")
const SelectionMarqueeScript = preload("res://scripts/simulations/simulation_selection_marquee.gd")
const ExampleWorlds = preload("res://scripts/simulations/simulation_example_worlds.gd")
const ObjectCatalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")
const SampleEstimator = preload("res://scripts/simulations/simulation_sample_estimator.gd")
const NodePaletteStyle = preload("res://scripts/node_palette.gd")

const RUNTIME_BUTTON_MATERIAL := "res://resources/button_mat.tres"
const RUNTIME_BUTTON_CONFIG := "res://resources/lite_config.tres"
const PLAY_BUTTON_COLOR := Color("39c98a")
const STOP_BUTTON_COLOR := Color("e65d5d")

@onready var world_root: Node2D = $WorldRoot
@onready var camera: SimulationCamera = $Camera2D
@onready var drop_surface: Control = $UI/Root/DropSurface
@onready var palette: PanelContainer = $UI/Root/Palette
@onready var brain_mapping_panel: PanelContainer = $UI/Root/BrainMappingPanel
@onready var dataset_generation: Control = $UI/Root/DatasetGeneration
@onready var dataset_view: Control = $UI/Root/DatasetGeneration/EnvironmentView
@onready var dataset_dashboard: PanelContainer = $UI/Root/DatasetGeneration/Dashboard
@onready var inspector: PanelContainer = $UI/Root/Inspector
@onready var runtime: SimulationRuntime = $Runtime
@onready var model_runner: SimulationModelRunner = $ModelRunner
@onready var dataset_generator: SimulationDatasetGenerator = $DatasetGenerator
@onready var training_bridge: Node = $TrainingBridge
@onready var runtime_controls: HBoxContainer = $UI/Root/RuntimeBar/Margin/Controls
@onready var runtime_background: ColorRect = $UI/Root/RuntimeBar/Background
@onready var palette_background: ColorRect = $UI/Root/Palette/Background
@onready var generation_overlay: PanelContainer = $UI/Root/GenerationOverlay
@onready var generation_count: Label = $UI/Root/GenerationOverlay/Margin/Content/Count
@onready var generation_bar: ProgressBar = $UI/Root/GenerationOverlay/Margin/Content/Progress

var play_button
var pause_button
var generate_button

var world_state: SimulationWorldState = WorldStateScript.new()
var selected_object: SimulationVirtualObject = null
var selected_object_ids: Array[String] = []

var _history: SimulationCommandHistory = HistoryScript.new()
var _spatial_index: SimulationSpatialIndex = SpatialIndexScript.new()
var _renderer: SimulationWorldRenderer
var _selection_proxy: SimulationVirtualObject
var _transform_gizmo: SimulationTransformGizmo
var _selection_marquee: SimulationSelectionMarquee
var _performance_probe: SimulationPerformanceProbe
var _expert_trace: Line2D
var _navigator: RefCounted # SimulationNavigator
var _nav_debug: Node2D
var _dragging := false
var _drag_offset := Vector2.ZERO
var _drag_before: Dictionary = {}
var _drag_group_before: Dictionary = {}
var _drag_group_start_positions: Dictionary = {}
var _drag_group_anchor := Vector2.ZERO
var _gizmo_mode: StringName = &""
var _gizmo_before: Dictionary = {}
var _last_layout_viewport_size := Vector2.ZERO
## Pixel design: frame the scene the first time the tab shows a newly opened project.
var _frame_pending := true
var _last_camera_zoom := 1.0
var _generation_running := false
var _leave_after_generation := false
var _generation_cancel_requested := false
var _generation_cancel_in_flight := false
var _play_request_running := false
var _generation_progress_current := 0
var _generation_progress_total := 0
var _latest_generation_metrics: Dictionary = {}
var _latest_dataset_name := ""


var _nav_rebuild_requested := false


func _build_runtime_controls() -> void:
	var complete_definition := {
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
		"fit_max_size": [240, 50],
		"id": "simulation_return",
		"text": "   Return",
		"icon": "res://game_assets/icons/refresh.png",
		"color": Color(0, 0, 0, 0),
		"size": [160, 50],
	}

	_return_btn = UIAdapter.build(complete_definition)
	var localization := Loc.new()
	localization.name = "Localization"
	localization.auto = true
	localization.localizations_ru = {"return": "   Вернуться"}
	localization.localizations_kz = {"return": "   Қайту"}
	_return_btn.add_child(localization)

	_return_btn.set_instance_shader_parameter("outline_color", Color(0.6, 0.6, 0.6))
	_return_btn.set_instance_shader_parameter("outline_width", 2.0)
	_return_btn.released.connect(func():
		camera.go_camera(camera.zoom.x, Vector2.ZERO)
	)

	var ui_root = get_node("UI/Root")
	UIAdapter.mount(ui_root, _return_btn)
	_return_btn.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_return_btn.offset_left = 24
	_return_btn.offset_bottom = -12
	_return_btn.offset_top = -62
	_return_btn.offset_right = 184
	_return_btn.visible = false

	play_button = _create_runtime_button({
		"id": "simulation_play",
		"text": "▶ Play",
		"size": [116, 50],
		"color": PLAY_BUTTON_COLOR,
	}, {
		"play": "▶ Запустить",
		"stop": "■ Стоп",
	}, {
		"play": "▶ Іске қосу",
		"stop": "■ Тоқтату",
	})
	pause_button = _create_runtime_button({
		"id": "simulation_pause",
		"text": "Ⅱ Pause",
		"size": [116, 50],
		"color": Color("e2ad45"),
	}, {"pause": "Ⅱ Пауза"}, {"pause": "Ⅱ Үзіліс"})
	generate_button = _create_runtime_button({
		"id": "simulation_generate",
		"text": "◆ Generate",
		"size": [148, 50],
		"color": Color("5299e8"),
	}, {
		"generate": "◆ Создать датасет",
		"cancel": "× Отмена",
		"cancelling": "… Отмена",
	}, {
		"generate": "◆ Датасет жасау",
		"cancel": "× Болдырмау",
		"cancelling": "… Тоқтатылуда",
	})


	# The button text is changed at runtime when the simulation is paused, so this
	# second localization key must be registered before Loc captures its source.
	var pause_localization := pause_button.get_node_or_null("Localization") as Loc
	if pause_localization:
		pause_localization.localizations_ru["resume"] = "▶ Продолжить"
		pause_localization.localizations_kz["resume"] = "▶ Жалғастыру"
	if design.pixel:
		_apply_pixel_runtime_bar()


## Pixel design: the runtime bar floats as a white pill at the bottom centre;
## "Run" is the green filled action (red while it reads "Stop"), "Pause" is
## neutral and "Create dataset" is a tonal button in the colour of data.
func _apply_pixel_runtime_bar() -> void:
	var frame := _SceneFrame.new()
	frame.palette = palette
	$UI/Root.add_child(frame)
	# Over the world's view, under the palette and every panel after it.
	$UI/Root.move_child(frame, palette.get_index() if palette.get_parent() == $UI/Root else 0)
	glob.project_opened.connect(func(..._args): _frame_pending = true)
	var bar: PanelContainer = $UI/Root/RuntimeBar
	runtime_background.hide()
	bar.set_anchors_preset(Control.PRESET_CENTER_BOTTOM)
	bar.grow_horizontal = Control.GROW_DIRECTION_BOTH
	bar.grow_vertical = Control.GROW_DIRECTION_BEGIN
	bar.offset_left = 0.0
	bar.offset_right = 0.0
	bar.offset_bottom = -24.0
	bar.offset_top = -24.0
	var pill := StyleBoxFlat.new()
	pill.bg_color = design.SC_LOWEST
	pill.set_corner_radius_all(999)
	pill.shadow_color = Color(0, 0, 0, 0.10)
	pill.shadow_size = 10
	pill.shadow_offset = Vector2(0, 3)
	pill.content_margin_left = 14.0
	pill.content_margin_right = 14.0
	bar.add_theme_stylebox_override(&"panel", pill)
	design.set_role(play_button, design.Role.PRIMARY)
	design.set_text_role(play_button.get_node("Label"), 1)
	_sync_play_button_state()
	design.set_role(pause_button, design.Role.QUIET)
	design.set_role(generate_button, design.Role.TONAL)
	design.set_colour(generate_button, &"design_fill", design.CATEGORY[&"data"].fill)


func _create_runtime_button(
	definition: Dictionary,
	localizations_ru: Dictionary[String, String],
	localizations_kz: Dictionary[String, String]
):
	var complete_definition := {
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
		"fit_max_size": [240, 50],
	}
	complete_definition.merge(definition, true)
	var button := UIAdapter.build(complete_definition)
	var localization := Loc.new()
	localization.name = "Localization"
	localization.auto = true
	localization.localizations_ru = localizations_ru
	localization.localizations_kz = localizations_kz
	button.add_child(localization)
	UIAdapter.mount(runtime_controls, button)
	return button


func _apply_blur_backgrounds() -> void:
	NodePaletteStyle.apply_project_blur_background(palette_background)
	NodePaletteStyle.apply_project_blur_background(runtime_background)


func _set_runtime_button_enabled(button, enabled: bool) -> void:
	if not is_instance_valid(button):
		return
	if enabled:
		button.unblock_input()
		button.modulate = Color.WHITE
		button.scaler.modulate = Color.WHITE
	else:
		button.block_input()
		button.modulate = Color(1.0, 1.0, 1.0, 0.42)
		# BlockComponent animates its own modulate every frame. Tint the stable
		# scaler wrapper as well so disabled controls remain visibly disabled.
		button.scaler.modulate = Color(1.0, 1.0, 1.0, 0.42)


func _set_generate_button_state(state: StringName) -> void:
	if not is_instance_valid(generate_button):
		return
	match state:
		&"cancel":
			generate_button.text = "× Cancel"
			_set_runtime_button_enabled(generate_button, true)
		&"cancelling":
			generate_button.text = "… Cancelling"
			_set_runtime_button_enabled(generate_button, false)
		_:
			generate_button.text = "◆ Generate"
			_set_runtime_button_enabled(generate_button, true)
	_refresh_runtime_tooltips()


func _sync_play_button_state() -> void:
	if not is_instance_valid(play_button):
		return
	if runtime.current_state() == &"stopped":
		play_button.text = "▶ Play"
		play_button.color = PLAY_BUTTON_COLOR
	else:
		play_button.text = "■ Stop"
		play_button.color = STOP_BUTTON_COLOR
	if design.pixel:
		var running: bool = runtime.current_state() != &"stopped"
		design.set_colour(play_button, &"design_fill", design.STOP if running else design.GO)
	_refresh_runtime_tooltips()


func _sync_pause_button_state() -> void:
	if not is_instance_valid(pause_button):
		return
	if runtime.current_state() == &"paused":
		pause_button.text = "▶ Resume"
	else:
		pause_button.text = "Ⅱ Pause"
	_refresh_runtime_tooltips()


func _localized(en: String, ru: String, kz: String) -> String:
	match glob.curr_lang:
		"ru": return ru
		"kz": return kz
		_: return en


func _refresh_runtime_tooltips() -> void:
	if not is_instance_valid(play_button):
		return
	if runtime.current_state() == &"stopped":
		play_button.tooltip_text = _localized(
			"Start the simulation and the agent model.",
			"Запустить симуляцию и модель агента.",
			"Симуляция мен агент моделін іске қосу."
		)
	else:
		play_button.tooltip_text = _localized(
			"Stop the simulation and the agent.",
			"Остановить симуляцию и агента.",
			"Симуляция мен агентті тоқтату."
		)
	pause_button.tooltip_text = _localized(
		"Pause the simulation and the agent.",
		"Поставить симуляцию и агента на паузу.",
		"Симуляция мен агентті уақытша тоқтату."
	)
	var recommended := recommended_sample_count()
	if _generation_running:
		var current := int(generate_button.get_meta("generation_current", 0))
		var total := int(generate_button.get_meta("generation_total", recommended))
		generate_button.tooltip_text = _localized(
			"Generating %d/%d samples. Click to cancel." % [current, total],
			"Создано %d из %d примеров. Нажмите, чтобы отменить." % [current, total],
			"%d/%d мысал жасалды. Болдырмау үшін басыңыз." % [current, total]
		)
	else:
		generate_button.tooltip_text = _localized(
			"Generate a dataset automatically (%d samples for this world)." % recommended,
			"Автоматически создать датасет (%d примеров для этого мира)." % recommended,
			"Датасетті автоматты түрде жасау (осы әлемге %d мысал)." % recommended
		)
	_refresh_generation_overlay()


func _refresh_generation_overlay() -> void:
	if not is_instance_valid(generation_count):
		return
	var current := maxi(0, _generation_progress_current)
	var total := maxi(0, _generation_progress_total)
	generation_count.text = _localized(
		"Generated samples: %d / %d" % [current, total],
		"Создано примеров: %d / %d" % [current, total],
		"Жасалған мысалдар: %d / %d" % [current, total]
	)
	generation_bar.max_value = maxi(1, total)
	generation_bar.value = mini(current, total)


var _return_btn: ColorRect

func _ready() -> void:
	var custom_theme := Theme.new()
	var font := load("res://game_assets/fonts/JetBrainsMono-VariableFont_wght.ttf") as Font
	if font != null:
		custom_theme.default_font = font
		custom_theme.default_font_size = 14
	$UI/Root.theme = custom_theme
	_apply_blur_backgrounds()
	_apply_blur_backgrounds.call_deferred()
	_build_runtime_controls()
	_renderer = RendererScript.new()
	_renderer.name = "VirtualWorldRenderer"
	world_root.add_child(_renderer)
	_renderer.configure(world_state, _spatial_index)
	_selection_proxy = VirtualObjectScript.new()
	_selection_proxy.name = "SelectionProxy"
	add_child(_selection_proxy)
	_transform_gizmo = TransformGizmoScript.new()
	_transform_gizmo.name = "TransformGizmo"
	add_child(_transform_gizmo)
	_selection_marquee = SelectionMarqueeScript.new()
	_selection_marquee.name = "SelectionMarquee"
	add_child(_selection_marquee)
	_expert_trace = Line2D.new()
	_expert_trace.name = "ExpertTrace"
	_expert_trace.default_color = Color("ff4455")
	_expert_trace.width = 4.0
	_expert_trace.begin_cap_mode = Line2D.LINE_CAP_ROUND
	_expert_trace.end_cap_mode = Line2D.LINE_CAP_ROUND
	_expert_trace.joint_mode = Line2D.LINE_JOINT_ROUND
	_expert_trace.z_index = 100
	world_root.add_child(_expert_trace)
	_history.configure(world_state)
	_spatial_index.rebuild(world_state)
	world_state.structure_changed.connect(_on_document_structure_changed)
	world_state.structure_changed.connect(func(): if palette.has_method("sync_perspective"): palette.sync_perspective(world_state.perspective_mode))
	world_state.object_changed.connect(_on_document_object_changed)
	world_state.changed.connect(func(): if palette.has_method("sync_perspective"): palette.sync_perspective(world_state.perspective_mode))
	runtime.configure(world_state, _renderer)
	model_runner.configure(runtime)
	drop_surface.object_dropped.connect(_on_palette_object_dropped)
	palette.object_requested.connect(_on_palette_object_requested)
	inspector.transform_changed.connect(_on_inspector_transform_changed)
	inspector.duplicate_requested.connect(duplicate_selection)
	inspector.delete_requested.connect(delete_selection)
	play_button.released.connect(_on_play_requested)
	pause_button.released.connect(_on_pause_requested)
	generate_button.released.connect(_on_generate_requested)
	dataset_generator.expert_path_generated.connect(_on_expert_path_generated)
	dataset_generator.progress.connect(_on_generation_progress)
	dataset_generator.sample_preview.connect(_on_generation_preview)
	dataset_generator.metrics_updated.connect(_on_generation_metrics)
	dataset_generator.episode_completed.connect(_on_episode_completed)
	brain_mapping_panel.close_requested.connect(_on_brain_mapping_closed)
	brain_mapping_panel.binding_changed.connect(_on_brain_mapping_binding_changed)
	dataset_dashboard.stop_requested.connect(_on_dataset_stop_requested)
	runtime.runtime_state_changed.connect(_on_runtime_state_changed)
	runtime.runtime_event.connect(_on_runtime_event)
	if not glob.language_changed.is_connected(_refresh_runtime_tooltips):
		glob.language_changed.connect(_refresh_runtime_tooltips)
	_refresh_runtime_tooltips()
	_sync_play_button_state()
	_sync_pause_button_state()
	_performance_probe = PerformanceProbe.new()
	_performance_probe.name = "PerformanceProbe"
	add_child(_performance_probe)
	_performance_probe.configure(self)

	var nav_script = load("res://scripts/simulations/navigation/simulation_navigator.gd")
	if nav_script:
		_navigator = nav_script.new()
		var debug_script = load("res://scripts/simulations/navigation/simulation_nav_debug_overlay.gd")
		_nav_debug = debug_script.new()
		_nav_debug.z_index = 100
		_nav_debug.navigator = _navigator
		add_child(_nav_debug)
		print("Simulation Navigator successfully loaded!")
	else:
		print("Failed to load simulation_navigator.gd!")





func create_object(type_id: StringName, world_position: Vector2) -> Node:
	if not _can_change_world_structure():
		return null

	var def = ObjectCatalog.definition(type_id)
	var obj_persp = StringName(def.get("compatible_perspective", &"any"))
	print("[DEBUG-PERSPECTIVE] create_object called for type_id: ", type_id)
	print("[DEBUG-PERSPECTIVE] Object's compatible_perspective: ", obj_persp)
	if obj_persp != &"any":
		var current_persp = world_state.perspective_mode
		print("[DEBUG-PERSPECTIVE] Current scene perspective: ", current_persp)
		if current_persp == &"auto":
			print("[DEBUG-PERSPECTIVE] Scene was auto, locking to: ", obj_persp)
			world_state.perspective_mode = obj_persp
		elif current_persp != obj_persp:
			print("[DEBUG-PERSPECTIVE] Perspective mismatch! Scene is ", current_persp, " but object needs ", obj_persp)
			if is_instance_valid(ui):
				var msg = "Can't add side-view agent to top-down scene" if current_persp == &"top_down" else "Can't add top-down agent to side-view scene"
				ui.error(msg)
				print("[DEBUG-PERSPECTIVE] Error toast shown.")
			else:
				print("[DEBUG-PERSPECTIVE] glob.ui is invalid, couldn't show toast.")
			return null
	print("[DEBUG-PERSPECTIVE] Perspective check passed, spawning object.")

	var object_id := world_state.add_object(type_id, Transform2D(0.0, world_position))
	if object_id.is_empty():
		return null
	var after: Dictionary = world_state.object_data(object_id)
	_history.push_change("Add simulation object", {}, after, world_state.index_of(object_id))
	select_id(object_id)
	return selected_object


func _physics_process(_delta: float) -> void:
	if _nav_rebuild_requested and _navigator != null and _nav_debug != null:
		var k = runtime.kernel()
		if k and k._physics:
			var hazard_bounds: Array[Rect2] = []
			var physics_kind: StringName = &"side_view_car"

			var agent_size = Vector2(32, 32)
			for i in range(k._blueprint.definitions.size()):
				var def = k._blueprint.definitions[i]
				var t_str = str(k._blueprint.get("types", [])[i])
				var role = str(def.get("dataset_role", ""))

				if t_str in ["spikes", "lava"] or role == "hazard":
					var p: Vector2 = k._blueprint.get("positions")[i]
					var s: Vector2 = k._blueprint.get("sizes")[i]
					var sc: Vector2 = k._blueprint.get("scales")[i]
					var half = s * sc.abs() * 0.5
					hazard_bounds.append(Rect2(p - half, half * 2.0))

				if t_str in ["car", "rover", "flying_agent"]:
					var s: Vector2 = k._blueprint.get("sizes")[i]
					var sc: Vector2 = k._blueprint.get("scales")[i]
					agent_size = s * sc.abs()

				if t_str == "car":
					physics_kind = &"side_view_car"
				elif t_str == "rover" or t_str == "top_down_rover":
					physics_kind = &"top_down_rigid"
				elif t_str == "flying_agent":
					physics_kind = &"flying_rigid"

			var islands_raw = world_state.world_bounds_islands(256.0)
			var safe_bounds = Rect2(-4000, -4000, 8000, 8000)
			var final_islands: Array[Rect2] = []
			for island in islands_raw:
				var clamped = island.intersection(safe_bounds)
				if clamped.has_area():
					final_islands.append(clamped)

			_navigator.rebuild_navigation(k._physics._space, final_islands, physics_kind, {"jump_velocity": 450.0, "max_speed": 350.0, "size": agent_size}, hazard_bounds)
			_nav_debug.queue_redraw()
		_nav_rebuild_requested = false

func select_object(object: Variant) -> void:
	if object is String:
		select_id(object)
	elif is_instance_valid(object) and object.get("object_id") != null:
		select_id(str(object.object_id))
	else:
		select_id("")


func select_id(object_id: String) -> void:
	select_ids([object_id] if not object_id.is_empty() else [], object_id)


func select_ids(object_ids: Array, primary_id: String = "") -> void:
	var normalized: Array[String] = []
	for object_id in object_ids:
		if not object_id.is_empty() and world_state.has_object(object_id) and not normalized.has(object_id):
			normalized.append(object_id)
	selected_object_ids = normalized
	var selected_id := primary_id if normalized.has(primary_id) else (normalized[-1] if not normalized.is_empty() else "")
	if selected_id.is_empty():
		selected_object = null
		_renderer.set_selected_ids([])
		_transform_gizmo.clear_target()
		inspector.clear_object()
		brain_mapping_panel.hide()
		if not dataset_generation.visible:
			palette.show()
		_sync_right_rail_layout()
		return
	_selection_proxy.bind_document_object(world_state, selected_id)
	selected_object = _selection_proxy
	_renderer.set_selected_ids(selected_object_ids)
	if selected_object_ids.size() > 1:
		_transform_gizmo.clear_target()
		inspector.clear_object()
		brain_mapping_panel.hide()
		if not dataset_generation.visible:
			palette.show()
		_sync_right_rail_layout()
		return
	_sync_transform_gizmo()
	inspector.show_object(selected_object)
	if dataset_generation.visible:
		palette.hide()
		brain_mapping_panel.hide()
		inspector.hide()
		return
	if str(selected_object.get_definition().get("body_kind", "")) == "agent":
		palette.hide()
		var agent: SimulationVirtualObject = selected_object.get_agent()
		brain_mapping_panel.show_for_agent(agent, _project_model_name(), _project_model_contract(agent))
	else:
		brain_mapping_panel.hide()
		palette.show()
	_sync_right_rail_layout()


func delete_selection() -> void:
	if not _can_change_world_structure() or selected_object_ids.is_empty():
		return

	var to_delete = []
	for object_id in selected_object_ids:
		var idx = world_state.index_of(object_id)
		if idx >= 0:
			to_delete.append({"id": object_id, "index": idx, "data": world_state.object_data(object_id)})

	to_delete.sort_custom(func(a, b): return a["index"] < b["index"])

	var changes: Array[Dictionary] = []
	for item in to_delete:
		changes.append({"before": item["data"], "after": {}, "index": item["index"]})

	for item in to_delete:
		world_state.remove_object(item["id"])

	select_id("")

	if changes.size() == 1:
		_history.push_change("Delete simulation object", changes[0]["before"], {}, changes[0]["index"])
	elif changes.size() > 1:
		_history.push_batch_change("Delete simulation objects", changes)


func duplicate_selection() -> void:
	if not _can_change_world_structure() or selected_object_ids.is_empty():
		return

	var changes: Array[Dictionary] = []
	var new_selected_ids: Array[String] = []

	for object_id in selected_object_ids:
		var index := world_state.index_of(object_id)
		if index < 0: continue
		var source := world_state.object_data(object_id)
		var properties: Dictionary = source.get("properties", {}).duplicate(true)
		properties["size"] = source["size"]
		var transform := Transform2D(float(source["rotation"]), source["position"] + Vector2(28.0, 28.0)).scaled_local(source["scale"])
		var new_id := world_state.add_object(StringName(source["type_id"]), transform, properties)
		if not new_id.is_empty():
			new_selected_ids.append(new_id)
			changes.append({
				"before": {},
				"after": world_state.object_data(new_id),
				"index": world_state.index_of(new_id)
			})

	if new_selected_ids.is_empty(): return

	if changes.size() == 1:
		_history.push_change("Duplicate simulation object", {}, changes[0]["after"], changes[0]["index"])
	else:
		_history.push_batch_change("Duplicate simulation objects", changes)

	select_ids(new_selected_ids, new_selected_ids[-1])


func set_selected_transform(next_position: Vector2, next_rotation: float, next_scale: Vector2, next_size: Vector2 = Vector2.ZERO) -> void:
	if not _can_transform_object(selected_object):
		return
	var before: Dictionary = selected_object.serialize()
	_apply_selected_transform(next_position, next_rotation, next_scale, next_size)
	_history.push_change("Transform simulation object", before, selected_object.serialize())


func _apply_selected_transform(next_position: Vector2, next_rotation: float, next_scale: Vector2, next_size: Vector2 = Vector2.ZERO) -> void:
	if not is_instance_valid(selected_object):
		return
	var patch := {"position": next_position, "rotation": next_rotation, "scale": next_scale}
	if str(selected_object.get_definition().get("body_kind", "")) == "agent":
		patch["scale"] = selected_object.scale # prevent scaling agents

	if next_size != Vector2.ZERO:
		if str(selected_object.get_definition().get("body_kind", "")) == "agent":
			patch["size"] = selected_object.object_size # prevent resizing agents
		else:
			patch["size"] = Vector2(maxf(8.0, next_size.x), maxf(8.0, next_size.y))
	world_state.update_object(selected_object.object_id, patch)
	inspector.show_object(selected_object)
	var is_agent = str(selected_object.get_definition().get("body_kind", "")) == "agent"
	_transform_gizmo.show_for(selected_object, camera.zoom.x, is_agent)


func begin_gizmo_transform(mode: StringName, _world_mouse: Vector2) -> bool:
	if not _can_transform_object(selected_object) or mode not in [&"resize", &"rotate"]:
		return false
	if mode == &"resize" and str(selected_object.get_definition().get("body_kind", "")) == "agent":
		return false
	_gizmo_mode = mode
	_gizmo_before = selected_object.serialize()
	camera.set_navigation_enabled(false)
	return true


func update_gizmo_transform(world_mouse: Vector2) -> void:
	if _gizmo_mode.is_empty() or not is_instance_valid(selected_object):
		return
	if _gizmo_mode == &"resize":
		var local_mouse: Vector2 = selected_object.to_local(world_mouse)
		_apply_selected_transform(selected_object.position, selected_object.rotation, selected_object.scale, Vector2(absf(local_mouse.x), absf(local_mouse.y)) * 2.0)
	else:
		var direction := world_mouse - selected_object.global_position
		if direction.length_squared() > 0.0001:
			_apply_selected_transform(selected_object.position, direction.angle() + PI * 0.5, selected_object.scale)


func end_gizmo_transform() -> void:
	if _gizmo_mode.is_empty():
		return
	var label := "Resize simulation object" if _gizmo_mode == &"resize" else "Rotate simulation object"
	_history.push_change(label, _gizmo_before, selected_object.serialize())
	_gizmo_mode = &""
	_gizmo_before = {}
	camera.set_navigation_enabled(true)


func begin_selection_marquee(world_position: Vector2) -> void:
	select_id("")
	_selection_marquee.begin(world_position)
	camera.set_navigation_enabled(false)


func update_selection_marquee(world_position: Vector2) -> void:
	_selection_marquee.update(world_position)


func _selection_workspace_rect() -> Rect2:
	var workspace := get_viewport_rect()
	var top := maxf(workspace.position.y, float($UI/Root.offset_top))
	var bottom := minf(workspace.end.y, $UI/Root/RuntimeBar.get_global_rect().position.y)
	workspace.position.y = top
	workspace.size.y = maxf(0.0, bottom - top)
	# Every right-side tool panel contributes its actual visible boundary. This
	# stays correct if responsive layout or a future panel changes its width.
	for panel in [palette, brain_mapping_panel, inspector]:
		if not is_instance_valid(panel) or not panel.visible:
			continue
		var panel_rect: Rect2 = panel.get_global_rect()
		if panel_rect.position.x > workspace.position.x:
			workspace.size.x = maxf(0.0, minf(workspace.end.x, panel_rect.position.x) - workspace.position.x)
	return workspace


func _selection_world_position_from_pointer() -> Vector2:
	var workspace := _selection_workspace_rect()
	var pointer := get_viewport().get_mouse_position().clamp(workspace.position, workspace.end)
	return get_viewport().get_canvas_transform().affine_inverse() * pointer


func end_selection_marquee() -> Node:
	if not _selection_marquee.is_active():
		return null
	var rect = _selection_marquee.finish()
	var matches := _spatial_index.objects_in_rect(rect)

	if runtime.current_state() != &"stopped" and runtime.kernel() != null:
		var dynamic_ids := PackedStringArray()
		var blueprint = runtime.kernel().blueprint()
		if typeof(blueprint) == TYPE_DICTIONARY:
			var ids = blueprint.get("ids", PackedStringArray())
			for i in blueprint.get("dynamic_indices", PackedInt32Array()):
				dynamic_ids.append(str(ids[i]))

		var static_matches: Array[String] = []
		for object_id in matches:
			if not dynamic_ids.has(object_id):
				static_matches.append(object_id)
		matches = static_matches

		if runtime.kernel().has_method("objects_in_rect"):
			var dynamic_matches = runtime.kernel().objects_in_rect(rect)
			for d_id in dynamic_matches:
				if not matches.has(d_id):
					matches.append(d_id)

	select_ids(matches, matches[-1] if not matches.is_empty() else "")
	camera.set_navigation_enabled(true)
	return selected_object


func get_world_state():
	return world_state


func get_state_dictionary() -> Dictionary:
	var dict: Dictionary = world_state.to_dictionary()
	dict["camera"] = {"x": camera.position.x, "y": camera.position.y, "z": camera.zoom.x}
	return dict


func load_default_world() -> void:
	load_example(&"side_view_car")


func load_example(example_id: StringName) -> void:
	if runtime.current_state() != &"stopped":
		runtime.stop()
	load_state_dictionary(ExampleWorlds.world(example_id))
	select_id("")
	frame_world.call_deferred()


func load_state_dictionary(data: Dictionary, clear_history := true) -> void:
	select_id("")
	world_state.load_dictionary(data)
	if data.has("camera"):
		var c: Dictionary = data["camera"]
		camera.position = Vector2(float(c.get("x", 0.0)), float(c.get("y", 0.0)))
		var z: float = float(c.get("z", 1.0))
		camera.zoom = Vector2(z, z)
	if clear_history:
		_history.clear()


func _process(_delta: float) -> void:
	if not visible:
		return

	if is_instance_valid(_return_btn):
		_return_btn.visible = camera.position.length() > 2000.0 # > 1000 pixels

	if is_visible_in_tree():

		var palette_open: bool = palette.visible and not (palette.has_method("is_collapsed") and palette.is_collapsed())
		var left_space := 0.0
		if brain_mapping_panel.visible:
			left_space = brain_mapping_panel.get_rect().end.x
		elif palette_open:
			left_space = palette.get_rect().end.x
		glob.space_begin.x = left_space
		glob.space_end.x = get_viewport_rect().size.x
		glob.space_end.y = $UI/Root/RuntimeBar.global_position.y
		_update_selection_marquee_edge_pan()
		if _dragging:
			_update_drag_edge_pan()

		if camera.zoom.x != _last_camera_zoom:
			_last_camera_zoom = camera.zoom.x
			_transform_gizmo.set_zoom_value(camera.zoom.x)

	if runtime.current_state() != &"stopped" and runtime.kernel() != null and is_instance_valid(selected_object):
		if not _dragging and _gizmo_mode.is_empty():
			var index := _get_blueprint_index(selected_object.object_id)
			if index >= 0:
				var dynamic: PackedInt32Array = runtime.kernel().blueprint().get("dynamic_indices", PackedInt32Array())
				if dynamic.has(index):
					selected_object.sync_runtime_transform(runtime.kernel().position_for(index), runtime.kernel().rotation_for(index))
					_transform_gizmo.queue_redraw()
		elif _dragging and _drag_group_start_positions.is_empty():
			# Group updates already travel through world_state.object_changed to the
			# live runtime. Avoid submitting the primary body a second time here.
			var index := _get_blueprint_index(selected_object.object_id)
			if index >= 0 and runtime.kernel()._physics != null:
				runtime.kernel()._physics.live_update_object(index, world_state.object_data(selected_object.object_id), runtime.kernel().blueprint()["definitions"][index])


func _update_selection_marquee_edge_pan() -> void:
	if not _selection_marquee.is_active():
		return
	var workspace := _selection_workspace_rect()
	# Keep panning when the pointer has crossed into an excluded panel. The
	# marquee corner itself stays clamped by _selection_world_position_from_pointer,
	# matching the Graphs selector: clamp limits geometry, never navigation.
	var mouse := get_viewport().get_mouse_position().clamp(workspace.position, workspace.end)
	var edge_margin := minf(72.0, minf(workspace.size.x, workspace.size.y) * 0.5)
	var direction := Vector2.ZERO
	if mouse.x < workspace.position.x + edge_margin:
		direction.x = -inverse_lerp(workspace.position.x + edge_margin, workspace.position.x, mouse.x)
	elif mouse.x > workspace.end.x - edge_margin:
		direction.x = inverse_lerp(workspace.end.x - edge_margin, workspace.end.x, mouse.x)
	if mouse.y < workspace.position.y + edge_margin:
		direction.y = -inverse_lerp(workspace.position.y + edge_margin, workspace.position.y, mouse.y)
	elif mouse.y > workspace.end.y - edge_margin:
		direction.y = inverse_lerp(workspace.end.y - edge_margin, workspace.end.y, mouse.y)
	if direction == Vector2.ZERO:
		return
	camera.pan_for_selection_edge(direction)
	# The pointer may stay still at the edge while the camera moves. Updating on
	# every frame keeps the dragged corner attached to that world position.
	update_selection_marquee(_selection_world_position_from_pointer())


func _update_drag_edge_pan() -> void:
	if not _dragging or not _gizmo_mode.is_empty():
		return
	var workspace := _selection_workspace_rect()
	var mouse := get_viewport().get_mouse_position().clamp(workspace.position, workspace.end)
	var edge_margin := minf(72.0, minf(workspace.size.x, workspace.size.y) * 0.5)
	var direction := Vector2.ZERO
	if mouse.x < workspace.position.x + edge_margin:
		direction.x = -inverse_lerp(workspace.position.x + edge_margin, workspace.position.x, mouse.x)
	elif mouse.x > workspace.end.x - edge_margin:
		direction.x = inverse_lerp(workspace.end.x - edge_margin, workspace.end.x, mouse.x)
	if mouse.y < workspace.position.y + edge_margin:
		direction.y = -inverse_lerp(workspace.position.y + edge_margin, workspace.position.y, mouse.y)
	elif mouse.y > workspace.end.y - edge_margin:
		direction.y = inverse_lerp(workspace.end.y - edge_margin, workspace.end.y, mouse.y)
	if direction == Vector2.ZERO:
		return
	camera.pan_for_selection_edge(direction)
	var world_mouse = get_viewport().get_canvas_transform().affine_inverse() * get_viewport().get_mouse_position()
	update_object_drag(world_mouse)

func undo_last() -> void:
	if _can_change_world_structure() and _history.can_undo():
		var selection_before := selected_object_ids.duplicate()
		var primary_before: String = selected_object.object_id if is_instance_valid(selected_object) else ""
		_history.undo()
		select_ids(selection_before, primary_before)


func can_undo() -> bool:
	return _can_change_world_structure() and _history.can_undo()


func redo_last() -> void:
	if _can_change_world_structure() and _history.can_redo():
		var selection_before := selected_object_ids.duplicate()
		var primary_before: String = selected_object.object_id if is_instance_valid(selected_object) else ""
		_history.redo()
		select_ids(selection_before, primary_before)


func can_redo() -> bool:
	return _can_change_world_structure() and _history.can_redo()


func select_first_agent() -> void:
	for index in world_state.object_count():
		if str(ObjectCatalog.definition(world_state.type_at(index)).get("body_kind", "")) == "agent":
			select_id(world_state.id_at(index))
			return


## Pixel design: the scene is a card between the object palette and the window
## edge, with the workspace painted around it, as on the graph window.
class _SceneFrame extends ColorRect:
	const MARGIN := 16.0
	var palette: Control

	# Set up before entering the tree: design adapts every new ColorRect it
	# meets there unless the rect already carries its own material.
	func _init() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		set_anchors_preset(Control.PRESET_FULL_RECT)
		var paint := ShaderMaterial.new()
		paint.shader = preload("res://shaders/graph_frame.gdshader")
		paint.set_shader_parameter(&"frame_color", design.FRAME_BG)
		paint.set_shader_parameter(&"radius", 24.0)
		material = paint

	func _process(_delta: float) -> void:
		var left := MARGIN
		if is_instance_valid(palette) and palette.visible:
			left = palette.position.x + palette.size.x + 12.0
		var top := 6.0
		var card := Vector4(left, top, size.x - left - MARGIN, size.y - top - MARGIN)
		material.set_shader_parameter(&"card_rect", card)


func frame_world() -> void:
	if world_state.object_count() == 0:
		return
	var bounds := world_state.world_bounds().grow(72.0)
	if bounds.size.x <= 0.0 or bounds.size.y <= 0.0:
		return
	var viewport_size := get_viewport_rect().size
	var top_offset := float($UI/Root.offset_top)
	var palette_open: bool = palette.visible and not (palette.has_method("is_collapsed") and palette.is_collapsed())
	var palette_width := palette.size.x if palette_open else 0.0
	var available_size := Vector2(maxf(120.0, viewport_size.x - palette_width - 36.0), maxf(100.0, viewport_size.y - top_offset - 118.0))
	var fit_zoom := clampf(minf(available_size.x / bounds.size.x, available_size.y / bounds.size.y), camera.min_zoom, minf(camera.max_zoom, 1.15))
	camera.zoom = Vector2.ONE * fit_zoom
	var available_center := Vector2(palette_width + available_size.x * 0.5 + 18.0, top_offset + available_size.y * 0.5 + 18.0)
	camera.position = bounds.get_center() - (available_center - viewport_size * 0.5) / fit_zoom
	camera.reset()
	_transform_gizmo.set_zoom_value(camera.zoom.x)


func set_content_top(top_offset: float) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"editor.set_content_top")
	var ui_root := $UI/Root as Control
	if not is_equal_approx(ui_root.offset_top, top_offset):
		ui_root.offset_top = top_offset
	var viewport_size := get_viewport_rect().size
	var viewport_changed := not viewport_size.is_equal_approx(_last_layout_viewport_size)
	_last_layout_viewport_size = viewport_size
	var viewport_width := viewport_size.x
	var palette_collapsed: bool = palette.has_method("is_collapsed") and palette.is_collapsed()
	var palette_tweening: bool = palette.get("_toggle_tween") != null and palette.get("_toggle_tween").is_running()
	if not palette_collapsed and not palette_tweening:
		var palette_left := _SceneFrame.MARGIN if design.pixel else 0.0
		palette.offset_left = palette_left
		palette.offset_right = palette_left + 248.0
	var mapping_width := 340.0 if viewport_width < 900.0 else 432.0
	brain_mapping_panel.offset_left = 0.0
	brain_mapping_panel.offset_right = mapping_width
	_sync_right_rail_layout()
	_apply_responsive_runtime_layout(viewport_width)
	if (viewport_changed or (design.pixel and _frame_pending)) and world_state.object_count() > 0:
		_frame_pending = false
		frame_world.call_deferred()
	PerformanceProbe.end_scope(&"editor.set_content_top", perf_token)


func recommended_sample_count() -> int:
	return SampleEstimator.sample_count(get_state_dictionary(), _active_agent_binding())


func start_dataset_generation(sample_count_override: int = -1) -> void:
	if _generation_running:
		return
	if runtime.current_state() != &"stopped":
		runtime.stop()
	_generation_running = true
	_leave_after_generation = false
	_generation_cancel_requested = false
	_generation_cancel_in_flight = false
	_generation_progress_current = 0
	_expert_trace.clear_points()
	var sample_count := sample_count_override if sample_count_override > 0 else recommended_sample_count()
	_generation_progress_total = sample_count
	_set_generation_mode(true)
	_set_generate_button_state(&"cancel")
	_refresh_generation_overlay()
	var seed := int(Time.get_unix_time_from_system())
	var state := get_state_dictionary()
	var dataset_name := str(state.get("metadata", {}).get("dataset_name", "simulation_dataset"))
	var binding := _active_agent_binding()
	dataset_view.configure_world(state)
	dataset_dashboard.reset(dataset_name, sample_count, int(binding.get("input_width", 0)), int(binding.get("output_width", 0)), state.get("metadata", {}).get("randomization", {}))
	var dataset: Dictionary = await dataset_generator.generate(sample_count, seed, state)
	var row_count := PackedNumericDataset.row_count(dataset)
	var should_save := row_count > 0
	if DatasetSavePolicy.requires_confirmation(dataset, _generation_cancel_requested):
		should_save = false
		if ui != null and ui.has_method("show_dialog_and_get_result"):
			var result: Dictionary = await ui.show_dialog_and_get_result(DatasetSavePolicy.confirmation_spec(row_count))
			should_save = str(result.get("action", "")) == "save"
	if should_save:
		var saved_name := "generated"
		dataset["name"] = saved_name
		glob.ds_dump[saved_name] = glob.create_dataset(randi_range(0, 999999999), saved_name, dataset)
		glob.change_local_ds(saved_name)
		# Generated datasets are already packed and save on the existing dataset
		# worker thread. Persist immediately so a restart cannot discard a dataset
		# that was already used to launch training.
		await glob.save_datasets([saved_name])
		_latest_dataset_name = saved_name
		training_bridge.configure_dataset(saved_name)
	elif row_count == 0 and not dataset_generator.last_error().is_empty():
		ui.error(dataset_generator.last_error())

	if row_count == 0 and dataset_generator.last_error().contains("50 times consecutively"):
		ui.error("Generation aborted: The expert policy failed 50 times consecutively. The environment may be impossible.")

	_generation_running = false
	_generation_cancel_in_flight = false
	_set_generate_button_state(&"generate")
	_set_generation_mode(false)

	if not _leave_after_generation:
		dataset_dashboard.set_complete()


func object_at_world_position(world_position: Vector2) -> Node:
	var preferred: String = selected_object.object_id if is_instance_valid(selected_object) else ""
	var object_id := ""
	var dynamic_ids := PackedStringArray()
	if runtime.current_state() != &"stopped" and runtime.kernel() != null:
		if runtime.kernel().has_method("object_at"):
			object_id = runtime.kernel().object_at(world_position, preferred)
		var blueprint = runtime.kernel().blueprint()
		if typeof(blueprint) == TYPE_DICTIONARY:
			var ids = blueprint.get("ids", PackedStringArray())
			for i in blueprint.get("dynamic_indices", PackedInt32Array()):
				dynamic_ids.append(str(ids[i]))
	if object_id.is_empty():
		object_id = _spatial_index.object_at(world_position, preferred)
		if dynamic_ids.has(object_id):
			object_id = ""
	if object_id.is_empty():
		return null
	_selection_proxy.bind_document_object(world_state, object_id)
	return _selection_proxy


func _get_blueprint_index(object_id: String) -> int:
	if runtime.current_state() != &"stopped" and runtime.kernel() != null:
		var blueprint = runtime.kernel().blueprint()
		if typeof(blueprint) == TYPE_DICTIONARY and blueprint.has("ids"):
			var ids = blueprint["ids"]
			for i in ids.size():
				if str(ids[i]) == object_id:
					return i
	return -1


func begin_object_drag(object: Node, world_mouse: Vector2) -> bool:
	var object_id := str(object.get("object_id")) if is_instance_valid(object) else ""
	if selected_object_ids.size() > 1 and selected_object_ids.has(object_id):
		# Each update still goes through world_state.object_changed, which is the
		# same live-edit path used by a single crate, ball or agent. The batch only
		# groups document/history state; it never pauses or rebuilds the runtime.
		for selected_id in selected_object_ids:
			_sync_dynamic_object_to_runtime_pose(selected_id)
		select_ids(selected_object_ids, object_id)
		return _begin_group_drag(world_mouse)
	# A virtual object is backed by the saved document, while an active agent is
	# rendered from physics. Capture the latter before binding the proxy, so
	# selecting it cannot flash or snap it back to its authored start position.
	_sync_dynamic_object_to_runtime_pose(object_id)
	select_object(object)
	if not _can_transform_object(selected_object):
		return false
	if not _dragging:
		_drag_before = selected_object.serialize()
		_dragging = true

		var actual_position: Vector2 = selected_object.global_position
		if runtime.current_state() != &"stopped" and runtime.kernel() != null:
			var index := _get_blueprint_index(selected_object.object_id)
			if index >= 0:
				actual_position = runtime.kernel().position_for(index)

		_drag_offset = actual_position - world_mouse
		var obj_type = str(selected_object.serialize().get("id", ""))
		if obj_type == "finish" or (selected_object.has_method("is_live_editable") and not selected_object.is_live_editable()):
			_drag_offset = Vector2.ZERO

		update_object_drag(world_mouse)
		camera.set_navigation_enabled(false)
	return true


func _sync_dynamic_object_to_runtime_pose(object_id: String) -> void:
	if object_id.is_empty() or runtime.current_state() == &"stopped" or runtime.kernel() == null:
		return
	var index := _get_blueprint_index(object_id)
	if index < 0:
		return
	var dynamic: PackedInt32Array = runtime.kernel().blueprint().get("dynamic_indices", PackedInt32Array())
	if not dynamic.has(index):
		return
	var current := world_state.object_data(object_id)
	if current.is_empty():
		return
	var current_position: Vector2 = current.get("position", Vector2.ZERO)
	var current_rotation := float(current.get("rotation", 0.0))
	var runtime_position := runtime.kernel().position_for(index)
	var runtime_rotation := runtime.kernel().rotation_for(index)
	if (
		current_position.is_equal_approx(runtime_position)
		and is_equal_approx(current_rotation, runtime_rotation)
	):
		return
	world_state.update_object(object_id, {
		"position": runtime_position,
		"rotation": runtime_rotation,
	})


func _begin_group_drag(world_mouse: Vector2) -> bool:
	if _dragging or not is_instance_valid(selected_object):
		return false
	if not _can_transform_object(selected_object):
		return false
	_drag_group_before.clear()
	_drag_group_start_positions.clear()
	for object_id in selected_object_ids:
		var before := world_state.object_data(object_id)
		if before.is_empty():
			continue
		_drag_group_before[object_id] = before
		_drag_group_start_positions[object_id] = before["position"]
	if _drag_group_start_positions.size() < 2:
		_drag_group_before.clear()
		return false
	_dragging = true
	_drag_group_anchor = _drag_group_start_positions[selected_object.object_id]
	_drag_offset = _drag_group_anchor - world_mouse
	update_object_drag(world_mouse)
	camera.set_navigation_enabled(false)
	return true


func update_object_drag(world_mouse: Vector2) -> void:
	if not _dragging or not is_instance_valid(selected_object):
		return
	if not _drag_group_start_positions.is_empty():
		var delta := world_mouse + _drag_offset - _drag_group_anchor
		for object_id in _drag_group_start_positions:
			if world_state.has_object(object_id):
				world_state.update_object(object_id, {"position": _drag_group_start_positions[object_id] + delta})
		return
	_apply_selected_transform(world_mouse + _drag_offset, selected_object.rotation, selected_object.scale)


func end_object_drag() -> void:
	if not _drag_group_before.is_empty():
		var changes: Array[Dictionary] = []
		for object_id in _drag_group_before:
			changes.append({
				"before": _drag_group_before[object_id],
				"after": world_state.object_data(object_id),
				"index": world_state.index_of(object_id),
			})
		_history.push_batch_change("Move simulation objects", changes)
	elif _dragging and is_instance_valid(selected_object):
		_history.push_change("Move simulation object", _drag_before, selected_object.serialize())
	_dragging = false
	_drag_before = {}
	_drag_group_before = {}
	_drag_group_start_positions = {}
	_drag_group_anchor = Vector2.ZERO
	camera.set_navigation_enabled(true)


func _unhandled_input(event: InputEvent) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"input.editor_unhandled")
	_handle_unhandled_input(event)
	PerformanceProbe.end_scope(&"input.editor_unhandled", perf_token)


func _handle_unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _selection_marquee.is_active():
		update_selection_marquee(_selection_world_position_from_pointer())
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseMotion and not _gizmo_mode.is_empty():
		update_gizmo_transform(get_global_mouse_position())
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed and _gizmo_mode.is_empty():
			var handle: StringName = _transform_gizmo.handle_at(get_global_mouse_position())
			if not handle.is_empty() and begin_gizmo_transform(handle, get_global_mouse_position()):
				get_viewport().set_input_as_handled()
				return
		if not event.pressed and not _gizmo_mode.is_empty():
			end_gizmo_transform()
			get_viewport().set_input_as_handled()
			return
		if event.pressed and not _dragging:
			var object := object_at_world_position(get_global_mouse_position())
			if is_instance_valid(object):
				begin_object_drag(object, get_global_mouse_position())
			else:
				begin_selection_marquee(_selection_world_position_from_pointer())
			get_viewport().set_input_as_handled()
			return
		if not event.pressed and _selection_marquee.is_active():
			end_selection_marquee()
			get_viewport().set_input_as_handled()
			return
	if event is InputEventMouseMotion and _dragging:
		update_object_drag(get_global_mouse_position())
		get_viewport().set_input_as_handled()
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		end_object_drag()
		return
	if event is InputEventKey and event.pressed:
		match event.keycode:
			KEY_DELETE, KEY_BACKSPACE:
				if is_instance_valid(selected_object) and not _generation_running:
					delete_selection()
			KEY_N:
				print("N key pressed! Navigator: ", _navigator, " Debug: ", _nav_debug)
				if _navigator != null and _nav_debug != null:
					# Request Debug Nav rebuild on physics thread
					_nav_rebuild_requested = true
					print("Requested navigation rebuild on physics thread...")

	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
		var object := object_at_world_position(get_global_mouse_position())

		print("want...")
		if is_instance_valid(object):
			var object_id := str(object.get("object_id")) if is_instance_valid(object) else ""
			if not selected_object_ids.has(object_id):
				select_ids([object_id], object_id)
			glob.set_menu_type(self, "edit_sim_obj")
			if glob.menus.has("edit_sim_obj"):
				glob.menus["edit_sim_obj"].show_for_objects(
					selected_object_ids.size(),
					delete_selection,
					duplicate_selection
				)
			get_viewport().set_input_as_handled()
			return
		#print("restt")
		glob.reset_menu_type(self, "edit_sim_obj")
		if _navigator != null and _nav_debug != null:
			var start = Vector2.ZERO
			var found_agent = false
			# Find the agent
			for obj in world_state.objects_array():
				var t_str = str(obj.get("type_id", ""))
				if t_str in ["car", "rover", "flying_agent"]:
					start = obj.get("position", Vector2.ZERO)
					found_agent = true
					break
			if found_agent:
				var target = get_global_mouse_position()
				_nav_debug.current_path = _navigator.get_path(start, target)
				_nav_debug.queue_redraw()
				get_viewport().set_input_as_handled()
				return
	if event is InputEventKey and event.pressed and not event.echo:
		var key_event: InputEventKey = event as InputEventKey
		var command: bool = key_event.ctrl_pressed or key_event.meta_pressed
		if command and key_event.keycode == KEY_Z:
			if key_event.shift_pressed:
				redo_last()
			else:
				undo_last()
			get_viewport().set_input_as_handled()
		elif command and key_event.keycode == KEY_Y:
			redo_last()
			get_viewport().set_input_as_handled()
		elif key_event.keycode in [KEY_DELETE, KEY_BACKSPACE]:
			delete_selection()
			get_viewport().set_input_as_handled()
		elif command and key_event.keycode == KEY_D:
			duplicate_selection()
			get_viewport().set_input_as_handled()


func _on_document_structure_changed() -> void:
	_spatial_index.rebuild(world_state)

	var any_agent_has_perspective = false
	var inferred_perspective: StringName = &"any"
	for i in range(world_state.object_count()):
		var type_id = world_state.type_at(i)
		var def = ObjectCatalog.definition(type_id)
		var obj_persp = StringName(def.get("compatible_perspective", &"any"))
		if obj_persp != &"any":
			any_agent_has_perspective = true
			inferred_perspective = obj_persp
			break

	if not any_agent_has_perspective and world_state.perspective_mode != &"auto":
		print("[DEBUG-PERSPECTIVE] No perspective-locked agents remaining, resetting to auto.")
		world_state.perspective_mode = &"auto"
		if palette.has_method("sync_perspective"):
			palette.sync_perspective(world_state.perspective_mode)
	elif any_agent_has_perspective and world_state.perspective_mode == &"auto":
		print("[DEBUG-PERSPECTIVE] Inferred perspective from loaded world: ", inferred_perspective)
		world_state.perspective_mode = inferred_perspective
		if palette.has_method("sync_perspective"):
			palette.sync_perspective(world_state.perspective_mode)


func _on_document_object_changed(object_id: String) -> void:
	_spatial_index.update_object(object_id)
	if is_instance_valid(selected_object) and selected_object.object_id == object_id:
		_selection_proxy.sync_from_document()
		_transform_gizmo.queue_redraw()
	if runtime.current_state() != &"stopped" and runtime.kernel() != null and runtime.kernel()._physics != null:
		var index := _get_blueprint_index(object_id)
		if index >= 0:
			runtime.kernel()._physics.live_update_object(index, world_state.object_data(object_id), runtime.kernel().blueprint()["definitions"][index])
			if runtime.current_state() == &"paused":
				_renderer.set_runtime_snapshot(runtime.kernel().snapshot())


func _on_palette_object_requested(type_id: StringName) -> void:
	create_object(type_id, camera.get_screen_center_position())


func _on_palette_object_dropped(type_id: StringName, viewport_position: Vector2) -> void:
	create_object(type_id, get_viewport().get_canvas_transform().affine_inverse() * viewport_position)


func _on_inspector_transform_changed(next_position: Vector2, next_rotation: float, next_scale: Vector2, next_size: Vector2) -> void:
	set_selected_transform(next_position, next_rotation, next_scale, next_size)


func _on_brain_mapping_binding_changed(binding: Dictionary) -> void:
	if not is_instance_valid(selected_object):
		return
	var before: Dictionary = world_state.object_data(selected_object.object_id)
	world_state.update_object(selected_object.object_id, {"properties": {"model_binding": binding.duplicate(true)}})
	_selection_proxy.sync_from_document()
	_history.push_change("Change brain mapping", before, world_state.object_data(selected_object.object_id))


func _on_brain_mapping_closed() -> void:
	palette.show()
	_sync_right_rail_layout()


func _on_runtime_state_changed(state: StringName) -> void:
	match state:
		&"running": model_runner.resume()
		&"paused": model_runner.pause()
		&"stopped":
			model_runner.stop()
			select_object(null)
	_sync_play_button_state()
	_sync_pause_button_state()
	_sync_transform_gizmo()


func _on_runtime_event(event: Dictionary) -> void:
	match StringName(event.get("effect", "")):
		&"finish": runtime.call_deferred("pause")
		&"damage", &"reset": runtime.call_deferred("stop")


func _on_generation_progress(current: int, total: int) -> void:
	_generation_progress_current = current
	_generation_progress_total = total
	generate_button.set_meta("generation_current", current)
	generate_button.set_meta("generation_total", total)
	_refresh_runtime_tooltips()


func _on_generation_preview(environment_index: int, preview: Dictionary) -> void:
	dataset_view.update_environment(environment_index, preview)


func _on_generation_metrics(metrics: Dictionary) -> void:
	_latest_generation_metrics = metrics.duplicate(true)
	var binding := _active_agent_binding()
	dataset_dashboard.update_metrics(metrics, str(world_state.metadata.get("dataset_name", "simulation_dataset")), int(binding.get("input_width", 0)), int(binding.get("output_width", 0)))


func _on_dataset_stop_requested() -> void:
	if _generation_running:
		_leave_after_generation = true
		dataset_dashboard.set_stopping()
		_request_generation_cancel()
	else:
		_set_generation_mode(false)
		_expert_trace.clear_points()

func _on_episode_completed(summary: Dictionary) -> void:
	pass

func _on_expert_path_generated(path: Array) -> void:
	if path.size() > 0:
		_expert_trace.clear_points()
		for pos in path:
			_expert_trace.add_point(pos)
		if path.size() == 1:
			_expert_trace.add_point(path[0] + Vector2(1.0, 1.0))


func _set_generation_mode(enabled: bool) -> void:
	dataset_generation.visible = false
	generation_overlay.visible = enabled
	drop_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE if enabled else Control.MOUSE_FILTER_PASS
	inspector.visible = false if enabled else is_instance_valid(selected_object)
	_set_runtime_button_enabled(play_button, not enabled)
	_set_runtime_button_enabled(pause_button, not enabled)
	if enabled:
		palette.hide()
		brain_mapping_panel.hide()
	else:
		select_id(selected_object.object_id if is_instance_valid(selected_object) else "")
	_sync_right_rail_layout()


func _active_agent_binding() -> Dictionary:
	if is_instance_valid(selected_object) and is_instance_valid(selected_object.get_agent()):
		return selected_object.get_model_binding()
	for index in world_state.object_count():
		var definition := ObjectCatalog.definition(world_state.type_at(index))
		if str(definition.get("body_kind", "")) != "agent":
			continue
		var properties := world_state.properties_at(index)
		var binding: Variant = properties.get("model_binding", {})
		return binding.duplicate(true) if binding is Dictionary and not binding.is_empty() else SimulationModelBinding.create_default(StringName(definition.get("agent_id", "side_view_car")))
	return IOSchema.default_binding()


func _can_transform_object(object: Node) -> bool:
	return is_instance_valid(object) and not _generation_running


func _can_change_world_structure() -> bool:
	return not _generation_running


func _sync_transform_gizmo() -> void:
	if _can_transform_object(selected_object):
		var is_agent = str(selected_object.get_definition().get("body_kind", "")) == "agent"
		_transform_gizmo.show_for(selected_object, camera.zoom.x, is_agent)
	else:
		_transform_gizmo.clear_target()


func _open_graph_training() -> void:
	training_bridge.configure_dataset(_latest_dataset_name)
	if not await training_bridge.start_training():
		var message := str(training_bridge.last_error())
		ui.error(message if not message.is_empty() else "The project training flow could not be started.")


func _run_project_model() -> void:
	var binding_error := _synchronize_agent_bindings_to_project_model()
	if not binding_error.is_empty():
		ui.error(binding_error)
		return
	runtime.play()
	if runtime.current_state() != &"running":
		ui.error("The simulation could not be started.")
		return
	if not await model_runner.start():
		runtime.stop()
		var message := str(model_runner.last_error())
		ui.error(message if not message.is_empty() else "The project model could not be started.")


func _on_play_requested() -> void:
	if _play_request_running or _generation_running:
		return
	if runtime.current_state() != &"stopped":
		runtime.stop()
		return
	_play_request_running = true
	_set_runtime_button_enabled(play_button, false)
	await _run_project_model()
	_play_request_running = false
	_set_runtime_button_enabled(play_button, true)


func _on_pause_requested() -> void:
	if _generation_running:
		return
	if runtime.current_state() == &"paused":
		runtime.play()
	elif runtime.current_state() == &"running":
		runtime.pause()


func _on_generate_requested() -> void:
	if _generation_running:
		_request_generation_cancel()
	else:
		start_dataset_generation()


func _request_generation_cancel() -> void:
	if not _generation_running or _generation_cancel_in_flight:
		return
	_generation_cancel_requested = true
	_generation_cancel_in_flight = true
	_set_generate_button_state(&"cancelling")
	dataset_generator.cancel()


func _unique_dataset_name(base_name: String) -> String:
	var normalized := base_name.strip_edges()
	if normalized.is_empty(): normalized = "simulation_dataset"
	if not glob.dataset_datas.has(normalized): return normalized
	var suffix := 2
	while glob.dataset_datas.has("%s_%d" % [normalized, suffix]): suffix += 1
	return "%s_%d" % [normalized, suffix]


func _project_model_name() -> String:
	var value: Variant = glob.get("project_name")
	return str(value) if value != null and not str(value).strip_edges().is_empty() else "Project model"


func _project_model_contract(agent: SimulationVirtualObject) -> Dictionary:
	var binding: Dictionary = agent.get_model_binding() if is_instance_valid(agent) else IOSchema.default_binding()
	var result := {"input_width": int(binding.get("input_width", 0)), "output_width": int(binding.get("output_width", 0))}
	var input_graph: Graph = graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME)
	if not is_instance_valid(input_graph): return result
	result["input_width"] = int(input_graph.useful_properties().get("shape", result["input_width"]))
	for graph in graphs.simple_reach(input_graph, true):
		if is_instance_valid(graph) and StringName(graph.server_typename) == &"ClassifierNode":
			var units: Variant = graph.get("units")
			if units is Array and not units.is_empty(): result["output_width"] = units.size()
	return result


func _synchronize_agent_bindings_to_project_model(
	input_width: int = -1,
	output_width: int = -1
) -> String:
	if input_width <= 0 or output_width <= 0:
		var input_graph: Graph = graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME)
		if not is_instance_valid(input_graph):
			return ""
		input_width = int(input_graph.useful_properties().get("shape", 0))
		output_width = model_runner.graph_output_width(input_graph)
	if input_width <= 0 or output_width <= 0:
		return ""

	for index in world_state.object_count():
		var definition := ObjectCatalog.definition(world_state.type_at(index))
		if str(definition.get("body_kind", "")) != "agent":
			continue
		var agent_id := StringName(definition.get("agent_id", ""))
		var properties := world_state.properties_at(index)
		var existing: Variant = properties.get("model_binding", {})
		if (
			existing is Dictionary
			and SimulationModelBinding.validate(existing).get("valid", false)
			and int(existing.get("input_width", 0)) == input_width
			and int(existing.get("output_width", 0)) == output_width
		):
			continue
		var automatic := SimulationModelBinding.create_auto(
			agent_id,
			input_width,
			output_width
		)
		if automatic.is_empty():
			return (
				"The %s agent cannot be mapped to a model with %d inputs and %d outputs."
				% [str(definition.get("label", agent_id)), input_width, output_width]
			)
		world_state.update_object(
			world_state.id_at(index),
			{"properties": {"model_binding": automatic}}
		)
	if is_instance_valid(selected_object):
		_selection_proxy.sync_from_document()
	return ""


func _sync_right_rail_layout() -> void:
	if not is_node_ready(): return
	inspector.offset_right = -16.0
	inspector.offset_left = inspector.offset_right - 324.0


func _apply_responsive_runtime_layout(viewport_width: float) -> void:
	if (
		not runtime_controls.has_theme_constant_override(&"separation")
		or runtime_controls.get_theme_constant(&"separation") != 12
	):
		runtime_controls.add_theme_constant_override(&"separation", 12)
