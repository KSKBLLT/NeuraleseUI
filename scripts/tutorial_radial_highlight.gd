extends TextureRect
class_name TutorialRadialHighlight

var center_opacity: float = 0.5
var padding: float = 24.0
var fade_in: float = 0.16
var fade_out: float = 0.18
var _fade_tween: Tween = null


func configure(style: Dictionary) -> void:
	center_opacity = clampf(float(style.get("center_opacity", 0.5)), 0.0, 1.0)
	padding = maxf(0.0, float(style.get("padding", 24.0)))
	fade_in = maxf(0.0, float(style.get("fade_in", 0.16)))
	fade_out = maxf(0.0, float(style.get("fade_out", 0.18)))
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED

	var gradient := Gradient.new()
	gradient.offsets = PackedFloat32Array([0.0, 1.0])
	gradient.colors = PackedColorArray([
		Color(1.0, 1.0, 1.0, center_opacity * 0.5),
		Color(1.0, 1.0, 1.0, 0.0),
	])
	var radial_texture := GradientTexture2D.new()
	radial_texture.width = 256
	radial_texture.height = 256
	radial_texture.fill = GradientTexture2D.FILL_RADIAL
	radial_texture.fill_from = Vector2(0.5, 0.5)
	radial_texture.fill_to = Vector2(1.0, 0.5)
	radial_texture.gradient = gradient
	texture = radial_texture

	# ADD is a light pass: white only increases the existing pixels' brightness
	# and does not tint the target with a separate colour.
	var additive := CanvasItemMaterial.new()
	additive.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	material = additive
	modulate.a = 0.0


func appear() -> void:
	if _fade_tween != null:
		_fade_tween.kill()
		_fade_tween = null
	visible = true
	if fade_in <= 0.0:
		modulate.a = 1.0
		return
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 1.0, fade_in).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_OUT)


func disappear() -> void:
	if _fade_tween != null:
		_fade_tween.kill()
		_fade_tween = null
	if fade_out <= 0.0:
		queue_free()
		return
	_fade_tween = create_tween()
	_fade_tween.tween_property(self, "modulate:a", 0.0, fade_out).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN)
	_fade_tween.tween_callback(queue_free)


func place_over(target_rect: Rect2, canvas_transform: Transform2D) -> void:
	var diameter := maxf(target_rect.size.x, target_rect.size.y) + padding * 2.0
	size = Vector2(diameter, diameter)
	var viewport_center := target_rect.get_center()
	var local_center := canvas_transform.affine_inverse() * viewport_center
	position = local_center - size * 0.5
