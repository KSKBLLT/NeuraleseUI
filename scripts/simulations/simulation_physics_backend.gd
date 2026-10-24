class_name SimulationPhysicsBackend
extends RefCounted

## Thin, session-owned adapter over PhysicsServer2D. It is safe to place sessions on
## separate workers because no session shares RIDs or mutable containers with another.

var _blueprint: Dictionary = {}
var _space := RID()
var _body_by_index: Array[RID] = []
var _shapes: Array[RID] = []
var _active := false
var _positions := PackedVector2Array()
var _rotations := PackedFloat32Array()
var _velocities := PackedVector2Array()
var _angular_velocities := PackedFloat32Array()
var _jump_pressed := PackedByteArray()
var _state_mutex := Mutex.new()


func create(blueprint: Dictionary, active := true) -> bool:
	destroy()
	_blueprint = blueprint
	_space = PhysicsServer2D.space_create()
	if not _space.is_valid():
		return false
	_configure_default_area()
	var object_count: int = blueprint.get("ids", PackedStringArray()).size()
	_body_by_index.resize(object_count)
	_positions.resize(object_count)
	_rotations.resize(object_count)
	_velocities.resize(object_count)
	_angular_velocities.resize(object_count)
	_jump_pressed.resize(object_count)
	for index in _body_by_index.size():
		_body_by_index[index] = RID()
		_positions[index] = blueprint.get("positions", PackedVector2Array())[index]
		_rotations[index] = blueprint.get("rotations", PackedFloat32Array())[index]
		_velocities[index] = Vector2.ZERO
		_angular_velocities[index] = 0.0
		_jump_pressed[index] = 0
	for index in blueprint.get("physical_indices", PackedInt32Array()):
		_create_body(int(index))
	set_active(active)
	return true


func destroy() -> void:
	if _space.is_valid():
		PhysicsServer2D.space_set_active(_space, false)
	for body in _body_by_index:
		if body.is_valid():
			PhysicsServer2D.free_rid(body)
	for shape in _shapes:
		if shape.is_valid():
			PhysicsServer2D.free_rid(shape)
	if _space.is_valid():
		PhysicsServer2D.free_rid(_space)
	_space = RID()
	_body_by_index.clear()
	_shapes.clear()
	_positions.clear()
	_rotations.clear()
	_velocities.clear()
	_angular_velocities.clear()
	_jump_pressed.clear()
	_blueprint = {}
	_active = false


func set_active(value: bool) -> void:
	if not _space.is_valid():
		return
	_active = value
	PhysicsServer2D.space_set_active(_space, value)


func is_active() -> bool:
	return _active


func space_rid() -> RID:
	return _space


func reset_to_blueprint() -> void:
	_jump_pressed.fill(0)
	var positions: PackedVector2Array = _blueprint.get("positions", PackedVector2Array())
	var rotations: PackedFloat32Array = _blueprint.get("rotations", PackedFloat32Array())
	for index in _body_by_index.size():
		if _body_by_index[index].is_valid():
			set_body_state(index, positions[index], rotations[index], Vector2.ZERO, 0.0)
			set_material(index, _blueprint["definitions"][index])


func set_material(index: int, definition: Dictionary) -> bool:
	var body := body_rid(index)
	if not body.is_valid() or str(_blueprint["definitions"][index].get("body_kind", "")) == "area":
		return false
	PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_FRICTION, float(definition.get("friction", 0.8)))
	PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_BOUNCE, float(definition.get("bounce", 0.0)))
	return true


func set_body_state(index: int, position: Vector2, rotation: float, velocity := Vector2.ZERO, angular_velocity := 0.0) -> void:
	var body := body_rid(index)
	if not body.is_valid():
		return
	_state_mutex.lock()
	_positions[index] = position
	_rotations[index] = rotation
	_velocities[index] = velocity
	_angular_velocities[index] = angular_velocity
	_state_mutex.unlock()
	var body_kind := str(_blueprint["definitions"][index].get("body_kind", "static"))
	if body_kind == "area":
		PhysicsServer2D.area_set_transform(body, Transform2D(rotation, position))
		return
		
	PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_SLEEPING, false)
	PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(rotation, position))
	PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, velocity)
	PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY, angular_velocity)
	PhysicsServer2D.body_set_constant_force(body, Vector2.ZERO)
	PhysicsServer2D.body_set_constant_torque(body, 0.0)


func set_object_transform(index: int, position: Vector2, rotation: float) -> void:
	var body := body_rid(index)
	if body.is_valid():
		_state_mutex.lock()
		_positions[index] = position
		_rotations[index] = rotation
		_state_mutex.unlock()
		var body_kind := str(_blueprint["definitions"][index].get("body_kind", "static"))
		if body_kind == "area":
			PhysicsServer2D.area_set_transform(body, Transform2D(rotation, position))
		else:
			PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_TRANSFORM, Transform2D(rotation, position))


