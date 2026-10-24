extends RefCounted
class_name GraphicsQualityConfig

enum Level { High, Medium, Low }

const ARG_PREFIX := "--graphics="
const _SCREEN_SHADER := preload("res://shaders/block_screen.gdshader")
const _BACKGROUND_SHADER := preload("res://shaders/block.gdshader")
static var _original_msaa := -1
static var _bake_blur := false
static var _disable_blur := false
static var _current_level := Level.High
# CanvasItems temporarily redirected to the background-only shader.  The source
# ShaderMaterial is never edited: Godot is therefore unable to serialize away
# its parameters when the graphics preset is changed at runtime.
static var _screen_material_backups: Dictionary = {}


static func auto_level() -> int:
	match RenderingServer.get_video_adapter_type():
		RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU, \
		RenderingDevice.DEVICE_TYPE_CPU, \
		RenderingDevice.DEVICE_TYPE_VIRTUAL_GPU:
			return Level.Medium
	return Level.High


static func resolve(user_args: PackedStringArray) -> int:
	for argument in user_args:
		if not argument.begins_with(ARG_PREFIX):
			continue
		var explicit_level := _parse_level(argument.trim_prefix(ARG_PREFIX))
		if explicit_level >= 0:
			return explicit_level
	return auto_level()


static func resolve_preference(user_args: PackedStringArray, saved_preference: String) -> int:
	for argument in user_args:
		if not argument.begins_with(ARG_PREFIX):
			continue
		var explicit_level := _parse_level(argument.trim_prefix(ARG_PREFIX))
		if explicit_level >= 0:
			return explicit_level
	var saved_level := _parse_level(saved_preference)
	return saved_level if saved_level >= 0 else auto_level()


static func normalize_level_name(value: String) -> String:
	var level := _parse_level(value)
	return level_name(level) if level >= 0 else ""


static func level_name(level: int) -> String:
	match level:
		Level.Low:
			return "low"
		Level.Medium:
			return "medium"
		_:
			return "high"


static func localized_level_name(level: int, language: String) -> String:
	var names := {
		"en": ["High", "Medium", "Low"],
		"ru": ["Высокое", "Среднее", "Низкое"],
		"kz": ["Жоғары", "Орташа", "Төмен"],
	}
	var localized: Array = names.get(language.to_lower(), names["en"])
	return str(localized[clampi(level, Level.High, Level.Low)])


static func apply(level: int) -> void:
	_capture_defaults()
	var root_viewport := (Engine.get_main_loop() as SceneTree).root
	match level:
		Level.Low:
			_current_level = Level.Low
			root_viewport.msaa_2d = Viewport.MSAA_DISABLED
			_bake_blur = false
			_disable_blur = true
			RenderingServer.global_shader_parameter_set(&"_quality_disable_blur", true)
			RenderingServer.global_shader_parameter_set(&"_quality_use_baked_blur", false)
		Level.Medium:
			_current_level = Level.Medium
			root_viewport.msaa_2d = Viewport.MSAA_DISABLED
			_bake_blur = true
			_disable_blur = false
			RenderingServer.global_shader_parameter_set(&"_quality_disable_blur", false)
			RenderingServer.global_shader_parameter_set(&"_quality_use_baked_blur", true)
		_:
			_current_level = Level.High
			root_viewport.msaa_2d = _original_msaa as Viewport.MSAA
			_bake_blur = false
			_disable_blur = false
			RenderingServer.global_shader_parameter_set(&"_quality_disable_blur", false)
			RenderingServer.global_shader_parameter_set(&"_quality_use_baked_blur", false)
	sync_runtime_screen_materials(root_viewport)


static func current_level() -> int:
	return _current_level


static func bakes_blur() -> bool:
	return _bake_blur


static func blur_disabled() -> bool:
	return _disable_blur


## Replaces live-screen materials only on live CanvasItems.  `hint_screen_texture`
## is a compile-time renderer feature, so a uniform branch cannot prevent its
## framebuffer copy.  Medium and Low instead receive a duplicated material using
## the authored bg-only shader; High restores the exact original material.
static func sync_runtime_screen_materials(root: Node) -> void:
	if not is_instance_valid(root):
		return
	if _current_level == Level.High:
		_restore_screen_materials()
		return
	_swap_screen_materials_in(root)


## Replaces an authored screen material after a UI style refresh. If Medium/Low
## already installed a runtime clone on this item, its old backup must be
## discarded before installing and tracking the new material.
static func set_authored_screen_material(item: CanvasItem, material: ShaderMaterial) -> void:
	if not is_instance_valid(item) or material == null:
		return
	_screen_material_backups.erase(item.get_instance_id())
	item.material = material
	if _current_level != Level.High:
		_swap_screen_materials_in(item)


static func _swap_screen_materials_in(node: Node) -> void:
	if node is CanvasItem:
		var canvas_item := node as CanvasItem
		var source_material := canvas_item.material as ShaderMaterial
		var item_id := canvas_item.get_instance_id()
		if source_material != null and source_material.shader == _SCREEN_SHADER and not _screen_material_backups.has(item_id):
			var replacement := source_material.duplicate(true) as ShaderMaterial
			replacement.resource_local_to_scene = true
			replacement.shader = _BACKGROUND_SHADER
			_screen_material_backups[item_id] = {
				"target": weakref(canvas_item),
				"source": source_material,
				"replacement": replacement,
			}
			canvas_item.material = replacement
	for child in node.get_children():
		_swap_screen_materials_in(child)


static func _restore_screen_materials() -> void:
	for item_id in _screen_material_backups.keys():
		var entry: Dictionary = _screen_material_backups[item_id]
		var target := entry["target"].get_ref() as CanvasItem
		# Do not overwrite a material changed by the scene itself while the preset
		# was active; only undo the replacement we installed.
		if is_instance_valid(target) and target.material == entry["replacement"]:
			target.material = entry["source"]
	_screen_material_backups.clear()


static func _parse_level(value: String) -> int:
	match value.strip_edges().to_lower():
		"low":
			return Level.Low
		"medium", "med":
			return Level.Medium
		"high":
			return Level.High
	return -1


static func _capture_defaults() -> void:
	if _original_msaa >= 0:
		return
	var root_viewport := (Engine.get_main_loop() as SceneTree).root
	_original_msaa = root_viewport.msaa_2d
