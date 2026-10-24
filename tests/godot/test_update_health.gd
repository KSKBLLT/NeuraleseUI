extends SceneTree

const UpdateHealth = preload("res://scripts/update_health.gd")

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var health_dir := "user://updates/health"
	var absolute_health_dir := ProjectSettings.globalize_path(health_dir)
	DirAccess.make_dir_recursive_absolute(absolute_health_dir)
	var marker_name := "0123456789abcdef0123456789abcdef.json"
	var marker_path := absolute_health_dir.path_join(marker_name)
	_cleanup(marker_path)

	_expect_equal(
		UpdateHealth.acknowledge(PackedStringArray(), health_dir, "1.0.8", 4242),
		false,
		"missing arguments"
	)
	_expect_equal(FileAccess.file_exists(marker_path), false, "missing args write nothing")

	var token := "123e4567-e89b-42d3-a456-426614174000"
	var outside_path := ProjectSettings.globalize_path("user://updates/outside.json")
	_cleanup(outside_path)
	_expect_equal(
		UpdateHealth.acknowledge(PackedStringArray([
			"--post-update-health-file=%s" % outside_path,
			"--post-update-token=%s" % token,
		]), health_dir, "1.0.8", 4242),
		false,
		"outside path rejected"
	)
	_expect_equal(FileAccess.file_exists(outside_path), false, "outside file absent")

	_expect_equal(
		UpdateHealth.acknowledge(PackedStringArray([
			"--post-update-health-file=%s" % marker_path,
			"--post-update-token=%s" % token,
		]), health_dir, "1.0.8", 4242),
		true,
		"valid acknowledgement"
	)
	var payload: Variant = JSON.parse_string(FileAccess.get_file_as_string(marker_path))
	_expect_equal(payload, {
		"token": token,
		"version": "1.0.8",
		"pid": 4242.0,
	}, "health payload")
	_expect_equal(_has_temp_files(absolute_health_dir, marker_name), false, "atomic temp removed")

	_cleanup(marker_path)
	_cleanup(outside_path)
	if failures.is_empty():
		print("PASS test_update_health")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _has_temp_files(directory: String, marker_name: String) -> bool:
	for filename in DirAccess.get_files_at(directory):
		if filename.begins_with(marker_name + ".tmp."):
			return true
	return false


func _cleanup(path: String) -> void:
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
