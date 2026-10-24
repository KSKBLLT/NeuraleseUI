class_name SimulationDatasetDashboard
extends PanelContainer

const RandomizationProfile = preload("res://scripts/simulations/simulation_randomization_profile.gd")

signal stop_requested

var _metrics: Dictionary = {}
var _stop_button: Button = null
var _variations_section: Control = null
var _variations_container: VBoxContainer = null
var _active_variation_labels: Array[String] = []
var _progress_bar: ProgressBar = null
var _value_labels: Dictionary = {}


func _ready() -> void:
	_build_ui()


func reset(
	dataset_name: String,
	total: int,
	input_count: int,
	output_count: int,
	randomization: Dictionary = {}
) -> void:
	_metrics = {
		"completed_samples": 0,
		"total_samples": total,
		"completed_episodes": 0,
		"success_rate": 0.0,
		"collisions": 0,
		"stuck": 0,
		"timeouts": 0,
		"discarded_rows": 0,
	}
	if is_instance_valid(_stop_button):
		_stop_button.disabled = false
		_stop_button.text = "Stop and save partial dataset"
	_sync_variations(randomization)
	update_metrics(_metrics, dataset_name, input_count, output_count)


func update_metrics(
	metrics: Dictionary,
	dataset_name: String,
	input_count: int,
	output_count: int
) -> void:
	_metrics = metrics.duplicate(true)
	_set_text("ProgressValue", "%s / %s samples" % [_format_int(int(metrics.get("completed_samples", 0))), _format_int(int(metrics.get("total_samples", 0)))])
	if is_instance_valid(_progress_bar):
		_progress_bar.max_value = maxf(1.0, float(metrics.get("total_samples", 0)))
		_progress_bar.value = float(metrics.get("completed_samples", 0))
	_set_text("SuccessValue", "%d%%" % roundi(float(metrics.get("success_rate", 0.0)) * 100.0))
	_set_text("CollisionsValue", str(int(metrics.get("collisions", 0))))
	_set_text("EpisodesValue", str(int(metrics.get("completed_episodes", 0))))
	_set_text("DiscardedValue", str(int(metrics.get("discarded_rows", 0))))
	_set_text("StuckValue", str(int(metrics.get("stuck", 0))))
	_set_text("TimeoutsValue", str(int(metrics.get("timeouts", 0))))
	_set_text("DatasetNameValue", dataset_name)
	_set_text("InputsValue", str(input_count))
	_set_text("OutputsValue", str(output_count))
	_set_text("QualityValue", _quality_label(metrics))
	var thread_count := maxi(1, int(metrics.get("thread_count", 1)))
	_set_text("RunningLabel", "Running %d isolated environment%s" % [thread_count, "" if thread_count == 1 else "s"])


func set_complete() -> void:
	if is_instance_valid(_stop_button):
		_stop_button.disabled = false
		_stop_button.text = "Back to editor"


func set_stopping() -> void:
	if is_instance_valid(_stop_button):
		_stop_button.disabled = true
		_stop_button.text = "Stopping generation..."


func displayed_metrics() -> Dictionary:
	return _metrics.duplicate(true)


func active_variations() -> Array[String]:
	return _active_variation_labels.duplicate()


func request_stop() -> void:
	stop_requested.emit()


func _build_ui() -> void:
	add_theme_stylebox_override("panel", _panel_style())
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 16)
	margin.add_theme_constant_override("margin_top", 14)
	margin.add_theme_constant_override("margin_right", 16)
	margin.add_theme_constant_override("margin_bottom", 14)
	add_child(margin)
	var scroll := ScrollContainer.new()
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	margin.add_child(scroll)
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	content.add_theme_constant_override("separation", 10)
	scroll.add_child(content)

	content.add_child(_title_row())
	content.add_child(_separator())
	content.add_child(_label("ProgressValue", "0 / 1,000 samples", 17, Color("eff1f4")))
	var progress := ProgressBar.new()
	progress.name = "Progress"
	progress.custom_minimum_size.y = 8.0
	progress.show_percentage = false
	progress.add_theme_stylebox_override("background", _progress_style(Color("555960")))
	progress.add_theme_stylebox_override("fill", _progress_style(Color("72dfa0")))
	content.add_child(progress)
	_progress_bar = progress
	content.add_child(_label("RunningLabel", "Running 1 environment", 11, Color("b1b5bd")))
	content.add_child(_separator())
	content.add_child(_metrics_grid())
	content.add_child(_detail_row("Stuck", "StuckValue", "0"))
	content.add_child(_detail_row("Timeouts", "TimeoutsValue", "0"))
	_variations_section = _section("Environment variations")
	content.add_child(_variations_section)
	_variations_container = VBoxContainer.new()
	_variations_container.add_theme_constant_override("separation", 2)
	content.add_child(_variations_container)
	_sync_variations({})
	content.add_child(_section("Dataset details"))
	content.add_child(_detail_row("Dataset name", "DatasetNameValue", "simulation_dataset"))
	content.add_child(_detail_row("Inputs", "InputsValue", "9"))
	content.add_child(_detail_row("Outputs", "OutputsValue", "3"))
	content.add_child(_detail_row("Target quality", "QualityValue", "Collecting..."))
	content.add_child(_detail_row("Format", "FormatValue", "Trajectories"))
	var spacer := Control.new()
	spacer.custom_minimum_size.y = 4.0
	content.add_child(spacer)
	_stop_button = Button.new()
	_stop_button.name = "StopAndSave"
	_stop_button.custom_minimum_size.y = 44.0
	_stop_button.text = "Stop and save partial dataset"
	_stop_button.focus_mode = Control.FOCUS_NONE
	_stop_button.add_theme_color_override("font_color", Color("f0795d"))
	_stop_button.add_theme_stylebox_override("normal", _button_style(Color(0.07, 0.045, 0.04, 0.9), Color("e66b50")))
	_stop_button.add_theme_stylebox_override("hover", _button_style(Color(0.14, 0.065, 0.05, 0.98), Color("f57d60")))
	_stop_button.pressed.connect(request_stop)
	content.add_child(_stop_button)


