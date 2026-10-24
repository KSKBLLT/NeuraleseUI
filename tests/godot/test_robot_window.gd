extends Node
## The robot window's own logic, without a robot: the drawings and their
## measurements, the names of a network's inputs and outputs, the sensor spots,
## the training world, the checklist's steps for different networks, the wheel
## check, and the configuration a run is started with (every conversion from the
## robot's length).

const Compiler = preload("res://scripts/simulations/simulation_compiler.gd")

var failures: Array[String] = []


func _ready() -> void:
	call_deferred("_run")


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)
		push_error(message)


func _run() -> void:
	var glob_node: Node = glob
	var steps := 0
	_test_art()
	steps += 1
	_test_labels(glob_node)
	steps += 1
	_test_training_world()
	steps += 1
	await _test_world()
	steps += 1
	await _test_config()
	steps += 1
	await _test_spots()
	steps += 1
	_test_tooltip()
	steps += 1
	await _test_steps()
	steps += 1
	await _test_wheel_check()
	steps += 1
	await _test_config_variants()
	steps += 1
	await _test_blocked_model()
	steps += 1
	_test_dataset_fields()
	steps += 1
	glob_node.change_lang("ru")
	_expect(steps == 12, "every part of the test must run")
	if failures.is_empty():
		print("PASS test_robot_window")
	else:
		printerr("FAIL test_robot_window: %d failure(s)" % failures.size())
	get_tree().quit()


func _test_art() -> void:
	for id in ["ev3", "spike", "microbit"]:
		var base := RobotArtData.base(id)
		_expect(float(base.get("length_cm", 0.0)) > 3.0, "%s needs its length" % id)
		_expect(float(base.get("track_cm", 0.0)) > 3.0, "%s needs its wheel track" % id)
		_expect(RobotArtData.texture(str(base.get("image", ""))) != null, "%s drawing must load" % id)
		_expect(base.get("wheels", {}).has("left") and base.get("wheels", {}).has("right"), "%s must say where its wheels are" % id)
	_expect(RobotArtData.base_id("dummy") == "ev3", "the virtual robot is drawn as the EV3 it imitates")
	_expect(RobotArtData.sensor_texture("ev3_direct", true) != null, "the EV3 sensor's front picture must load")
	_expect(RobotArtData.sensor_texture("spike", false) != null, "the SPIKE sensor's top picture must load")
	# The build screen's camera: tilted pictures for the LDraw robots, from above for the micro:bit.
	for platform in ["dummy", "spike"]:
		_expect(RobotArtData.tilt_deg(platform) > 5.0 and RobotArtData.tilt_deg(platform) < 20.0, "%s is drawn slightly tilted" % platform)
		_expect(RobotArtData.view_texture(platform) != RobotArtData.texture(str(RobotArtData.base(platform)["image"])), "%s has its own tilted picture" % platform)
		for angle in [0, 45, 90, 135, 180, -135, -90, -45]:
			_expect(not RobotArtData.sensor_view(platform, angle).is_empty(), "%s has its sensor seen facing %d degrees" % [platform, angle])
	_expect(is_zero_approx(RobotArtData.tilt_deg("microbit")), "the hand-drawn micro:bit stays seen from above")
	_expect(RobotArtData.sensor_view("microbit", 0).is_empty(), "the micro:bit turns its top-view sensors instead")


func _test_labels(glob_node: Node) -> void:
	glob_node.change_lang("ru")
	_expect(RobotLabels.sensor("ray_distance") == "Датчик зрения", "rays are named as in Brain Mapping (ru)")
	_expect(RobotLabels.actuator("steering") == "Поворот руля", "steering is named as in Brain Mapping (ru)")
	_expect(RobotLabels.sensor("local_goal_direction") == "Поворот к цели", "the local goal is named as in Brain Mapping (ru)")
	glob_node.change_lang("en")
	_expect(RobotLabels.sensor("ray_distance") == "Ray Sensor", "English uses the registry's label")
	glob_node.change_lang("kz")
	_expect(RobotLabels.actuator("throttle") == "Газ", "throttle is named as in Brain Mapping (kz)")
	_expect(RobotLabels.group({"labels": ["out 3"]}, true) == "out 3", "an output without a registry id keeps its own name")


