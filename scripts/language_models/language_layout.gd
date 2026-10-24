extends RefCounted
## Read the reference scene rather than maintaining a second set of chrome values.
const CONV = preload("res://scenes/conv2d.tscn")
const INPUT = preload("res://scenes/input_graph.tscn")
const INPUT_BASE = preload("res://scenes/input_base.tscn")
const BASE = preload("res://scenes/base_graph.tscn")
static var _values: Dictionary = {}
static var _input_values: Dictionary = {}

static func _scene_values(scene: PackedScene) -> Dictionary:
	var values: Dictionary={}
	var state:=scene.get_state()
	for i in state.get_node_count():
		var path:=str(state.get_node_path(i)).trim_prefix("./")
		values[path]={}
		for j in state.get_node_property_count(i):
			values[path][str(state.get_node_property_name(i,j))]=state.get_node_property_value(i,j)
	return values

static func property(path: String, key: StringName, fallback: Variant = null) -> Variant:
	if _values.is_empty():
		_values=_scene_values(CONV)
	return _values.get(path,{}).get(str(key),fallback)

static func input_property(path: String, key: StringName, fallback: Variant = null) -> Variant:
	if _input_values.is_empty():
		_input_values=_scene_values(BASE)
		for scene in [INPUT_BASE,INPUT]:
			var input_values:=_scene_values(scene)
			for node_path in input_values:
				if not _input_values.has(node_path): _input_values[node_path]={}
				_input_values[node_path].merge(input_values[node_path],true)
	return _input_values.get(path,{}).get(str(key),fallback)

static func input_origin() -> Vector2:
	return Vector2(input_property("TextureRect",&"offset_left")-input_property("ColorRect",&"offset_left"),input_property("TextureRect",&"offset_top")-input_property("ColorRect",&"offset_top"))

static func input_padding() -> Vector2:
	var image_size: Vector2=Vector2(input_property("TextureRect",&"offset_right")-input_property("TextureRect",&"offset_left"),input_property("TextureRect",&"offset_bottom")-input_property("TextureRect",&"offset_top"))*input_property("TextureRect",&"scale")
	var frame_size:=Vector2(input_property("ColorRect",&"offset_right")-input_property("ColorRect",&"offset_left"),input_property("ColorRect",&"offset_bottom")-input_property("ColorRect",&"offset_top"))
	return frame_size-input_origin()-image_size

static func measure_text(editor: TextEdit, minimum_width: float) -> Vector2:
	var margins:=editor.get_theme_stylebox("normal").get_minimum_size()
	var maximum:=step().x*max_cells()-grid_gap()
	var font: Font=editor.get_theme_font("font")
	var font_size:=editor.get_theme_font_size("font_size")
	var longest:=0.0
	for line in editor.text.split("\n"):
		longest=maxf(longest,font.get_string_size(line,HORIZONTAL_ALIGNMENT_LEFT,-1,font_size).x)
	# TextEdit reserves its scrollbar gutter even when all lines fit vertically.
	var preferred:=longest+margins.x+editor.get_v_scroll_bar().get_minimum_size().x+2*editor.get_theme_constant("caret_width")
	editor.scroll_fit_content_height=false
	editor.scroll_fit_content_width=false
	editor.size.x=maxf(minimum_width,minf(maximum,preferred))
	var rows:=0
	for line in editor.get_line_count(): rows+=1+editor.get_line_wrap_count(line)
	editor.size.y=maxi(1,rows)*editor.get_line_height()+margins.y
	return editor.size

static func frame_position() -> Vector2:
	return Vector2(property("ColorRect",&"offset_left"),property("ColorRect",&"offset_top"))

static func grid_origin() -> Vector2:
	return property(".",&"offset")-frame_position()

static func unit_size() -> Vector2:
	return Vector2(property("unit",&"offset_right")-property("unit",&"offset_left"),property("unit",&"offset_bottom")-property("unit",&"offset_top"))

static func grid_gap() -> float:
	return property(".",&"grid_padding")

static func trailing_padding() -> Vector2:
	return property(".",&"size_add_vec")+frame_position()+Vector2.ONE*grid_gap()

static func content_origin() -> Vector2:
	return Vector2(grid_origin().x,float(property("Label",&"offset_top"))-frame_position().y)

static func header_y() -> float:
	return property("ColorRect/root/Label",&"offset_top")

static func header_scale() -> Vector2:
	return property("ColorRect/root/Label",&"scale")

static func minimum_size() -> Vector2:
	return Vector2(property("ColorRect",&"offset_right"),property("ColorRect",&"offset_bottom"))-frame_position()

static func radius_adjustment() -> Vector2:
	return property("ColorRect",&"instance_shader_parameters/corner_radius_width_add")

static func fit(content: Vector2) -> Vector2:
	return (content_origin()+content+trailing_padding()).max(minimum_size())

static func step() -> Vector2:
	return unit_size()+Vector2.ONE*grid_gap()

static func max_cells() -> int:
	return property(".",&"max_displayed")

static func row_gap() -> float:
	# Space after Conv2D's three parameter rows, before its grid.
	var pitch: float=property("Label2",&"offset_top")-property("Label",&"offset_top")
	return grid_origin().y-content_origin().y-3*pitch
