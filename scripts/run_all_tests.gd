extends SceneTree

# Standalone test runner that mimics run_all.sh
# Can be run via godot --headless -s scripts/run_all_tests.gd

func _initialize() -> void:
	call_deferred("_run_standalone")

func _run_standalone() -> void:
	run_all_tests(self)

static func run_all_tests(tree: SceneTree = null) -> void:
	var file = FileAccess.open("res://tests/godot/run_all.sh", FileAccess.READ)
	if not file:
		push_error("Failed to open tests/godot/run_all.sh")
		if tree: tree.quit(1)
		return
	
	var text = file.get_as_text()
	var lines = text.split("\n")
	var tests = []
	var parsing = false
	for line in lines:
		line = line.strip_edges()
		if line == "TESTS=(":
			parsing = true
			continue
		if parsing and line == ")":
			break
		if parsing and line.begins_with("\"") and line.ends_with("\""):
			var stripped = line.substr(1, line.length() - 2)
			var parts = stripped.split(":", true, 1)
			if parts.size() == 2:
				tests.append({"file": parts[0], "marker": parts[1]})

	var exe = OS.get_executable_path()
	var failed = 0
	var failed_reports = []
	
	for test in tests:
		var test_file = test["file"]
		var marker = test["marker"]
		
		# Skip excluded tests as documented in AGENTS.md
		var skip_list = ["test_auth_live.gd", "test_auth_device_live.gd", "test_output_map_migration.gd", "test_simulation_dataset_generator.gd"]
		if skip_list.has(test_file):
			print("SKIP ", test_file)
			continue
			
		print("RUN ", test_file)
		var args = ["--headless", "--path", "."]
		if test_file.ends_with(".tscn"):
			args.append("--scene")
		else:
			args.append("-s")
		args.append("tests/godot/" + test_file)
		var output = []
		var exit_code = OS.execute(exe, args, output, true)
		
		var out_str = output[0] if output.size() > 0 else ""
		
		if exit_code != 0 or not out_str.contains(marker):
			failed += 1
			failed_reports.append({"file": test_file, "out": out_str})
			
	if failed > 0:
		print("\n============== TEST FAILURES ==============")
		for rep in failed_reports:
			print("\nFAILED: ", rep["file"])
			print("--- OUTPUT ---")
			print(rep["out"])
			print("--------------")
		print("TESTS FAILED! Total failed: ", failed)
		if tree: tree.quit(1)
	else:
		print("ALL TESTS PASSED!")
		if tree: tree.quit(0)

