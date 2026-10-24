from __future__ import annotations

import json
from pathlib import Path
import unittest


ROOT = Path(__file__).resolve().parents[2]
PUBLIC_NODE_IDS = (
    "input",
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
    "augment_tf",
    "concat",
    "lua_env",
    "dataset",
    "model_name",
    "output_map",
    "train_begin",
    "run_model",
    "train_input",
    "train_rl",
)
FORBIDDEN_RUSSIAN_FRAGMENTS = (
    "данные типа ",
    "совместимым следующим узлам",
    "через вход ",
    "настроенные значения",
)


class PublicDocsContentTests(unittest.TestCase):
    def load_document(self, node_id: str) -> dict:
        path = ROOT / "JasonDocs" / node_id / "node.json"
        return json.loads(path.read_text(encoding="utf-8"))

    def test_public_nodes_have_complete_human_russian_copy(self) -> None:
        for node_id in PUBLIC_NODE_IDS:
            with self.subTest(node_id=node_id):
                docs = self.load_document(node_id)["docs"]
                required_text = (
                    docs["title"]["ru"],
                    docs["summary"]["ru"],
                    docs["operation"]["ru"],
                    docs["compact"]["body"]["ru"],
                )

                self.assertTrue(all(text.strip() for text in required_text))
                joined = " ".join(required_text).lower()
                self.assertFalse(
                    any(fragment in joined for fragment in FORBIDDEN_RUSSIAN_FRAGMENTS)
                )

                for section_name in ("ports", "settings"):
                    for item_id, item in docs[section_name].items():
                        self.assertTrue(
                            item["label"]["ru"].strip(),
                            f"{node_id} {section_name}.{item_id} has no Russian label",
                        )
                        self.assertTrue(
                            item["description"]["ru"].strip(),
                            f"{node_id} {section_name}.{item_id} has no Russian description",
                        )
                        description = item["description"]["ru"].lower()
                        self.assertFalse(
                            any(
                                fragment in description
                                for fragment in FORBIDDEN_RUSSIAN_FRAGMENTS
                            ),
                            f"{node_id} {section_name}.{item_id} uses generated wording",
                        )

                self.assertTrue(docs["examples"], f"{node_id} has no practical example")
                for example in docs["examples"]:
                    self.assertTrue(example["body"]["ru"].strip())

    def test_public_nodes_keep_generated_identity(self) -> None:
        for node_id in PUBLIC_NODE_IDS:
            with self.subTest(node_id=node_id):
                document = self.load_document(node_id)
                self.assertEqual(document["node_id"], node_id)
                self.assertEqual(document["generated"]["node_id"], node_id)
                self.assertTrue(document["generated"]["scene_path"].startswith("res://"))
                self.assertTrue(document["generated"]["icon_source"].startswith("res://"))


if __name__ == "__main__":
    unittest.main()
