class_name SimulationNavigator
extends RefCounted

var _physics_space: RID
var _islands: Array[Rect2] = []
var _kind: StringName
var _agent_params: Dictionary

var _astar: AStar2D = null

# For visualization
var debug_nodes: Array[Vector2] = []
var debug_edges: Array[Dictionary] = [] # {from: Vector2, to: Vector2, color: Color}

var _hazard_bounds: Array[Rect2] = []

func rebuild_navigation(space: RID, islands: Array[Rect2], physics_kind: StringName, agent_params: Dictionary, hazard_bounds: Array[Rect2] = []) -> void:
	_physics_space = space
	_islands = islands
	_kind = physics_kind
	_agent_params = agent_params
	_hazard_bounds = hazard_bounds

	debug_nodes.clear()
	debug_edges.clear()

	if physics_kind == &"side_view_car":
		_build_platformer_astar()
	else:
		_build_topdown_astar()

func get_path(start: Vector2, target: Vector2) -> PackedVector2Array:
	if _astar == null or _astar.get_point_count() == 0:
		return PackedVector2Array()

	var start_id = _astar.get_closest_point(start)
	var end_id = _astar.get_closest_point(target)
	if start_id == -1 or end_id == -1:
		return PackedVector2Array()

	return _astar.get_point_path(start_id, end_id)

func debug_draw(canvas: CanvasItem) -> void:
	for node in debug_nodes:
		canvas.draw_circle(node, 4.0, Color.WHITE)

	for edge in debug_edges:
		canvas.draw_line(edge.from, edge.to, edge.color, 2.0)

var _debug_state_null_printed = false

func _is_hazard(pos: Vector2) -> bool:
	for bounds in _hazard_bounds:
		if bounds.has_point(pos):
			return true
	return false

func _segment_intersects_hazard(from: Vector2, to: Vector2, shape_size: Vector2) -> bool:
	var hw := shape_size.x * 0.5
	var hh := shape_size.y * 0.5
	for bounds in _hazard_bounds:
		var inflated := bounds.grow_individual(hw, hh, hw, hh)
		if inflated.has_point(from) or inflated.has_point(to):
			return true
		var p1 := Vector2(inflated.position.x, inflated.position.y)
		var p2 := Vector2(inflated.end.x, inflated.position.y)
		var p3 := Vector2(inflated.end.x, inflated.end.y)
		var p4 := Vector2(inflated.position.x, inflated.end.y)
		if Geometry2D.segment_intersects_segment(from, to, p1, p2) != null: return true
		if Geometry2D.segment_intersects_segment(from, to, p2, p3) != null: return true
		if Geometry2D.segment_intersects_segment(from, to, p3, p4) != null: return true
		if Geometry2D.segment_intersects_segment(from, to, p4, p1) != null: return true
	return false

func is_valid_air(pos: Vector2, exclude: Array[RID] = []) -> bool:
	if _is_hazard(pos): return false
	var state := PhysicsServer2D.space_get_direct_state(_physics_space)
	if state == null: return false
	var params := PhysicsPointQueryParameters2D.new()
	params.position = pos
	params.exclude = exclude
	params.collision_mask = 1
	var result = state.intersect_point(params, 4)
	return result.size() == 0

func is_valid_floor(pos: Vector2, exclude: Array[RID] = []) -> bool:
	if _is_hazard(pos): return false
	var state := PhysicsServer2D.space_get_direct_state(_physics_space)
	if state == null: return false
	var params := PhysicsPointQueryParameters2D.new()
	params.position = pos
	params.exclude = exclude
	params.collision_mask = 1
	var result = state.intersect_point(params, 4)
	return result.size() > 0

