extends SceneTree

const GraphicsQualityConfigScript := preload("res://scripts/graphics_quality.gd")

var failures: Array[String] = []


func _initialize() -> void:
	var high: int = GraphicsQualityConfigScript.Level.High
	var medium: int = GraphicsQualityConfigScript.Level.Medium
	var low: int = GraphicsQualityConfigScript.Level.Low

	_expect(
		GraphicsQualityConfigScript.resolve(PackedStringArray(["--graphics=low"])) == low,
		"explicit low argument must select Low"
	)
	_expect(
		GraphicsQualityConfigScript.resolve(PackedStringArray(["--graphics=medium"])) == medium,
		"explicit medium argument must select Medium"
	)
	_expect(
		GraphicsQualityConfigScript.resolve(PackedStringArray(["--graphics=high"])) == high,
		"explicit high argument must select High"
	)
	_expect(
		GraphicsQualityConfigScript.resolve(PackedStringArray())
		== GraphicsQualityConfigScript.auto_level(),
		"missing graphics argument must use GPU auto-detection"
	)
	var dynamic_quality_script: Script = load("res://scripts/graphics_quality.gd")
	if dynamic_quality_script.has_method("resolve_preference"):
		_expect(
			dynamic_quality_script.call("resolve_preference", PackedStringArray(), "low") == low,
			"saved Low preference must be restored when no command-line override exists"
		)
		_expect(
			dynamic_quality_script.call(
				"resolve_preference",
				PackedStringArray(["--graphics=high"]), "low"
			) == high,
			"explicit command-line quality must override the saved preference"
		)
	else:
		failures.append("graphics quality must support a saved preference")

	if dynamic_quality_script.has_method("localized_level_name"):
		_expect(
			dynamic_quality_script.call("localized_level_name", medium, "ru") == "Среднее",
			"Medium must have a Russian UI label"
		)
		_expect(
			dynamic_quality_script.call("localized_level_name", low, "kz") == "Төмен",
			"Low must have a Kazakh UI label"
		)
	else:
		failures.append("graphics quality must expose localized level names")

	var screen_shader := load("res://shaders/block_screen.gdshader") as Shader
	_expect(screen_shader != null, "live-screen shader must load")
	if screen_shader == null:
		_finish()
		return

	GraphicsQualityConfigScript.apply(high)
	var original_msaa := root.msaa_2d
	var original_screen_code := screen_shader.code
	_expect(
		original_screen_code.contains("BLOCK_SAMPLE_SCREEN_TEXTURE"),
		"High must retain the live-screen shader source"
	)
	_expect(not GraphicsQualityConfigScript.bakes_blur(), "High must not bake blur")
	_expect(not GraphicsQualityConfigScript.blur_disabled(), "High must enable blur")

	GraphicsQualityConfigScript.apply(medium)
	_expect(root.msaa_2d == Viewport.MSAA_DISABLED, "Medium must disable 2D MSAA")
	_expect(GraphicsQualityConfigScript.bakes_blur(), "Medium must bake blur")
	_expect(not GraphicsQualityConfigScript.blur_disabled(), "Medium must keep blur enabled")
	_expect(
		screen_shader.code == original_screen_code,
		"quality changes must never mutate the authored screen shader resource"
	)
	var canvas_item := ColorRect.new()
	var source_material := ShaderMaterial.new()
	source_material.shader = screen_shader
	source_material.set_shader_parameter("corner_radius", 17.0)
	canvas_item.material = source_material
	root.add_child(canvas_item)
	GraphicsQualityConfigScript.sync_runtime_screen_materials(root)
	var replacement := canvas_item.material as ShaderMaterial
	_expect(replacement != source_material, "Medium must use a runtime material duplicate")
	_expect(
		replacement != null and replacement.shader == load("res://shaders/block.gdshader"),
		"Medium duplicate must use the bg-only shader without hint_screen_texture"
	)
	_expect(
		replacement != null and is_equal_approx(replacement.get_shader_parameter("corner_radius"), 17.0),
		"runtime material replacement must preserve authored shader parameters"
	)

	GraphicsQualityConfigScript.apply(high)
	_expect(root.msaa_2d == original_msaa, "High must restore the captured 2D MSAA")
	_expect(screen_shader.code == original_screen_code, "High must restore exact screen shader code")
	_expect(canvas_item.material == source_material, "High must restore the original ShaderMaterial")
	_expect(not GraphicsQualityConfigScript.bakes_blur(), "restored High must not bake blur")
	_expect(not GraphicsQualityConfigScript.blur_disabled(), "restored High must enable blur")

	GraphicsQualityConfigScript.apply(low)
	_expect(root.msaa_2d == Viewport.MSAA_DISABLED, "Low must disable 2D MSAA")
	_expect(not GraphicsQualityConfigScript.bakes_blur(), "Low must not bake blur")
	_expect(GraphicsQualityConfigScript.blur_disabled(), "Low must disable backdrop blur")

	var glob_source := FileAccess.get_file_as_string("res://scripts/glob.gd")
	_expect(
		not glob_source.contains(
			"GraphicsQualityConfigScript.apply(GraphicsQualityConfigScript.Level.Medium)"
		),
		"startup must not contain the forced-Medium test hook"
	)

	GraphicsQualityConfigScript.apply(high)
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_graphics_quality")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
