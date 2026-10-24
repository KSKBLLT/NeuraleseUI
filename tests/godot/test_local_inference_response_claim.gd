extends SceneTree
func _initialize() -> void:
	call_deferred("_run")
func _run() -> void:
	var manager=root.get_node("nn")
	manager.set_process(false)
	var owner=Node.new();owner.name="ResponseClaimTest";root.add_child(owner)
	var channel=manager.LocalInferChannel.new()
	channel.job_dir=ProjectSettings.globalize_path("user://response-claim-test")
	DirAccess.make_dir_recursive_absolute(channel.job_dir)
	channel.response_path=channel.job_dir.path_join("response.json")
	channel.stop_path=channel.job_dir.path_join("stop")
	channel.pid=OS.create_process("cmd.exe",["/c","ping -n 30 127.0.0.1 >nul"]) if OS.has_feature("windows") else OS.create_process("/bin/sleep",["30"])
	channel.request_in_flight=true
	channel.last_request_msec=Time.get_ticks_msec()
	var replies: Array=[]
	channel.packet_callback=func(packet):replies.append(packet)
	manager.inference_sockets[owner]=channel
	manager._write_json(channel.response_path,{"phase":"ready","index":0})
	manager._poll_local_inference_channels()
	while channel.reader!=null and channel.reader.is_alive(): await process_frame
	# Publish after the read, before its result is consumed on the UI thread.
	manager._write_json(channel.response_path,{"phase":"inference","index":1,"response":{"request_id":9,"ok":true}})
	for frame in 12:
		manager._poll_local_inference_channels()
		await process_frame
	manager._close_local_infer_channel(owner,channel,true,false)
	if replies.size()!=1 or replies[0].request_id!=9:
		push_error("A ready response consumed a newer inference result");quit(1);return
	print("PASS test_local_inference_response_claim");quit(0)
