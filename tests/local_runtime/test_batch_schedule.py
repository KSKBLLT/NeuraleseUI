from __future__ import annotations

import numpy as np

import pytest

from neuralese_local.batch_schedule import (
    BatchSlice,
    PrePermutedEpochBuffer,
    descriptor_indices,
    make_schedule,
    select_schedule_policy,
)
from neuralese_local.dataset_store import ArrayDataset


def test_array_dataset_batch_view_is_zero_copy_for_materialized_arrays():
    dataset = ArrayDataset(
        "table",
        np.arange(24, dtype=np.float32).reshape(6, 4),
        np.arange(6, dtype=np.int64),
    )

    batch_x, batch_y = dataset.batch_view(1, 4)

    assert np.shares_memory(batch_x, dataset.x)
    assert np.shares_memory(batch_y, dataset.y)
    np.testing.assert_array_equal(batch_y, [1, 2, 3])


def test_prepermuted_epoch_buffer_gathers_once_then_returns_contiguous_views():
    dataset = ArrayDataset(
        "table",
        np.arange(40, dtype=np.float32).reshape(10, 4),
        np.arange(10, dtype=np.int64),
    )
    order = np.asarray([9, 0, 7, 1, 6, 2, 5, 3, 8, 4], dtype=np.int64)
    buffer = PrePermutedEpochBuffer(dataset, batch_size=4)

    buffer.prepare(order)
    batches = list(buffer.batches())

    assert [len(y) for _, y in batches] == [4, 4, 2]
    np.testing.assert_array_equal(np.concatenate([y for _, y in batches]), order)
    assert all(x.flags.c_contiguous for x, _ in batches)
    assert all(np.shares_memory(x, buffer.x) for x, _ in batches)


@pytest.mark.parametrize("policy", ["exact", "blocks", "prepermuted"])
@pytest.mark.parametrize("size", [1, 127, 128, 129, 60_000])
def test_schedule_invariants_cover_every_sample_once(policy, size):
    schedule = make_schedule(policy, size, 128)
    descriptors = schedule.descriptors(np.random.default_rng(11))
    values = np.concatenate([descriptor_indices(item) for item in descriptors])

    assert len(values) == size
    assert sorted(values.tolist()) == list(range(size))
    assert len(set(values.tolist())) == size
    assert all(0 < len(descriptor_indices(item)) <= 128 for item in descriptors)


@pytest.mark.parametrize("policy", ["exact", "blocks", "prepermuted"])
def test_schedule_seed_is_reproducible_and_epoch_order_changes(policy):
    schedule = make_schedule(policy, 1025, 128)
    first_rng = np.random.default_rng(7)
    second_rng = np.random.default_rng(7)
    first = [descriptor_indices(item).tolist() for item in schedule.descriptors(first_rng)]
    repeated = [descriptor_indices(item).tolist() for item in schedule.descriptors(second_rng)]
    next_epoch = [descriptor_indices(item).tolist() for item in schedule.descriptors(first_rng)]

    assert first == repeated
    assert first != next_epoch


def test_auto_schedule_uses_shape_not_dataset_name():
    images = ArrayDataset("renamed", np.zeros((1024, 512), np.float32), np.zeros(1024, np.int64))
    same_images = ArrayDataset("mnist", images.x.copy(), images.y.copy())
    table = ArrayDataset("images", np.zeros((1024, 8), np.float32), np.zeros(1024, np.int64))

    assert select_schedule_policy(images, 64) == "blocks"
    assert select_schedule_policy(same_images, 64) == "blocks"
    assert select_schedule_policy(table, 64) == "prepermuted"


def test_lazy_scaled_dataset_rejects_view_but_indexed_batch_normalizes():
    dataset = ArrayDataset(
        "lazy",
        np.arange(16, dtype=np.uint8).reshape(4, 4),
        np.arange(4, dtype=np.int64),
        materialize_x=False,
        x_scale=1.0 / 255.0,
    )
    out_x = np.empty((2, 4), np.float32)
    out_y = np.empty((2,), np.int64)

    with pytest.raises(ValueError, match="zero-copy"):
        dataset.batch_view(0, 2)
    x, y = dataset.batch_indices(np.asarray([3, 1]), out_x, out_y)
    np.testing.assert_allclose(x, dataset.x[[3, 1]].astype(np.float32) / 255.0)
    np.testing.assert_array_equal(y, [3, 1])
