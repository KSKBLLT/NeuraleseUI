class_name SimulationWorldRenderer
extends Node2D

const Catalog = preload("res://scripts/simulations/simulation_object_catalog.gd")
const ChunkScript = preload("res://scripts/simulations/simulation_render_chunk.gd")
const CanvasDraw = preload("res://scripts/simulations/simulation_canvas_draw.gd")
const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

const CHUNK_SIZE := 768.0
const MAX_LIVE_CHUNKS := 96

var _document: SimulationWorldState
var _chunk_objects: Dictionary = {}
var _chunk_by_index: Dictionary = {}
var _live_chunks: Dictionary = {}
var _chunk_pool: Array[Node2D] = []
var _dynamic_indices := PackedInt32Array()
var _runtime_ids := PackedStringArray()
var _runtime_transforms := PackedFloat32Array()
var _runtime_raycasts: Dictionary = {}
var _hidden_ids: Dictionary = {}
var _selected_ids: Dictionary = {}
var _layout_dirty := true
var _last_visible_rect := Rect2()


var _animated_layer: Node2D

func _ready() -> void:
	z_index = 1
	_animated_layer = Node2D.new()
	_animated_layer.name = "AnimatedLayer"
	_animated_layer.draw.connect(_on_animated_layer_draw)
	add_child(_animated_layer)
	set_process(true)


var _spatial_index: SimulationSpatialIndex

func configure(document: SimulationWorldState, spatial_index: SimulationSpatialIndex = null) -> void:
	_disconnect_document()
	_document = document
	_spatial_index = spatial_index
	if _document != null:
		_document.structure_changed.connect(_rebuild_layout)
		_document.object_changed.connect(_on_object_changed)
	_rebuild_layout()


func set_selected_id(object_id: String) -> void:
	set_selected_ids([object_id] if not object_id.is_empty() else [])


func set_selected_ids(object_ids: Array[String]) -> void:
	_selected_ids.clear()
	for object_id in object_ids:
		if not object_id.is_empty():
			_selected_ids[object_id] = true
	_refresh_chunks()
	queue_redraw()


func set_runtime_snapshot(snapshot: Dictionary) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"renderer.set_runtime_snapshot")
	_runtime_ids = snapshot.get("ids", PackedStringArray())
	_runtime_transforms = snapshot.get("transforms", PackedFloat32Array())
	_runtime_raycasts = snapshot.get("raycasts", {})
	var next_hidden: Dictionary = snapshot.get("hidden_ids", {}).duplicate() if snapshot.get("hidden_ids", {}) is Dictionary else {}
	if next_hidden != _hidden_ids:
		_hidden_ids = next_hidden
		_refresh_chunks()
	queue_redraw()
	PerformanceProbe.end_scope(&"renderer.set_runtime_snapshot", perf_token)


func clear_runtime_snapshot() -> void:
	_runtime_ids.clear()
	_runtime_transforms.clear()
	_runtime_raycasts.clear()
	var had_hidden := not _hidden_ids.is_empty()
	_hidden_ids.clear()
	if had_hidden:
		_refresh_chunks()
	queue_redraw()


func _process(_delta: float) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"renderer.process")
	_profiled_process()
	PerformanceProbe.end_scope(&"renderer.process", perf_token)
	
	if is_instance_valid(_document):
		for index in _dynamic_indices:
			if _document.type_at(index) == &"flying_agent":
				_animated_layer.queue_redraw()
				break


func _profiled_process() -> void:
	if _document == null:
		return
	var visible_rect := _visible_world_rect().grow(CHUNK_SIZE)
	if _layout_dirty or not _rect_approximately_equal(visible_rect, _last_visible_rect):
		_last_visible_rect = visible_rect
		_materialize_visible_chunks(visible_rect)
		_layout_dirty = false
		queue_redraw()


func _draw() -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"renderer.draw_dynamic")
	_profiled_draw()
	PerformanceProbe.end_scope(&"renderer.draw_dynamic", perf_token)


