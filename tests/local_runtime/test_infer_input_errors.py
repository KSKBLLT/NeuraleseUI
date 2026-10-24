from __future__ import annotations

import importlib
import sys
import types
import unittest
from unittest.mock import patch

from neuralese_local.runtime_errors import UserFacingRuntimeError


class _FakeArray:
    def __init__(self, values) -> None:
        self.values = list(values)
        self.size = len(self.values)

    def reshape(self, *_shape):
        return self


class InferenceInputErrorTests(unittest.TestCase):
    def test_input_mismatch_is_detected_before_onnx_runtime(self) -> None:
        fake_numpy = types.ModuleType("numpy")
        fake_numpy.float32 = "float32"
        fake_numpy.asarray = lambda values, dtype=None: _FakeArray(values)
        fake_numpy.prod = lambda dims: __import__("math").prod(dims)
        fake_ort = types.ModuleType("onnxruntime")

        with patch.dict(sys.modules, {"numpy": fake_numpy, "onnxruntime": fake_ort}):
            sys.modules.pop("neuralese_local.infer_once", None)
            infer_once = importlib.import_module("neuralese_local.infer_once")
            with self.assertRaises(UserFacingRuntimeError) as raised:
                infer_once._shape_input([0.0, 1.0, 2.0], [None, 4])

        self.assertEqual(raised.exception.code, "inference_input_shape_mismatch")
        self.assertEqual(raised.exception.details, {"expected": "4", "actual": 3})


if __name__ == "__main__":
    unittest.main()
