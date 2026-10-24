extends SceneTree


func _initialize() -> void:
	var baseline_path := _argument_value("--baseline=")
	var candidate_path := _argument_value("--candidate=")
	if baseline_path.is_empty() or candidate_path.is_empty():
		_fail("--baseline=<png> and --candidate=<png> are required", 2)
		return

	var baseline := Image.load_from_file(baseline_path)
	var candidate := Image.load_from_file(candidate_path)
	if baseline == null or baseline.is_empty():
		_fail("failed to load baseline image: %s" % baseline_path)
		return
	if candidate == null or candidate.is_empty():
		_fail("failed to load candidate image: %s" % candidate_path)
		return
	if baseline.get_size() != candidate.get_size():
		_fail("image sizes differ: %s != %s" % [baseline.get_size(), candidate.get_size()])
		return

	var total_abs := 0.0
	var over_threshold := 0
	var channel_threshold := 3.0 / 255.0
	for y in baseline.get_height():
		for x in baseline.get_width():
			var before := baseline.get_pixel(x, y)
			var after := candidate.get_pixel(x, y)
			var dr := absf(before.r - after.r)
			var dg := absf(before.g - after.g)
			var db := absf(before.b - after.b)
			var da := absf(before.a - after.a)
			total_abs += dr + dg + db + da
			if maxf(maxf(dr, dg), maxf(db, da)) > channel_threshold:
				over_threshold += 1
	var pixel_count := baseline.get_width() * baseline.get_height()
	var mean_abs := total_abs / float(pixel_count * 4)
	var changed_ratio := float(over_threshold) / float(pixel_count)
	var metrics := "mean_abs=%.8f changed_ratio=%.8f" % [mean_abs, changed_ratio]
	if mean_abs > 1.0 / 255.0 or changed_ratio > 0.005:
		_fail("blur render comparison failed: %s" % metrics)
		return
	print("PASS compare_blur_renders: %s" % metrics)
	quit(0)


func _argument_value(prefix: String) -> String:
	for argument in OS.get_cmdline_user_args():
		if argument.begins_with(prefix):
			return argument.trim_prefix(prefix)
	return ""


func _fail(message: String, exit_code := 1) -> void:
	push_error(message)
	quit(exit_code)
