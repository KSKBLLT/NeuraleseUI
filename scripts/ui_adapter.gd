@tool
class_name UIAdapter
extends Node

const BASE_B_COMPONENT = preload("res://scenes/BaseBComponent.tscn")
const DEFAULT_CONFIG = preload("res://resources/default_config.tres")
const AUTO_FIT_SETTLE_PENDING := &"ui_adapter_auto_fit_settle_pending"
const SCALED_LAYOUT_META := &"ui_adapter_scale_affects_layout"

static func build(data: Dictionary) -> BlockComponent:
	var comp: BlockComponent = BASE_B_COMPONENT.instantiate()

	var type_str = data.get("type", "block").to_lower()
	if type_str == "context":
		comp.button_type = BlockComponent.ButtonType.CONTEXT_MENU
	elif type_str == "dropout":
		comp.button_type = BlockComponent.ButtonType.DROPOUT_MENU
	else:
		comp.button_type = BlockComponent.ButtonType.BLOCK_BUTTON

	# Basics
	if data.has("id"):
		comp.hint = StringName(data["id"])
		comp.name = data["id"]
	if data.has("text"):
		comp.text = data["text"]
	if data.has("size"):
		var sz = data["size"]
		if sz is Vector2:
			comp.base_size = sz
		elif sz is Array and sz.size() == 2:
			comp.base_size = Vector2(sz[0], sz[1])
	if data.has("scale"):
		comp.scale = _to_vector2(data["scale"], comp.scale)
	if data.has("alignment"):
		comp.alignment = _to_vector2(data["alignment"], comp.alignment)
	if bool(data.get("scale_affects_layout", false)):
		comp.set_meta(SCALED_LAYOUT_META, true)

	# Config override
	if data.has("config"):
		comp.config = load(data["config"])
	else:
		if comp.config == null:
			comp.config = DEFAULT_CONFIG

	# Colors & Shaders
	if data.has("color"):
		var col = data["color"]
		if col is String:
			col = Color(col)
		comp.color = col

	# Material override if specified
	if data.has("material"):
		comp.material = load(data["material"])

	# Flags
	if data.has("top"):
		comp.top = data["top"]
	if data.has("static"):
		comp.static_mode = data["static"]
	if data.has("mouse_open"):
		comp.mouse_open = data["mouse_open"]
	if data.has("max_size"):
		comp.max_size = data["max_size"]
	if data.has("dynamic_size"):
		comp.dynamic_size = data["dynamic_size"]
	if data.has("expanded_size"):
		comp.expanded_size = data["expanded_size"]
		comp.set_meta("original_expanded_size", data["expanded_size"])
	else:
		comp.expanded_size = 0
	if data.has("text_alignment"):
		var ta = data["text_alignment"]
		if ta is Vector2: comp.text_alignment = ta
		elif ta is Array: comp.text_alignment = Vector2(ta[0], ta[1])
	if data.has("text_offset"):
		var to = data["text_offset"]
		if to is Vector2: comp.text_offset = to
		elif to is Array: comp.text_offset = Vector2(to[0], to[1])
	if data.has("marquee"):
		comp.marquee_enabled = data["marquee"]
	if data.has("auto_trim"):
		comp.auto_trim_text = data["auto_trim"]

	# Text auto-fit. The declared size is the default minimum, so fitting grows
	# the component to contain its text but can return to its authored size when
	# the text becomes shorter.
	if data.has("auto_fit"):
		comp.text_auto_fit = _parse_auto_fit(data["auto_fit"])
		if comp.text_auto_fit != 0:
			if bool(data.get("fit_shrink", false)):
				comp.text_fit_min_size = Vector2(0.0, comp.base_size.y)
			else:
				comp.text_fit_min_size = comp.base_size
	if data.has("fit_padding"):
		comp.text_fit_padding = _to_vector2(data["fit_padding"], comp.text_fit_padding)
	if data.has("fit_min_size"):
		comp.text_fit_min_size = _to_vector2(data["fit_min_size"], comp.text_fit_min_size)
	if data.has("fit_max_size"):
		comp.text_fit_max_size = _to_vector2(data["fit_max_size"], comp.text_fit_max_size)
	if comp.text_auto_fit != 0:
		comp.text_changed.connect(_settle_after_auto_fit.bind(comp))

	# Icon
	if data.has("icon"):
		var icon_tex = load(data["icon"]) if data["icon"] is String else data["icon"]
		if icon_tex and icon_tex is Texture2D:
			var sprite = Sprite2D.new()
			sprite.name = "i"
			sprite.texture = icon_tex
			sprite.position = Vector2(comp.base_size.x * 0.25, comp.base_size.y * 0.5)
			comp.add_child(sprite)

	# Children
	if data.has("children") and data["children"] is Array:
		var children = data["children"]
		for child_data in children:
			var child_comp = build(child_data)
			# Add as a direct child. We DO NOT call contain() here because the node is an orphan
			# and @onready hasn't fired. If we reparent to vbox now, `get_parent()` inside the button
			# will return VBoxContainer and crash `is_blocking` checks.
			comp.add_child(child_comp)
	glob.wait(2,true).connect(comp.update_children_reveal)

	return comp


