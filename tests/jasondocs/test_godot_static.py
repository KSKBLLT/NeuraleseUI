from __future__ import annotations

import unittest

from tools.jasondocs.godot_static import SceneNode, GodotStaticAnalyzer
from pathlib import Path


class GodotStaticTests(unittest.TestCase):
    def test_nested_text_input_inherits_the_shared_input_graph(self) -> None:
        nodes = {node.node_id: node for node in GodotStaticAnalyzer(Path(__file__).resolve().parents[2]).scan()}
        text_input = nodes["text_input"]
        self.assertTrue(text_input.inherits_graph)
        self.assertIn("res://scripts/input_base.gd", text_input.inheritance_chain)
        self.assertIn("res://scripts/base_graph.gd", text_input.inheritance_chain)
        self.assertIn("res://scripts/input_base.gd", nodes["input"].inheritance_chain)
        text_port = next(port for port in text_input.ports if port.server_name == "text_out")
        image_port = next(port for port in nodes["input"].ports if port.server_name == "input_out")
        self.assertEqual(text_port.direction, "output")
        self.assertEqual(text_port.visual["color"], image_port.visual["color"])

    def test_language_compatibility_respects_domains(self) -> None:
        nodes = {node.node_id: node for node in GodotStaticAnalyzer(Path(__file__).resolve().parents[2]).scan()}
        embedding_targets = {item["to_node"] for item in nodes["embedding"].static_compatible_nodes}
        self.assertIn("attention_head", embedding_targets)
        self.assertIn("layer", embedding_targets)
        self.assertNotIn("gru_cell", embedding_targets)
        self.assertNotIn("classifier", embedding_targets)
        self.assertNotIn("token_labels", embedding_targets)
        self.assertNotIn("token_labels", {item["to_node"] for item in nodes["attention_head"].static_compatible_nodes})
        self.assertIn("token_labels", {item["to_node"] for item in nodes["softmax"].static_compatible_nodes})
        self.assertNotIn("attention_head", {item["to_node"] for item in nodes["softmax"].static_compatible_nodes})
        self.assertNotIn("token_labels", {item["to_node"] for item in nodes["gru_cell"].static_compatible_nodes})

    def test_scene_property_distinguishes_null_from_the_string_null(self) -> None:
        node = SceneNode(
            name="Connection",
            parent=".",
            header="",
            attrs={},
            block='keyword = null\nlabel = "null"\n',
        )

        self.assertIsNone(node.prop("keyword"))
        self.assertEqual(node.prop("label"), "null")


if __name__ == "__main__":
    unittest.main()