func _title_row() -> Control:
	var row := HBoxContainer.new()
	var title := Label.new()
	title.text = "Dataset generation"
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 15)
	row.add_child(title)
	var status := Label.new()
	status.name = "StatusIndicator"
	status.text = char(0x25CF)
	status.add_theme_color_override("font_color", Color("72e7a2"))
	status.add_theme_font_size_override("font_size", 18)
	row.add_child(status)
	return row


func _metrics_grid() -> Control:
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	for item in [
		["Episodes", "EpisodesValue", "0"],
		["Success", "SuccessValue", "0%"],
		["Collisions", "CollisionsValue", "0"],
		["Discarded", "DiscardedValue", "0"],
	]:
		var box := VBoxContainer.new()
		box.add_theme_constant_override("separation", 2)
		box.add_child(_label("", item[0], 9, Color("9da1a9")))
		box.add_child(_label(item[1], item[2], 17, Color("e8eaed")))
		grid.add_child(box)
	return grid


func _variation_row(text: String) -> Control:
	var row := HBoxContainer.new()
	row.custom_minimum_size.y = 28.0
	var label := Label.new()
	label.text = text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 10)
	row.add_child(label)
	var dot := Label.new()
	dot.text = "o"
	dot.add_theme_color_override("font_color", Color("72e7a2"))
	row.add_child(dot)
	var active := Label.new()
	active.text = "Active"
	active.add_theme_color_override("font_color", Color("b8bbc2"))
	active.add_theme_font_size_override("font_size", 10)
	row.add_child(active)
	return row


func _sync_variations(randomization: Dictionary) -> void:
	_active_variation_labels = RandomizationProfile.active_labels(randomization)
	if not is_instance_valid(_variations_container):
		return
	for child in _variations_container.get_children():
		child.queue_free()
	for label in _active_variation_labels:
		_variations_container.add_child(_variation_row(label))
	var has_variations := not _active_variation_labels.is_empty()
	_variations_container.visible = has_variations
	if is_instance_valid(_variations_section):
		_variations_section.visible = has_variations


func _detail_row(label_text: String, value_name: String, value_text: String) -> Control:
	var row := HBoxContainer.new()
	var label := Label.new()
	label.text = label_text
	label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	label.add_theme_font_size_override("font_size", 10)
	row.add_child(label)
	row.add_child(_label(value_name, value_text, 10, Color("d9dce1")))
	return row


func _section(text: String) -> Label:
	var label := _label("", text, 11, Color("dfe1e5"))
	label.custom_minimum_size.y = 25.0
	label.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	return label


func _label(name_value: String, text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	if not name_value.is_empty():
		label.name = name_value
		_value_labels[name_value] = label
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _set_text(node_name: String, text: String) -> void:
	var label: Label = _value_labels.get(node_name)
	if is_instance_valid(label):
		label.text = text


func _format_int(value: int) -> String:
	var raw := str(value)
	var result := ""
	for index in raw.length():
		if index > 0 and (raw.length() - index) % 3 == 0:
			result += ","
		result += raw[index]
	return result


func _quality_label(metrics: Dictionary) -> String:
	var collapsed_value: Variant = metrics.get("collapsed_outputs", [])
	if collapsed_value is Array and not collapsed_value.is_empty():
		var labels: Array[String] = []
		for label_value in collapsed_value:
			labels.append(str(label_value))
		return "Nearly constant: %s" % ", ".join(labels)
	if str(metrics.get("quality_status", "")) == "good":
		return "Good spread"
	return "Collecting..."


func _separator() -> HSeparator:
	return HSeparator.new()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.035, 0.038, 0.043, 0.99)
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = Color(0.25, 0.27, 0.3, 0.95)
	return style


func _progress_style(color: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.corner_radius_top_left = 3
	style.corner_radius_top_right = 3
	style.corner_radius_bottom_left = 3
	style.corner_radius_bottom_right = 3
	return style


func _button_style(background: Color, border: Color) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = background
	style.border_width_left = 1
	style.border_width_top = 1
	style.border_width_right = 1
	style.border_width_bottom = 1
	style.border_color = border
	style.corner_radius_top_left = 4
	style.corner_radius_top_right = 4
	style.corner_radius_bottom_left = 4
	style.corner_radius_bottom_right = 4
	return style