static func _parse_auto_fit(value: Variant) -> int:
	if value is bool:
		return BlockComponent.TEXT_FIT_WIDTH | BlockComponent.TEXT_FIT_HEIGHT if value else 0
	if value is int:
		return int(value) & (BlockComponent.TEXT_FIT_WIDTH | BlockComponent.TEXT_FIT_HEIGHT)

	match str(value).strip_edges().to_lower():
		"x", "width", "horizontal":
			return BlockComponent.TEXT_FIT_WIDTH
		"y", "height", "vertical":
			return BlockComponent.TEXT_FIT_HEIGHT
		"both", "xy", "all", "true":
			return BlockComponent.TEXT_FIT_WIDTH | BlockComponent.TEXT_FIT_HEIGHT
		_:
			return 0


static func _to_vector2(value: Variant, fallback: Vector2) -> Vector2:
	if value is Vector2:
		return value
	if value is Vector2i:
		return Vector2(value)
	if value is Array and value.size() == 2:
		return Vector2(float(value[0]), float(value[1]))
	return fallback


static func _settle_after_auto_fit(_new_text: String, comp: BlockComponent) -> void:
	if not is_instance_valid(comp) or not comp.is_inside_tree():
		return
	if comp.has_meta(AUTO_FIT_SETTLE_PENDING):
		return
	comp.set_meta(AUTO_FIT_SETTLE_PENDING, true)
	await comp.get_tree().process_frame
	if not is_instance_valid(comp):
		return
	comp.remove_meta(AUTO_FIT_SETTLE_PENDING)
	_apply_adapter_layout(comp)
	var owner_menu := comp.is_contained
	if is_instance_valid(owner_menu):
		_recalc_menu_size(owner_menu)
		owner_menu.arrange()
		owner_menu.update_children_reveal()

static func add_dynamic_child(parent_menu: BlockComponent, child_data: Dictionary) -> void:
	var child_comp = build(child_data)
	parent_menu.add_child(child_comp)
	parent_menu.dynamic_child_enter(child_comp)
	_recalc_menu_size(parent_menu)
	parent_menu.arrange()
	_settle_menu_layout(parent_menu)

static func remove_dynamic_child(parent_menu: BlockComponent, child_hint: StringName) -> void:
	var target = parent_menu.button_by_hint.get(child_hint)
	if not target:
		for c in parent_menu.vbox.get_children():
			if c is Wrapper and c.wrapping_target and c.wrapping_target.hint == child_hint:
				target = c.wrapping_target
				break
			elif c is BlockComponent and c.hint == child_hint:
				target = c
				break
	if target:
		parent_menu.dynamic_child_exit(target)
		_recalc_menu_size(parent_menu)
		if target._wrapped_in and is_instance_valid(target._wrapped_in) and target._wrapped_in != target:
			target._wrapped_in.queue_free()
		else:
			target.queue_free()
		parent_menu.arrange()
		_settle_menu_layout(parent_menu)