func body_rid(index: int) -> RID:
	return _body_by_index[index] if index >= 0 and index < _body_by_index.size() else RID()


func position(index: int) -> Vector2:
	if index >= 0 and index < _body_by_index.size():
		var body: RID = _body_by_index[index]
		if body.is_valid():
			if str(_blueprint["definitions"][index].get("body_kind", "static")) == "area":
				return PhysicsServer2D.area_get_transform(body).origin
			return PhysicsServer2D.body_get_state(body, PhysicsServer2D.BODY_STATE_TRANSFORM).origin
	_state_mutex.lock()
	var val := _positions[index] if index >= 0 and index < _positions.size() else Vector2.ZERO
	_state_mutex.unlock()
	return val


func rotation(index: int) -> float:
	if index >= 0 and index < _body_by_index.size():
		var body: RID = _body_by_index[index]
		if body.is_valid():
			if str(_blueprint["definitions"][index].get("body_kind", "static")) == "area":
				return PhysicsServer2D.area_get_transform(body).get_rotation()
			return PhysicsServer2D.body_get_state(body, PhysicsServer2D.BODY_STATE_TRANSFORM).get_rotation()
	_state_mutex.lock()
	var val := _rotations[index] if index >= 0 and index < _rotations.size() else 0.0
	_state_mutex.unlock()
	return val


func velocity(index: int) -> Vector2:
	if index >= 0 and index < _body_by_index.size():
		var body: RID = _body_by_index[index]
		if body.is_valid():
			if str(_blueprint["definitions"][index].get("body_kind", "static")) == "area":
				return Vector2.ZERO
			return PhysicsServer2D.body_get_state(body, PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY)
	_state_mutex.lock()
	var val := _velocities[index] if index >= 0 and index < _velocities.size() else Vector2.ZERO
	_state_mutex.unlock()
	return val


func angular_velocity(index: int) -> float:
	if index >= 0 and index < _body_by_index.size():
		var body: RID = _body_by_index[index]
		if body.is_valid():
			if str(_blueprint["definitions"][index].get("body_kind", "static")) == "area":
				return 0.0
			return float(PhysicsServer2D.body_get_state(body, PhysicsServer2D.BODY_STATE_ANGULAR_VELOCITY))
	_state_mutex.lock()
	var val := _angular_velocities[index] if index >= 0 and index < _angular_velocities.size() else 0.0
	_state_mutex.unlock()
	return val



func apply_agent_controls(index: int, physics_kind: StringName, controls: Dictionary) -> void:
	var body := body_rid(index)
	if not body.is_valid():
		return
	var steering := float(controls.get("steering", 0.0))
	var throttle := float(controls.get("throttle", 0.0))
	var brake := float(controls.get("brake", 0.0))
	var force := Vector2.ZERO
	var torque := 0.0
	match physics_kind:
		&"flying_rigid":
			force = Vector2(float(controls.get("horizontal_thrust", 0.0)), float(controls.get("vertical_thrust", 0.0))) * 2400.0
		&"top_down_rigid":
			force = Vector2.RIGHT.rotated(rotation(index)) * throttle * 2400.0 * (1.0 - brake)
			torque = steering * 12000.0
		&"ground_rigid":
			var is_car: bool = index < _blueprint["types"].size() and _blueprint["types"][index] == "car"
			if is_car:
				# A side-view car's expert policy sets `steering` for left/right direction (-1 to 1) 
				# and `throttle` for speed. We must multiply them to get directional force.
				force = Vector2.RIGHT.rotated(rotation(index)) * steering * absf(throttle) * 4800.0 * (1.0 - brake)
				torque = 0.0
			else:
				# Unicycles also use steering for direction, but require balancing torque.
				force = Vector2.RIGHT * steering * absf(throttle) * 4800.0 * (1.0 - brake)
				var tilt := wrapf(rotation(index), -PI, PI)
				torque = -tilt * 24000.0 - angular_velocity(index) * 1200.0
			var jump_pressed := float(controls.get("jump", 0.0)) > 0.5
			var jump_started := jump_pressed and _jump_pressed[index] == 0
			_jump_pressed[index] = 1 if jump_pressed else 0
			if jump_started and bool(controls.get("grounded", false)):
				PhysicsServer2D.body_apply_central_impulse(body, Vector2.UP * 800.0)
	# Controls are produced less frequently than physics ticks during live model
	# inference, so keep them active until the next control packet replaces them.
	PhysicsServer2D.body_set_constant_force(body, force)
	PhysicsServer2D.body_set_constant_torque(body, torque)
	if force.length_squared() > 0.000001 or absf(torque) > 0.000001:
		# PhysicsServer2D does not guarantee that changing a constant force wakes a
		# sleeping body. This commonly happens when Play is pressed before Model.
		PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_SLEEPING, false)
	var base_linear_damp := 1.0 if physics_kind == &"flying_rigid" else (1.4 if physics_kind == &"top_down_rigid" else 0.35)
	var base_angular_damp := 0.0 if physics_kind == &"flying_rigid" else 3.0
	PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_LINEAR_DAMP, base_linear_damp + brake * 8.0)
	PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_ANGULAR_DAMP, base_angular_damp + brake * 4.0)
	_limit_speed(body, 820.0 if physics_kind == &"flying_rigid" else 700.0)


