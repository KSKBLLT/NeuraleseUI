from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def _walk(value, path="$"):
    if isinstance(value, dict):
        for key, child in value.items():
            yield from _walk(child, f"{path}.{key}")
    elif isinstance(value, list):
        for index, child in enumerate(value):
            yield from _walk(child, f"{path}[{index}]")
    elif isinstance(value, str):
        yield path, value


def test_runtime_catalog_contains_no_cp1251_utf8_mojibake() -> None:
    catalog = json.loads(
        (ROOT / "resources" / "node_info_catalog.json").read_text(encoding="utf-8")
    )
    broken = []
    for path, value in _walk(catalog):
        try:
            repaired = value.encode("cp1251").decode("utf-8")
        except (UnicodeEncodeError, UnicodeDecodeError):
            continue
        if repaired != value:
            broken.append((path, value, repaired))
    assert broken == []
