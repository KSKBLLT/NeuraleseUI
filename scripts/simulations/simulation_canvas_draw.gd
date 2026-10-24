class_name SimulationCanvasDraw
extends RefCounted

const Catalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const Registry = preload("res://scripts/simulations/simulation_definition_registry.gd")


static func draw_object(canvas: CanvasItem, data: Dictionary, local_origin: Vector2 = Vector2.ZERO, selected: bool = false) -> void:
	var type_id: StringName = StringName(data.get("type_id", ""))
	if not Catalog.has_type(type_id):
		return
	var definition: Dictionary = Catalog.definition(type_id)
	var object_position: Vector2 = data.get("position", Vector2.ZERO)
	var object_rotation: float = float(data.get("rotation", 0.0))
	var object_scale: Vector2 = data.get("scale", Vector2.ONE)
	var object_size: Vector2 = data.get("size", definition.get("default_size", Vector2(64.0, 64.0)))
	var accent: Color = Color(definition.get("color", Color("7f858f")))
	var is_agent: bool = str(definition.get("body_kind", "")) == "agent"

	# The legacy renderer drew every object below a Node2D carrying this exact
	# transform. Applying it to the shared canvas preserves the old geometry,
	# rotation and scale without restoring one CanvasItem node per object.
	canvas.draw_set_transform(object_position - local_origin, object_rotation, object_scale)
	_draw_base(canvas, str(definition.get("shape_kind", "rectangle")), object_size, accent, is_agent, selected)
	_draw_details(canvas, type_id, object_size, accent, data)
	if is_agent:
		_draw_raycasts(canvas, data, accent)
	canvas.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


static func _draw_base(canvas: CanvasItem, shape_kind: String, object_size: Vector2, accent: Color, is_agent: bool, selected: bool) -> void:
	var points: PackedVector2Array = _shape_points(shape_kind, object_size)
	if points.size() < 3:
		return
	var fill: Color = Color(accent, 0.0 if is_agent else 0.16)
	if selected and not is_agent:
		fill = fill * Color(1.24, 1.24, 1.24, 1.0)
	canvas.draw_colored_polygon(points, fill)
	if is_agent and not selected:
		return
	var closed: PackedVector2Array = points.duplicate()
	closed.append(points[0])
	var outline: Color = Color("65d8dc") if selected else accent.lightened(0.25)
	canvas.draw_polyline(closed, outline, 3.0 if selected else 1.5)


static func _shape_points(shape_kind: String, object_size: Vector2) -> PackedVector2Array:
	var half: Vector2 = object_size * 0.5
	match shape_kind:
		"circle":
			var circle: PackedVector2Array = PackedVector2Array()
			var radius: float = minf(object_size.x, object_size.y) * 0.5
			for index in 32:
				var angle: float = TAU * float(index) / 32.0
				circle.append(Vector2(cos(angle), sin(angle)) * radius)
			return circle
		"slope":
			return PackedVector2Array([
				Vector2(-half.x, half.y),
				Vector2(half.x, -half.y),
				Vector2(half.x, half.y),
			])
		_:
			return PackedVector2Array([
				Vector2(-half.x, -half.y),
				Vector2(half.x, -half.y),
				Vector2(half.x, half.y),
				Vector2(-half.x, half.y),
			])


