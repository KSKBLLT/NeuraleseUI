class_name ProjectThumbnailStore
extends RefCounted

class ThumbnailDecodeJob:
	var absolute_path: String
	var image: Image
	var error := ERR_UNAVAILABLE

	func _init(path: String) -> void:
		absolute_path = path

	func run() -> void:
		image = Image.new()
		error = image.load(absolute_path)


static var _texture_cache: Dictionary = {}


static func thumbnail_path(root_path: String, project_id: String) -> String:
	return root_path.path_join("%s.png" % project_id)


static func save_thumbnail(image: Image, path: String, target_size := Vector2i(480, 270)) -> bool:
	if image == null or image.is_empty():
		return false
	var absolute_path := ProjectSettings.globalize_path(path)
	var directory := absolute_path.get_base_dir()
	if not directory.is_empty() and DirAccess.make_dir_recursive_absolute(directory) != OK:
		return false
	var prepared := image.duplicate()
	var target_aspect := float(target_size.x) / float(target_size.y)
	var source_aspect := float(prepared.get_width()) / float(prepared.get_height())
	if source_aspect > target_aspect:
		var crop_width := maxi(1, int(round(prepared.get_height() * target_aspect)))
		var crop_x: int = (prepared.get_width() - crop_width) / 2
		prepared = prepared.get_region(Rect2i(crop_x, 0, crop_width, prepared.get_height()))
	elif source_aspect < target_aspect:
		var crop_height := maxi(1, int(round(prepared.get_width() / target_aspect)))
		var crop_y: int = (prepared.get_height() - crop_height) / 2
		prepared = prepared.get_region(Rect2i(0, crop_y, prepared.get_width(), crop_height))
	prepared.resize(target_size.x, target_size.y, Image.INTERPOLATE_LANCZOS)
	var saved: bool = prepared.save_png(absolute_path) == OK
	if saved:
		_invalidate_cached_path(absolute_path)
	return saved


static func load_thumbnail(path: String) -> Texture2D:
	if path.strip_edges().is_empty():
		return null
	var image := Image.new()
	if image.load(ProjectSettings.globalize_path(path)) != OK or image.is_empty():
		return null
	return ImageTexture.create_from_image(image)


static func load_thumbnail_async(path: String) -> Texture2D:
	if path.strip_edges().is_empty():
		return null
	var absolute_path := ProjectSettings.globalize_path(path)
	if not FileAccess.file_exists(absolute_path):
		return null
	var cache_key := "%s:%s" % [absolute_path, str(FileAccess.get_modified_time(absolute_path))]
	var cached := _texture_cache.get(cache_key) as Texture2D
	if is_instance_valid(cached):
		return cached

	var job := ThumbnailDecodeJob.new(absolute_path)
	var task_id := WorkerThreadPool.add_task(Callable(job, "run"), false, "Decode project thumbnail")
	var tree := Engine.get_main_loop() as SceneTree
	while not WorkerThreadPool.is_task_completed(task_id):
		if tree == null:
			return null
		await tree.process_frame
	if WorkerThreadPool.wait_for_task_completion(task_id) != OK:
		return null
	if job.error != OK or job.image == null or job.image.is_empty():
		return null
	var texture := ImageTexture.create_from_image(job.image)
	_texture_cache[cache_key] = texture
	return texture


static func _invalidate_cached_path(absolute_path: String) -> void:
	var prefix := absolute_path + ":"
	for key in _texture_cache.keys():
		if str(key).begins_with(prefix):
			_texture_cache.erase(key)
