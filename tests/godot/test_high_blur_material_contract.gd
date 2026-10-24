extends SceneTree

const EXPECTED := {
	"res://resources/add_button.tres": [1.0],
	"res://resources/alt.tres": [1.0],
	"res://resources/button_mat.tres": [1.0],
	"res://resources/connection.tres": [1.0],
	"res://resources/connin.tres": [1.0],
	"res://resources/context_menu.tres": [1.0],
	"res://resources/fg_block.tres": [1.0],
	"res://resources/fork.tres": [1.0],
	"res://resources/graph.tres": [1.0],
	"res://resources/neuron_graph.tres": [1.0],
	"res://resources/panel.tres": [1.0],
	"res://resources/panels_mat.tres": [1.0],
	"res://resources/robot_parts_panel.tres": [1.0],
	"res://resources/sas.tres": [1.0],
	"res://scenes/builtin_project_card.tscn": [1.0],
	"res://scenes/dataset_tab.tscn": [1.0],
	"res://scenes/env_tab.tscn": [1.0],
	"res://scenes/fg.tscn": [1.0, 1.0, 0.822000039045],
	"res://scenes/hint.tscn": [1.0],
	"res://scenes/menus.tscn": [1.0],
	"res://scenes/project_card.tscn": [1.0],
	"res://scenes/quest.tscn": [1.0, 1.0],
	"res://scenes/quest_legacy.tscn": [1.0],
	"res://scenes/robot_card.tscn": [1.0],
	"res://scenes/splash.tres": [1.0],
	"res://scenes/tests.tscn": [1.0],
	"res://scenes/topr.tscn": [1.0],
}

var failures: Array[String] = []
var gaussian_pattern := RegEx.new()


func _initialize() -> void:
	var compile_error := gaussian_pattern.compile(
		"shader_parameter/gaussian_mix\\s*=\\s*([-+0-9.eE]+)"
	)
	_expect(compile_error == OK, "gaussian_mix regular expression must compile")

	for path: String in EXPECTED:
		var values := _gaussian_values(path)
		var wanted: Array = EXPECTED[path]
		_expect(
			values.size() == wanted.size(),
			"%s must contain %d gaussian_mix values, got %d" % [
				path, wanted.size(), values.size()
			]
		)
		for index in mini(values.size(), wanted.size()):
			_expect(
				is_equal_approx(values[index], float(wanted[index])),
				"%s gaussian_mix[%d] must remain %s, got %s" % [
					path, index, wanted[index], values[index]
				]
			)

	var parameter_files: Array[String] = []
	_collect_parameter_files("res://resources", parameter_files)
	_collect_parameter_files("res://scenes", parameter_files)
	for path in parameter_files:
		_expect(EXPECTED.has(path), "%s adds an untracked gaussian_mix value" % path)

	var marquee_source := FileAccess.get_file_as_string(
		"res://scripts/simulations/simulation_selection_marquee.gd"
	)
	_expect(
		marquee_source.contains('set_shader_parameter("gaussian_mix", 0.82200004)'),
		"simulation marquee gaussian_mix must remain 0.82200004"
	)

	_finish()


func _gaussian_values(path: String) -> Array[float]:
	var result: Array[float] = []
	var source := FileAccess.get_file_as_string(path)
	for match_result in gaussian_pattern.search_all(source):
		result.append(match_result.get_string(1).to_float())
	return result


func _collect_parameter_files(root_path: String, result: Array[String]) -> void:
	for file_name in DirAccess.get_files_at(root_path):
		if file_name.get_extension() not in ["tres", "tscn"]:
			continue
		var path := root_path.path_join(file_name)
		if not _gaussian_values(path).is_empty():
			result.append(path)
	for directory_name in DirAccess.get_directories_at(root_path):
		_collect_parameter_files(root_path.path_join(directory_name), result)


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_high_blur_material_contract")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