static func _draw_details(canvas: CanvasItem, type_id: StringName, object_size: Vector2, accent: Color, data: Dictionary = {}) -> void:
	var half: Vector2 = object_size * 0.5
	var stroke: Color = accent.lightened(0.22)
	var dim: Color = Color(stroke, 0.62)
	var dark: Color = Color("17191d")

	match type_id:
		&"ice":
			for x in range(int(-half.x) + 12, int(half.x), 24):
				canvas.draw_line(Vector2(x - 10, half.y), Vector2(x + 10, -half.y), dim, 1.2)
		&"sand":
			var step_x = 18.0
			var step_y = 14.0
			var count = (object_size.x / step_x) * (object_size.y / step_y)
			if count > 400.0:
				var k = sqrt(count / 400.0)
				step_x *= k
				step_y *= k
			
			var step_x_int = maxi(1, int(step_x))
			var step_y_int = maxi(1, int(step_y))
			for x in range(int(-half.x) + 10, int(half.x), step_x_int):
				for y in range(int(-half.y) + 8, int(half.y), step_y_int):
					canvas.draw_circle(Vector2(x, y), 1.2, dim)
		&"trampoline":
			canvas.draw_line(Vector2(-half.x, -half.y), Vector2(half.x, -half.y), stroke, 3.0)
			var trampoline_x: float = -half.x + 10.0
			while trampoline_x < half.x - 10.0:
				canvas.draw_polyline(PackedVector2Array([
					Vector2(trampoline_x - 7.0, half.y),
					Vector2(trampoline_x, -half.y + 5.0),
					Vector2(trampoline_x + 7.0, half.y),
				]), dim, 1.5)
				trampoline_x += 20.0
		&"finish":
			var finish_radius: float = minf(half.x - 4.0, object_size.y * 0.28)
			var arch_center: Vector2 = Vector2(0.0, -half.y + finish_radius + 5.0)
			canvas.draw_arc(arch_center, finish_radius, PI, TAU, 24, stroke, 2.5, true)
			canvas.draw_line(Vector2(-finish_radius, arch_center.y), Vector2(-finish_radius, half.y), stroke, 2.5)
			canvas.draw_line(Vector2(finish_radius, arch_center.y), Vector2(finish_radius, half.y), stroke, 2.5)
			canvas.draw_line(Vector2(0.0, arch_center.y), Vector2(0.0, half.y), Color("67df9b"), 3.0)
		&"checkpoint":
			canvas.draw_line(Vector2(-half.x * 0.3, half.y), Vector2(-half.x * 0.3, -half.y), stroke, 2.0)
			canvas.draw_colored_polygon(PackedVector2Array([
				Vector2(-half.x * 0.3, -half.y),
				Vector2(half.x * 0.75, -half.y * 0.65),
				Vector2(-half.x * 0.3, -half.y * 0.3),
			]), Color(accent, 0.42))
		&"coin":
			var coin_radius: float = minf(half.x, half.y) * 0.68
			canvas.draw_circle(Vector2.ZERO, coin_radius, dark)
			canvas.draw_arc(Vector2.ZERO, coin_radius, 0.0, TAU, 32, stroke, 2.5)
			canvas.draw_arc(Vector2.ZERO, minf(half.x, half.y) * 0.42, 0.0, TAU, 32, dim, 1.5)
		&"spikes":
			var spike_count: int = maxi(2, int(object_size.x / 24.0))
			var spike_width: float = object_size.x / float(spike_count)
			for index in spike_count:
				var left: float = -half.x + float(index) * spike_width
				var spike_points: PackedVector2Array = PackedVector2Array([
					Vector2(left, half.y),
					Vector2(left + spike_width * 0.5, -half.y),
					Vector2(left + spike_width, half.y),
				])
				canvas.draw_colored_polygon(spike_points, Color(accent, 0.34))
				canvas.draw_polyline(spike_points, stroke, 1.5)
		&"lava":
			var wave: PackedVector2Array = PackedVector2Array()
			var steps: int = maxi(4, int(object_size.x / 18.0))
			for index in range(steps + 1):
				var px: float = lerpf(-half.x, half.x, float(index) / float(steps))
				var py: float = -half.y + (5.0 if index % 2 == 0 else 0.0)
				wave.append(Vector2(px, py))
			canvas.draw_polyline(wave, stroke, 2.0)
			for x in range(int(-half.x) + 10, int(half.x), 22):
				canvas.draw_circle(Vector2(x, 2.0), 1.5, dim)
		&"crate":
			canvas.draw_line(Vector2(-half.x, -half.y), Vector2(half.x, half.y), dim, 1.5)
			canvas.draw_line(Vector2(half.x, -half.y), Vector2(-half.x, half.y), dim, 1.5)
		&"ball":
			canvas.draw_arc(Vector2.ZERO, minf(half.x, half.y) * 0.55, -0.7, 2.4, 18, dim, 1.5)
		&"spawner":
			canvas.draw_arc(Vector2.ZERO, minf(half.x, half.y) * 0.55, 0.0, TAU, 24, stroke, 2.0)
			canvas.draw_colored_polygon(PackedVector2Array([
				Vector2(-6.0, -10.0),
				Vector2(12.0, 0.0),
				Vector2(-6.0, 10.0),
			]), Color(stroke, 0.78))
		&"car":
			_draw_car(canvas, half, dim, data)
		&"platformer":
			var head_radius: float = minf(half.x, half.y) * 0.3
			canvas.draw_circle(Vector2(0.0, -half.y * 0.55), head_radius, dark)
			canvas.draw_arc(Vector2(0.0, -half.y * 0.55), head_radius, 0.0, TAU, 20, stroke, 2.0)
			canvas.draw_line(Vector2(0.0, -half.y * 0.2), Vector2(0.0, half.y * 0.5), stroke, 2.0)
		&"rover":
			var body_pts = PackedVector2Array([
				Vector2(-half.x * 0.8, -half.y * 0.55),
				Vector2(half.x * 0.8, -half.y * 0.5),
				Vector2(half.x * 0.9, -half.y * 0.3),
				Vector2(half.x * 0.9, half.y * 0.3),
				Vector2(half.x * 0.8, half.y * 0.5),
				Vector2(-half.x * 0.8, half.y * 0.55),
			])
			canvas.draw_colored_polygon(body_pts, dark)
			canvas.draw_polyline(body_pts + PackedVector2Array([body_pts[0]]), stroke, 1.8)
			var wind_pts = PackedVector2Array([
				Vector2(half.x * 0.1, -half.y * 0.4),
				Vector2(half.x * 0.4, -half.y * 0.35),
				Vector2(half.x * 0.4, half.y * 0.35),
				Vector2(half.x * 0.1, half.y * 0.4),
			])
			canvas.draw_colored_polygon(wind_pts, Color("202530"))
			canvas.draw_polyline(wind_pts + PackedVector2Array([wind_pts[0]]), dim, 1.2)
			var rear_pts = PackedVector2Array([
				Vector2(-half.x * 0.6, -half.y * 0.35),
				Vector2(-half.x * 0.4, -half.y * 0.35),
				Vector2(-half.x * 0.4, half.y * 0.35),
				Vector2(-half.x * 0.6, half.y * 0.35),
			])
			canvas.draw_colored_polygon(rear_pts, Color("202530"))
			var roof_pts = PackedVector2Array([
				Vector2(-half.x * 0.4, -half.y * 0.35),
				Vector2(half.x * 0.1, -half.y * 0.4),
				Vector2(half.x * 0.1, half.y * 0.4),
				Vector2(-half.x * 0.4, half.y * 0.35),
			])
			canvas.draw_colored_polygon(roof_pts, dark.lightened(0.1))
			canvas.draw_polyline(roof_pts + PackedVector2Array([roof_pts[0]]), stroke, 1.2)
			for wx in [-half.x * 0.55, half.x * 0.55]:
				for wy in [-half.y * 0.65, half.y * 0.65]:
					canvas.draw_rect(Rect2(Vector2(wx - half.x*0.15, wy - half.y*0.15), Vector2(half.x*0.3, half.y*0.3)), Color("111111"))
			canvas.draw_circle(Vector2(half.x * 0.85, -half.y * 0.3), 3.0, Color(1, 1, 0.8, 0.8))
			canvas.draw_circle(Vector2(half.x * 0.85, half.y * 0.3), 3.0, Color(1, 1, 0.8, 0.8))
			canvas.draw_line(Vector2(-half.x * 0.8, -half.y * 0.45), Vector2(-half.x * 0.8, -half.y * 0.25), Color(1, 0.2, 0.2, 0.8), 2.0)
			canvas.draw_line(Vector2(-half.x * 0.8, half.y * 0.25), Vector2(-half.x * 0.8, half.y * 0.45), Color(1, 0.2, 0.2, 0.8), 2.0)
		&"flying_agent":
			# Side-view helicopter
			# Fuselage
			var fuse_pts = PackedVector2Array([
				Vector2(half.x * 0.7, 0.0),             # Nose
				Vector2(half.x * 0.4, -half.y * 0.5),   # Windshield top
				Vector2(-half.x * 0.3, -half.y * 0.5),  # Roof back
				Vector2(-half.x * 0.5, 0.0),            # Body back
				Vector2(-half.x * 0.3, half.y * 0.4),   # Bottom back
				Vector2(half.x * 0.4, half.y * 0.4),    # Bottom front
			])
			canvas.draw_colored_polygon(fuse_pts, dark)
			canvas.draw_polyline(fuse_pts + PackedVector2Array([fuse_pts[0]]), stroke, 1.8)
			
			# Window
			var window_pts = PackedVector2Array([
				Vector2(half.x * 0.6, -half.y * 0.05),
				Vector2(half.x * 0.35, -half.y * 0.4),
				Vector2(-half.x * 0.1, -half.y * 0.4),
				Vector2(-half.x * 0.1, -half.y * 0.05),
			])
			canvas.draw_colored_polygon(window_pts, Color("202530"))
			
			# Tail boom
			var tail_pts = PackedVector2Array([
				Vector2(-half.x * 0.4, -half.y * 0.2),
				Vector2(-half.x * 1.1, -half.y * 0.4),
				Vector2(-half.x * 1.1, -half.y * 0.2),
				Vector2(-half.x * 0.4, 0.0),
			])
			canvas.draw_colored_polygon(tail_pts, dark)
			canvas.draw_polyline(tail_pts + PackedVector2Array([tail_pts[0]]), stroke, 1.5)
			
			# Tail fin
			var fin_pts = PackedVector2Array([
				Vector2(-half.x * 1.0, -half.y * 0.4),
				Vector2(-half.x * 1.1, -half.y * 0.8),
				Vector2(-half.x * 1.2, -half.y * 0.8),
				Vector2(-half.x * 1.1, -half.y * 0.2),
			])
			canvas.draw_colored_polygon(fin_pts, dark)
			canvas.draw_polyline(fin_pts + PackedVector2Array([fin_pts[0]]), stroke, 1.5)
			
			# Skids (Landing gear)
			canvas.draw_line(Vector2(-half.x * 0.2, half.y * 0.4), Vector2(-half.x * 0.2, half.y * 0.7), stroke, 2.0)
			canvas.draw_line(Vector2(half.x * 0.3, half.y * 0.4), Vector2(half.x * 0.3, half.y * 0.7), stroke, 2.0)
			canvas.draw_line(Vector2(-half.x * 0.4, half.y * 0.7), Vector2(half.x * 0.6, half.y * 0.7), stroke, 2.5)
			
			# Main Rotor Shaft
			canvas.draw_line(Vector2(0.0, -half.y * 0.5), Vector2(0.0, -half.y * 0.75), stroke, 3.0)
			
			# Main Rotor spinning (side view is just a line that changes length/perspective)
			var time_sec = float(Time.get_ticks_msec()) / 1000.0
			var rotor_angle = time_sec * 25.0
			var rotor_radius = maxf(half.x, half.y) * 1.2
			var apparent_radius = rotor_radius * absf(cos(rotor_angle))
			canvas.draw_line(Vector2(-apparent_radius, -half.y * 0.75), Vector2(apparent_radius, -half.y * 0.75), Color(stroke, 0.8), 3.0)
			
			# Tail rotor spinning
			var tail_rotor_radius = half.y * 0.4
			var tail_apparent = tail_rotor_radius * absf(cos(rotor_angle * 1.5))
			canvas.draw_line(Vector2(-half.x * 1.1, -half.y * 0.5 - tail_apparent), Vector2(-half.x * 1.1, -half.y * 0.5 + tail_apparent), Color(stroke, 0.8), 2.0)
		&"ray_sensor":
			for angle in [-0.45, -0.22, 0.0, 0.22, 0.45]:
				canvas.draw_line(Vector2.ZERO, Vector2.RIGHT.rotated(angle) * 34.0, dim, 1.2)
		&"distance_sensor", &"speed_sensor":
			canvas.draw_arc(Vector2.ZERO, minf(half.x, half.y) * 0.58, 0.2, 2.9, 18, stroke, 2.0)
			canvas.draw_line(Vector2.ZERO, Vector2(9.0, -5.0), stroke, 1.8)


