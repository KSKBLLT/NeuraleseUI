from __future__ import annotations

import json

import numpy as np

from neuralese_local.dataset_store import ArrayDataset
from neuralese_local.training_dataset_cache import TrainingDatasetCache


def _write_builtin(runtime_root, name="tiny"):
    base = runtime_root / "datasets" / name
    base.mkdir(parents=True)
    np.save(base / "train_x.npy", np.arange(12, dtype=np.float32).reshape(4, 3))
    np.save(base / "train_y.npy", np.arange(4, dtype=np.int64))
    return base


def _write_user(path, rows):
    path.write_text(
        json.dumps({
            "name": "custom",
            "x": [[float(value), float(value + 1)] for value in range(rows)],
            "y": list(range(rows)),
        }),
        encoding="utf-8",
    )


def test_warm_builtins_keeps_dataset_identity(tmp_path):
    _write_builtin(tmp_path)
    cache = TrainingDatasetCache(tmp_path)

    warmed = cache.warm_builtins()
    first = cache.get({"kind": "builtin_numpy", "name": "tiny"})
    second = cache.get({"kind": "builtin_numpy", "name": "tiny"})

    assert warmed == {"tiny": first}
    assert first is second


def test_user_dataset_is_cached_and_invalidated_by_file_state(tmp_path):
    path = tmp_path / "dataset.json"
    _write_user(path, 2)
    cache = TrainingDatasetCache(tmp_path)
    dataset_ref = {
        "kind": "godot_json",
        "name": "custom",
        "path": str(path),
        "revision": "7",
    }

    first = cache.get(dataset_ref)
    second = cache.get(dataset_ref)
    assert first is second

    _write_user(path, 3)
    third = cache.get(dataset_ref)

    assert third is not first
    assert len(third) == 3


def test_user_revision_invalidates_unchanged_file(tmp_path):
    path = tmp_path / "dataset.json"
    _write_user(path, 2)
    cache = TrainingDatasetCache(tmp_path)

    first = cache.get({"kind": "godot_json", "path": str(path), "revision": "1"})
    second = cache.get({"kind": "godot_json", "path": str(path), "revision": "2"})

    assert second is not first


def test_user_lru_respects_byte_budget(tmp_path):
    first_path = tmp_path / "first.json"
    second_path = tmp_path / "second.json"
    _write_user(first_path, 2)
    _write_user(second_path, 2)
    cache = TrainingDatasetCache(tmp_path, user_budget_bytes=40)

    first = cache.get({"kind": "godot_json", "path": str(first_path)})
    cache.get({"kind": "godot_json", "path": str(second_path)})
    reloaded = cache.get({"kind": "godot_json", "path": str(first_path)})

    assert reloaded is not first


def test_batch_indices_normalizes_lazy_uint8_into_reusable_buffer():
    source = np.array([[0, 255], [64, 128], [10, 20]], dtype=np.uint8)
    dataset = ArrayDataset(
        name="images",
        x=source,
        y=np.array([0, 1, 2]),
        materialize_x=False,
        x_scale=1.0 / 255.0,
    )
    out_x = np.empty((2, 2), dtype=np.float32)
    out_y = np.empty((2,), dtype=np.int64)

    batch_x, batch_y = dataset.batch_indices(np.array([1, 0]), out_x=out_x, out_y=out_y)

    assert dataset.x.dtype == np.uint8
    assert batch_x is out_x
    assert batch_y is out_y
    np.testing.assert_allclose(batch_x, [[64 / 255, 128 / 255], [0, 1]])
    np.testing.assert_array_equal(batch_y, [1, 0])


def test_materialized_dataset_applies_scale_only_once():
    dataset = ArrayDataset(
        name="materialized",
        x=np.array([[255]], dtype=np.uint8),
        y=np.array([1]),
        x_scale=1.0 / 255.0,
    )

    batch_x, _ = dataset.batch_indices(np.array([0]))

    np.testing.assert_allclose(dataset.x, [[1.0]])
    np.testing.assert_allclose(batch_x, [[1.0]])