func _profiled_draw() -> void:
	if _document == null:
		return
	var visible_rect := _visible_world_rect().grow(128.0)
	for dynamic_offset in _dynamic_indices.size():
		var index := _dynamic_indices[dynamic_offset]
		var data := _document.render_data_at(index)
		var object_id := str(data.get("id", ""))
		if _hidden_ids.has(object_id):
			continue
		var transform_offset := dynamic_offset * 3
		if dynamic_offset < _runtime_ids.size() and _runtime_ids[dynamic_offset] == object_id and transform_offset + 2 < _runtime_transforms.size():
			data["position"] = Vector2(_runtime_transforms[transform_offset], _runtime_transforms[transform_offset + 1])
			data["rotation"] = _runtime_transforms[transform_offset + 2]
			if _runtime_raycasts.has(object_id):
				data["raycast_distances"] = _runtime_raycasts[object_id]
		if not _render_bounds(data).intersects(visible_rect, true):
			continue
		if _spatial_index != null:
			data["spatial_index"] = _spatial_index
			
		if data.get("type_id", "") == "flying_agent":
			continue
			
		CanvasDraw.draw_object(self, data, Vector2.ZERO, _selected_ids.has(object_id))


func _rebuild_layout() -> void:
	_chunk_objects.clear()
	_chunk_by_index.clear()
	_dynamic_indices.clear()
	if _document != null:
		for index in _document.object_count():
			var definition := Catalog.definition(_document.type_at(index))
			if str(definition.get("body_kind", "")) in ["rigid", "agent"]:
				_dynamic_indices.append(index)
				continue
			var key := _chunk_key(_document.position_at(index))
			var bucket: PackedInt32Array = _chunk_objects.get(key, PackedInt32Array())
			bucket.append(index)
			_chunk_objects[key] = bucket
			_chunk_by_index[index] = key
	_layout_dirty = true
	_refresh_chunks()
	queue_redraw()


func _on_object_changed(object_id: String) -> void:
	if _document == null:
		return
	var index := _document.index_of(object_id)
	if index < 0:
		return
	var definition := Catalog.definition(_document.type_at(index))
	if str(definition.get("body_kind", "")) in ["rigid", "agent"]:
		queue_redraw()
		return
	var old_key: Variant = _chunk_by_index.get(index)
	var new_key := _chunk_key(_document.position_at(index))
	if old_key != null and old_key != new_key:
		var old_bucket: PackedInt32Array = _chunk_objects.get(old_key, PackedInt32Array())
		var at := old_bucket.find(index)
		if at >= 0:
			old_bucket.remove_at(at)
		if old_bucket.is_empty():
			_chunk_objects.erase(old_key)
		else:
			_chunk_objects[old_key] = old_bucket
		if _live_chunks.has(old_key):
			_configure_chunk(old_key)
	if old_key == null or old_key != new_key:
		var new_bucket: PackedInt32Array = _chunk_objects.get(new_key, PackedInt32Array())
		new_bucket.append(index)
		_chunk_objects[new_key] = new_bucket
		_chunk_by_index[index] = new_key
		_layout_dirty = true
	if _live_chunks.has(new_key):
		_configure_chunk(new_key)

func _on_animated_layer_draw() -> void:
	if _document == null:
		return
	var visible_rect := _visible_world_rect().grow(128.0)
	for dynamic_offset in _dynamic_indices.size():
		var index := _dynamic_indices[dynamic_offset]
		var data := _document.render_data_at(index)
		if data.get("type_id", "") != "flying_agent":
			continue
			
		var object_id := str(data.get("id", ""))
		if _hidden_ids.has(object_id):
			continue
		var transform_offset := dynamic_offset * 3
		if dynamic_offset < _runtime_ids.size() and _runtime_ids[dynamic_offset] == object_id and transform_offset + 2 < _runtime_transforms.size():
			data["position"] = Vector2(_runtime_transforms[transform_offset], _runtime_transforms[transform_offset + 1])
			data["rotation"] = _runtime_transforms[transform_offset + 2]
			if _runtime_raycasts.has(object_id):
				data["raycast_distances"] = _runtime_raycasts[object_id]
		if not _render_bounds(data).intersects(visible_rect, true):
			continue
		if _spatial_index != null:
			data["spatial_index"] = _spatial_index
			
		CanvasDraw.draw_object(_animated_layer, data, Vector2.ZERO, _selected_ids.has(object_id))


