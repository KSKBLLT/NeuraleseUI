extends Node

class RecordingBackend extends "res://scripts/language_models/dummy_language_backend.gd":
	var previews: Array = []
	var steps := 0
	var delayed: Dictionary = {}
	var delay_steps := false
	func submit(request: Dictionary) -> void:
		if request.method == "preview_node": previews.append(request.duplicate(true))
		if request.method == "run_step": steps += 1
		if request.method == "run_step" and delay_steps:
			delayed = request.duplicate(true)
			return
		super.submit(request)

func settle() -> void:
	for frame in 16: await get_tree().process_frame

func _ready() -> void:
	for frame in 12: await get_tree().process_frame
	var backend := RecordingBackend.new()
	language_models.set_backend(backend)
	var source = graphs.get_graph(&"text_input")
	source.controller.set_process(false)
	source.update_config({"text":"The cat"})
	source.controller._automatic_remaining = -1
	var previous = source
	var chain: Array = [source]
	for kind in [&"tokenizer", &"embedding", &"attention_head", &"layer", &"softmax", &"token_labels", &"autoregression"]:
		var node = graphs.get_graph(kind)
		if kind == &"layer": node.update_config({"neuron_count":8192})
		if not output(previous).connect_to(input(node)): fail("Valid language connection rejected: " + kind); return
		await settle()
		if backend.previews.size() != chain.size() or backend.steps != 0:
			fail("A newly accepted language edge needs exactly one non-generating target preview: " + kind + str([backend.previews.size(),chain.size(),backend.steps])); return
		if backend.previews[-1].params.target_id != str(node.graph_id): fail("Preview refreshed the wrong endpoint"); return
		if not source.controller.last_snapshot.get("nodes", {}).has(str(node.graph_id)) or not source.controller.generated_ids.is_empty(): fail("Partial chain did not populate without generation"); return
		if node.has_method("apply_language_trace") and node.trace.is_empty(): fail("Receiving node did not display its trace"); return
		chain.append(node)
		previous = node
	var count := backend.previews.size()
	var saved: Dictionary = chain[2].trace.duplicate(true)
	chain[2].position += Vector2(30, 70)
	chain[2].select(); chain[2].unselect()
	glob.cam.zoom *= 1.05
	var unrelated = graphs.get_graph(&"layer")
	unrelated.update_config({"neuron_count":17})
	chain[4].update_config({"neuron_count":8191})
	source.controller._process(1.0)
	await settle()
	if backend.previews.size() != count or chain[2].trace != saved:
		fail("Ordinary graph edits refreshed language content"); return
	# An existing edge and an incompatible edge are not new accepted connections.
	output(chain[1]).connect_to(input(chain[2]))
	output(chain[2]).connect_to(input(chain[5]))
	await settle()
	if backend.previews.size() != count: fail("Rejected/duplicate edge generated a preview"); return
	chain[4].update_config({"neuron_count":8192})
	output(chain[2]).disconnect_from(input(chain[3]), false, true)
	await settle()
	if backend.previews.size() != count or not chain[3].trace.is_empty() or not chain[6].trace.is_empty():
		fail("Disconnect must invalidate downstream traces without previewing"); return
	# Redo/recreate uses the same accepted-edge signal, including offscreen sources.
	source.process_mode = Node.PROCESS_MODE_DISABLED
	if not output(chain[2]).connect_to(input(chain[3])): fail("Recreated edge rejected"); return
	await settle()
	if backend.previews.size() != count + 1 or chain[3].trace.is_empty(): fail("Offscreen accepted edge did not refresh its target"); return
	count = backend.previews.size()
	var extra = graphs.get_graph(&"attention_head")
	graphs.loading = true
	output(chain[2]).connect_to(input(extra))
	graphs.loading = false
	await settle()
	if backend.previews.size() != count: fail("Batch loading ran intermediate inference"); return
	# Disconnecting a side branch while Step is pending must release the main
	# generation control, even though Autoregression is not downstream of it.
	backend.delay_steps = true
	chain[-1].request_step()
	await settle()
	if backend.delayed.is_empty() or source.controller.state != &"running": fail("The delayed real controller step did not start"); return
	output(chain[2]).disconnect_from(input(extra), false, true)
	await settle()
	if source.controller.state != &"idle" or chain[-1].btn_step.is_blocking:
		fail("Disconnecting a side branch left Step blocked"); return
	backend.delay_steps = false
	# A later topology change must reject a previously pending reply.
	source.process_mode = Node.PROCESS_MODE_INHERIT
	var stale = backend.previews[-1]
	source.controller._pending = stale.request_id
	source.controller._phase = "preview_node"
	source.controller.graph_revision = stale.graph_revision + 1
	var before: Dictionary = chain[3].trace.duplicate(true)
	source.controller._response({"request_id":stale.request_id,"graph_revision":stale.graph_revision,"session_id":source.controller.session_id,"ok":true,"result":{"nodes":{str(chain[3].graph_id):{"preview":{"matrix":[[999]]}}}}})
	if chain[3].trace != before: fail("Stale connection response changed the new graph"); return
	print("PASS test_language_connection_refresh")
	get_tree().quit(0)

func output(node: Node) -> Connection:
	for port in node.outputs:
		if not port.config_conn: return port
	return null

func fail(message: String) -> void:
	push_error(message)
	get_tree().quit(1)

func input(node: Node) -> Connection:
	for port in node._inputs:
		if not port.config_conn: return port
	return null