var _drag_history: Dictionary = {}

func live_update_object(index: int, object_data: Dictionary, definition: Dictionary) -> void:
	var body = body_rid(index)
	if not body.is_valid():
		return
	var shape := PhysicsServer2D.body_get_shape(body, 0) if PhysicsServer2D.body_get_shape_count(body) > 0 else RID()
	if shape.is_valid():
		var size_value: Vector2 = object_data.get("size", Vector2.ZERO) * (object_data.get("scale", Vector2.ONE) as Vector2).abs()
		_set_shape_data(shape, str(definition.get("shape_kind", "rectangle")), size_value)

	var new_position = object_data.get("position", Vector2.ZERO)
	var new_rotation = float(object_data.get("rotation", 0.0))

	var history: Array = _drag_history.get(index, [])
	var current_time = Time.get_ticks_usec()

	history.push_back({"time": current_time, "pos": new_position, "rot": new_rotation})

	while history.size() > 0 and current_time - history[0].time > 100000:
		history.pop_front()

	_drag_history[index] = history

	var velocity := Vector2.ZERO
	var angular_velocity := 0.0

	if history.size() > 1:
		var oldest: Dictionary = history[0]
		var dt: float = (current_time - oldest.time) / 1000000.0
		if dt > 0.0:
			velocity = ((new_position - oldest.pos) / dt) * 0.3
			var angle_diff: float = wrapf(new_rotation - oldest.rot, -PI, PI)
			angular_velocity = angle_diff / dt

	set_body_state(index, new_position, new_rotation, velocity, angular_velocity)


func _create_body(index: int) -> void:
	var definition: Dictionary = _blueprint["definitions"][index]
	var body_kind := str(definition.get("body_kind", "static"))
	
	if body_kind == "area":
		var area := PhysicsServer2D.area_create()
		PhysicsServer2D.area_set_space(area, _space)
		PhysicsServer2D.area_set_collision_layer(area, 2)
		PhysicsServer2D.area_set_collision_mask(area, 1)
		
		if definition.has("viscosity"):
			PhysicsServer2D.area_set_param(area, PhysicsServer2D.AREA_PARAM_LINEAR_DAMP_OVERRIDE_MODE, PhysicsServer2D.AREA_SPACE_OVERRIDE_COMBINE)
			PhysicsServer2D.area_set_param(area, PhysicsServer2D.AREA_PARAM_LINEAR_DAMP, float(definition.get("viscosity", 0.0)))
			PhysicsServer2D.area_set_param(area, PhysicsServer2D.AREA_PARAM_ANGULAR_DAMP_OVERRIDE_MODE, PhysicsServer2D.AREA_SPACE_OVERRIDE_COMBINE)
			PhysicsServer2D.area_set_param(area, PhysicsServer2D.AREA_PARAM_ANGULAR_DAMP, float(definition.get("viscosity", 0.0)))
			
		var shape := _create_shape(index, definition)
		if shape.is_valid():
			PhysicsServer2D.area_add_shape(area, shape)
			_shapes.append(shape)
		_body_by_index[index] = area
		set_body_state(index, _blueprint["positions"][index], _blueprint["rotations"][index])
		return

	var body := PhysicsServer2D.body_create()
	var mode := PhysicsServer2D.BODY_MODE_STATIC if body_kind == "static" else PhysicsServer2D.BODY_MODE_RIGID
	var physics_kind := StringName()
	if mode == PhysicsServer2D.BODY_MODE_RIGID:
		var agent_id := StringName(definition.get("agent_id", ""))
		var agent_definition := SimulationDefinitionRegistry.agent(agent_id)
		physics_kind = StringName(agent_definition.get("physics_kind", ""))
		if physics_kind == &"flying_rigid":
			mode = PhysicsServer2D.BODY_MODE_RIGID_LINEAR
	PhysicsServer2D.body_set_mode(body, mode)
	PhysicsServer2D.body_set_space(body, _space)
	PhysicsServer2D.body_set_collision_layer(body, 1)
	PhysicsServer2D.body_set_collision_mask(body, 1)
	PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_FRICTION, float(definition.get("friction", 0.8)))
	PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_BOUNCE, float(definition.get("bounce", 0.0)))
	if mode in [PhysicsServer2D.BODY_MODE_RIGID, PhysicsServer2D.BODY_MODE_RIGID_LINEAR]:
		PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_MASS, float(definition.get("mass", 1.0)))
		if physics_kind in [&"top_down_rigid", &"flying_rigid"]:
			PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_GRAVITY_SCALE, 0.0)
		var linear_damp: float = 1.0 if physics_kind == &"flying_rigid" else (1.4 if physics_kind == &"top_down_rigid" else 0.35)
		var angular_damp: float = 0.0 if physics_kind == &"flying_rigid" else 3.0
		PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_LINEAR_DAMP, linear_damp)
		PhysicsServer2D.body_set_param(body, PhysicsServer2D.BODY_PARAM_ANGULAR_DAMP, angular_damp)
	var shape := _create_shape(index, definition)
	if shape.is_valid():
		PhysicsServer2D.body_add_shape(body, shape)
		_shapes.append(shape)
	_body_by_index[index] = body
	PhysicsServer2D.body_set_state_sync_callback(body, _sync_body_state.bind(index))
	set_body_state(index, _blueprint["positions"][index], _blueprint["rotations"][index])