func _test_training_world() -> void:
	var blueprint := {
		"bounds": Rect2(-480.0, -260.0, 960.0, 520.0),
		"positions": PackedVector2Array([Vector2(-300, 40), Vector2(350, -100)]),
		"rotations": PackedFloat32Array([0.5, 0.0]),
		"sizes": PackedVector2Array([Vector2(72, 48), Vector2(40, 40)]),
		"scales": [Vector2(1.5, 1.5), Vector2.ONE],
		"types": ["rover", "finish"],
		"agent_indices": PackedInt32Array([0]),
		"goal_indices": PackedInt32Array([1]),
	}
	var world := Compiler.training_world(blueprint)
	_expect(world["agent_start"] == [-300.0, 40.0, 0.5], "the agent's start position and heading are kept")
	_expect(world["agent_size"] == [108.0, 72.0], "the agent's size includes its scale")
	_expect(world["goal"] == [350.0, -100.0], "the goal is the finish object's position")
	_expect(world["bounds"] == [-480.0, -260.0, 960.0, 520.0], "the bounds are x, y, width, height")


func _test_world() -> void:
	var world := RobotWorld.new()
	world.size = Vector2(600, 400)
	add_child(world)
	await get_tree().process_frame
	world.put_sensor_default("in3")
	world.put_sensor_default("in4")
	_expect(str(world.sensors["in3"]["spot"]) == "front", "the first sensor goes to the front")
	_expect(float(world.sensors["in3"]["angle_deg"]) == 0.0, "the front spot faces ahead")
	_expect(str(world.sensors["in4"]["spot"]) == "front_left", "the next one goes front left")
	_expect(float(world.sensors["in4"]["y_cm"]) > 0.0, "left is positive y")
	world.put_sensor("in4", "front")
	_expect(str(world.sensors["in4"]["spot"]) == "front", "a sensor may be moved to another spot")
	world.queue_free()


func _test_config() -> void:
	var panel := RobotPanel.new()
	add_child(panel)
	await get_tree().process_frame
	panel.robot = {"platform": "dummy", "ports": []}
	panel.contract = {"world": {"bounds": [-480.0, -260.0, 960.0, 520.0], "agent_start": [-300.0, 40.0, 0.0], "agent_size": [72.0, 48.0], "goal": [350.0, -100.0]}}
	panel.geometry = {
		"length_cm": 18.0,
		"drive_sides": {"left": [{"port": "outD", "invert": false}, {"port": "outA", "invert": true}], "right": [{"port": "outB", "invert": false}]},
	}
	panel.model = {
		"inputs": [
			{"index": 0, "sensor_id": "ray_distance"}, {"index": 1, "sensor_id": "ray_distance"},
			{"index": 2, "sensor_id": "speed", "quantity": "speed"},
			{"index": 3, "sensor_id": "local_goal_direction", "quantity": "local_goal_x"},
			{"index": 4, "sensor_id": "local_goal_direction", "quantity": "local_goal_y"},
		],
		"outputs": [{"index": 0, "actuator_id": "steering"}, {"index": 1, "actuator_id": "throttle"}],
		"ray_angles_deg": [66.0, -66.0],
		"needs": ["field", "goal", "sensors", "wheels"],
	}
	panel._world.sensors = {"in3": panel._world.spot_pose("front")}
	panel._field.load_world(panel.contract["world"], panel.cm_per_unit())
	_expect(is_equal_approx(panel.cm_per_unit(), 0.25), "an 18 cm robot and the 72-unit rover: 0.25 cm per unit")
	_expect(is_equal_approx(panel.ray_reach_cm(), 80.0), "the rays reach 320 units, 80 cm")
	var config := panel.build_config()
	var inputs: Array = config["inputs"]
	_expect(inputs.size() == 5, "one config input per model input")
	_expect(inputs[0]["derive"] == "ray" and is_equal_approx(float(inputs[0]["scale"]["in_max"]), 800.0), "a ray reads millimetres up to its reach")
	_expect(inputs[2] == {"derive": "pose", "quantity": "speed"}, "speed comes from the robot's movement")
	_expect(inputs[4]["quantity"] == "local_goal_y", "the goal's second channel keeps its order")
	_expect(is_equal_approx(float(config["world"]["cm_per_unit"]), 0.25), "the world gets the scale")
	_expect(config["world"]["goal"] == [350.0, -100.0], "the world gets the goal")
	_expect(config["odometry"]["left"].size() == 2, "both left motors count the left wheel")
	_expect(bool(config["odometry"]["left"][1]["invert"]), "a reversed motor counts backwards")
	var drive: Dictionary = config["outputs"][0]
	_expect(drive["channels"] == [["outD.power", "outA.power"], ["outB.power"]], "every drive motor gets power")
	_expect(drive["invert"] == [[false, true], [false]], "each motor keeps its own direction")
	panel.queue_free()


