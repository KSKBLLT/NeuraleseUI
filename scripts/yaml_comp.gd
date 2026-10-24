class_name YAMLComp
extends RefCounted

const TutorialLocalizationCore := preload("res://scripts/startup/tutorial_localization.gd")

static func compile_bundle(zip_path: String, zip: bool = false) -> Dictionary:
	var dir
	if zip:
		dir = glob.unzip_to_temp_dir(zip_path)
		if dir == null:
			push_error("ZIP: failed to unzip '%s'" % zip_path)
			return {}

		if dir.dir_exists("lesson_bundle"):
			dir.change_dir("lesson_bundle")
	else:
		dir = DirAccess.open(zip_path)

	if not dir.file_exists("bundle.yaml"):
		push_error("ZIP: missing bundle.yaml")
		return {}

	var bundle_yaml = _read_text_file(dir, "bundle.yaml")
	if bundle_yaml == "":
		return {}

	var bundle_root = _parse_yaml(bundle_yaml)
	if bundle_root == null:
		return {}

	var bundle_name = str(bundle_root.get("name", "")).strip_edges()
	if bundle_name == "":
		push_error("bundle.yaml: missing 'name'")
		return {}

	var lesson_order_src = bundle_root.get("lesson_order", [])
	if typeof(lesson_order_src) != TYPE_ARRAY:
		push_error("bundle.yaml: 'lesson_order' must be a list")
		return {}

	# ---------------- lessons ----------------
	if not dir.dir_exists("lessons"):
		push_error("ZIP: missing lessons/ directory")
		return {}

	var lessons_dir = DirAccess.open(dir.get_current_dir().path_join("lessons"))
	if lessons_dir == null:
		push_error("ZIP: cannot open lessons/")
		return {}

	var lessons_out := {}
	var lesson_order_out := []

	for lesson_key in lesson_order_src:
		var key := str(lesson_key)
		var lesson_file := "%s.yaml" % key

		if not lessons_dir.file_exists(lesson_file):
			push_error("lesson '%s' missing (%s)" % [key, lesson_file])
			return {}

		var lesson_yaml = _read_text_file(lessons_dir, lesson_file)
		if lesson_yaml == "":
			return {}

		var compiled = _compile_single_lesson(lesson_yaml, key, dir.get_current_dir())
		if compiled.is_empty():
			return {}

		lessons_out[key] = compiled
		lesson_order_out.append(key)

	return {
		"name": bundle_name,
		"lesson_order": lesson_order_out,
		"lessons": lessons_out
	}



static func _compile_single_lesson(yaml_text: String, fallback_title: String, bundle_root_path: String = "") -> Dictionary:
	var root = _parse_yaml(yaml_text)
	if root == null:
		return {}

	# ------------------------------------------------
	# Main flow (required)
	# ------------------------------------------------
	var flow = root.get("flow", null)
	if typeof(flow) != TYPE_ARRAY:
		push_error("lesson '%s': missing/invalid 'flow'" % fallback_title)
		return {}

	var flows_out: Dictionary = {}
	var main_steps = _compile_steps_array(flow, fallback_title)
	if main_steps.is_empty():
		return {}

	flows_out["flow"] = main_steps

	# ------------------------------------------------
	# Branches (optional)
	# ------------------------------------------------
	if root.has("branches"):
		var branches = root.get("branches")
		if typeof(branches) != TYPE_DICTIONARY:
			push_error("lesson '%s': 'branches' must be a mapping" % fallback_title)
			return {}

		for bname in branches.keys():
			var branch_name = str(bname).strip_edges()
			if branch_name == "":
				push_error("lesson '%s': empty branch name" % fallback_title)
				return {}

			if branch_name == "flow":
				push_error("lesson '%s': branch name 'flow' is reserved" % fallback_title)
				return {}

			var branch_body = branches[bname]
			if typeof(branch_body) != TYPE_ARRAY:
				push_error("lesson '%s': branch '%s' must be a list of steps" % [fallback_title, branch_name])
				return {}

			var branch_steps = _compile_steps_array(branch_body, fallback_title)
			if branch_steps.is_empty():
				return {}

			flows_out[branch_name] = branch_steps

	# ------------------------------------------------
	# Validate ask → goto targets
	# ------------------------------------------------
	if not _validate_branch_gotos(flows_out):
		return {}

	var lesson_title: Variant = root.get("lesson_title", fallback_title)
	if not TutorialLocalizationCore.is_valid(lesson_title):
		push_error("lesson '%s': lesson_title must be text or an en/ru/kz mapping" % fallback_title)
		return {}
	var compiled_lesson := {
		"lesson_title": lesson_title,
		"code": {
			"entry": "flow",
			"flows": flows_out
		}
	}
	var tutorial_ui = _compile_tutorial_ui(root, fallback_title)
	if tutorial_ui == null:
		return {}
	if not tutorial_ui.is_empty():
		compiled_lesson["tutorial_ui"] = tutorial_ui
	var auto_project = _compile_auto_project(root, bundle_root_path, fallback_title)
	if auto_project == null:
		return {}
	if typeof(auto_project) == TYPE_DICTIONARY and not auto_project.is_empty():
		compiled_lesson["auto_project"] = auto_project
	return compiled_lesson


