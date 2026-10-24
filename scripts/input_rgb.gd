extends "res://scripts/input_graph.gd"
## Input RGB: the Input2D canvas in colour. Two buttons in the header open a
## picture and clear the canvas; under the canvas are the brush colours, black
## being the eraser. Everything else (size from the dataset, pictures dropped
## on the canvas, what goes to the model) is Input2D's.

const COLOURS: Array[Color] = [Color.BLACK, Color.WHITE, Color("e8453c"), Color("f6c445"), Color("4caf50"), Color("3f7fe0")]
## The chosen colour is ringed in the node's title colour.
const CHOSEN := Color(1, 0.986667, 0.6)
const ICONS := {"open": "res://game_assets/icons/upload.png", "clear": "res://game_assets/icons/none.png"}
## The header buttons stand as far from the frame's top as from its right edge.
const HEADER := {"open": Vector2(2, -30), "clear": Vector2(23, -30)}
const TIPS := {
	"open": {"en": "Open a picture", "ru": "Открыть картинку", "kz": "Суретті ашу"},
	"clear": {"en": "Clear", "ru": "Очистить", "kz": "Тазарту"},
}
## A round button, 38 wide before the half scale every button here has.
const BUTTON_SIDE := 38.0

var _buttons := {}
var _swatches: Array[BlockComponent] = []


func _after_ready() -> void:
	_build_controls()
	super()


func _build_controls() -> void:
	for id in HEADER:
		_buttons[id] = _round_button(id, ICONS[id], HEADER[id])
	_buttons["open"].released.connect(_on_open_pressed)
	_buttons["clear"].released.connect($TextureRect.clear)
	var canvas: TextureRect = $TextureRect
	var width: float = canvas.size.x * canvas.scale.x
	var step := width / COLOURS.size()
	var top: float = canvas.position.y + canvas.size.y * canvas.scale.y + 6.0
	for i in COLOURS.size():
		var swatch := _round_button("colour", "", Vector2(canvas.position.x + i * step, top))
		swatch.scale = Vector2.ONE * ((step - 3.0) / BUTTON_SIDE)
		var fill := Panel.new()
		var round := StyleBoxFlat.new()
		round.bg_color = COLOURS[i]
		round.set_corner_radius_all(11)
		fill.add_theme_stylebox_override("panel", round)
		fill.position = Vector2(8, 8)
		fill.size = Vector2(22, 22)
		fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
		swatch.add_child(fill)
		swatch.released.connect(_choose.bind(i))
		_swatches.append(swatch)
	_choose(1)
	glob.language_changed.connect(_say_tips)
	_say_tips()


func _round_button(id: String, icon: String, at: Vector2) -> BlockComponent:
	var spec := {
		"id": id, "type": "block", "text": "", "size": [BUTTON_SIDE, BUTTON_SIDE],
		"scale": [0.5, 0.5], "alignment": [0, 0], "scale_affects_layout": true,
	}
	if not icon.is_empty():
		spec["icon"] = icon
	var button := UIAdapter.build(spec)
	button.position = at
	button.graph = self
	button.graph_root = self
	UIAdapter.mount(self, button)
	var sprite: Sprite2D = button.get_node_or_null("i")
	if sprite != null:
		sprite.position = Vector2.ONE * BUTTON_SIDE * 0.5
		sprite.scale = Vector2.ONE * (22.0 / sprite.texture.get_size().x)
	return button


## The brush takes this colour, and its circle is ringed.
func _choose(index: int) -> void:
	$TextureRect.brush_color = COLOURS[index]
	for i in _swatches.size():
		_swatches[i].color = CHOSEN if i == index else Color.WHITE


func _say_tips() -> void:
	var lang := str(glob.get_lang())
	for id in _buttons:
		_buttons[id].tooltip_text = str(TIPS[id].get(lang, TIPS[id]["en"]))


func _on_open_pressed() -> void:
	var picked = await ui.splash_and_get_result("path_open", _buttons["open"], null, true, {"filter": PICTURE_TYPES})
	if picked:
		open_picture(str(picked["path"]))


func _can_drag() -> bool:
	for button in _buttons.values():
		if button.is_mouse_inside():
			return false
	for swatch in _swatches:
		if swatch.is_mouse_inside():
			return false
	return super()