func _configure_default_area() -> void:
	# A raw space defaults to 9.80665 px/s² pointing up. World2D normally
	# overwrites the space's default area from ProjectSettings; do the same here.
	var perspective = StringName(_blueprint.get("perspective_mode", "auto"))
	var gravity: float = float(ProjectSettings.get_setting("physics/2d/default_gravity", 980.0))
	if perspective == &"top_down":
		gravity = 0.0
	var gravity_vector: Vector2 = ProjectSettings.get_setting("physics/2d/default_gravity_vector", Vector2.DOWN)
	var linear_damp: float = float(ProjectSettings.get_setting("physics/2d/default_linear_damp", 0.1))
	var angular_damp: float = float(ProjectSettings.get_setting("physics/2d/default_angular_damp", 1.0))
	PhysicsServer2D.area_set_param(_space, PhysicsServer2D.AREA_PARAM_GRAVITY, gravity)
	PhysicsServer2D.area_set_param(_space, PhysicsServer2D.AREA_PARAM_GRAVITY_VECTOR, gravity_vector)
	PhysicsServer2D.area_set_param(_space, PhysicsServer2D.AREA_PARAM_LINEAR_DAMP, linear_damp)
	PhysicsServer2D.area_set_param(_space, PhysicsServer2D.AREA_PARAM_ANGULAR_DAMP, angular_damp)


func _sync_body_state(state: PhysicsDirectBodyState2D, index: int) -> void:
	if index < 0 or index >= _positions.size():
		return
	_state_mutex.lock()
	_positions[index] = state.transform.origin
	_rotations[index] = state.transform.get_rotation()
	_velocities[index] = state.linear_velocity
	_angular_velocities[index] = state.angular_velocity
	_state_mutex.unlock()


func _create_shape(index: int, definition: Dictionary) -> RID:
	var shape := RID()
	var size_value: Vector2 = _blueprint["sizes"][index] * _blueprint["scales"][index].abs()
	var shape_kind := str(definition.get("shape_kind", "rectangle"))
	match shape_kind:
		"circle":
			shape = PhysicsServer2D.circle_shape_create()
		"slope":
			shape = PhysicsServer2D.convex_polygon_shape_create()
		_:
			shape = PhysicsServer2D.rectangle_shape_create()
	_set_shape_data(shape, shape_kind, size_value)
	return shape


func _set_shape_data(shape: RID, shape_kind: String, size_value: Vector2) -> void:
	match shape_kind:
		"circle":
			PhysicsServer2D.shape_set_data(shape, minf(size_value.x, size_value.y) * 0.5)
		"slope":
			PhysicsServer2D.shape_set_data(shape, PackedVector2Array([
				Vector2(-size_value.x * 0.5, size_value.y * 0.5),
				Vector2(size_value.x * 0.5, -size_value.y * 0.5),
				Vector2(size_value.x * 0.5, size_value.y * 0.5),
			]))
		_:
			PhysicsServer2D.shape_set_data(shape, size_value * 0.5)


func _limit_speed(body: RID, maximum: float) -> void:
	var index: int = _body_by_index.find(body)
	var current: Vector2 = velocity(index)
	if current.length() > maximum:
		var limited: Vector2 = current.normalized() * maximum
		_velocities[index] = limited
		PhysicsServer2D.body_set_state(body, PhysicsServer2D.BODY_STATE_LINEAR_VELOCITY, limited)