const DUMMY_PORTS := [
	{"id": "in2", "device": "ultrasonic"}, {"id": "in3", "device": "ultrasonic"}, {"id": "in4", "device": "ultrasonic"},
	{"id": "outA", "device": "medium_motor"}, {"id": "outB", "device": "large_motor"}, {"id": "outD", "device": "large_motor"},
]
const DRIVE_NEURONS := [{"index": 0, "actuator_id": "steering"}, {"index": 1, "actuator_id": "throttle"}]


## A build screen with a network and the Dummy's ports, as after connecting.
func _panel_with(model: Dictionary, ports: Array = []) -> RobotPanel:
	var panel := RobotPanel.new()
	add_child(panel)
	await get_tree().process_frame
	panel.robot = {"platform": "dummy", "ports": ports if not ports.is_empty() else DUMMY_PORTS}
	panel.contract = {"world": {"bounds": [-480.0, -260.0, 960.0, 520.0], "agent_start": [-300.0, 40.0, 0.0], "agent_size": [72.0, 48.0], "goal": [350.0, -100.0]}}
	panel.model = model
	panel._show(RobotPanel.Screen.BUILD)
	return panel


func _group(sensor_id: String, start: int, length: int, needs: Array, supported: bool = true) -> Dictionary:
	return {"sensor_id": sensor_id, "start": start, "length": length, "needs": needs, "supported": supported}


func _drive_outputs() -> Array:
	return [{"actuator_id": "steering", "start": 0, "length": 1, "supported": true}, {"actuator_id": "throttle", "start": 1, "length": 1, "supported": true}]


## Sensors never cover a wheel or each other, on the robots that drive.
func _test_spots() -> void:
	for platform in ["dummy", "spike"]:
		var world := RobotWorld.new()
		world.size = Vector2(700, 420)
		world.platform = platform
		add_child(world)
		await get_tree().process_frame
		var sensor: Vector2 = world.sensor_size_cm()
		var placed: Array = []
		for spot in RobotWorld.SPOTS:
			var pose := world.spot_pose(spot)
			var at := Vector2(pose["x_cm"], pose["y_cm"])
			var angle := float(RobotWorld.SPOTS[spot])
			# Square-on, a sensor reaches half its depth towards a wheel; turned, half its diagonal.
			var reach := sensor.x * 0.5 if is_zero_approx(fmod(absf(angle), 90.0)) else sensor.length() * 0.5
			for side in ["left", "right"]:
				var wheel: Rect2 = world._wheel_cm(side)
				var nearest := Vector2(clampf(at.x, wheel.position.x, wheel.end.x), clampf(at.y, wheel.position.y, wheel.end.y))
				_expect(nearest.distance_to(at) >= reach, "%s: the %s sensor covers the %s wheel" % [platform, spot, side])
			for other in placed:
				_expect(at.distance_to(other) >= sensor.y, "%s: the %s sensor covers another sensor" % [platform, spot])
			placed.append(at)
			if spot.ends_with("left"):
				_expect(at.y > 0.0, "%s: the %s spot is on the left" % [platform, spot])
			if spot.begins_with("front"):
				_expect(at.x > world.length_cm() * 0.5, "%s: the %s spot is in front" % [platform, spot])
		world.queue_free()