static func _compile_tutorial_ui(root: Dictionary, fallback_title: String):
	if not root.has("tutorial_ui"):
		return {}
	var source: Variant = root.get("tutorial_ui")
	if typeof(source) != TYPE_DICTIONARY:
		push_error("lesson '%s': tutorial_ui must be a mapping" % fallback_title)
		return null
	var show_progress: Variant = source.get("show_progress", true)
	if typeof(show_progress) != TYPE_BOOL:
		push_error("lesson '%s': tutorial_ui.show_progress must be a boolean" % fallback_title)
		return null
	var out := {"show_progress": show_progress}
	if source.has("arrow_style"):
		var arrow_style = _compile_tutorial_arrow_style(source.get("arrow_style"), fallback_title)
		if arrow_style == null:
			return null
		out["arrow_style"] = arrow_style
	if source.has("highlight_style"):
		var highlight_style = _compile_tutorial_highlight_style(source.get("highlight_style"), fallback_title)
		if highlight_style == null:
			return null
		out["highlight_style"] = highlight_style
	return out


static func _compile_tutorial_arrow_style(source: Variant, fallback_title: String):
	if typeof(source) != TYPE_DICTIONARY:
		push_error("lesson '%s': tutorial_ui.arrow_style must be a mapping" % fallback_title)
		return null
	var out := {}
	for key in ["thickness", "head_size", "wobble_amplitude"]:
		if not source.has(key):
			continue
		var value: Variant = source[key]
		if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or float(value) < 0.0:
			push_error("lesson '%s': tutorial_ui.arrow_style.%s must be a non-negative number" % [fallback_title, key])
			return null
		out[key] = float(value)
	if source.has("color"):
		var parsed_color = _compile_tutorial_color(source["color"], "tutorial_ui.arrow_style.color", fallback_title)
		if parsed_color == null:
			return null
		out["color"] = parsed_color
	if source.has("shadow"):
		var shadow_source: Variant = source["shadow"]
		if typeof(shadow_source) != TYPE_DICTIONARY:
			push_error("lesson '%s': tutorial_ui.arrow_style.shadow must be a mapping" % fallback_title)
			return null
		var shadow := {}
		var enabled: Variant = shadow_source.get("enabled", false)
		if typeof(enabled) != TYPE_BOOL:
			push_error("lesson '%s': tutorial_ui.arrow_style.shadow.enabled must be a boolean" % fallback_title)
			return null
		shadow["enabled"] = enabled
		if shadow_source.has("color"):
			var parsed_shadow_color = _compile_tutorial_color(shadow_source["color"], "tutorial_ui.arrow_style.shadow.color", fallback_title)
			if parsed_shadow_color == null:
				return null
			shadow["color"] = parsed_shadow_color
		if shadow_source.has("offset"):
			var offset: Variant = shadow_source["offset"]
			if typeof(offset) != TYPE_ARRAY or offset.size() != 2:
				push_error("lesson '%s': tutorial_ui.arrow_style.shadow.offset must be [x, y]" % fallback_title)
				return null
			shadow["offset"] = Vector2(float(offset[0]), float(offset[1]))
		for key in ["thickness_add", "head_size_add"]:
			if not shadow_source.has(key):
				continue
			var value: Variant = shadow_source[key]
			if typeof(value) not in [TYPE_INT, TYPE_FLOAT] or float(value) < 0.0:
				push_error("lesson '%s': tutorial_ui.arrow_style.shadow.%s must be a non-negative number" % [fallback_title, key])
				return null
			shadow[key] = float(value)
		out["shadow"] = shadow
	return out


