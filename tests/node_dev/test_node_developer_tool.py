from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from tools.jasondocs.godot_static import GodotStaticAnalyzer
from tools.node_dev.cli import build_parser, cmd_godot_check
from tools.node_dev.generator import render_godot_sources, stale_outputs
from tools.node_dev.model import NodeDefinition, NodeDefinitionError
from tools.node_dev.registry import NodeRegistry


REPO_ROOT = Path(__file__).resolve().parents[2]
EXPECTED_PUBLIC_ORDER = [
    "input",
    "input_rgb",
    "input_1d",
    "classifier",
    "flatten",
    "reshape2d",
    "softmax",
    "layer",
    "conv2d",
    "maxpool",
    "dropout",
    "neuron",
    "gru_cell",
    "dataset",
    "train_begin",
    "run_model",
    "train_input",
    "concat",
    "text_input",
    "tokenizer",
    "embedding",
    "attention_head",
    "token_labels",
    "autoregression",
]


class NodeDeveloperToolIntegrationTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.registry = NodeRegistry(REPO_ROOT)
        cls.nodes = cls.registry.resolve()

    def test_all_current_nodes_have_one_definition(self) -> None:
        self.assertEqual(len(self.nodes), 28)
        self.assertEqual(len({node.id for node in self.nodes}), len(self.nodes))
        self.assertNotIn("output_map", {node.id for node in self.nodes})

    def test_public_menu_order_is_compiled_from_definitions(self) -> None:
        self.assertEqual(
            [node.id for node in self.registry.public_nodes()],
            EXPECTED_PUBLIC_ORDER,
        )

    def test_jasondocs_uses_the_same_public_catalog(self) -> None:
        analyzer = GodotStaticAnalyzer(REPO_ROOT)
        graph_types = analyzer.graph_types()

        self.assertEqual(analyzer.creation_type_ids(graph_types), EXPECTED_PUBLIC_ORDER)
        self.assertNotIn("activation_node", graph_types)
        self.assertNotIn("augment_tf", analyzer.creation_type_ids(graph_types))

    def test_generated_artifacts_are_current(self) -> None:
        self.assertEqual(stale_outputs(self.registry), [])

    def test_development_catalog_reuses_scene_contracts(self) -> None:
        by_id = {node.id: node for node in self.nodes}
        conv = by_id["conv2d"].development_dict()["resolved"]
        dense = by_id["layer"].development_dict()["resolved"]

        self.assertIn("_get_unit", dense["script_hooks"])
        self.assertGreaterEqual(len(conv["ports"]), 2)
        self.assertIn("filter", {item["name"] for item in conv["scene_nodes"]})
        self.assertIn("res://scenes/Connection.tscn", conv["scene_components"])

    def test_core_has_no_second_node_registry(self) -> None:
        graph_manager = (REPO_ROOT / "scripts" / "graph_manager.gd").read_text(encoding="utf-8")
        project = (REPO_ROOT / "scripts" / "project.gd").read_text(encoding="utf-8")
        project_scene = (REPO_ROOT / "scenes" / "project.tscn").read_text(encoding="utf-8")
        project_settings = (REPO_ROOT / "project.godot").read_text(encoding="utf-8")
        node_sources = (REPO_ROOT / "scripts" / "generated" / "node_sources.gd").read_text(encoding="utf-8")
        menus = (REPO_ROOT / "scenes" / "menus.tscn").read_text(encoding="utf-8")

        self.assertNotIn("func gload(", graph_manager)
        self.assertNotIn("var graph_types = {", graph_manager)
        self.assertNotIn("res://scenes/input_graph.tscn", project)

        self.assertIn('path="res://scripts/generated/node_sources.gd"', project_scene)
        self.assertNotIn("node_sources", project_settings)
        self.assertIn('extends "res://scripts/project.gd"', node_sources)
        self.assertIn("preload(", node_sources)
        self.assertNotIn(" := load(", node_sources)
        self.assertNotIn("warm_up", node_sources)
        self.assertIn('"--node-dev-validate"', node_sources)
        self.assertIn("func instantiate_node(type_id: StringName)", node_sources)
        self.assertIn("glob.base_node.instantiate_node(type_id)", graph_manager)

    def test_godot_validation_is_an_explicit_development_command(self) -> None:
        args = build_parser().parse_args(["godot-check", "--godot-bin", "godot.exe"])

        self.assertEqual(args.command, "godot-check")
        self.assertEqual(args.godot_bin, "godot.exe")

    def test_godot_validation_uses_a_dedicated_headless_script(self) -> None:
        args = build_parser().parse_args([
            "godot-check",
            "--godot-bin",
            sys.executable,
        ])
        completed = subprocess.CompletedProcess(
            args=[],
            returncode=0,
            stdout=f"NODE_DEV_SOURCES_OK: {len(self.nodes)}\n",
        )

        with patch("tools.node_dev.cli.subprocess.run", return_value=completed) as run:
            self.assertEqual(cmd_godot_check(args), 0)

        command = run.call_args.args[0]
        self.assertIn("--script", command)
        validator = command[command.index("--script") + 1]
        validator_parts = Path(validator).parts
        self.assertEqual(validator_parts[-3:], ("tools", "node_dev", "godot_validate.gd"))
        self.assertNotIn("--node-dev-validate", command)

    def test_jasondocs_does_not_silently_accept_a_partial_registry(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            definitions = Path(temp_dir) / "node_defs"
            definitions.mkdir()
            (definitions / "broken.json").write_text("{", encoding="utf-8")

            with self.assertRaisesRegex(ValueError, "invalid node definition"):
                GodotStaticAnalyzer(Path(temp_dir)).graph_types()


class NodeDefinitionValidationTests(unittest.TestCase):
    def _valid_definition(self) -> dict:
        return {
            "schema_version": 1,
            "id": "future_node",
            "source": {"kind": "scene", "path": "res://scenes/future_node.tscn"},
            "load_order": 200,
            "menu": {"visible": False, "section": "other", "order": 200},
        }

    def test_unknown_fields_fail_loudly(self) -> None:
        raw = self._valid_definition()
        raw["menu"]["visble"] = True

        with self.assertRaisesRegex(NodeDefinitionError, "unknown field"):
            NodeDefinition.from_dict(raw)

    def test_required_fields_cannot_fall_back_silently(self) -> None:
        raw = self._valid_definition()
        del raw["menu"]

        with self.assertRaisesRegex(NodeDefinitionError, "missing required field.*menu"):
            NodeDefinition.from_dict(raw)

    def test_source_kind_requires_the_right_extension(self) -> None:
        raw = self._valid_definition()
        raw["source"] = {"kind": "provider", "path": "res://scripts/provider.tscn"}

        with self.assertRaisesRegex(NodeDefinitionError, "must end with .gd"):
            NodeDefinition.from_dict(raw)

    def test_duplicate_aliases_fail_loudly(self) -> None:
        raw = self._valid_definition()
        raw["llm"] = {"type": "future", "aliases": ["future", "future"]}

        with self.assertRaisesRegex(NodeDefinitionError, "must not contain duplicates"):
            NodeDefinition.from_dict(raw)

    def test_programmatic_provider_is_statically_compiled(self) -> None:
        with tempfile.TemporaryDirectory() as temp_dir:
            root = Path(temp_dir)
            provider_path = root / "scripts" / "providers" / "future_node.gd"
            provider_path.parent.mkdir(parents=True)
            provider_path.write_text(
                "extends RefCounted\n\n"
                "func instantiate_node(_definition: Dictionary) -> Graph:\n"
                "\treturn null\n",
                encoding="utf-8",
            )
            definitions_dir = root / "node_defs"
            definitions_dir.mkdir()
            definition = self._valid_definition()
            definition["source"] = {
                "kind": "provider",
                "path": "res://scripts/providers/future_node.gd",
            }
            definition["display"] = {
                "title": {"en": "Future", "ru": "Будущая", "kz": "Болашақ"}
            }
            (definitions_dir / "future_node.json").write_text(
                json.dumps(definition, ensure_ascii=False),
                encoding="utf-8",
            )

            nodes = NodeRegistry(root).resolve()
            generated = render_godot_sources(nodes)

            self.assertEqual([node.id for node in nodes], ["future_node"])
            self.assertIn('preload("res://scripts/providers/future_node.gd")', generated)
            self.assertNotIn(" := load(", generated)
            self.assertIn("func instantiate_node(type_id: StringName)", generated)
            self.assertIn("provider.instantiate_node", generated)
            self.assertNotIn("const NodeCatalog =", generated)
            self.assertIn("func _enter_tree()", generated)


if __name__ == "__main__":
    unittest.main()
