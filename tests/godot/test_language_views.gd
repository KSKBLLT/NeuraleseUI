extends SceneTree

func _initialize() -> void:
	call_deferred("_run")

func _run() -> void:
	var candidates_script = load("res://scripts/language_models/views/token_candidates.gd")
	var embedding_script = load("res://scripts/language_models/views/embedding_plot.gd")
	var attention_script = load("res://scripts/language_models/views/attention_heatmap.gd")
	if candidates_script == null or embedding_script == null or attention_script == null: push_error("Language views not implemented"); quit(1); return
	var candidates = candidates_script.new()
	root.add_child(candidates)
	var scores: Array = []; scores.resize(65536); scores.fill(0.5/65535.0); scores[65535] = 0.5
	candidates.set_distribution(scores,65535,{"65535":"last"})
	if candidates.rows.size()!=5 or candidates.rows[0].token_id!=65535 or absf(candidates.other_mass-(1.0-0.5-4.0*0.5/65535.0))>0.00001:
		push_error("Top N created incorrect rows/mass"); quit(1); return
	candidates.set_visible_count(20)
	if candidates.rows.size()!=20 or candidates.get_child_count()>21: push_error("Unbounded candidate widgets"); quit(1); return
	var plot = embedding_script.new()
	root.add_child(plot)
	plot.set_preview({"points":[{"id":1,"position":0,"piece":"cat","x":0.5,"y":0.5}]})
	plot.select_position(0)
	if plot.selected_position != 0: push_error("PCA selection failed"); quit(1); return
	var heat = attention_script.new()
	root.add_child(heat)
	heat.set_preview({"matrix":[[1.0,0.0],[0.25,0.75]],"tokens":[{"piece":"cat","start":0,"end":3},{"piece":"cat","start":4,"end":7}],"source_text":"cat cat","start":0})
	if heat.display_matrix().size()!=2 or heat.labels()[0]!= "cat": push_error("Attention labels/matrix mismatch"); quit(1); return
	var short_size: Vector2 = heat.content_size()
	var anchored: Vector2 = heat._geometry(2).origin
	heat.size=Vector2(800,800)
	if heat._geometry(2).origin!=anchored: push_error("Heatmap moved when only the frame grew"); quit(1); return
	heat.set_preview({"matrix":[[1.0,0.0,0.0],[0.5,0.5,0.0],[0.3,0.3,0.4]],"tokens":[{"piece":"cat","start":0,"end":3},{"piece":"cat","start":4,"end":7},{"piece":"cat","start":8,"end":11}],"source_text":"cat cat cat","start":0})
	var grown_size: Vector2 = heat.content_size()
	if not (grown_size-short_size).is_equal_approx(Vector2(17,17)): push_error("Heatmap cells must determine node size with Conv2D's fixed step"); quit(1); return
	heat.advance_reveal(0.016,Vector2(800,800))
	if heat.cell_alpha(Vector2i(2,2))<=0 or heat.cell_alpha(Vector2i(2,2))>=1: push_error("New attention cells must fade in"); quit(1); return
	for frame in 100: heat.advance_reveal(0.016,Vector2(800,800))
	if heat.cell_alpha(Vector2i(2,2))<0.99: push_error("Attention reveal did not finish"); quit(1); return
	if heat._cell_at(heat._geometry(3).origin+Vector2(17,17)+Vector2(7,7))!=Vector2i(1,1): push_error("Heatmap hit test diverges from fixed grid"); quit(1); return
	heat.set_preview({"matrix":[[1.0,0.0,0.0],[0.5,0.5,0.0],[0.1,0.1,0.8]],"tokens":[{"piece":"cat","start":0,"end":3},{"piece":"cat","start":4,"end":7},{"piece":"cat","start":8,"end":11}],"source_text":"cat cat cat","start":0})
	if absf(heat.display_matrix()[2][2]-0.8)>0.00001: push_error("Attention cache reused stale rows when only later probabilities changed"); quit(1); return
	var strip = load("res://scripts/language_models/views/token_strip.gd").new()
	root.add_child(strip)
	strip.size=Vector2(220,100)
	strip.set_preview({"tokens":[{"id":16,"piece":"The"},{"id":17,"piece":" cat"}]})
	if strip.pills.size()!=2 or strip.pills[0].get_script()!=load("res://scripts/block_component.gd"):
		push_error("Tokenizer must reuse native node buttons"); quit(1); return
	var adjustment: Vector2 = strip.pills[0].get_instance_shader_parameter("corner_radius_width_add")
	if adjustment!=Vector2(-9,0): push_error("Token radius differs from Train!"); quit(1); return
	strip.show_ids=true
	strip.set_preview({"source_text":"ма cat","tokens":[{"id":142,"piece":"Ð","start":0,"end":1},{"id":122,"piece":"¼","start":0,"end":1},{"id":9539,"piece":"Ð°","start":1,"end":2},{"id":300,"piece":"Ġcat","start":2,"end":6}]})
	if strip.pills.size()!=3 or strip.pills[0].text!="м" or strip.pills[1].text!="а" or strip.pills[2].text!="·cat" or strip.pills[0].get_node("TokenID").text!="142 122":
		push_error("Real ByteLevel token pieces must use readable source spans while preserving every ID"); quit(1); return
	strip.set_preview({"tokens":[{"id":16,"piece":"The"},{"id":17,"piece":" cat"}]})
	strip.select_position(1)
	if strip.pills[1].text!="·cat" or strip.pills[1].get_node("TokenID").text!="17": push_error("Token identity/whitespace lost"); quit(1); return
	for pill in strip.pills:
		if pill.position.y+pill.size.y>strip.custom_minimum_size.y+0.5: push_error("Native token pill overflows row height"); quit(1); return
	var style=load("res://scripts/language_models/language_style.gd")
	style.localized("Run","Пуск","Іске қос")
	strip.set_preview({"tokens":[{"id":50,"piece":"Run"}]})
	style.retranslate(strip)
	if strip.pills[0].text!="Run": push_error("Localization changed token data"); quit(1); return
	var backend=load("res://scripts/language_models/dummy_language_backend.gd").new()
	var ascii: Dictionary=backend.tokenize("watch\n")
	strip.show_ids=false
	strip.set_preview({"tokens":ascii.tokens,"source_text":ascii.text})
	var visible: String=""
	for pill in strip.pills: visible+=pill.text
	if visible!="watch↵" or strip.tokens!=ascii.tokens: push_error("Byte fallback pills must show readable source text without changing tokens"); quit(1); return
	var unicode: Dictionary=backend.tokenize("П🙂")
	strip.set_preview({"tokens":unicode.tokens,"source_text":unicode.text})
	if strip.pills.size()!=2 or strip.pills[0].text!="П" or strip.pills[1].text!="🙂": push_error("UTF-8 bytes must display each source character once"); quit(1); return
	strip.show_ids=true
	var first_ids: String="%d %d" % [unicode.ids[0],unicode.ids[1]]
	if strip.tokens!=unicode.tokens or strip.pills[0].get_node("TokenID").text!=first_ids: push_error("Readable Unicode pills lost their original byte IDs"); quit(1); return
	strip.pills[1].pressed.emit()
	if strip.selected_position!=2: push_error("Grouped Unicode pill selected a display index instead of its original token position"); quit(1); return
	strip.select_position(1)
	if strip.pills[0].get_instance_shader_parameter("outline_color")!=style.ACCENT: push_error("Selecting a continuation byte must select its readable pill"); quit(1); return
	var saved_pill=strip.pills[0]
	var extended: Dictionary=backend.tokenize("П🙂!")
	strip.set_preview({"tokens":extended.tokens,"source_text":extended.text})
	if strip.pills[0]!=saved_pill: push_error("Readable prefix pills were recreated when generation appended text"); quit(1); return
	plot.set_preview({"tokens":unicode.tokens,"source_text":unicode.text,"points":[{"id":unicode.ids[0],"position":0,"piece":"<0xD0>","x":0.5,"y":0.5}]})
	if not plot._get_tooltip(plot._point(plot.preview.points[0])).begins_with("П · #"): push_error("Embedding labels must show readable characters rather than byte codes"); quit(1); return
	var token_text=load("res://scripts/language_models/token_text.gd")
	var technical: Array=[{"id":464,"piece":"<0xD0>"},{"id":999,"piece":"<0xGG>","start":0,"end":1},{"id":998,"piece":"<0x-1>","start":0,"end":1}]
	var unchanged: Array=token_text.groups(technical,"П")
	if unchanged.size()!=3 or unchanged[0].piece!="<0xD0>" or unchanged[1].piece!="<0xGG>" or unchanged[2].piece!="<0x-1>": push_error("Labels without a valid byte/source mapping must remain intact"); quit(1); return
	backend.dispose()
	if not plot.has_method("point_color"): push_error("Embedding points do not encode the third projection component in color"); quit(1); return
	var depth_points: Array=[{"id":1,"position":0,"piece":"low","x":-0.5,"y":0.0,"z":-1.0},{"id":2,"position":1,"piece":"zero","x":0.0,"y":0.5,"z":0.0},{"id":3,"position":2,"piece":"high","x":0.5,"y":0.0,"z":1.0}]
	plot.set_preview({"points":depth_points,"z_range":[-1.0,1.0]})
	var low: Color=plot.point_color(depth_points[0])
	var middle: Color=plot.point_color(depth_points[1])
	var high: Color=plot.point_color(depth_points[2])
	if low==middle or middle==high or low==high: push_error("Different third coordinates must produce different colors"); quit(1); return
	for z in [-1.0,-0.5,0.0,0.5,1.0]:
		var color: Color=plot.point_color({"z":z})
		if color==style.ACCENT or color.b>color.g: push_error("The chosen YlGn depth palette must remain distinct from the node's blue accent"); quit(1); return
	if low.get_luminance()<=high.get_luminance() or middle.g<=middle.r or high.g<=high.b: push_error("YlGn must progress from pale yellow to darker green"); quit(1); return
	if plot.point_color({"z":-20})!=low or plot.point_color({"z":20})!=high: push_error("Depth colors must clamp to the supplied scale"); quit(1); return
	if plot.point_color({})!=style.ACCENT: push_error("Older 2D previews must retain the native accent"); quit(1); return
	var colored_size: Vector2=plot.content_size()
	var before: Vector2=plot._point(depth_points[0])
	plot.select_position(0)
	if plot.point_color(depth_points[0])!=low: push_error("Selection must preserve a point's depth color"); quit(1); return
	if not "PC3: -1.000" in plot._get_tooltip(before): push_error("Embedding tooltip must expose the third coordinate"); quit(1); return
	plot.set_preview({"points":depth_points+[{"id":4,"position":3,"piece":"new","x":0.2,"y":0.2,"z":20.0}],"z_range":[-1.0,1.0]})
	if plot.point_color(depth_points[0])!=low or plot.point_color(depth_points[1])!=middle: push_error("New tokens must not renormalize existing depth colors"); quit(1); return
	plot.set_preview({"points":depth_points,"z_range":[-2.0,2.0]})
	if plot.point_color({"z":-2})!=low or plot.point_color({"z":2})!=high or plot.point_color(depth_points[2])==high: push_error("Depth colors must use the backend's projection range"); quit(1); return
	var flat_points: Array=depth_points.duplicate(true)
	for point in flat_points: point.erase("z")
	plot.set_preview({"points":flat_points})
	if plot.content_size()!=colored_size or colored_size!=Vector2(154,154) or not plot._point(flat_points[0]).is_equal_approx(before): push_error("Embedding plot must stay compact without a green scale strip"); quit(1); return
	var word_tokens: Array=[]
	for i in 9: word_tokens.append({"id":i,"start":i,"end":i+1,"position":i})
	var word_points: Array=[{"id":0,"position":0,"positions":[0,1,2,3],"piece":"мама","x":0.2,"y":0.3,"z":0.1,"vector":[1.0,2.0]}, {"id":5,"position":5,"positions":[5,6,7,8],"piece":"папа","x":0.6,"y":0.3,"z":0.1,"vector":[3.0,4.0]}]
	plot.set_preview({"points_are_words":true,"points":word_points,"tokens":word_tokens,"source_text":"мама папа"})
	if plot._display_points.size()!=2 or plot._display_points[0].x!=0.2 or plot._display_points[0].vector!=[1.0,2.0]:
		push_error("Already pooled real words must not be pooled again as token coordinates"); quit(1); return
	var pair: Vector2 = plot._point(word_points[1])-plot._point(word_points[0])
	if pair.length()<100: push_error("Close word embeddings must use the available plotting area"); quit(1); return
	var relation_points: Array=[{"position":0,"piece":"мама","x":0.01,"y":0.02},{"position":1,"piece":"папа","x":0.03,"y":0.02},{"position":2,"piece":"королева","x":0.04,"y":0.05},{"position":3,"piece":"король","x":0.06,"y":0.05}]
	plot.set_preview({"points_are_words":true,"points":relation_points})
	var first_relation: Vector2=plot._point(relation_points[1])-plot._point(relation_points[0])
	var second_relation: Vector2=plot._point(relation_points[3])-plot._point(relation_points[2])
	if first_relation.length()<30 or not first_relation.is_equal_approx(second_relation): push_error("Spreading embeddings must preserve equal relation vectors with one uniform camera scale"); quit(1); return
	var many: Array=[]
	for i in 100: many.append({"id":i,"piece":" word"})
	strip.set_preview({"tokens":many})
	strip.advance_reveal(0.016,Vector2(220,255))
	var last=strip.pills[-1]
	if last.get_parent().modulate.a>0.01: push_error("Offscreen token revealed too soon"); quit(1); return
	if not strip.has_method("set_scroll_offset"): push_error("Scrolled tokens have no reveal window"); quit(1); return
	strip.set_scroll_offset(Vector2(0,last.position.y-100))
	for frame in 100: strip.advance_reveal(0.016,Vector2(220,255))
	if last.get_parent().modulate.a<0.99: push_error("Scrolled token stays transparent"); quit(1); return
	strip.clear_preview()
	if not strip.pills.is_empty(): push_error("Stale token widgets"); quit(1); return
	strip.free()
	var crowded: Array = []
	for i in 10: crowded.append({"id":i,"position":i,"piece":"word%d" % i,"positions":[i],"x":0.0,"y":0.0,"z":0.0})
	plot.set_preview({"points_are_words":true,"points":crowded})
	var label_boxes: Array[Rect2] = []
	for item in plot._render_items:
		if not item.show_label: push_error("Ten close words should fit readable labels around their true points"); quit(1); return
		var box := Rect2(item.label_pos-Vector2(0,10),plot._cached_text_size(item.text,10))
		for other in label_boxes:
			if box.intersects(other): push_error("Close real word embedding labels overlap"); quit(1); return
		label_boxes.append(box)
		if item.pos!=Vector2(plot.CANVAS_DIM/2,plot.CANVAS_DIM/2): push_error("Avoiding label collisions moved actual embedding coordinates"); quit(1); return
	plot.set_preview({"points_are_words":true,"points":[{"id":0,"position":0,"piece":"ffwefewwefwefwefwwefwefwefewfwefwefwefwewefwefwefwefwefwef","x":0.1,"y":0.1}]})
	if plot._render_items[0].text.length()<=14 or not Rect2(Vector2.ZERO,Vector2(154,154)).encloses(plot._render_items[0].label_bounds):
		push_error("Centered long words must use the full available label width without overflowing"); quit(1); return
	candidates.free(); plot.free(); heat.free()
	print("PASS test_language_views")
	quit(0)
