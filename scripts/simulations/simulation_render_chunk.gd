class_name SimulationRenderChunk
extends Node2D

const CanvasDraw = preload("res://scripts/simulations/simulation_canvas_draw.gd")
const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

var _document: SimulationWorldState
var _indices := PackedInt32Array()
var _chunk_origin := Vector2.ZERO
var _selected_ids: Dictionary = {}
var _hidden_ids: Dictionary = {}
var _water_nodes: Dictionary = {}
var _water_material: ShaderMaterial

func _ready() -> void:
	_water_material = ShaderMaterial.new()
	_water_material.shader = preload("res://scripts/simulations/water.gdshader")

func configure(document: SimulationWorldState, indices: PackedInt32Array, chunk_origin: Vector2, selected_ids: Dictionary, hidden_ids: Dictionary = {}) -> void:
	_document = document
	_indices = indices
	_chunk_origin = chunk_origin
	_selected_ids = selected_ids
	_hidden_ids = hidden_ids
	position = chunk_origin
	queue_redraw()


func _draw() -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"renderer.draw_static_chunk")
	_profiled_draw()
	PerformanceProbe.end_scope(&"renderer.draw_static_chunk", perf_token)


func _profiled_draw() -> void:
	if _document == null:
		return
		
	var current_water := {}
	for index in _indices:
		var data := _document.render_data_at(index)
		var obj_id = str(data.get("id", ""))
		if _hidden_ids.has(obj_id):
			continue
			
		var type_id: StringName = StringName(data.get("type_id", ""))
		if type_id == &"water":
			current_water[obj_id] = true
			_update_water_node(obj_id, data)
			continue
			
		CanvasDraw.draw_object(self, data, _chunk_origin, _selected_ids.has(obj_id))

	var stale := []
	for obj_id in _water_nodes:
		if not current_water.has(obj_id):
			_water_nodes[obj_id].queue_free()
			stale.append(obj_id)
	for obj_id in stale:
		_water_nodes.erase(obj_id)

func _update_water_node(obj_id: String, data: Dictionary) -> void:
	var node: ColorRect
	if _water_nodes.has(obj_id):
		node = _water_nodes[obj_id]
	else:
		node = ColorRect.new()
		node.material = _water_material.duplicate()
		add_child(node)
		_water_nodes[obj_id] = node
		
	var size: Vector2 = data.get("size", Vector2(160, 64))
	node.position = data.get("position", Vector2.ZERO) - _chunk_origin - size * 0.5
	node.size = size
	node.rotation = float(data.get("rotation", 0.0))
	node.pivot_offset = size * 0.5
	node.material.set_shader_parameter("rect_size", size)
