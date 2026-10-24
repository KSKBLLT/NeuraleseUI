extends "res://tests/godot/support/e2e_app_test.gd"
## End-to-end pass through the bundled Python runtime (local_runtime/python):
## lesson 1 (eco_ai) trained with "Learn!", answered from the sensor sliders and
## exported as ONNX and as a Windows program; lesson 3 (MNIST convolution)
## trained one epoch and answering pictures dropped onto Input2D; the built-in
## Car Track model trained and driving the car in the simulations tab with
## run, pause, resume and stop.
##
## Opt-in: tests/godot/run_all.sh runs it with NEURALESE_RUN_LOCAL_RUNTIME_TESTS=1,
## since CI's Godot job has no Python runtime.

const Repository = preload("res://scripts/builtin_projects_repository.gd")

## Class means of local_runtime/datasets/eco_ai: weight, transparency,
## magnetic, hardness -> Glass, Metal, Paper, Plastic.
const ECO_PROTOTYPES := [
	[[0.79, 0.89, 0.04, 0.89], 0],
	[[0.79, 0.04, 0.88, 0.89], 1],
	[[0.11, 0.11, 0.04, 0.11], 2],
]


func _ready() -> void:
	marker = "PASS test_e2e_local_runtime"
	_run.call_deferred()


func _run() -> void:
	if not await _begin(900.0):
		return
	_step = "local runtime"
	var python: String = await nn._local_python_path()
	_expect(not python.is_empty() and FileAccess.file_exists(python), "the bundled Python runtime is installed: %s" % local_runtime.last_error())
	if python.is_empty():
		_finish()
		return
	await _new_project("E2E обучение")
	_step = "lesson 1 training"
	var lesson1 := await _build_lesson1()
	await _train(lesson1["begin"], 30, 180.0)
	_step = "lesson 1 inference"
	await _check_lesson1_answers(lesson1)
	_step = "lesson 1 export"
	await _check_exports(lesson1, python)
	_step = "lesson 3 training"
	await graphs.delete_all()
	var lesson3 := await _build_lesson3()
	await _train(lesson3["begin"], 1, 300.0)
	_step = "lesson 3 inference"
	await _check_lesson3_answers(lesson3, python)
	_step = "car simulation"
	await _check_car_simulation()
	_finish()


## Presses "Learn!" with this many epochs and waits for the run to end.
func _train(begin: Graph, epochs: int, seconds: float) -> void:
	var errors_before := get_tree().get_nodes_in_group("ui_error_toast").size()
	begin.get_node("YY").set_line(str(epochs))
	begin._on_train_released()
	await _frames(5)
	_expect(begin.training, "Learn! starts training")
	var started := Time.get_ticks_msec()
	var deadline := started + int(seconds * 1000.0)
	while begin.training and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	_expect(not begin.training, "training finishes within %d s" % int(seconds))
	while (not nn.local_training_jobs.is_empty() or not nn._resident_training_jobs.is_empty()) and Time.get_ticks_msec() < deadline:
		await get_tree().process_frame
	var errors := get_tree().get_nodes_in_group("ui_error_toast").size() - errors_before
	_expect(errors == 0, "training shows no error")
	print("E2E trained %d epoch(s) on %s in %.1f s" % [epochs, str(begin.dataset_meta.get("name", "")), (Time.get_ticks_msec() - started) / 1000.0])


## Runs inference from an input node the way its own change does and returns
## what the answer node then shows.
func _answer(input: Graph, answers: Graph, trigger: Callable) -> Array:
	var done := [false]
	var on_done := func(source, _request_id: int):
		if source == input:
			done[0] = true
	nn.inference_finished.connect(on_done)
	trigger.call()
	var deadline := Time.get_ticks_msec() + 60000
	while not done[0] and Time.get_ticks_msec() < deadline:
		# The pointer rests on the node after a drop; that keeps it processing.
		input.hold_for_frame()
		await get_tree().process_frame
	nn.inference_finished.disconnect(on_done)
	await _frames(3)
	_expect(done[0], "%s answers" % input.server_typename)
	var values: Array = []
	for unit in answers.units:
		values.append(float(unit.get("_target_weight")))
	return values