## A palette row shows its name as a tooltip only when the name is cut short.
func _test_tooltip() -> void:
	var row := RobotPaletteRow.new()
	add_child(row)
	row.configure({"id": "a", "text": "Speed", "accent": Color.WHITE, "count": 1})
	row.size = Vector2(240, 32)
	_expect(row._get_tooltip(Vector2.ZERO).is_empty(), "a name that fits has no tooltip")
	row.configure({"id": "b", "text": "Расстояние до цели · поле и ещё много слов", "accent": Color.WHITE, "count": 2, "state": "ok"})
	row.size = Vector2(240, 32)
	_expect(row._get_tooltip(Vector2.ZERO) == row.text, "a cut name is shown whole in the tooltip")
	row.queue_free()


## The checklist has the steps a network needs, opens on the first one not done,
## and Next only moves on from a step that is done.
func _test_steps() -> void:
	var rays := _group("ray_distance", 0, 8, ["sensors"])
	var speed := _group("speed", 8, 1, ["wheels"])
	var goal := _group("local_goal_direction", 9, 2, ["wheels", "heading", "field", "goal"])
	var cases := [
		[[rays], ["sensors"], ["sensors", "wheels", "size", "go"]],
		[[speed, goal], ["field", "goal", "heading", "wheels"], ["settings", "wheels", "size", "go"]],
		[[rays, speed, goal], ["field", "goal", "heading", "sensors", "wheels"], ["sensors", "settings", "wheels", "size", "go"]],
		[[rays, _group("height", 8, 1, [], false)], ["sensors"], ["sensors", "wheels", "size", "go"]],
	]
	for case in cases:
		var panel := await _panel_with({"input_groups": case[0], "output_groups": _drive_outputs(), "needs": case[1],
			"inputs": [], "outputs": DRIVE_NEURONS})
		_expect(panel._steps() == case[2], "steps for %s: %s" % [str(case[1]), str(panel._steps())])
		_expect(panel._first_open_step() == case[2][0], "a new robot starts on the first step")
		panel._go_step(panel._first_open_step())
		var first: String = case[2][0]
		_expect(not panel._step_done(first), "nothing is done yet")
		panel._on_next_pressed()
		_expect(panel._step == first, "Next does not leave a step that is not done")
		panel.queue_free()
	# Sensors placed, field set, wheels checked, length set: straight to Go.
	var ready := await _panel_with({"input_groups": [rays, speed, goal], "output_groups": _drive_outputs(),
		"needs": ["field", "goal", "heading", "sensors", "wheels"], "inputs": [], "outputs": DRIVE_NEURONS})
	ready._world.put_sensor("in3", "front")
	ready.mapping = {"field_set": true}
	ready.geometry = {"length_cm": 15.0, "drive_sides": {"left": [{"port": "outD", "invert": false}], "right": [{"port": "outB", "invert": false}]}}
	_expect(ready._first_open_step() == "go", "a robot set up before opens on Go")
	ready._go_step("size")
	ready._on_next_pressed()
	_expect(ready._step == "go", "Next moves on from a done step")
	ready.queue_free()


