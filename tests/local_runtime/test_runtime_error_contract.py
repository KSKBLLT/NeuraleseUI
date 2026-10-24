from __future__ import annotations

import unittest

from neuralese_local.runtime_errors import UserFacingRuntimeError, error_payload


class RuntimeErrorContractTests(unittest.TestCase):
    def test_domain_error_preserves_code_and_safe_details(self) -> None:
        error = UserFacingRuntimeError(
            "training_output_count_mismatch",
            "Dataset 'eco_ai' (training): class labels require 4 outputs, but the final layer has 3.",
            {"dataset": "eco_ai", "expected": 4, "actual": 3},
        )

        payload = error_payload(error, "training")

        self.assertEqual(payload["code"], "training_output_count_mismatch")
        self.assertEqual(payload["details"], {"dataset": "eco_ai", "expected": 4, "actual": 3})
        self.assertIn("final layer has 3", payload["technical_message"])
        self.assertNotIn("message", payload)

    def test_unknown_exception_is_generic_for_ui_but_keeps_diagnostics(self) -> None:
        payload = error_payload(
            RuntimeError("onnxruntime::training::api::Module::TrainStep failed at C:\\runtime\\module.cc:632"),
            "training",
        )

        self.assertEqual(payload["code"], "training_failed")
        self.assertEqual(payload["details"], {})
        self.assertIn("module.cc:632", payload["technical_message"])
        self.assertNotIn("module.cc:632", str(payload["details"]))

if __name__ == "__main__":
    unittest.main()