func _materialize_visible_chunks(rect: Rect2) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"renderer.materialize_chunks")
	var needed := {}
	var padded_rect := rect.grow(1200.0)
	var minimum := _chunk_key(padded_rect.position)
	var maximum := _chunk_key(padded_rect.end)

	# PREVENT FATAL FREEZE: Clamp iteration range to prevent memory explosion if bounds are corrupted
	maximum.x = mini(maximum.x, minimum.x + MAX_LIVE_CHUNKS)
	maximum.y = mini(maximum.y, minimum.y + MAX_LIVE_CHUNKS)

	for y in range(minimum.y, maximum.y + 1):
		for x in range(minimum.x, maximum.x + 1):
			var key := Vector2i(x, y)
			if _chunk_objects.has(key):
				needed[key] = true
	var keys: Array = needed.keys()
	if keys.size() > MAX_LIVE_CHUNKS:
		var center := rect.get_center() / CHUNK_SIZE
		keys.sort_custom(func(left: Vector2i, right: Vector2i) -> bool:
			return Vector2(left.x, left.y).distance_squared_to(center) < Vector2(right.x, right.y).distance_squared_to(center)
		)
		keys.resize(MAX_LIVE_CHUNKS)
		needed.clear()
		for key in keys:
			needed[key] = true
	for key in _live_chunks.keys():
		if not needed.has(key):
			_recycle_chunk(key)
	for key in needed:
		if not _live_chunks.has(key):
			var chunk := _take_chunk()
			_live_chunks[key] = chunk
			_configure_chunk(key)
	PerformanceProbe.end_scope(&"renderer.materialize_chunks", perf_token)


func _take_chunk() -> Node2D:
	var chunk: Node2D
	if _chunk_pool.is_empty():
		chunk = ChunkScript.new()
		chunk.z_index = -1
		add_child(chunk)
	else:
		chunk = _chunk_pool.pop_back()
	chunk.visible = true
	return chunk


func _recycle_chunk(key: Vector2i) -> void:
	var chunk: Node2D = _live_chunks[key]
	_live_chunks.erase(key)
	chunk.visible = false
	_chunk_pool.append(chunk)


func _configure_chunk(key: Vector2i) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"renderer.configure_chunk")
	var chunk: Node2D = _live_chunks[key]
	chunk.configure(_document, _chunk_objects.get(key, PackedInt32Array()), Vector2(key.x, key.y) * CHUNK_SIZE, _selected_ids, _hidden_ids)
	PerformanceProbe.end_scope(&"renderer.configure_chunk", perf_token)


func _refresh_chunks() -> void:
	for key in _live_chunks:
		_configure_chunk(key)


func _visible_world_rect() -> Rect2:
	var viewport_rect := get_viewport_rect()
	var inverse := get_viewport().get_canvas_transform().affine_inverse()
	var a := inverse * viewport_rect.position
	var b := inverse * viewport_rect.end
	return Rect2(a.min(b), (b - a).abs())


func _chunk_key(point: Vector2) -> Vector2i:
	return Vector2i(floori(point.x / CHUNK_SIZE), floori(point.y / CHUNK_SIZE))


func _render_bounds(data: Dictionary) -> Rect2:
	var size_value: Vector2 = data.get("size", Vector2.ZERO)
	var scale_value: Vector2 = data.get("scale", Vector2.ONE)
	var half := size_value * scale_value.abs() * 0.5
	# The axis-aligned diagonal is a cheap conservative bound for rotated objects.
	var radius := half.length()
	var type_id: StringName = StringName(data.get("type_id", ""))
	if Catalog.has_type(type_id) and Catalog.definition(type_id).get("body_kind", "") == "agent":
		radius += 1500.0
	return Rect2(data.get("position", Vector2.ZERO) - Vector2.ONE * radius, Vector2.ONE * radius * 2.0)


func _rect_approximately_equal(left: Rect2, right: Rect2) -> bool:
	return left.position.distance_squared_to(right.position) < 64.0 and left.size.distance_squared_to(right.size) < 64.0


func _disconnect_document() -> void:
	if _document == null:
		return
	if _document.structure_changed.is_connected(_rebuild_layout):
		_document.structure_changed.disconnect(_rebuild_layout)
	if _document.object_changed.is_connected(_on_object_changed):
		_document.object_changed.disconnect(_on_object_changed)