static func _compile_tutorial_highlight_style(source: Variant, fallback_title: String):
	if typeof(source) != TYPE_DICTIONARY:
		push_error("lesson '%s': tutorial_ui.highlight_style must be a mapping" % fallback_title)
		return null
	var out := {}
	if source.has("center_opacity"):
		var opacity: Variant = source["center_opacity"]
		if typeof(opacity) not in [TYPE_INT, TYPE_FLOAT] or float(opacity) < 0.0 or float(opacity) > 1.0:
			push_error("lesson '%s': tutorial_ui.highlight_style.center_opacity must be between 0 and 1" % fallback_title)
			return null
		out["center_opacity"] = float(opacity)
	if source.has("padding"):
		var padding: Variant = source["padding"]
		if typeof(padding) not in [TYPE_INT, TYPE_FLOAT] or float(padding) < 0.0:
			push_error("lesson '%s': tutorial_ui.highlight_style.padding must be a non-negative number" % fallback_title)
			return null
		out["padding"] = float(padding)
	for key in ["fade_in", "fade_out"]:
		if not source.has(key):
			continue
		var duration: Variant = source[key]
		if typeof(duration) not in [TYPE_INT, TYPE_FLOAT] or float(duration) < 0.0:
			push_error("lesson '%s': tutorial_ui.highlight_style.%s must be a non-negative number" % [fallback_title, key])
			return null
		out[key] = float(duration)
	return out


static func _compile_tutorial_color(value: Variant, field: String, fallback_title: String):
	if value is Color:
		return value
	if typeof(value) != TYPE_STRING or not Color.html_is_valid(str(value)):
		push_error("lesson '%s': %s must be a hex color" % [fallback_title, field])
		return null
	return Color.from_string(str(value), Color.WHITE)


static func _compile_auto_project(root: Dictionary, bundle_root_path: String, fallback_title: String):
	if not root.has("auto_project"):
		return {}
	if bundle_root_path.strip_edges() == "":
		push_error("lesson '%s': auto_project requires a bundle root path" % fallback_title)
		return null
	var ref := str(root.get("auto_project", "")).replace("\\", "/").strip_edges()
	if ref == "":
		push_error("lesson '%s': auto_project must be a relative .scn path" % fallback_title)
		return null
	if ref.begins_with("/") or ref.find("://") != -1 or ref.split("/", false).has(".."):
		push_error("lesson '%s': auto_project must be relative to bundle root and cannot escape it" % fallback_title)
		return null
	if not ref.to_lower().ends_with(".scn"):
		push_error("lesson '%s': auto_project must point to a .scn project payload" % fallback_title)
		return null
	var path := bundle_root_path.path_join(ref)
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("lesson '%s': auto_project file missing: %s" % [fallback_title, ref])
		return null
	var payload = file.get_var()
	file.close()
	if typeof(payload) != TYPE_PACKED_BYTE_ARRAY:
		push_error("lesson '%s': auto_project .scn must contain the same PackedByteArray payload used by project saves" % fallback_title)
		return null
	return {
		"source": ref,
		"name": str(root.get("auto_project_name", root.get("lesson_title", fallback_title))),
		"encoding": "base64_var_bytes",
		"blob": Marshalls.raw_to_base64(payload),
	}

static func _compile_steps_array(src: Array, fallback_title: String) -> Array:
	var out: Array = []

	for item in src:
		var step_def = _compile_flow_item(item)
		if step_def.is_empty():
			print("lesson '%s': step compilation failed" % fallback_title, item)
			return []
		out.append(step_def)

	return out

static func _validate_branch_gotos(flows: Dictionary) -> bool:
	for flow_name in flows.keys():
		var steps: Array = flows[flow_name]

		for step in steps:
			var actions: Array = step.get("actions", [])
			for act in actions:
				if typeof(act) != TYPE_DICTIONARY:
					continue

				if str(act.get("type", "")) != "ask":
					continue

				var on_answer = act.get("on_answer", {})
				for idx in on_answer.keys():
					var target = on_answer[idx]
					if str(target.get("op", "")) != "goto":
						continue

					var branch = str(target.get("target", "")).strip_edges()
					if not flows.has(branch):
						push_error("ask.goto references unknown branch '%s'" % branch)
						return false

				if act.has("default"):
					var def = act["default"]
					if str(def.get("op", "")) == "goto":
						var branch2 = str(def.get("target", "")).strip_edges()
						if not flows.has(branch2):
							push_error("ask.default.goto references unknown branch '%s'" % branch2)
							return false

	return true




