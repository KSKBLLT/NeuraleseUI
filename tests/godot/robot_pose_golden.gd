extends SceneTree
## Writes the simulation's own sensor values for a set of rover states, so the
## robot runtime (local_runtime/neuralese_local/robot/odometry.py) can be checked
## against them: the robot must feed a network exactly what the simulation fed
## it while it learned.
##
## Run: godot --headless --path . -s tests/godot/robot_pose_golden.gd
## Output: local_runtime/tests/fixtures/robot_pose_golden.json

const KernelAgent = preload("res://scripts/simulations/simulation_kernel_agent.gd")
const OUT := "res://local_runtime/tests/fixtures/robot_pose_golden.json"


## The few kernel calls the encoders make, answered from one fixed state.
class StubKernel extends RefCounted:
	var position := Vector2.ZERO
	var rotation := 0.0
	var velocity := Vector2.ZERO

	func position_for(_index: int) -> Vector2:
		return position

	func rotation_for(_index: int) -> float:
		return rotation

	func velocity_for(_index: int) -> Vector2:
		return velocity


func _init() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261012
	var cases: Array = []
	var fixed := [
		{"position": Vector2(0, 0), "rotation": 0.0, "velocity": Vector2(0, 0), "goal": Vector2(100, 0)},
		{"position": Vector2(10, -20), "rotation": PI * 0.5, "velocity": Vector2(0, 300), "goal": Vector2(10, 200)},
		{"position": Vector2(-470, 250), "rotation": -PI, "velocity": Vector2(-700, 0), "goal": Vector2(-470, 250)},
		{"position": Vector2(500, -300), "rotation": 7.0, "velocity": Vector2(450, -450), "goal": Vector2(0, 0)},
	]
	for item in fixed:
		cases.append(_case(item, Rect2(-480.0, -260.0, 960.0, 520.0)))
	for i in 40:
		var bounds := Rect2(rng.randf_range(-900, -100), rng.randf_range(-600, -100), rng.randf_range(300, 2000), rng.randf_range(200, 1200))
		cases.append(_case({
			"position": Vector2(rng.randf_range(bounds.position.x - 100, bounds.end.x + 100), rng.randf_range(bounds.position.y - 100, bounds.end.y + 100)),
			"rotation": rng.randf_range(-3.0 * PI, 3.0 * PI),
			"velocity": Vector2(rng.randf_range(-800, 800), rng.randf_range(-800, 800)),
			"goal": Vector2(rng.randf_range(bounds.position.x, bounds.end.x), rng.randf_range(bounds.position.y, bounds.end.y)),
		}, bounds))
	var file := FileAccess.open(OUT, FileAccess.WRITE)
	file.store_string(JSON.stringify({"source": "simulation_kernel_agent.gd encode_*", "cases": cases}, " "))
	file.close()
	print("robot pose golden: wrote %d cases" % cases.size())
	quit()


func _case(state: Dictionary, bounds: Rect2) -> Dictionary:
	var kernel := StubKernel.new()
	kernel.position = state["position"]
	kernel.rotation = state["rotation"]
	kernel.velocity = state["velocity"]
	var agent := KernelAgent.new()
	agent._kernel = kernel
	agent._index = 0
	var context := {
		"goal_position": state["goal"],
		"world_bounds": bounds,
		"max_goal_distance": maxf(bounds.size.length(), 1.0),
	}
	return {
		"state": {
			"x": kernel.position.x, "y": kernel.position.y, "heading": kernel.rotation,
			"vx": kernel.velocity.x, "vy": kernel.velocity.y,
			"goal": [state["goal"].x, state["goal"].y],
			"bounds": [bounds.position.x, bounds.position.y, bounds.size.x, bounds.size.y],
		},
		"values": {
			"speed": Array(agent.encode_speed(1, context)),
			"velocity_x": Array(agent.encode_velocity_x(1, context)),
			"velocity_y": Array(agent.encode_velocity_y(1, context)),
			"rotation": Array(agent.encode_rotation(1, context)),
			"heading_sincos": Array(agent.encode_heading_sincos(2, context)),
			"normalized_position": Array(agent.encode_normalized_position(2, context)),
			"goal_direction": Array(agent.encode_goal_direction(2, context)),
			"local_goal_direction": Array(agent.encode_local_goal_direction(2, context)),
			"goal_distance": Array(agent.encode_goal_distance(1, context)),
		},
	}
