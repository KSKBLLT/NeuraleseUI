from __future__ import annotations

from pathlib import Path
import unittest

from tools.jasondocs.godot_static import GodotStaticAnalyzer


REPO_ROOT = Path(__file__).resolve().parents[2]


class GodotStaticCatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.analyzer = GodotStaticAnalyzer(REPO_ROOT)
        cls.nodes = cls.analyzer.scan()
        cls.by_id = {node.node_id: node for node in cls.nodes}

    def test_scan_uses_add_menu_catalog(self) -> None:
        node_ids = [node.node_id for node in self.nodes]

        self.assertIn("input", node_ids)
        self.assertIn("conv2d", node_ids)
        self.assertNotIn("augment_tf", node_ids)
        self.assertNotIn("train_rl", node_ids)
        self.assertNotIn("lua_env", node_ids)
        self.assertNotIn("model_name", node_ids)

    def test_static_compatibility_only_references_catalog_nodes(self) -> None:
        known = set(self.by_id)

        for node in self.nodes:
            for edge in node.static_compatible_nodes:
                self.assertIn(edge["to_node"], known)

    def test_port_visuals_include_color_and_relative_position(self) -> None:
        conv = self.by_id["conv2d"]
        port = next(port for port in conv.ports if port.id == "input_ni_layer_in")

        self.assertEqual(port.visual["gradient_color"], "#e6b175ff")
        self.assertEqual(port.visual["side"], "left")
        self.assertEqual(port.visual["verbal_label"]["ru"], "\u041e\u0440\u0430\u043d\u0436\u0435\u0432\u044b\u0439 \u043f\u043e\u0440\u0442 \u0441\u043b\u0435\u0432\u0430")
        self.assertGreaterEqual(len(port.visual["text_color"]), 7)
        self.assertEqual(port.visual["relative_to"]["role"], "graph_rect")
        self.assertEqual(port.visual["relative_to"]["scene_path"], "ColorRect")
        self.assertIn("relative_rect", port.visual)
        self.assertIn("relative_origin", port.visual)
        self.assertLess(port.visual["relative_origin"]["x"], 0.0)

    def test_hidden_scene_connections_are_not_documented(self) -> None:
        for node_id in ("input", "input_1d"):
            port_ids = {port.id for port in self.by_id[node_id].ports}
            self.assertNotIn("input_o2_runmodel", port_ids)

    def test_loc_children_export_parent_localizations(self) -> None:
        conv = self.by_id["conv2d"]
        localized = conv.localized_properties

        self.assertEqual(localized["title"]["values"]["en"], "Conv2D")
        self.assertEqual(localized["title"]["values"]["ru"], "\u0421\u0432\u0451\u0440\u04422D")
        self.assertEqual(localized["controls"]["Label"]["values"]["en"], "Window")
        self.assertEqual(localized["controls"]["Label"]["values"]["ru"], "\u041a\u0435\u0440\u043d\u0435\u043b")

    def test_line_edit_loc_uses_placeholder_text(self) -> None:
        localized = self.by_id["input_1d"].localized_properties["controls"]["input/LineEdit"]

        self.assertEqual(localized["property"], "placeholder_text")
        self.assertEqual(localized["values"]["kz"], "\u0411\u0435\u043b\u0433\u0456 \u0430\u0442\u0430\u0443\u044b")

    def test_graph_rect_inherits_unoverridden_geometry(self) -> None:
        layer = self.by_id["layer"]
        port = next(port for port in layer.ports if port.id == "input_ni_layer_in")

        self.assertEqual(port.visual["reference_rect"]["y"], -64.0)
        self.assertGreater(port.visual["reference_rect"]["h"], 0.0)

    def test_input_to_conv2d_compatibility_remains(self) -> None:
        input_node = self.by_id["input"]

        self.assertTrue(
            any(edge["to_node"] == "conv2d" for edge in input_node.static_compatible_nodes)
        )


if __name__ == "__main__":
    unittest.main()
