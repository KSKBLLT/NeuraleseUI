class_name SimulationRuntime
extends Node

const Compiler = preload("res://scripts/simulations/simulation_compiler.gd")
const Kernel = preload("res://scripts/simulations/simulation_kernel.gd")
const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

signal runtime_state_changed(state: StringName)
signal snapshot_updated(snapshot: Dictionary)
signal runtime_event(event: Dictionary)

var _document: SimulationWorldState
var _renderer: SimulationWorldRenderer
var _kernel: SimulationKernel
var _state: StringName = &"stopped"
var _kernel_mutex := Mutex.new()


func _ready() -> void:
	set_physics_process(false)


func configure(document: SimulationWorldState, renderer: SimulationWorldRenderer) -> void:
	if _document != null:
		_document.object_changed.disconnect(_on_document_object_changed)
		_document.structure_changed.disconnect(_on_document_structure_changed)
	_document = document
	if _document != null:
		_document.object_changed.connect(_on_document_object_changed)
		_document.structure_changed.connect(_on_document_structure_changed)
	_renderer = renderer


func current_state() -> StringName:
	return _state


func kernel() -> SimulationKernel:
	return _kernel


func play() -> void:
	if _document == null:
		return
	if _state == &"paused" and _kernel != null:
		_kernel.set_active(true)
		_set_state(&"running")
		set_physics_process(true)
		return
	if _state == &"running":
		return
	_kernel_mutex.lock()
	_kernel = Kernel.new()
	var blueprint := Compiler.compile(_document.thread_snapshot())
	if not _kernel.create(blueprint, true):
		_kernel = null
		_kernel_mutex.unlock()
		return
	set_physics_process(true)
	_set_state(&"running")
	_kernel_mutex.unlock()


func pause() -> void:
	if _state != &"running" or _kernel == null:
		return
	_kernel.set_active(false)
	set_physics_process(false)
	_set_state(&"paused")


func stop() -> void:
	set_physics_process(false)
	_kernel_mutex.lock()
	if _kernel != null:
		_kernel.destroy()
	_kernel = null
	_kernel_mutex.unlock()
	if is_instance_valid(_renderer):
		_renderer.clear_runtime_snapshot()
	_set_state(&"stopped")


func commit_live_edit(_object: Node) -> bool:
	# Runtime worlds are immutable compiled sessions. Edits remain in the document
	# and are picked up on the next Play, avoiding partial RID rebuilds mid-step.
	return false


func _physics_process(delta: float) -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"runtime.physics_total")
	_profiled_physics_process(delta)
	PerformanceProbe.end_scope(&"runtime.physics_total", perf_token)


func _profiled_physics_process(delta: float) -> void:
	if _state != &"running":
		return

	_kernel_mutex.lock()
	if _kernel == null:
		_kernel_mutex.unlock()
		return

	var tick_token: int = PerformanceProbe.begin_scope(&"runtime.kernel_tick")
	_kernel.tick(delta)
	PerformanceProbe.end_scope(&"runtime.kernel_tick", tick_token)
	var snapshot_token: int = PerformanceProbe.begin_scope(&"runtime.snapshot")
	var snapshot: Dictionary = _kernel.snapshot()
	PerformanceProbe.end_scope(&"runtime.snapshot", snapshot_token)

	var events := _kernel.drain_events()
	_kernel_mutex.unlock()

	if is_instance_valid(_renderer):
		_renderer.call_deferred("set_runtime_snapshot", snapshot)
	var signals_token: int = PerformanceProbe.begin_scope(&"runtime.signals_and_events")
	snapshot_updated.emit(snapshot)
	for event in events:
		runtime_event.emit(event)
	PerformanceProbe.end_scope(&"runtime.signals_and_events", signals_token)


func _set_state(next_state: StringName) -> void:
	if _state == next_state:
		return
	_state = next_state
	runtime_state_changed.emit(_state)


func _on_document_object_changed(object_id: String) -> void:
	if _state == &"stopped" or _kernel == null:
		return
	var object_data := _document.object_data(object_id)
	if not object_data.is_empty():
		_kernel.live_update_object(object_data)


func _on_document_structure_changed() -> void:
	if _state == &"stopped":
		return

	_kernel_mutex.lock()
	if _kernel == null:
		_kernel_mutex.unlock()
		return

	var old_states = _kernel.export_dynamic_states()
	var elapsed = _kernel._elapsed
	var active_pairs = _kernel._active_pairs.duplicate()
	var hidden_ids = _kernel._hidden_ids.duplicate()

	_kernel.destroy()
	var blueprint := Compiler.compile(_document.thread_snapshot())
	if not _kernel.create(blueprint, true):
		_kernel = null
		_set_state(&"stopped")
		_kernel_mutex.unlock()
		return

	_kernel._elapsed = elapsed
	_kernel._active_pairs = active_pairs
	_kernel._hidden_ids = hidden_ids

	_kernel.import_dynamic_states(old_states)
	if _state == &"paused":
		_kernel.set_active(false)

	_kernel_mutex.unlock()
