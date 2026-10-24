extends Node

var failures: Array[String] = []


func _ready() -> void:
	_run.call_deferred()


func _run() -> void:
	for _frame in 20:
		await get_tree().process_frame

	var gallery_scene := load("res://scenes/project_gallery.tscn") as PackedScene
	var gallery := gallery_scene.instantiate() as ProjectGallery
	add_child(gallery)
	gallery.size = Vector2(520, 400)
	await get_tree().process_frame

	gallery.set_column_count(3)
	await get_tree().process_frame
	var grid := gallery.get_node("GalleryInset/Scroll/GridCenter/Grid") as ProjectGrid
	_expect(grid.columns == 3, "explicit works-list column count must win over the narrow startup size")

	gallery.size = Vector2(770, 400)
	await get_tree().process_frame
	_expect(grid.columns == 3, "gallery resize must not independently replace the works-list column count")

	gallery.queue_free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_project_gallery_layout")
		get_tree().quit(0)
		return
	for failure in failures:
		push_error(failure)
	get_tree().quit(1)