func _argmax(values: Array) -> int:
	var best := -1
	for i in values.size():
		if best < 0 or values[i] > values[best]:
			best = i
	return best


func _check_lesson1_answers(nodes: Dictionary) -> void:
	var input: Graph = nodes["input"]
	_expect(nn.can_export_fully_local(input), "training leaves a trained model for this graph")
	for prototype in ECO_PROTOTYPES:
		var payload: Dictionary = input.useful_properties()
		payload["raw_values"] = prototype[0]
		# What moving the sensor sliders does once their values settle.
		var values := await _answer(input, nodes["answers"], func(): input._auto_infer_touch(payload))
		_expect(_argmax(values) == prototype[1], "sensors %s are %s, the model says %s" % [prototype[0], ECO_MATERIALS[prototype[1]], values])
	print("E2E lesson 1 answers the sensor prototypes")


func _check_exports(nodes: Dictionary, python: String) -> void:
	var input: Graph = nodes["input"]
	var dir := ProjectSettings.globalize_path("user://e2e_exports")
	DirAccess.make_dir_recursive_absolute(dir)
	var onnx_path := dir.path_join("eco.onnx")
	var onnx: Dictionary = await nn.export_fully_local_model(input, "onnx", "none", onnx_path)
	_expect(str(onnx.get("status", "")) == "ok" and FileAccess.file_exists(onnx_path), "the model exports as ONNX: %s" % onnx)
	var samples: Array = []
	for prototype in ECO_PROTOTYPES:
		samples.append(prototype[0])
	var script := "import json,sys,numpy as np,onnxruntime as ort\ns=ort.InferenceSession(sys.argv[1],providers=['CPUExecutionProvider'])\nname=s.get_inputs()[0].name\nprint(json.dumps([int(np.argmax(s.run(None,{name:np.array([x],dtype=np.float32)})[0])) for x in json.loads(sys.argv[2])]))"
	var output: Array = []
	var code := OS.execute(python, ["-I", "-c", script, onnx_path, JSON.stringify(samples)], output, true)
	var predicted = JSON.parse_string(str(output[0]).strip_edges().get_slice("\n", str(output[0]).strip_edges().count("\n"))) if code == 0 and not output.is_empty() else null
	_expect(predicted is Array and predicted == [0.0, 1.0, 2.0], "the exported ONNX gives the same answers in onnxruntime: %s" % [output])

	if OS.get_name() != "Windows":
		return
	var exe_path := dir.path_join("eco.exe")
	var exe: Dictionary = await nn.export_fully_local_model(input, "windows", "none", exe_path)
	_expect(str(exe.get("status", "")) == "ok" and FileAccess.file_exists(exe_path), "the model exports as a Windows program: %s" % exe)
	var lines := PackedStringArray()
	for sample in samples:
		lines.append(JSON.stringify(sample))
	var input_path := dir.path_join("samples.txt")
	var file := FileAccess.open(input_path, FileAccess.WRITE)
	file.store_string("\n".join(lines) + "\n")
	file.close()
	var run_output: Array = []
	var run_code := OS.execute("cmd.exe", ["/c", "\"%s\" < \"%s\"" % [exe_path.replace("/", "\\"), input_path.replace("/", "\\")]], run_output, true)
	var answers: Array = []
	for line in str(run_output[0] if not run_output.is_empty() else "").split("\n"):
		line = line.strip_edges()
		if line.begins_with("[") and line.ends_with("]"):
			var parsed = JSON.parse_string(line)
			if parsed is Array:
				answers.append(_argmax(parsed))
	_expect(run_code == 0 and answers == [0, 1, 2], "the exported program answers like the app: %s" % [run_output])
	print("E2E exports: ONNX and Windows program answer ", answers)


