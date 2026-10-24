class_name RobotModelContract
extends RefCounted
## What the open project's model is, gathered for the robot window.
##
## The training node (TrainBegin) of the project keeps the dataset the model was
## trained on in ``dataset_meta``: its name, its column names, and for datasets
## made in the simulation the agent in ``metadata.binding``. The meaning of each
## neuron is worked out from that in Python (robot/model_contract.py); this class
## only collects the raw facts.
##
## A network that sees its place in the world or a goal also needs that world:
## datasets keep it in ``metadata.world`` (SimulationCompiler.training_world);
## for older datasets the project's current simulation world stands in.

const Compiler = preload("res://scripts/simulations/simulation_compiler.gd")

const META_KEYS := ["name", "inputs", "outputs", "input_hints", "col_names", "outputs_from", "description"]


## {"dataset_meta", "input_width", "output_width", "model_ready", "model_path", "model_name",
##  "world", "world_source": "dataset" | "current_world" | ""}
static func collect() -> Dictionary:
	var model_name := str(glob.DEFAULT_MODEL_NAME)
	var result := {
		"dataset_meta": {},
		"input_width": 0,
		"output_width": 0,
		"model_ready": false,
		"model_path": "",
		"model_name": model_name,
		"world": {},
		"world_source": "",
	}
	var input_graph = graphs.get_input_graph_by_name(model_name)
	if not is_instance_valid(input_graph):
		return result
	result["input_width"] = int(input_graph.useful_properties().get("shape", 0))
	for graph in graphs.simple_reach(input_graph, true):
		if is_instance_valid(graph) and str(graph.server_typename) == "ClassifierNode":
			var units: Variant = graph.get("units")
			if units is Array and not units.is_empty():
				result["output_width"] = units.size()
				break
	var model_path: String = nn._local_inference_model_path(input_graph.context_id)
	result["model_path"] = model_path
	result["model_ready"] = FileAccess.file_exists(model_path)
	var train_begin = _find_train_begin(model_name)
	if train_begin != null:
		result["dataset_meta"] = with_dataset_fields(slim_meta(train_begin.dataset_meta))
	var stored: Variant = result["dataset_meta"].get("metadata", {}).get("world")
	if stored is Dictionary and stored.get("agent_start") != null:
		result["world"] = stored
		result["world_source"] = "dataset"
	else:
		var current := current_world()
		if not current.is_empty():
			result["world"] = current
			result["world_source"] = "current_world"
	return result


## The project's simulation world as SimulationCompiler.training_world sees it.
static func current_world() -> Dictionary:
	var env_window = glob.tree_windows.get("env")
	if not is_instance_valid(env_window) or not env_window.has_method("get_simulation_state"):
		return {}
	var state: Variant = env_window.get_simulation_state()
	if not state is Dictionary or state.is_empty():
		return {}
	var world := Compiler.training_world(Compiler.compile(state))
	return world if world.get("agent_start") != null else {}


## The small fields of a dataset dictionary. A dataset made in the simulation
## carries all its rows too, which must not travel to the session process.
static func slim_meta(meta: Variant) -> Dictionary:
	var slim := {}
	if not meta is Dictionary:
		return slim
	for key in META_KEYS:
		if meta.has(key):
			slim[key] = meta[key]
	var metadata: Variant = meta.get("metadata")
	if metadata is Dictionary:
		slim["metadata"] = {}
		for key in ["binding", "world"]:
			if metadata.get(key) is Dictionary:
				slim["metadata"][key] = metadata[key]
	return slim


## The training node often holds only the dataset's preview, which is what a
## Dataset node passes on (names and sizes, DsObjRLE.get_preview): the binding,
## the world and the column names are in the dataset itself. Without them every
## input but rays and speed would be refused as unknown.
static func with_dataset_fields(meta: Dictionary) -> Dictionary:
	if meta.get("metadata", {}).has("binding"):
		return meta
	var dataset: Variant = glob.dataset_datas.get(str(meta.get("name", "")))
	if not dataset is Dictionary:
		return meta
	var full := slim_meta(dataset)
	full.merge(meta, false)
	return full


## The TrainBegin node that trains the given model (the one that reaches a
## RunModel node with that name); any TrainBegin with a dataset as a fallback.
static func _find_train_begin(model_name: String):
	var fallback = null
	for graph in graphs._graphs.values():
		if not is_instance_valid(graph) or str(graph.server_typename) != "TrainBegin":
			continue
		if not graph.dataset_meta or str(graph.dataset_meta.get("name", "")).is_empty():
			continue
		if fallback == null:
			fallback = graph
		var found := {"match": false}
		var visit = func(_from, to, _cache):
			if to.parent_graph.server_typename == "RunModel" and str(to.parent_graph.name_graph) == model_name:
				found["match"] = true
		graphs.reach(graph, visit)
		if found["match"]:
			return graph
	return fallback