static func _draw_car(canvas: CanvasItem, half: Vector2, dim: Color, data: Dictionary) -> void:
	var body_stroke: Color = Color("d7dce2")
	var body_fill: Color = Color(0.12, 0.13, 0.15, 0.96)
	var glass_fill: Color = Color(0.16, 0.25, 0.29, 0.78)
	var chassis: PackedVector2Array = PackedVector2Array([
		Vector2(-half.x * 0.92, 3.0),
		Vector2(-half.x * 0.72, -5.0),
		Vector2(-half.x * 0.42, -half.y * 0.68),
		Vector2(half.x * 0.2, -half.y * 0.68),
		Vector2(half.x * 0.48, -half.y * 0.22),
		Vector2(half.x * 0.82, -1.0),
		Vector2(half.x * 0.9, half.y * 0.46),
		Vector2(-half.x * 0.92, half.y * 0.46),
	])
	canvas.draw_colored_polygon(chassis, body_fill)
	var closed_chassis: PackedVector2Array = chassis.duplicate()
	closed_chassis.append(chassis[0])
	canvas.draw_polyline(closed_chassis, body_stroke, 1.8, true)

	var cabin: PackedVector2Array = PackedVector2Array([
		Vector2(-half.x * 0.35, -half.y * 0.6),
		Vector2(-half.x * 0.06, -half.y * 0.6),
		Vector2(half.x * 0.14, -half.y * 0.18),
		Vector2(-half.x * 0.3, -half.y * 0.18),
	])
	canvas.draw_colored_polygon(cabin, glass_fill)
	var closed_cabin: PackedVector2Array = cabin.duplicate()
	closed_cabin.append(cabin[0])
	canvas.draw_polyline(closed_cabin, Color("8edce2"), 1.2, true)
	canvas.draw_line(Vector2(-half.x * 0.9, half.y * 0.15), Vector2(half.x * 0.88, half.y * 0.15), dim, 1.2)

	for wheel_x in [-half.x * 0.55, half.x * 0.53]:
		var wheel_center: Vector2 = Vector2(wheel_x, half.y * 0.48)
		canvas.draw_circle(wheel_center, 8.5, Color("111318"))
		canvas.draw_arc(wheel_center, 8.5, 0.0, TAU, 24, body_stroke, 1.8, true)
		canvas.draw_circle(wheel_center, 3.1, Color("59616c"))
		canvas.draw_arc(wheel_center, 3.1, 0.0, TAU, 18, Color("c2c9d2"), 1.0, true)

