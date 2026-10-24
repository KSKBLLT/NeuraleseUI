class_name SimulationPaletteEntry
extends Button

const PerformanceProbe = preload("res://scripts/simulations/simulation_performance_probe.gd")

var _definition: Dictionary = {}
## Pixel design: a tile with a large icon above the name instead of a row.
var tile := false


func configure(definition: Dictionary) -> void:
	_definition = definition.duplicate(true)
	# The icon ends at x≈22. Two spaces leave a small visual gap without the
	# large empty column created by the old five-space prefix.
	text = str(_definition.get("label", "Object")) if tile else "  %s" % str(_definition.get("label", "Object"))
	queue_redraw()


func _get_drag_data(_at_position: Vector2) -> Variant:
	var type_id := StringName(get_meta("type_id", &""))
	if type_id.is_empty():
		return null
	var preview := Label.new()
	preview.text = "  %s  " % str(_definition.get("label", "Object"))
	preview.modulate = Color(1.0, 1.0, 1.0, 0.9)
	preview.add_theme_font_size_override("font_size", 14)
	set_drag_preview(preview)
	return {"simulation_type_id": str(type_id)}


func _draw() -> void:
	var perf_token: int = PerformanceProbe.begin_scope(&"ui.palette_entry_draw")
	_profiled_draw()
	PerformanceProbe.end_scope(&"ui.palette_entry_draw", perf_token)


func _profiled_draw() -> void:
	if _definition.is_empty():
		return
	var color: Color = _definition.get("color", Color.WHITE)
	var center := Vector2(15.0, size.y * 0.5)
	if tile:
		# Icon above the name, drawn at 2.4x around the tile's upper centre.
		draw_set_transform(Vector2(size.x * 0.5, 34.0), 0.0, Vector2.ONE * 2.4)
		center = Vector2.ZERO
		color = color.darkened(0.25)
	var shape_kind := str(_definition.get("shape_kind", "rectangle"))
	match shape_kind:
		"circle":
			draw_circle(center, 6.0, Color(color, 0.13))
			draw_arc(center, 6.0, 0.0, TAU, 18, color.lightened(0.22), 1.25)
		"slope":
			var points := PackedVector2Array([
				center + Vector2(-7.0, 6.0),
				center + Vector2(7.0, 6.0),
				center + Vector2(7.0, -6.0),
			])
			draw_colored_polygon(points, Color(color, 0.13))
			draw_polyline(points, color.lightened(0.22), 1.25)
		_:
			var icon_rect := Rect2(center - Vector2(7.0, 5.0), Vector2(14.0, 10.0))
			draw_rect(icon_rect, Color(color, 0.12))
			draw_rect(icon_rect, color.lightened(0.22), false, 1.25)
