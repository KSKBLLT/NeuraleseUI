from __future__ import annotations

import json
from pathlib import Path
import tempfile
import unittest

from tools.jasondocs.runtime_catalog import (
    build_runtime_catalog,
    runtime_catalog_is_current,
    write_runtime_catalog,
)


class RuntimeCatalogTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.docs_root = self.root / "JasonDocs"
        self.target = self.root / "resources" / "node_info_catalog.json"
        self._write_node("run_model", "RunModel", "Запуск модели")
        self._write_node("input", "Input2D", "Ввод2D")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def _write_node(self, node_id: str, title_en: str, title_ru: str) -> None:
        target = self.docs_root / node_id / "node.json"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(
            json.dumps(
                {
                    "schema_version": 1,
                    "node_id": node_id,
                    "status": "stable",
                    "generated": {
                        "node_id": node_id,
                        "scene_path": f"res://scenes/{node_id}.tscn",
                        "title_candidates": {
                            "en": title_en,
                            "ru": title_ru,
                            "kz": title_en,
                        },
                        "ports": [{"id": "output", "direction": "output"}],
                        "settings": [{"id": "value", "default": 1}],
                        "static_compatible_nodes": [
                            {
                                "from_port": "output",
                                "to_node": "run_model",
                                "to_port": "input",
                                "datatypes": ["input2d"],
                                "confidence": "static_datatype_intersection",
                            }
                        ],
                    },
                    "docs": {
                        "title": {"en": title_en, "ru": title_ru, "kz": title_en},
                        "summary": {"en": "Summary", "ru": "Описание", "kz": "Сипаттама"},
                        "operation": {"en": "Operation", "ru": "Работа", "kz": "Жұмыс"},
                        "compact": {"body": {"en": "Short", "ru": "Кратко", "kz": "Қысқа"}},
                        "ports": {},
                        "settings": {},
                    },
                },
                ensure_ascii=False,
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )

    def test_builds_compact_catalog_from_jasondocs(self) -> None:
        catalog = build_runtime_catalog(self.docs_root)

        self.assertEqual(catalog["schema_version"], 1)
        self.assertEqual(list(catalog["nodes"]), ["input", "run_model"])
        self.assertEqual(catalog["nodes"]["input"]["docs"]["title"]["ru"], "Ввод2D")
        self.assertEqual(catalog["nodes"]["input"]["generated"]["ports"][0]["id"], "output")
        self.assertEqual(
            catalog["nodes"]["input"]["generated"]["static_compatible_nodes"][0]["to_node"],
            "run_model",
        )
        self.assertNotIn("scene_path", catalog["nodes"]["input"]["generated"])

    def test_can_filter_preserved_inactive_docs(self) -> None:
        catalog = build_runtime_catalog(self.docs_root, {"input"})

        self.assertEqual(list(catalog["nodes"]), ["input"])

    def test_written_catalog_is_deterministic_and_current(self) -> None:
        write_runtime_catalog(self.docs_root, self.target)
        first = self.target.read_bytes()
        write_runtime_catalog(self.docs_root, self.target)

        self.assertEqual(self.target.read_bytes(), first)
        self.assertTrue(runtime_catalog_is_current(self.docs_root, self.target))

    def test_reports_missing_or_stale_runtime_catalog(self) -> None:
        self.assertFalse(runtime_catalog_is_current(self.docs_root, self.target))
        self.target.parent.mkdir(parents=True, exist_ok=True)
        self.target.write_text("{}\n", encoding="utf-8")

        self.assertFalse(runtime_catalog_is_current(self.docs_root, self.target))


if __name__ == "__main__":
    unittest.main()
