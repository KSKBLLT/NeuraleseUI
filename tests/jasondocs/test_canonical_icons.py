from __future__ import annotations

from pathlib import Path
import tempfile
import unittest

from tools.jasondocs.godot_static import NodeInfo
from tools.jasondocs.jason_docs import load_json, sync_jasondocs, validate_docs, write_json


class CanonicalIconTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temp_dir = tempfile.TemporaryDirectory()
        self.root = Path(self.temp_dir.name)
        self.docs_root = self.root / "JasonDocs"
        self.schema = self.root / "node.schema.json"
        self.schema.write_text("{}\n", encoding="utf-8")
        self.node = NodeInfo(
            node_id="input",
            created_with="input",
            scene_path="res://scenes/input_graph.tscn",
            scene_uid=None,
            root_instance_path=None,
            script_path="res://scripts/input_graph.gd",
            inheritance_chain=[],
            inherits_graph=True,
            server_typename="InputNode",
            layer_name=None,
            title_candidates={"en": "Input2D", "ru": "Ввод2D", "kz": "Кіріс2D"},
            base_config={},
            ports=[],
            settings=[],
            icon_source="res://node_icons/IconInput.png",
        )
        target = self.root / "node_icons" / "IconInput.png"
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(b"icon:canonical")

    def tearDown(self) -> None:
        self.temp_dir.cleanup()

    def test_sync_copies_only_the_canonical_node_icon(self) -> None:
        sync_jasondocs(
            repo_root=self.root,
            docs_root=self.docs_root,
            nodes=[self.node],
            schema_source=self.schema,
        )

        node_root = self.docs_root / "input"
        self.assertEqual(
            (node_root / "icon.png").read_bytes(),
            b"icon:canonical",
        )
        self.assertEqual(list(node_root.glob("icon.*.png")), [])

    def test_validation_reports_a_missing_canonical_icon(self) -> None:
        sync_jasondocs(
            repo_root=self.root,
            docs_root=self.docs_root,
            nodes=[self.node],
            schema_source=self.schema,
        )
        (self.docs_root / "input" / "icon.png").unlink()

        messages = [issue.message for issue in validate_docs(
            self.docs_root,
            [self.node],
            strict_generated=True,
        )]

        self.assertIn("missing icon.png", messages)

    def test_unchanged_icons_are_not_copied_again(self) -> None:
        sync_jasondocs(self.root, self.docs_root, [self.node], self.schema)
        messages = sync_jasondocs(self.root, self.docs_root, [self.node], self.schema)

        self.assertTrue(any(message.startswith("unchanged input icon") for message in messages))

    def test_validation_requires_every_example_language(self) -> None:
        sync_jasondocs(
            repo_root=self.root,
            docs_root=self.docs_root,
            nodes=[self.node],
            schema_source=self.schema,
        )
        document_path = self.docs_root / "input" / "node.json"
        document = load_json(document_path)
        document["docs"]["examples"] = [
            {"body": {"en": "Example", "ru": "Пример", "kz": ""}},
        ]
        write_json(document_path, document)

        messages = [issue.message for issue in validate_docs(
            self.docs_root,
            [self.node],
            strict_generated=True,
        )]

        self.assertIn("docs.examples[0].body missing: kz", messages)


if __name__ == "__main__":
    unittest.main()
