extends SceneTree

const Quality := preload("res://scripts/graphics_quality.gd")
const ScreenShader := preload("res://shaders/block_screen.gdshader")
const BackgroundShader := preload("res://shaders/block.gdshader")

var failures: Array[String] = []


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	Quality.apply(Quality.Level.High)
	var palette_style := load("res://scripts/node_palette.gd") as Script
	_expect(palette_style != null, "palette style script must load")
	if palette_style == null:
		_finish()
		return
	var global_node := root.get_node_or_null("glob")
	_expect(global_node != null, "glob autoload must exist")
	if global_node == null:
		_finish()
		return
	var previous_base := global_node.get("base_node") as Node2D
	var base := Node2D.new()
	base.name = "PaletteBlurTestBase"
	root.add_child(base)
	global_node.set("base_node", base)
	var fg := Node.new()
	fg.name = "fg"
	base.add_child(fg)
	var top := ColorRect.new()
	top.name = "ColorRect"
	top.material = ShaderMaterial.new()
	(top.material as ShaderMaterial).shader = ScreenShader
	(top.material as ShaderMaterial).set_shader_parameter(&"gaussian_mix", 1.0)
	(top.material as ShaderMaterial).set_shader_parameter(&"blur_level", 3.87)
	fg.add_child(top)
	var palette := ColorRect.new()
	base.add_child(palette)

	_expect(bool(palette_style.call("apply_project_blur_background", palette, 0.0)), "palette style must apply")
	_expect(_shader_is(palette, ScreenShader), "High palette must sample the live screen")
	_expect(_mix_is(palette, 0.0), "palette alone must use the clean one-tap blur")
	_expect(_mix_is(top, 1.0), "top bar material must not be changed")

	for level in [Quality.Level.Medium, Quality.Level.Low]:
		Quality.apply(level)
		_expect(_shader_is(top, BackgroundShader), "Medium/Low top bar must use bg-only shader")
		_expect(_shader_is(palette, BackgroundShader), "Medium/Low palette must use bg-only shader")
		# Recopying the style while the top bar is swapped used to leave this
		# palette permanently on the bg-only shader after returning to High.
		_expect(bool(palette_style.call("apply_project_blur_background", palette, 0.0)), "style refresh must apply")
		_expect(_shader_is(palette, BackgroundShader), "style refresh must preserve Medium/Low routing")
		Quality.apply(Quality.Level.High)
		_expect(_shader_is(palette, ScreenShader), "High must restore live-screen palette blur")
		_expect(_mix_is(palette, 0.0), "High must keep the clean palette blur")
		_expect(_shader_is(top, ScreenShader), "High must restore the top bar")
		_expect(_mix_is(top, 1.0), "top bar Gaussian must remain unchanged")

	global_node.set("base_node", previous_base)
	base.queue_free()
	_finish()


func _shader_is(item: CanvasItem, shader: Shader) -> bool:
	var material := item.material as ShaderMaterial
	return material != null and material.shader == shader


func _mix_is(item: CanvasItem, value: float) -> bool:
	var material := item.material as ShaderMaterial
	return material != null and is_equal_approx(float(material.get_shader_parameter(&"gaussian_mix")), value)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_node_palette_blur_quality")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
