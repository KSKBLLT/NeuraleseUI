from __future__ import annotations

import json
from pathlib import Path
from typing import Any

from .jason_docs import load_json


RUNTIME_SCHEMA_VERSION = 1
GENERATED_FIELDS = (
    "node_id",
    "title_candidates",
    "localized_properties",
    "ports",
    "settings",
    "static_compatible_nodes",
)


def build_runtime_catalog(docs_root: Path, allowed_node_ids: set[str] | None = None) -> dict[str, Any]:
    nodes: dict[str, Any] = {}
    for child in sorted(docs_root.iterdir(), key=lambda path: path.name):
        source = child / "node.json"
        if not source.is_file():
            continue
        document = load_json(source)
        node_id = str(document["node_id"])
        if allowed_node_ids is not None and node_id not in allowed_node_ids:
            continue
        generated = document.get("generated", {})
        nodes[node_id] = {
            "status": document.get("status", "stable"),
            "generated": {
                field: generated.get(field, [] if field in ("ports", "settings", "static_compatible_nodes") else {})
                for field in GENERATED_FIELDS
            },
            "docs": document.get("docs", {}),
        }
    return {"schema_version": RUNTIME_SCHEMA_VERSION, "nodes": nodes}


def runtime_catalog_bytes(docs_root: Path, allowed_node_ids: set[str] | None = None) -> bytes:
    text = json.dumps(build_runtime_catalog(docs_root, allowed_node_ids), ensure_ascii=False, indent=2) + "\n"
    return text.encode("utf-8")


def write_runtime_catalog(docs_root: Path, target: Path, allowed_node_ids: set[str] | None = None) -> None:
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(runtime_catalog_bytes(docs_root, allowed_node_ids))


def runtime_catalog_is_current(docs_root: Path, target: Path, allowed_node_ids: set[str] | None = None) -> bool:
    if not target.is_file():
        return False
    return target.read_bytes() == runtime_catalog_bytes(docs_root, allowed_node_ids)
