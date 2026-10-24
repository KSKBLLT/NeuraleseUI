extends SceneTree

var tests = []
var current_test_idx = 0
var current_test_node = null
var godot_skip_tests = []

func _initialize():
	var env_skip = OS.get_environment("GODOT_SKIP_TESTS")
	if env_skip != "":
		godot_skip_tests = env_skip.split(",")
	
	var f = FileAccess.open("res://tests/godot/run_all.sh", FileAccess.READ)
	var content = f.get_as_text()
	f.close()
	
	var in_tests = false
	for line in content.split("\n"):
		line = line.strip_edges()
		if line.begins_with("TESTS=("):
			in_tests = true
			continue
		if in_tests and line.begins_with(")"):
			in_tests = false
			break
		if in_tests and line != "":
			var parts = line.replace("\"", "").split(":")
			if parts.size() >= 2:
				tests.append({"file": parts[0], "marker": parts[1]})
				
	call_deferred("_run_next")

func _run_next():
	if current_test_node != null:
		if is_instance_valid(current_test_node):
			current_test_node.queue_free()
		current_test_node = null
		
	if current_test_idx >= tests.size():
		quit(0)
		return
		
	var test_info = tests[current_test_idx]
	var file = test_info["file"]
	var marker = test_info["marker"]
	current_test_idx += 1
	
	if file in godot_skip_tests:
		print("SKIP " + file)
		call_deferred("_run_next")
		return
		
	if file.ends_with(".tscn"):
		var packed = load("res://tests/godot/" + file) as PackedScene
		if packed:
			current_test_node = packed.instantiate()
			get_root().add_child(current_test_node)
	else:
		var script = load("res://tests/godot/" + file)
		if script == null:
			print("FAIL " + file)
			quit(1)
			return
			
		current_test_node = Node.new()
		current_test_node.set_script(script)
		
		if current_test_node.has_signal("finished"):
			current_test_node.connect("finished", Callable(self, "_on_test_finished").bind(file, marker))
		else:
			print("WARNING: Test " + file + " missing finished signal!")
			
		get_root().add_child(current_test_node)
		
		if current_test_node.has_method("run_test"):
			current_test_node.run_test()

func _on_test_finished(file: String, marker: String):
	if "failures" in current_test_node and typeof(current_test_node.failures) == TYPE_ARRAY and current_test_node.failures.size() > 0:
		print("FAIL " + file)
		quit(1)
		return
		
	print(marker)
	call_deferred("_run_next")
