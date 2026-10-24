extends SceneTree

const BUTTON_SCENE := "res://scenes/BaseBComponent.tscn"

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var packed: PackedScene = load(BUTTON_SCENE)
	_expect(packed != null, "base button scene loads")
	if packed == null:
		_finish()
		return

	var button := packed.instantiate()
	button.set("auto_ready", false)
	_expect_equal(button.get("hint"), &"", "hint keeps its default")
	_expect_equal(button.get("scale_anim"), false, "scale_anim keeps its default")
	_expect_equal(button.get("expand_anim"), true, "expand_anim keeps its default")

	button.set("hint", &"ask_axon")
	button.set("scale_anim", true)
	button.set("expand_anim", false)

	_expect(button.has_meta("block_component_hint"), "hint uses node metadata")
	_expect(button.has_meta("block_component_scale_anim"), "scale_anim uses node metadata")
	_expect(button.has_meta("block_component_expand_anim"), "expand_anim uses node metadata")

	var snapshot := PackedScene.new()
	_expect_equal(snapshot.pack(button), OK, "button snapshot packs")
	var snapshot_path := "user://button_property_persistence.tscn"
	_expect_equal(ResourceSaver.save(snapshot, snapshot_path), OK, "button snapshot saves")
	button.free()

	var restored_scene: PackedScene = ResourceLoader.load(
		snapshot_path,
		"PackedScene",
		ResourceLoader.CACHE_MODE_IGNORE
	)
	_expect(restored_scene != null, "button snapshot reloads")
	if restored_scene == null:
		_finish()
		return
	button = restored_scene.instantiate()

	_expect_equal(button.get("hint"), &"ask_axon", "hint survives scene reload")
	_expect_equal(button.get("scale_anim"), true, "scale_anim survives scene reload")
	_expect_equal(button.get("expand_anim"), false, "expand_anim survives scene reload")

	button.free()
	_finish()


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_button_property_persistence")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)


func _expect(condition: bool, label: String) -> void:
	if not condition:
		failures.append(label)


func _expect_equal(actual: Variant, expected: Variant, label: String) -> void:
	if actual != expected:
		failures.append("%s: expected %s, got %s" % [label, str(expected), str(actual)])
