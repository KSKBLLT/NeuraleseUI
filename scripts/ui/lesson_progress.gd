extends RefCounted
## Which lessons each student has finished. Classroom computers are shared,
## so progress is kept per student name from the startup dialog.

const PATH := "user://lesson_progress.json"


static func student() -> String:
	var profile: Dictionary = cookies.get_neuralese_profile()
	var name := ("%s %s" % [profile.get("first_name", ""), profile.get("last_name", "")]).strip_edges()
	return name if not name.is_empty() else "guest"


static func done_lessons() -> Array:
	var mine: Dictionary = _load().get(student(), {})
	return mine.get("done", [])


static func mark_done(lesson_key: String) -> void:
	var data := _load()
	var mine: Dictionary = data.get(student(), {})
	var done: Array = mine.get("done", [])
	if done.has(lesson_key):
		return
	done.append(lesson_key)
	mine["done"] = done
	data[student()] = mine
	var file := FileAccess.open(PATH, FileAccess.WRITE)
	if file:
		file.store_string(JSON.stringify(data, "\t"))


static func _load() -> Dictionary:
	if not FileAccess.file_exists(PATH):
		return {}
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(PATH))
	return parsed if parsed is Dictionary else {}
