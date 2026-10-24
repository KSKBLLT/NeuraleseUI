from __future__ import annotations

import hashlib
import json


ALGORITHM_VERSION = 2


def resolve_graph(graph: dict, profiles: dict, source_layers: int = 10) -> dict:
    graph = graph.get("mapping_graph", graph)
    nodes = {str(n["id"]): n for n in graph.get("nodes", [])}
    incoming = {key: [] for key in nodes}
    for edge in graph.get("edges", []):
        source, target = str(edge["from_node"]), str(edge["to_node"])
        if source not in nodes or target not in nodes:
            raise ValueError("Connection references a missing language node")
        incoming[target].append(source)
    stage, order = {}, []
    pending = sorted(nodes)
    while pending:
        ready = [key for key in pending if all(p in stage for p in incoming[key])]
        if not ready:
            raise ValueError("Language graph contains a cycle")
        for key in ready:
            stage[key] = max((stage[p] for p in incoming[key]), default=0) + (nodes[key]["op"] == "attention_head")
            pending.remove(key)
            order.append(key)
    requested = max(1, max(stage.values(), default=0))
    candidate = profiles.get(str(requested), {})
    use_profile = not 8 <= requested <= 12 and candidate.get("quality_passed") is True
    effective = int(candidate["layers"]) if use_profile else source_layers
    profile_id = str(candidate["id"]) if use_profile else "identity"
    mapping, heads_by_stage = {}, {}
    for key in order:
        if nodes[key]["op"] == "attention_head":
            heads_by_stage.setdefault(max(1, stage[key]), []).append(key)
    for siblings in heads_by_stage.values():
        siblings.sort(key=lambda key: (int(nodes[key].get("config", {}).get("head_index", 0)), key))
    for key in order:
        op = nodes[key]["op"]
        depth = max(1, stage[key])
        start = min(effective - 1, (depth - 1) * effective // requested)
        end = min(effective - 1, max(start, depth * effective // requested - 1))
        item = {"op": op, "stage": depth, "layer": end, "layers": list(range(start, end + 1))}
        if op == "attention_head":
            item["head"] = heads_by_stage[depth].index(key) % 4
        mapping[key] = item
    canonical = {
        "version": ALGORITHM_VERSION,
        "source_hash": profiles.get("source_hash", ""),
        "profile": profile_id,
        "nodes": [{"id": key, "op": nodes[key]["op"], "config": {k: v for k, v in nodes[key].get("config", {}).items() if k not in {"position", "width", "title"}}} for key in sorted(nodes)],
        "edges": sorted((str(e["from_node"]), str(e.get("from_port", "")), str(e["to_node"]), str(e.get("to_port", ""))) for e in graph.get("edges", [])),
    }
    cache_key = hashlib.sha256(json.dumps(canonical, sort_keys=True, ensure_ascii=False).encode()).hexdigest()
    return {"node_mapping": mapping, "requested_depth": requested, "effective_depth": effective, "profile_id": profile_id, "cache_key": cache_key}