static func _read_text_file(dir: DirAccess, path: String) -> String:
	var f = FileAccess.open(dir.get_current_dir().path_join(path), FileAccess.READ)
	if f == null:
		push_error("IO: failed to read %s" % path)
		return ""
	var txt = f.get_as_text()
	f.close()
	return txt





static func compile_bundle_json(yaml_text: String, indent: String = "\t") -> String:
	var dict_out = compile_bundle(yaml_text)
	return JSON.stringify(dict_out, indent)


static func _parse_yaml(yaml_text: String):
	var data = YAML.parse(yaml_text)
	if data.has_error():
		print(data.get_error())
	data = data.get_document()
	if data == null:
		push_error("YAML: parse failed")
		return null
	if typeof(data) != TYPE_DICTIONARY:
		push_error("YAML: root must be a mapping (dictionary)")
		return null
	return data


static func _compile_flow_item(item) -> Dictionary:
	if typeof(item) != TYPE_DICTIONARY or item.size() != 1:
		push_error("YAML: each flow item must be a mapping with a single key like 'step <id>:'")
		return {}

	var key = str(item.keys()[0])
	var body = item.values()[0]
	if typeof(body) != TYPE_DICTIONARY:
		push_error("YAML: step body must be a mapping")
		return {}

	var step_id = _parse_step_key(key)
	if step_id == "":
		push_error("YAML: invalid step key '%s' (expected 'step <id>')" % key)
		return {}

	var step_title: Variant = body.get("title", step_id)
	if not TutorialLocalizationCore.is_valid(step_title):
		push_error("YAML: step '%s' title must be text or an en/ru/kz mapping" % step_id)
		return {}
	var out_step: Dictionary = {
		"id": step_id,
		"title": step_title
	}

	if bool(body.get("persistent", false)):
		out_step["persistent"] = true

	var has_actions = body.has("actions")

	# ----------------------------
	# Case A: explicit actions:
	# ----------------------------
	if has_actions:
		# allow other metadata keys to pass through
		for k in body.keys():
			var kk = str(k)
			if kk == "title" or kk == "persistent":
				continue

			if dsl_reg.step_directives.has(kk):
				var fn = dsl_reg.step_directives[kk].get("compile", null)
				if fn == null:
					push_error("STEP_DIRECTIVES missing compile fn for '%s'" % kk)
					return {}
				var ok = fn.call(out_step, body[kk])
				if ok != true:
					return {}
			else:
				out_step[kk] = body[kk]

		return out_step

	# ----------------------------
	# Case B: sugar (no actions:)
	# Compile keys into actions in YAML order
	# ----------------------------
	var acts: Array = []

	for k in body.keys():
		var kk = str(k)

		if kk == "title" or kk == "persistent":
			continue

		# If this key is a runtime action type — compile into action
		if dsl_reg.action.has(kk):
			var act_compile = dsl_reg.action[kk].get("compile", null)
			if act_compile == null:
				push_error("ACTION missing compile fn for '%s'" % kk)
				return {}

			var act = act_compile.call(body[kk])
			if typeof(act) != TYPE_DICTIONARY or act.is_empty():
				return {}

			acts.append(act)
			continue

		# Otherwise, if it's a step directive (compile-time transform) — apply it
		if dsl_reg.step_directives.has(kk):
			var fn2 = dsl_reg.step_directives[kk].get("compile", null)
			if fn2 == null:
				push_error("STEP_DIRECTIVES missing compile fn for '%s'" % kk)
				return {}
			var ok2 = fn2.call(out_step, body[kk])
			if ok2 != true:
				return {}
			continue

		# Unknown keys pass-through
		out_step[kk] = body[kk]

	if acts.size() > 0:
		out_step["actions"] = acts

	return out_step





static func _parse_step_key(key: String) -> String:
	var s = key.strip_edges()
	if not s.begins_with("step "):
		return ""
	return s.substr(5, s.length() - 5).strip_edges()
