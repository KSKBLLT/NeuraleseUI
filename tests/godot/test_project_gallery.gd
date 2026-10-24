extends SceneTree

var failures: Array[String] = []


func _initialize() -> void:
	call_deferred("_run")


func _run() -> void:
	var store_script = load("res://scripts/project_thumbnail_store.gd")
	_expect(store_script != null, "project thumbnail store must exist")
	var gallery_scene = load("res://scenes/project_gallery.tscn") as PackedScene
	_expect(gallery_scene != null, "project gallery scene must exist")
	var workslist_scene = load("res://scenes/workslist.tscn") as PackedScene
	_expect(workslist_scene != null, "workslist scene must exist")
	if store_script == null or gallery_scene == null or workslist_scene == null:
		_finish()
		return
	var workslist = workslist_scene.instantiate()
	var workslist_surface := workslist.get_node("ColorRect") as ColorRect
	_expect(workslist_surface.material == null, "workslist must not draw an outer panel material")
	_expect(is_zero_approx(workslist_surface.color.a), "workslist outer panel must be transparent")
	workslist.free()

	var root := "user://project_gallery_test"
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path(root))
	var image := Image.create(64, 36, false, Image.FORMAT_RGBA8)
	image.fill(Color("315d4b"))
	var thumbnail_path: String = store_script.thumbnail_path(root, "17")
	_expect(
		store_script.save_thumbnail(image, thumbnail_path, Vector2i(320, 180)),
		"thumbnail store must persist a resized PNG"
	)
	var loaded: Texture2D = store_script.load_thumbnail(thumbnail_path)
	_expect(loaded != null, "thumbnail store must reload a persisted PNG")
	if loaded != null:
		_expect(loaded.get_size() == Vector2(320, 180), "thumbnail must use the card aspect size")

	var gallery = gallery_scene.instantiate()
	get_root().add_child(gallery)
	await process_frame
	await gallery.set_projects({
		"17": {"name": "Последний проект", "modified": 200.0, "thumbnail_path": thumbnail_path},
		"9": {"name": "Старый проект", "modified": 100.0},
	}, 17)
	await process_frame
	var cards: Array[Node] = []
	var grid_center := gallery.get_node("GalleryInset/Scroll/GridCenter") as CenterContainer
	var grid := gallery.get_node("GalleryInset/Scroll/GridCenter/Grid") as ProjectGrid
	var gallery_scroll := gallery.get_node("GalleryInset/Scroll") as ScrollContainer
	_expect(grid_center != null, "gallery must center its project grid")
	_expect(grid != null, "gallery must expose its project grid")
	_expect(gallery_scroll != null, "gallery must expose its scroll container")
	if gallery_scroll != null:
		var inset := gallery.get_node("GalleryInset") as MarginContainer
		_expect(inset.get_theme_constant("margin_left") == 15, "project grid must have a left breathing margin")
		_expect(inset.get_theme_constant("margin_right") == 15, "project grid scrollbar must stay inside the right breathing margin")
	if grid != null:
		# The works list owns the responsive decision.  A narrow transient size
		# during async card creation must not overwrite the final column count.
		gallery.size = Vector2(520, 400)
		await process_frame
		gallery.set_column_count(3)
		await process_frame
		_expect(grid.columns == 3, "project grid must keep the works-list column count after a narrow startup layout")
		gallery.size = Vector2(770, 400)
		await process_frame
		_expect(grid.columns == 3, "project grid resize must not independently replace the works-list column count")
		_expect(
			grid.size_flags_horizontal == Control.SIZE_SHRINK_CENTER,
			"project grid must shrink and remain horizontally centered"
		)
		var card_scene = load("res://scenes/project_card.tscn") as PackedScene
		var reference_card = card_scene.instantiate() as ProjectCard
		_expect(
			grid.cell_size == reference_card.custom_minimum_size,
			"grid cell size must match the actual project card"
		)
		_expect(grid.batch_size == 2, "project cards must be created in small frame batches")
		reference_card.free()
	_expect(grid_center is CenterContainer, "project grid container must center its child origin automatically")
	if grid != null:
		for child in grid.get_children():
			if child is ProjectCard:
				cards.append(child)
	_expect(cards.size() == 2, "gallery must render one card per project")
	if cards.size() == 2:
		_expect(str(cards[0].get_meta("project_id")) == "17", "gallery must show recently edited projects first")
		_expect(cards[0].get_node("Surface/Margin/Content/TitleRow/Title").text == "Последний проект", "card must expose the project name")
		_expect(cards[0].get_node("Surface/Margin/Content/Preview").texture != null, "card must render the saved thumbnail")
		_expect(cards[0].get_node("Surface/Margin/Content/Current").visible, "current project must be marked clearly")
		var fallback_preview := cards[1].get_node("Surface/Margin/Content/Preview") as TextureRect
		var neuralese_texture := load("res://neuralese.png") as Texture2D
		_expect(fallback_preview.texture == neuralese_texture, "cards without thumbnails must use neuralese.png")
		_expect(
			fallback_preview.stretch_mode == TextureRect.STRETCH_KEEP_ASPECT_CENTERED,
			"fallback project icon must stay properly sized inside the preview"
		)
	_expect(not gallery.get_node("EmptyState").visible, "non-empty gallery must hide the empty state")

	await gallery.set_projects({}, 17)
	await process_frame
	_expect(gallery.get_node("EmptyState").visible, "empty gallery must explain that no projects exist")
	gallery.queue_free()
	_finish()


func _expect(condition: bool, message: String) -> void:
	if not condition:
		failures.append(message)


func _finish() -> void:
	if failures.is_empty():
		print("PASS test_project_gallery")
		quit(0)
		return
	for failure in failures:
		push_error(failure)
	quit(1)
