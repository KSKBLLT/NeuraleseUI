extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var scene_path := "res://scenes/simulations/simulation_tab.tscn"
	var legacy_path := "res://scenes/env_tab.tscn"
	_expect(ResourceLoader.exists(scene_path), "simulation tab scene must exist")
	_expect(ResourceLoader.exists(legacy_path), "legacy Lua environment must remain available")
	if not ResourceLoader.exists(scene_path):
		_finish()
		return

	var packed := load(scene_path) as PackedScene
	_expect(packed != null, "simulation tab must load")
	if packed == null:
		_finish()
		return
	var tab = packed.instantiate()
	_expect(tab != null, "simulation tab must instantiate")
	if tab == null:
		_finish()
		return
	get_root().add_child(tab)
	await process_frame

	_expect(tab.window_name == "env", "simulation tab must preserve the existing env window key")
	_expect(tab.get_node_or_null("SimulationEditor") != null, "simulation tab must contain the editor")
	_expect(tab.has_method("get_simulation_state"), "simulation tab must expose project serialization")
	_expect(tab.has_method("load_simulation_state"), "simulation tab must expose project restore")
	_expect(tab.get_node_or_null("Background") != null, "simulation tab must reuse the graph background scene")
	var background_viewport := tab.get_node_or_null("Background/SubViewport") as SubViewport
	_expect(
		background_viewport != null and background_viewport.size == get_root().size,
		"shared backgrounds must render at the active window resolution"
	)
	var background_shader := FileAccess.get_file_as_string("res://shaders/bg.gdshader")
	_expect(
		background_shader.contains("texture(TEXTURE, UV)"),
		"each background instance must sample its own viewport texture"
	)
	_expect(
		not background_shader.contains("global uniform sampler2D bg"),
		"graph and simulation backgrounds must not share a global texture uniform"
	)
	var background_scene := FileAccess.get_file_as_string("res://scenes/bg.tscn")
	_expect(
		background_scene.contains("texture_filter = 1"),
		"pixel-art background output must preserve nearest-neighbor detail"
	)
	var background_loop := FileAccess.get_file_as_string("res://scripts/bg_loop.gd")
	_expect(
		background_loop.contains("CanvasItem.TEXTURE_FILTER_NEAREST"),
		"background artwork must preserve its native pixel detail"
	)
	var block_shader := FileAccess.get_file_as_string("res://shaders/block.gdshader")
	_expect(
		block_shader.contains("global uniform sampler2D bg"),
		"glass node materials must keep sampling the active workspace background"
	)
	_expect(not tab.get_node("SimulationEditor/Grid").visible, "legacy simulation grid must not cover the shared graph background")
	_expect(tab.has_method("get_texts"), "simulation tab must retain legacy project compatibility")
	_expect(tab.find_child("ModelStrip", true, false) == null, "simulation tab must not add model mapping UI")
	tab.window_hide()
	_expect(not tab.get_node("SimulationEditor/UI").visible, "hidden simulation tab must hide its CanvasLayer")
	_expect(not tab.get_node("Background").visible, "hidden tabs must disable the entire background CanvasLayer")
	tab.window_show()
	await process_frame
	_expect(tab.get_node("SimulationEditor/UI").visible, "shown simulation tab must restore its CanvasLayer")
	_expect(tab.get_node("Background").visible, "shown simulation tab must restore its background CanvasLayer")
	_expect(tab.get_node("Background/TextureRect").visible, "shown simulation tab must restore its background")
	var expected_background := tab.get_node("Background/TextureRect").texture as Texture2D
	_expect(
		tab.get_node("Background").active_texture == expected_background,
		"shown simulation tab must publish its own background for glass materials"
	)
	var background_script := FileAccess.get_file_as_string("res://scripts/bg.gd")
	_expect(
		background_script.contains("func _publish_background(texture: Texture2D)")
		and background_script.contains(
			'RenderingServer.global_shader_parameter_set("bg", texture)'
		),
		"active background must update the global texture sampled by glass materials"
	)

	var glob_source := FileAccess.get_file_as_string("res://scripts/glob.gd")
	_expect(
		glob_source.contains('"env": loaded("res://scenes/simulations/simulation_tab.tscn")'),
		"glob must register the native simulation tab for env"
	)
	var shell_source := FileAccess.get_file_as_string("res://scenes/fg.tscn")
	_expect(shell_source.contains('text = "Simulations"'), "top navigation must say Simulations")
	_expect(shell_source.contains('"simulations": "Симуляции"'), "Russian navigation label must be localized")
	_expect(shell_source.contains('"simulations": "Симуляциялар"'), "Kazakh navigation label must be localized")
	var top_panel_source := FileAccess.get_file_as_string("res://scripts/top_panel.gd")
	_expect(
		top_panel_source.contains("func set_active_window(window_name: String)"),
		"top navigation must expose one active-window state setter"
	)
	_expect(
		glob_source.contains("fg.set_active_window(window_name)"),
		"programmatic window changes must synchronize the top navigation"
	)

	tab.free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_simulation_tab")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	push_error("FAIL test_simulation_tab: %d failure(s)" % failures.size())
	quit(1)