static func _recalc_menu_size(parent_menu: BlockComponent) -> void:
	if not is_instance_valid(parent_menu): return

	var content: float = parent_menu.base_size.y + parent_menu.size_add
	for c in parent_menu._contained:
		if is_instance_valid(c) and not c.is_queued_for_deletion():
			content += floor(parent_menu._contained_child_height(c) + parent_menu.arrangement_padding.y)

	parent_menu._unclamped_expanded_size = int(content)

	var desired: float = parent_menu._unclamped_expanded_size + parent_menu.lerp_size_offset

	if parent_menu.has_meta("original_expanded_size"):
		var orig = parent_menu.get_meta("original_expanded_size")
		desired = max(desired, float(orig))

	parent_menu.expanded_size = int(desired)

	if parent_menu.scroll and is_instance_valid(parent_menu.scroll):
		if parent_menu.max_size != 0:
			parent_menu.scroll.size.y = parent_menu.max_size - parent_menu.base_size.y - 10
		else:
			parent_menu.scroll.size.y = parent_menu.expanded_size

	if parent_menu.static_mode:
		parent_menu.size.y = (parent_menu.expanded_size if not parent_menu.max_size else min(parent_menu.max_size, parent_menu.expanded_size)) + parent_menu.size_add
		if parent_menu.bar and is_instance_valid(parent_menu.bar):
			parent_menu.bar.self_modulate.a = 1.0 if (parent_menu.max_size != 0 and parent_menu.expanded_size > parent_menu.max_size) else 0.0

static func _settle_menu_layout(parent_menu: BlockComponent) -> void:
	# Phase B layout logic: wait a frame for nodes and wrappers to be fully added and layouts to stretch
	var tree = parent_menu.get_tree()
	if tree:
		await tree.process_frame

	if is_instance_valid(parent_menu):
		_recalc_menu_size(parent_menu)
		parent_menu.arrange()
		parent_menu.update_children_reveal()

static func mount(parent_node: Node, root_comp: BlockComponent) -> void:
	# Add to the tree. This naturally fires @onready and _ready() on all nodes bottom-up.
	parent_node.add_child(root_comp)
	# The _ready() function has now finished running and sizing the initial layout.
	# We manually disable `add_to_size` to prevent double-counting heights during dynamic additions.
	if "add_to_size" in root_comp:
		root_comp.add_to_size = false
	_recalc_menu_size(root_comp)
	_settle_adapter_layout.call_deferred(root_comp)


static func _settle_adapter_layout(comp: BlockComponent) -> void:
	if not is_instance_valid(comp) or not comp.is_inside_tree():
		return
	await comp.get_tree().process_frame
	_apply_adapter_layout(comp)


static func _apply_adapter_layout(comp: BlockComponent) -> void:
	if (
		not is_instance_valid(comp)
		or not bool(comp.get_meta(SCALED_LAYOUT_META, false))
		or comp._wrapped_in == comp
	):
		return
	var layout_size: Vector2 = comp.base_size * comp.base_scale.abs()
	# BlockComponent intentionally keeps its legacy layout semantics. UIAdapter
	# opt-in components correct their own wrapper after every auto-fit resize.
	comp.custom_minimum_size = comp.base_size
	comp.size = comp.base_size
	comp._wrapped_in.custom_minimum_size = layout_size
	comp._wrapped_in.size = layout_size
	comp.scaler.size = comp.base_size
	comp.position = -comp.alignment * comp.base_size
	comp.scaler.position = comp.alignment * comp.base_size * comp.base_scale
