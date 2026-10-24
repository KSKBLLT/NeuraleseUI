from __future__ import annotations

import json
import sys
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch


class InferenceLoopErrorTests(unittest.TestCase):
    def test_invalid_saved_model_returns_error_packet_instead_of_hanging(self) -> None:
        fake_ort = types.ModuleType("onnxruntime")

        def fail_to_open(_path, providers):
            raise RuntimeError("invalid ONNX protobuf at C:\\runtime\\session.cc:42")

        fake_ort.InferenceSession = fail_to_open
        fake_infer_once = types.ModuleType("neuralese_local.infer_once")
        fake_infer_once._extract_raw_values = lambda _request: []
        fake_infer_once._find_final_node_id = lambda _graph: "0"
        fake_infer_once._shape_input = lambda values, _shape: values
        with tempfile.TemporaryDirectory(prefix="neuralese_bad_model_") as directory:
            job_dir = Path(directory)
            bad_model = job_dir / "broken.onnx"
            bad_model.write_text("not an onnx model", encoding="utf-8")
            (job_dir / "control.json").write_text(
                json.dumps({"model_path": str(bad_model), "graph": {}, "output_node_id": "0"}),
                encoding="utf-8",
            )

            with patch.dict(sys.modules, {
                "onnxruntime": fake_ort,
                "neuralese_local.infer_once": fake_infer_once,
            }):
                sys.modules.pop("neuralese_local.infer_loop", None)
                from neuralese_local import infer_loop

                with patch.object(sys, "argv", ["infer_loop.py", str(job_dir)]):
                    exit_code = infer_loop.main()

            self.assertEqual(exit_code, 1)
            response = json.loads((job_dir / "response.json").read_text(encoding="utf-8"))
            self.assertEqual(response["phase"], "error")
            self.assertEqual(response["error"]["code"], "inference_failed")
            self.assertIn("technical_message", response["error"])
            self.assertNotIn("message", response["error"])


if __name__ == "__main__":
    unittest.main()
