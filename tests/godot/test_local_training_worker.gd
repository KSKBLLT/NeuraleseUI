extends Node

const WorkerScript := preload("res://scripts/local_training_worker.gd")

var packets: Array[Dictionary] = []
var prepared_handles: Array[Dictionary] = []


func _ready() -> void:
	var worker = WorkerScript.new()
	worker.packet_received.connect(func(packet: Dictionary): packets.append(packet))
	worker.prepared.connect(func(handle: Dictionary): prepared_handles.append(handle))

	var first := {"request_id": 1, "event": "PONG", "data": {"ready": true}}
	var second := {
		"request_id": 2,
		"event": "PREPARED",
		"data": {"prepared_id": "p-1", "graph_generation": 9},
	}
	var bytes: PackedByteArray = WorkerScript.encode_frame(first)
	bytes.append_array(WorkerScript.encode_frame(second))
	worker._feed_bytes(bytes.slice(0, 3))
	assert(packets.is_empty())
	worker._feed_bytes(bytes.slice(3, 11))
	assert(packets.is_empty())
	worker._feed_bytes(bytes.slice(11))
	# Frames carry JSON, and Godot's JSON has no integer type: every number
	# arrives as a float. Compare with what the wire can actually deliver.
	var wire_first: Dictionary = JSON.parse_string(JSON.stringify(first))
	var wire_second: Dictionary = JSON.parse_string(JSON.stringify(second))
	assert(packets == [wire_first, wire_second])
	assert(prepared_handles == [wire_second["data"]])

	var oversized := PackedByteArray([0, 128, 0, 1])
	worker._feed_bytes(oversized)
	assert(worker.state == "failed")

	print("PASS test_local_training_worker")
	get_tree().quit()