## Each motor turns; the child presses the wheel, then forward or back.
func _test_wheel_check() -> void:
	var panel := await _panel_with({"input_groups": [_group("ray_distance", 0, 8, ["sensors"])], "output_groups": _drive_outputs(),
		"needs": ["sensors"], "inputs": [], "outputs": DRIVE_NEURONS})
	panel._go_step("wheels")
	panel._on_start_check_pressed()
	_expect(panel._check_port == "outA" and panel._bar_mode == "wheels_question", "the first motor turns and the question is which wheel")
	_expect(panel._world.mode == "wheels", "the drawing lights the wheels")
	panel._on_not_wheel_pressed()                       # A drives an arm, not a wheel
	_expect(panel._check_port == "outB", "a motor that is not a wheel is skipped")
	panel._on_direction(true)
	_expect(panel._check_port == "outB", "no direction before a wheel is picked")
	panel._world._press(panel._world._wheel_rect("right").get_center())
	_expect(panel._check_side == "right" and panel._bar_mode == "wheels_direction", "pressing a wheel picks it and asks which way")
	_expect(panel._world.picked_side == "right", "the picked wheel stays lit")
	panel._world._press(panel._world._wheel_rect("left").get_center())
	_expect(panel._check_side == "right", "a second press does not change the picked wheel")
	panel._on_direction(true)
	_expect(panel._check_port == "outD" and panel._bar_mode == "wheels_question", "on to the next motor")
	panel._on_wheel_picked("left")
	panel._on_direction(false)
	_expect(panel._check_port.is_empty(), "the check is over after the last motor")
	_expect(panel._drive_sides() == {"left": [{"port": "outD", "invert": true}], "right": [{"port": "outB", "invert": false}]},
		"left D turning backwards is a reversed motor: %s" % str(panel.geometry.get("drive_sides")))
	_expect(panel._step == "size", "after the wheels comes the size")
	_expect(panel._world.mode == "build" and panel._world.picked_side.is_empty(), "the wheels go dark again")
	# Both motors said to be on one side: the check is not taken, and asks again.
	panel._on_start_check_pressed()
	panel._on_not_wheel_pressed()
	panel._on_wheel_picked("left")
	panel._on_direction(true)
	panel._on_wheel_picked("left")
	panel._on_direction(true)
	_expect(panel._step == "wheels" and not panel._hint.text.is_empty(), "one side without a wheel sends the child back to the check")
	_expect(panel._drive_sides()["left"][0]["port"] == "outD", "a failed check keeps the last good answer")
	# Cancel in the middle.
	panel._on_start_check_pressed()
	panel._on_wheel_picked("right")
	panel._on_cancel_pressed()
	_expect(panel._check_port.is_empty() and panel._bar_mode == "step" and panel._world.picked_side.is_empty(), "Cancel ends the check")
	panel.queue_free()


## Networks with two ray fans, a brake, a gyro, or no rays at all.
func _test_config_variants() -> void:
	var fan := [66.0, 22.0, -22.0, -66.0]
	var panel := await _panel_with({
		"inputs": [
			{"index": 0, "sensor_id": "ray_distance"}, {"index": 1, "sensor_id": "ray_distance"}, {"index": 2, "sensor_id": "ray_distance"}, {"index": 3, "sensor_id": "ray_distance"},
			{"index": 4, "sensor_id": "rotation", "quantity": "rotation"},
			{"index": 5, "sensor_id": "ray_distance"}, {"index": 6, "sensor_id": "ray_distance"}, {"index": 7, "sensor_id": "ray_distance"}, {"index": 8, "sensor_id": "ray_distance"},
		],
		"outputs": [{"index": 0, "actuator_id": "throttle"}, {"index": 1, "actuator_id": "brake"}, {"index": 2, "actuator_id": "steering"}],
		"ray_angles_deg": fan + fan,
		"needs": ["heading", "sensors"],
	}, DUMMY_PORTS + [{"id": "in1", "device": "gyro"}])
	panel.geometry = {"length_cm": 14.0, "drive_sides": {"left": [{"port": "outD", "invert": false}], "right": [{"port": "outB", "invert": true}]}}
	panel._world.sensors = {"in2": panel._world.spot_pose("front_right"), "in4": panel._world.spot_pose("front_left")}
	var config := panel.build_config()
	var angles: Array = config["inputs"].filter(func(e): return e["derive"] == "ray").map(func(e): return e["angle_deg"])
	_expect(angles == fan + fan, "each ray fan keeps its own angles: %s" % str(angles))
	_expect(config["inputs"][4] == {"derive": "pose", "quantity": "rotation"}, "rotation between the fans stays in its place")
	_expect(config["inputs"][0]["sources"].size() == 2, "every ray is made from the placed sensors")
	var drive: Dictionary = config["outputs"][0]
	_expect(drive["steer_index"] == 2 and drive["throttle_index"] == 0 and drive["brake_index"] == 1, "outputs are found by name, not by place")
	_expect(drive["invert"] == [[false], [true]], "a reversed right motor is inverted")
	_expect(config["odometry"]["heading"] == {"source": "gyro", "channel": "in1.angle_deg"}, "a gyro gives the heading by default")
	panel.geometry["heading"] = "wheels"
	_expect(panel.build_config()["odometry"]["heading"] == {"source": "wheels"}, "or the wheels, when the child says so")
	panel.queue_free()
	# A network that sees only its movement: no sensors, no rays.
	var pose_only := await _panel_with({
		"inputs": [{"index": 0, "sensor_id": "speed", "quantity": "speed"}, {"index": 1, "sensor_id": "local_goal_direction", "quantity": "local_goal_x"}, {"index": 2, "sensor_id": "local_goal_direction", "quantity": "local_goal_y"}],
		"outputs": DRIVE_NEURONS,
		"input_groups": [_group("speed", 0, 1, ["wheels"]), _group("local_goal_direction", 1, 2, ["wheels", "heading", "field", "goal"])],
		"needs": ["field", "goal", "heading", "wheels"],
	})
	pose_only.geometry = {"drive_sides": {"left": [{"port": "outD", "invert": false}], "right": [{"port": "outB", "invert": false}]}}
	pose_only._field.load_world(pose_only.contract["world"], pose_only.cm_per_unit())
	var pose_config := pose_only.build_config()
	_expect(pose_config["inputs"].all(func(e): return e["derive"] == "pose"), "no rays without ray inputs")
	_expect(pose_config["world"].has("goal"), "the goal travels with a goal network")
	_expect(not pose_only._missing().has("sensors"), "a network without rays needs no sensors")
	pose_only.queue_free()