func _build_platformer_astar() -> void:
	_astar = AStar2D.new()
	var step = 32.0 # Base grid resolution

	var walkable_points: Dictionary = {}
	var points_by_id: Dictionary = {}
	var columns: Dictionary = {}
	var next_id = 1

	var state := PhysicsServer2D.space_get_direct_state(_physics_space)
	if state == null: return

	var shape = RectangleShape2D.new()
	var shape_size: Vector2 = _agent_params.get("size", Vector2(32.0, 32.0))
	shape.size = shape_size

	var test_shape = RectangleShape2D.new()
	test_shape.size = shape_size - Vector2(4.0, 4.0)

	for bounds in _islands:
		var x = bounds.position.x
		while x <= bounds.position.x + bounds.size.x:
			var y = bounds.position.y - shape_size.y - 10.0
			var end_y = bounds.position.y + bounds.size.y + step

			while y < end_y:
				var query = PhysicsShapeQueryParameters2D.new()
				query.shape = shape
				query.transform = Transform2D(0, Vector2(x, y))
				query.motion = Vector2(0, end_y - y)
				query.collision_mask = 1

				var fraction = state.cast_motion(query)
				if fraction[0] < 1.0:
					var hit_pos = Vector2(x, y) + query.motion * fraction[0]
					var floor_pos = hit_pos + Vector2(0, shape_size.y * 0.5)

					var test_query = PhysicsShapeQueryParameters2D.new()
					test_query.shape = test_shape
					test_query.transform = Transform2D(0, hit_pos)
					test_query.collision_mask = 1
					var overlaps = state.intersect_shape(test_query, 1)

					if overlaps.is_empty() and not _is_hazard(floor_pos):
						walkable_points[floor_pos] = next_id
						points_by_id[next_id] = floor_pos
						_astar.add_point(next_id, floor_pos)
						debug_nodes.append(floor_pos)

						var col_x = roundi(x)
						if not columns.has(col_x):
							columns[col_x] = []
						columns[col_x].append(floor_pos)

						next_id += 1

					y = floor_pos.y + 4.0
				else:
					break
			x += step

	# 2. Connect horizontal walking
	for col_x in columns.keys():
		var right_x = col_x + int(step)
		if columns.has(right_x):
			for pos in columns[col_x]:
				for right_pos in columns[right_x]:
					if abs(right_pos.y - pos.y) < step:
						if _segment_intersects_hazard(pos, right_pos, shape_size):
							continue
						var id = walkable_points[pos]
						var right_id = walkable_points[right_pos]
						_astar.connect_points(id, right_id, true)
						debug_edges.append({"from": pos, "to": right_pos, "color": Color(0, 1, 0, 0.5)})

	# 3. Simulate Drops & Jumps
	var jump_speed = float(_agent_params.get("jump_velocity", 400.0))
	var move_speed = float(_agent_params.get("max_speed", 300.0))
	var gravity = 980.0
	var sim_dt = 0.05
	var max_sim_time = 1.5

	var velocities_to_test = [
		Vector2(move_speed, 0), # Run right drop
		Vector2(-move_speed, 0), # Run left drop
		Vector2(move_speed, -jump_speed), # Jump right
		Vector2(-move_speed, -jump_speed), # Jump left
		Vector2(0, -jump_speed) # Jump straight up
	]

	for pos in walkable_points:
		var id = walkable_points[pos]
		for initial_vel in velocities_to_test:
			# Offset up by 0.1 pixels to prevent the shape from starting exactly flush
			# or slightly embedded in the floor, which causes cast_motion to ignore the floor
			# and ghost straight through it.
			var sim_pos = pos + Vector2(0, -shape_size.y * 0.5 - 0.1)
			var sim_vel = initial_vel
			var t = 0.0
			var path_points = [sim_pos]
			max_sim_time = 2.0

			while t < max_sim_time:
				sim_vel.y += gravity * sim_dt
				var next_pos = sim_pos + sim_vel * sim_dt

				if _segment_intersects_hazard(sim_pos, next_pos, shape_size):
					break

				if state:
					var query = PhysicsShapeQueryParameters2D.new()
					query.shape = shape
					query.transform = Transform2D(0, sim_pos)
					query.motion = next_pos - sim_pos
					query.collision_mask = 1

					var safe_fraction = state.cast_motion(query)
					if safe_fraction[0] < 1.0:
						var hit_pos = sim_pos + query.motion * safe_fraction[0]
						var floor_hit_pos = hit_pos + Vector2(0, shape_size.y * 0.5)

						if _is_hazard(floor_hit_pos):
							break

						var hit_id = _astar.get_closest_point(floor_hit_pos)
						if hit_id != -1 and hit_id != id:
							var node_pos = _astar.get_point_position(hit_id)
							if floor_hit_pos.distance_to(node_pos) < step * 2.0:
								_astar.connect_points(id, hit_id, false)
								var c = Color(1.0, 0.5, 0.0, 0.5) if initial_vel.y < 0 else Color(1.0, 0.0, 1.0, 0.5)
								debug_edges.append({"from": pos, "to": node_pos, "color": c})
						break

				sim_pos = next_pos
				path_points.append(sim_pos)
				t += sim_dt

func _build_topdown_astar() -> void:
	_astar = AStar2D.new()
	var step = 32.0
	var walkable_points: Dictionary = {}
	var next_id = 1

	for bounds in _islands:
		var x = bounds.position.x
		while x <= bounds.position.x + bounds.size.x:
			var y = bounds.position.y
			while y <= bounds.position.y + bounds.size.y:
				var pos = Vector2(x, y)
				if walkable_points.has(pos):
					y += step
					continue

				if is_valid_air(pos):
					walkable_points[pos] = next_id
					_astar.add_point(next_id, pos)
					debug_nodes.append(pos)
					next_id += 1
				y += step
			x += step

	# Connect adjacent nodes
	for pos in walkable_points:
		var id = walkable_points[pos]
		var neighbors = [
			pos + Vector2(step, 0),
			pos + Vector2(0, step),
			pos + Vector2(step, step),
			pos + Vector2(-step, step)
		]
		for n in neighbors:
			if walkable_points.has(n):
				if _segment_intersects_hazard(pos, n, Vector2(32.0, 32.0)):
					continue
				var n_id = walkable_points[n]
				_astar.connect_points(id, n_id, true)
				# Optional: uncomment to draw top-down edges
				# debug_edges.append({"from": pos, "to": n, "color": Color(0, 1, 1, 0.1)})
