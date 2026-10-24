extends SceneTree

const NO_SCREEN_HINT := [
	"res://shaders/block.gdshader",
	"res://shaders/fork.gdshader",
]
const SERIALIZED_ROOTS := ["res://resources", "res://scenes"]

var failures: Array[String] = []


func _initialize() -> void:
	for path in NO_SCREEN_HINT:
		_expect(
			_count_active_lines(path, "hint_screen_texture") == 0,
			"%s must not declare an active screen texture" % path
		)

	var body_path := "res://shaders/block_body.gdshaderinc"
	var body_source := FileAccess.get_file_as_string(body_path)
	_expect(
		_count_active_lines(body_path, "hint_screen_texture") == 1,
		"block shader body must contain exactly one conditional screen texture declaration"
	)
	var guard_position := body_source.find("#ifdef BLOCK_SAMPLE_SCREEN_TEXTURE")
	var sampler_position := body_source.find("hint_screen_texture")
	var guard_end_position := body_source.find("#endif", sampler_position)
	_expect(
		guard_position >= 0 and sampler_position > guard_position and guard_end_position > sampler_position,
		"screen texture declaration must be guarded by BLOCK_SAMPLE_SCREEN_TEXTURE"
	)

	var screen_shader_source := FileAccess.get_file_as_string(
		"res://shaders/block_screen.gdshader"
	)
	_expect(
		screen_shader_source.contains("#define BLOCK_SAMPLE_SCREEN_TEXTURE"),
		"block_screen.gdshader must enable screen texture sampling"
	)

	var serialized_files: Array[String] = []
	for root_path in SERIALIZED_ROOTS:
		_collect_serialized_files(root_path, serialized_files)
	for path in serialized_files:
		var source := FileAccess.get_file_as_string(path)
		if source.contains("shader_parameter/use_bg = false"):
			_expect(
				source.contains('path="res://shaders/block_screen.gdshader"'),
				"%s uses live backdrop blur but is not routed to block_screen.gdshader" % path
			)

	var marquee_source := FileAccess.get_file_as_string(
		"res://scripts/simulations/simulation_selection_marquee.gd"
	)
	_expect(
		marquee_source.contains('preload("res://shaders/block_screen.gdshader")'),
		"simulation marquee must preload the live-screen shader variant"
	)

	for path in serialized_files:
		var source := FileAccess.get_file_as_string(path)
		if source.contains('path="res://shaders/fork.gdshader"'):
			_expect(
				not source.contains("shader_parameter/use_bg = false"),
				"fork.gdshader cannot serve a live-screen backdrop consumer: %s" % path
			)

	_finish()


func _count_active_lines(path: String, needle: String) -> int:
	var count := 0
	for line in FileAccess.get_file_as_string(path).split("\n"):
		var stripped := line.strip_edges()
		if stripped.begins_with("//"):
			continue
		if stripped.contains(needle):
			count += 1
	return count


func _collect_serialized_files(root_path: String, result: Array[String]) -> void:
	for file_name in DirAccess.get_files_at(root_path):
		if file_name.get_extension() in ["tres", "tscn"]:
			result.append(root_path.path_join(file_name))
	for directory_name in DirAccess.get_directories_at(root_path):
		_collect_serialized_files(root_path.path_join(directory_name), result)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_blur_shader_routing")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