static func _draw_raycasts(canvas: CanvasItem, data: Dictionary, dim: Color) -> void:
	var properties: Dictionary = data.get("properties", {})
	var model_binding: Dictionary = properties.get("model_binding", {})
	var inputs: Array = model_binding.get("inputs", [])
	if inputs.is_empty():
		var type_id = data.get("type_id", "")
		var def := Catalog.definition(type_id) if type_id != "" else {}
		var agent_def: Dictionary = Registry.AGENT_DEFINITIONS.get(def.get("agent_id", &""), {}) if def.has("agent_id") else {}
		inputs = agent_def.get("default_binding", {}).get("inputs", [])

	var ray_count: int = 0
	for input in inputs:
		if input is Dictionary and str(input.get("sensor_id", "")) == "ray_distance":
			ray_count = int(input.get("length", 0))
	if ray_count > 0:
		var raycast_distances = data.get("raycast_distances")
		var ray_length: float = 320.0
		var ray_arc_deg: float = 132.0
		var ray_arc := deg_to_rad(ray_arc_deg)
		var start_angle := -ray_arc * 0.5
		var step_angle := ray_arc / maxf(1.0, float(ray_count - 1)) if ray_count > 1 else 0.0
		var spatial_index = data.get("spatial_index")
		var origin: Vector2 = data.get("position", Vector2.ZERO)
		var rotation: float = float(data.get("rotation", 0.0))
		var object_id: String = str(data.get("id", ""))

		for i in ray_count:
			var angle := start_angle + float(i) * step_angle
			var draw_length := ray_length
			if raycast_distances is PackedFloat32Array and i < raycast_distances.size():
				draw_length = raycast_distances[i] * ray_length
			elif spatial_index != null:
				draw_length = spatial_index.raycast(origin, Vector2.RIGHT.rotated(rotation + angle), ray_length, object_id)
			canvas.draw_line(Vector2.ZERO, Vector2.RIGHT.rotated(angle) * draw_length, Color(dim, 0.35), 1.0)
