extends SceneTree

func _init():
	print("Starting parse...")
	var f = FileAccess.open("res://scratch/out.txt", FileAccess.WRITE)
	f.store_string("Hello from godot headless")
	f.close()
	print("Done parse")
	quit()
