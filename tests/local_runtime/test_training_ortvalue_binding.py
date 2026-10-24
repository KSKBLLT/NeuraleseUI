from __future__ import annotations

import numpy as np
import gc
import pytest

from neuralese_local.epoch_runner import (
    BoundBatchInputs,
    EpochRunner,
    OrtValueTrainingError,
    loss_scalar,
)


def test_bound_cpu_ortvalues_reuse_identity_and_observe_buffer_updates():
    x = np.zeros((4, 3), dtype=np.float32)
    y = np.zeros((4,), dtype=np.int64)
    bindings = BoundBatchInputs()

    first_x, first_y = bindings.bind(x, y)
    x[:] = 7.0
    y[:] = 2
    second_x, second_y = bindings.bind(x, y)

    assert first_x is second_x
    assert first_y is second_y
    np.testing.assert_array_equal(second_x.numpy(), x)
    np.testing.assert_array_equal(second_y.numpy(), y)


def test_loss_scalar_converts_only_the_requested_ortvalue():
    x = np.asarray([3.25], dtype=np.float32)
    value, _ = BoundBatchInputs().bind(x, np.asarray([0], dtype=np.int64))

    assert loss_scalar(value) == 3.25


@pytest.mark.parametrize("size, expected_bindings", [(128, 2), (129, 4), (300, 6)])
def test_full_and_tail_shapes_get_distinct_reusable_bindings(size, expected_bindings):
    x = np.zeros((size, 4), dtype=np.float32)
    y = np.zeros((size,), dtype=np.int64)
    bindings = BoundBatchInputs()
    for start in range(0, size, 128):
        bindings.bind(x[start : start + 128], y[start : start + 128])
    first_count = bindings.cache_size
    for start in range(0, size, 128):
        bindings.bind(x[start : start + 128], y[start : start + 128])

    assert first_count == expected_bindings
    assert bindings.cache_size == expected_bindings


def test_binding_keeps_numpy_owner_alive():
    def create_binding():
        x = np.full((2, 3), 9.0, np.float32)
        y = np.asarray([1, 2], np.int64)
        return BoundBatchInputs(), x, y

    bindings, x, y = create_binding()
    value_x, value_y = bindings.bind(x, y)
    del x, y
    gc.collect()

    np.testing.assert_array_equal(value_x.numpy(), np.full((2, 3), 9.0, np.float32))
    np.testing.assert_array_equal(value_y.numpy(), [1, 2])
