extends ProceduralNodes

func _ready() -> void:
	initialize()
	glob.ref(self, "vocabulary")

func _get_nodes(args, _kwargs = {}) -> Array[Node]:
	var output: Array[Node] = []
	if args is Array:
		for entry in args:
			if not (entry is Dictionary):
				continue
			var card: BlockComponent = frozen_duplicate.duplicate()
			card.placeholder = false
			card.text = str(entry.get("text", ""))
			card.hint = StringName(str(entry.get("id", card.text)))
			card.metadata = {
				"payload": entry.get("payload", {}),
				"is_preset": bool(entry.get("is_preset", false)),
			}
			output.append(card)
			if bool(entry.get("is_preset", false)):
				card.set_deferred("base_modulate", Color(0.856, 0.52, 1.0, 1.0))
			else:
				card.set_deferred("base_modulate", Color(0.34, 1.0, 0.824, 1.0))
	elif args is Dictionary:
		for key in args:
			var item = args[key]
			var card: BlockComponent = frozen_duplicate.duplicate()
			card.placeholder = false
			card.text = str(item.get("text", key)) if item is Dictionary else str(key)
			card.hint = StringName(str(key))
			card.metadata = {"payload": item if item is Dictionary else {"id": key}}
			output.append(card)
			card.set_deferred("base_modulate", Color(0.34, 1.0, 0.824, 1.0))
	return output
