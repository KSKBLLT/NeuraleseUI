from __future__ import annotations

import tempfile
import unittest
from pathlib import Path

from neuralese_local.train_task import _save_required_checkpoint


class _CheckpointStateApi:
    should_write = True
    should_raise = False

    @classmethod
    def save_checkpoint(cls, _state, path: str, _include_optimizer: bool) -> None:
        if cls.should_raise:
            raise RuntimeError("checkpoint backend failed")
        if cls.should_write:
            Path(path).write_bytes(b"checkpoint")


class _TrainingApi:
    CheckpointState = _CheckpointStateApi


class CheckpointContractTests(unittest.TestCase):
    def setUp(self) -> None:
        _CheckpointStateApi.should_write = True
        _CheckpointStateApi.should_raise = False

    def test_required_checkpoint_is_saved(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            checkpoint_path = _save_required_checkpoint(
                _TrainingApi,
                object(),
                Path(directory),
            )

            self.assertEqual(checkpoint_path, Path(directory) / "checkpoint")
            self.assertTrue(checkpoint_path.is_file())

    def test_backend_failure_is_not_swallowed(self) -> None:
        _CheckpointStateApi.should_raise = True
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "checkpoint backend failed"):
                _save_required_checkpoint(_TrainingApi, object(), Path(directory))

    def test_missing_checkpoint_file_is_an_error(self) -> None:
        _CheckpointStateApi.should_write = False
        with tempfile.TemporaryDirectory() as directory:
            with self.assertRaisesRegex(RuntimeError, "did not create"):
                _save_required_checkpoint(_TrainingApi, object(), Path(directory))


if __name__ == "__main__":
    unittest.main()