func _check_lesson3_answers(nodes: Dictionary, python: String) -> void:
	var input: Graph = nodes["input"]
	var dir := ProjectSettings.globalize_path("user://e2e_digits")
	DirAccess.make_dir_recursive_absolute(dir)
	# Five validation pictures from the built-in MNIST set, saved as the PNG
	# files a pupil would drop onto Input2D.
	var npz := ProjectSettings.globalize_path("res://local_runtime/datasets/mnist/train.npz")
	var script := "import json,struct,sys,zlib,numpy as np\nd=np.load(sys.argv[1]);out=sys.argv[2];labels=[]\nfor i in range(5):\n  img=(d['val_x'][i,0]*255).round().astype(np.uint8)\n  raw=b''.join(b'\\x00'+img[r].tobytes() for r in range(28))\n  chunk=lambda t,b: struct.pack('>I',len(b))+t+b+struct.pack('>I',zlib.crc32(t+b)&0xffffffff)\n  png=b'\\x89PNG\\r\\n\\x1a\\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',28,28,8,0,0,0,0))+chunk(b'IDAT',zlib.compress(raw))+chunk(b'IEND',b'')\n  open(out+'/%d.png'%i,'wb').write(png);labels.append(int(d['val_y'][i]))\nprint(json.dumps(labels))"
	var output: Array = []
	var code := OS.execute(python, ["-I", "-c", script, npz, dir], output, true)
	var labels = JSON.parse_string(str(output[0]).strip_edges()) if code == 0 and not output.is_empty() else null
	_expect(labels is Array and labels.size() == 5, "five MNIST pictures are prepared: %s" % [output])
	if not labels is Array:
		return
	var correct := 0
	for i in labels.size():
		var path := dir.path_join("%d.png" % i)
		var values := await _answer(input, nodes["answers"], func(): input.open_picture(path))
		if _argmax(values) == int(labels[i]):
			correct += 1
	_expect(correct >= 4, "after one epoch the network reads at least 4 of 5 digits: %d" % correct)
	print("E2E lesson 3 read %d of 5 MNIST digits" % correct)


func _check_car_simulation() -> void:
	var repository := Repository.new()
	repository.load_catalog()
	var copy: Dictionary = await repository.create_user_copy(&"car_track", "ru")
	_expect(bool(copy.get("ok", false)), "the Car Track project copies: %s" % copy)
	if not bool(copy.get("ok", false)):
		return
	await glob.load_scene(str(copy["project_id"]), true)
	await _frames(20)
	var begin: Graph = null
	for graph in graphs._graphs.values():
		if is_instance_valid(graph) and graph.server_typename == "TrainBegin":
			begin = graph
	_expect(begin != null, "Car Track has its training chain")
	if begin == null:
		return
	await _train(begin, 2, 180.0)

	glob.go_window("env")
	await _frames(10)
	var editor = glob.tree_windows["env"].get_node_or_null("SimulationEditor")
	editor.load_example(&"side_view_car")
	await _frames(5)
	var runtime = editor.runtime
	var input: Graph = graphs.get_input_graph_by_name(glob.DEFAULT_MODEL_NAME)
	var answers := [0]
	var count_answers := func(source, _request_id: int):
		if source == input:
			answers[0] += 1
	nn.inference_finished.connect(count_answers)
	await editor._on_play_requested()
	await get_tree().create_timer(3.0).timeout
	_expect(runtime.current_state() == &"running", "Run starts the car with the trained model")
	_expect(editor.model_runner.is_running_model() and editor.model_runner.last_error().is_empty(), "the model drives the car: %s" % editor.model_runner.last_error())
	_expect(answers[0] >= 3, "the car asks the model at least three times in 3 s: %d" % answers[0])
	editor._on_pause_requested()
	await _frames(10)
	_expect(runtime.current_state() == &"paused", "Pause pauses the drive")
	var paused_answers: int = answers[0]
	await get_tree().create_timer(1.0).timeout
	_expect(answers[0] <= paused_answers + 1, "a paused car stops asking the model")
	editor._on_pause_requested()
	await get_tree().create_timer(1.0).timeout
	_expect(runtime.current_state() == &"running" and answers[0] > paused_answers + 1, "Pause again resumes the drive")
	await editor._on_play_requested()
	await _frames(10)
	_expect(runtime.current_state() == &"stopped", "Run again stops the simulation")
	nn.inference_finished.disconnect(count_answers)
	glob.go_window("graph")
	print("E2E car simulation: ", answers[0], " model answers while driving")
