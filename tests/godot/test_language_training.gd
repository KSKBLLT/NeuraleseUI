extends Node
signal completed
@export var quit_when_done := true
const Demo=preload("res://scripts/language_models/language_demo.gd")
var max_frame_usec := 0
var previous_frame_usec := 0
var frames := 0
func _process(_delta: float) -> void:
	var now := Time.get_ticks_usec()
	if previous_frame_usec>0: max_frame_usec=maxi(max_frame_usec,now-previous_frame_usec)
	previous_frame_usec=now
	frames+=1

func _ready() -> void:
	for frame in 12: await get_tree().process_frame
	await graphs.delete_all()
	graphs.loading=true
	var nodes=Demo.build(graphs)
	var source=nodes.text_input
	source.controller.set_process(false)
	source.controller.stop()
	var dataset=graphs.get_graph(&"dataset")
	var begin=graphs.get_graph(&"train_begin")
	var runner=graphs.get_graph(&"run_model")
	var head=graphs.get_graph(&"train_input")
	var meta=glob._with_builtin_datasets({}).language_stories
	glob._load.clear()
	dataset.update_config({"name":"language_stories","meta":meta})
	wire(dataset,"netname",begin,"netname");wire(begin,"input_out",runner,"model_in");wire(runner,"model_out",head,"pred_in")
	graphs.loading=false
	for frame in 5: await get_tree().process_frame
	source.update_config({"text":"Copy exactly: red cup"})
	# Ordinary inference channel lifecycle, actual generation and responsive frames.
	var replies: Array=[]
	var backend=language_models.backend
	backend.response_ready.connect(func(packet):replies.append(packet))
	var request=language_models.request(&"open_session",{"graph":graphs.LanguageAdapter.collect(source)},"",1)
	var deadline=Time.get_ticks_msec()+30000
	while replies.is_empty() and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	if replies.is_empty() or not replies[-1].ok: fail("Standard inference channel failed"); return
	if not nn.inference_sockets.has(language_models): fail("LLM bypassed RunManager inference registry"); return
	var channel=nn.inference_sockets[language_models]
	if not channel is nn.LocalInferChannel: fail("LLM did not use common local inference channel"); return
	language_models.close_session(replies[-1].result.session_id)
	begin.get_node("YY").set_line("3")
	var states: Array=[]
	var snapshots: Array=[]
	source.controller.snapshot_ready.connect(func(snapshot):snapshots.append(snapshot))
	begin.train_start()
	deadline=Time.get_ticks_msec()+30000
	while begin.training and Time.get_ticks_msec()<deadline:
		var remaining := str(begin.get_node("YY").text)
		if states.is_empty() or states[-1]!=remaining: states.append(remaining)
		await get_tree().process_frame
	if begin.training: fail("Standard training did not finish"); return
	if not states.has("2") or not states.has("1"): fail("Epoch counter did not decrement: "+str(states)); return
	if runner.language_preparation.is_empty() or snapshots.is_empty(): fail("Common training lost model results/tensors"); return
	if is_instance_valid(head.get_node_or_null("ColorRect2/EpochProgress")): fail("Artificial activity bar remains"); return
	if not nn.local_training_jobs.is_empty() or not nn._resident_training_jobs.is_empty(): fail("Completed worker job remains registered"); return
	if frames<20 or max_frame_usec>500000: fail("UI stalled during runtime work: "+str(max_frame_usec)); return
	# Stop/restart uses ordinary RunManager stop path.
	while begin.delaying: await get_tree().process_frame
	begin.get_node("YY").set_line("99")
	var before := snapshots.size()
	begin.train_start()
	deadline=Time.get_ticks_msec()+15000
	while snapshots.size()==before and begin.training and Time.get_ticks_msec()<deadline: await get_tree().process_frame
	if not begin.training or snapshots.size()==before: fail("Restart did not actually start runtime training"); return
	source.update_config({"text":"Copy exactly: blue moon"})
	deadline=Time.get_ticks_msec()+15000
	while (source.controller.last_snapshot.is_empty() or source.controller.last_snapshot.nodes[str(nodes.embedding.graph_id)].preview.source_text!="Copy exactly: blue moon") and begin.training and Time.get_ticks_msec()<deadline:
		await get_tree().process_frame
	if not begin.training: fail("Editing only text cancelled the model"); return
	if source.controller.last_snapshot.is_empty(): fail("Runtime did not receive changed input text"); return
	begin.train_stop(true)
	deadline=Time.get_ticks_msec()+10000
	while (not nn.local_training_jobs.is_empty() or not nn._resident_training_jobs.is_empty()) and Time.get_ticks_msec()<deadline:
		await get_tree().process_frame
	if begin.training or head.training: fail("Ordinary stop left UI busy"); return
	print("PASS test_language_training ",JSON.stringify({"max_frame_ms":max_frame_usec/1000.0,"frames":frames,"epoch_counter":states,"snapshots":snapshots.size()}))
	nn.close_all(true)
	completed.emit()
	if quit_when_done: get_tree().quit(0)
func wire(from: Graph, output: String, to: Graph, input: String) -> void:
	for port in from.outputs:
		if port.server_name!=StringName(output): continue
		for target in to._inputs:
			if target.server_name==StringName(input): port.connect_to(target); return
func fail(message: String) -> void:
	push_error(message);nn.close_all(true);get_tree().quit(1)
