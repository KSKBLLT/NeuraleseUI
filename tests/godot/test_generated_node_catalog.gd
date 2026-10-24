extends SceneTree

const NodeCatalog = preload("res://scripts/generated/node_catalog.gd")

const EXPECTED_PUBLIC_ORDER: Array[StringName] = [
	&"input",
	&"input_rgb",
	&"input_1d",
	&"classifier",
	&"flatten",
	&"reshape2d",
	&"softmax",
	&"layer",
	&"conv2d",
	&"maxpool",
	&"dropout",
	&"neuron",
	&"gru_cell",
	&"dataset",
	&"train_begin",
	&"run_model",
	&"train_input",
	&"concat",
	&"text_input",
	&"tokenizer",
	&"embedding",
	&"attention_head",
	&"token_labels",
	&"autoregression",
]

var failures: Array[String] = []


func _initialize() -> void:
	_expect_equal(NodeCatalog.DEFINITIONS.size(), 28, "all registered node definitions")
	_expect_equal(NodeCatalog.SCENE_PATHS.size(), 28, "all current definitions use existing scenes")
	_expect_equal(NodeCatalog.PROVIDER_PATHS.size(), 0, "provider support adds no current runtime source")
	_expect_equal(NodeCatalog.menu_order(), EXPECTED_PUBLIC_ORDER, "compiled public menu order")
	_expect(not NodeCatalog.has(&"output_map"), "removed OutputMap must not return through generation")
	_expect_equal(NodeCatalog.input_types(), [&"input", &"input_rgb", &"input_1d", &"text_input"], "input role catalog")
	_expect_equal(NodeCatalog.llm_name_mapping().get(&"activation"), &"neuron", "LLM aliases")

	for type_id in NodeCatalog.load_order():
		var source_path := String(NodeCatalog.source_map().get(type_id, ""))
		_expect(not source_path.is_empty(), "%s has a compiled source path" % type_id)
		_expect(ResourceLoader.exists(source_path), "%s source exists" % type_id)

	if failures.is_empty():
		print("PASS test_generated_node_catalog")
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