## A model trained on another dataset is refused before Go, in words.
func _test_blocked_model() -> void:
	glob.change_lang("ru")
	var reason := "Датасет изменился после обучения. Обучите модель заново."
	var panel := await _panel_with({"blocked": {"code": "dataset_changed", "texts": {"ru": reason, "en": "x", "kz": "y"}},
		"input_groups": [_group("ray_distance", 0, 8, ["sensors"])], "output_groups": _drive_outputs(), "needs": ["sensors"],
		"inputs": [], "outputs": DRIVE_NEURONS})
	panel._go_step("go")
	_expect(panel._missing() == ["model"], "a refused model is the only thing missing")
	_expect(panel._hint_full == reason, "the reason is said, not a generic one: %s" % panel._hint_full)
	panel.queue_free()


## A Dataset node hands the training node only the dataset's preview (names and
## sizes); the window takes the binding from the dataset itself, so speed, the
## goal and the rest are not refused as unknown.
func _test_dataset_fields() -> void:
	var name := "__robot_window_test__"
	var binding := {"agent_id": "top_down_rover", "input_width": 11, "output_width": 3,
		"inputs": [{"sensor_id": "ray_distance", "start": 0, "length": 8}, {"sensor_id": "speed", "start": 8, "length": 1}, {"sensor_id": "local_goal_direction", "start": 9, "length": 2}],
		"outputs": [{"actuator_id": "steering", "start": 0, "length": 1}, {"actuator_id": "throttle", "start": 1, "length": 1}, {"actuator_id": "brake", "start": 2, "length": 1}]}
	glob.dataset_datas[name] = {"name": name, "col_names": ["Ray 1:float"], "outputs_from": 11, "values": PackedFloat32Array([1.0, 2.0]),
		"metadata": {"binding": binding, "world": {"agent_start": [0.0, 0.0, 0.0]}, "episodes": [1, 2, 3]}}
	var preview := {"name": name, "size": 2, "input_hints": [{"name": "Ray 1"}], "outputs": [{"label_names": ["Steering"], "x": 3}]}
	var meta := RobotModelContract.with_dataset_fields(preview)
	_expect(meta.get("metadata", {}).get("binding") == binding, "the binding comes from the dataset")
	_expect(meta.get("metadata", {}).has("world"), "and the training world with it")
	_expect(not meta.get("metadata", {}).has("episodes") and not meta.has("values"), "but not the rows or the episode log")
	_expect(meta.get("input_hints") == preview["input_hints"], "the preview's own fields stay")
	var unknown := RobotModelContract.with_dataset_fields({"name": "__no_such_dataset__", "input_hints": []})
	_expect(not unknown.has("metadata"), "a dataset that is not loaded leaves the preview as it is")
	glob.dataset_datas.erase(name)
