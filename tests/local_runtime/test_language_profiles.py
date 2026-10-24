import pytest

from neuralese_local.language.graph_mapping import resolve_graph


def graph(depth=1, heads=1):
    nodes = [{"id": "e", "op": "embedding", "config": {}}]
    edges = []
    previous = "e"
    for stage in range(depth):
        names = []
        for head in range(heads):
            name = f"h{stage}_{head}"
            nodes.append({"id": name, "op": "attention_head", "config": {}})
            edges.append({"from_node": previous, "to_node": name})
            names.append(name)
        if heads > 1:
            previous = f"c{stage}"
            nodes.append({"id": previous, "op": "concat", "config": {}})
            edges.extend({"from_node": name, "to_node": previous} for name in names)
        else:
            previous = names[0]
    return {"nodes": nodes, "edges": edges}


def test_parallel_heads_are_one_stage():
    mapped = resolve_graph(graph(1, 4), {})
    assert mapped["requested_depth"] == 1
    assert {mapped["node_mapping"][f"h0_{i}"]["head"] for i in range(4)} == {0, 1, 2, 3}
    assert len({mapped["node_mapping"][f"h0_{i}"]["layer"] for i in range(4)}) == 1


def test_partial_connection_preserves_full_component_layers_and_parallel_heads():
    complete = graph(2, 4)
    expected = resolve_graph(complete, {})
    for index in range(4):
        key = f"h0_{index}"
        partial = {"nodes": [complete["nodes"][0], complete["nodes"][index+1]],
                   "edges": [{"from_node": "e", "to_node": key}], "mapping_graph": complete}
        actual = resolve_graph(partial, {})
        assert actual["node_mapping"][key] == expected["node_mapping"][key]
        assert actual["requested_depth"] == 2


def test_new_random_id_does_not_reassign_existing_parallel_heads():
    complete = graph(1, 3)
    for index, node in enumerate(n for n in complete["nodes"] if n["op"] == "attention_head"):
        node["config"]["head_index"] = index
    expected = resolve_graph(complete, {})
    complete["nodes"].append({"id": "aaa_new", "op": "attention_head", "config": {"head_index": 3}})
    complete["edges"].append({"from_node": "e", "to_node": "aaa_new"})
    actual = resolve_graph(complete, {})
    for key in ("h0_0", "h0_1", "h0_2"):
        assert actual["node_mapping"][key] == expected["node_mapping"][key]
    assert actual["node_mapping"]["aaa_new"]["head"] == 3


@pytest.mark.parametrize("depth", [2, 8, 9, 10, 11, 12])
def test_depth_is_derived_from_topology_and_near_source_keeps_identity(depth):
    mapped = resolve_graph(graph(depth), {})
    assert mapped["requested_depth"] == depth
    assert mapped["effective_depth"] == 10
    assert mapped["profile_id"] == "identity"
    assert len({m["layer"] for m in mapped["node_mapping"].values() if "layer" in m}) <= 10


def test_geometry_does_not_invalidate_mapping_cache():
    first = graph(2)
    second = graph(2)
    second["nodes"][1]["position"] = [999, -100]
    assert resolve_graph(first, {})["cache_key"] == resolve_graph(second, {})["cache_key"]


def test_new_checkpoint_cannot_reuse_old_mapping_cache():
    assert resolve_graph(graph(), {"source_hash": "a"})["cache_key"] != resolve_graph(graph(), {"source_hash": "b"})["cache_key"]


def test_unverified_compressed_profile_is_not_selected():
    mapped = resolve_graph(graph(2), {"2": {"id": "damaged", "layers": 2, "quality_passed": False}})
    assert mapped["profile_id"] == "identity"


def test_cycle_is_rejected_instead_of_silent_mapping():
    value = graph(2)
    value["edges"].append({"from_node": "h1_0", "to_node": "h0_0"})
    with pytest.raises(ValueError, match="cycle"):
        resolve_graph(value, {})


def test_slerp_handles_zero_and_parallel_weights_without_nan():
    import numpy as np
    from tools.language_models.calibrate_profiles import interpolate_weights
    np.testing.assert_allclose(interpolate_weights(np.zeros(3), np.ones(3), 0.5, "slerp"), [0.5, 0.5, 0.5])
    np.testing.assert_allclose(interpolate_weights(np.ones(3), np.ones(3), 0.5, "slerp"), [1, 1, 1])
