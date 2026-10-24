from __future__ import annotations

from types import SimpleNamespace

import numpy as np

from neuralese_local.training_acceleration import (
    SelectiveBlockPolicy,
    algorithmic_acceleration_eligible,
    freeze_schedule,
    parameter_groups,
)


def _model():
    nodes = [
        SimpleNamespace(name="dense_hidden", input=["input", "w_hidden", "b_hidden"]),
        SimpleNamespace(name="dense_output", input=["hidden", "w_output", "b_output"]),
    ]
    return SimpleNamespace(graph=SimpleNamespace(node=nodes))


def test_parameter_groups_follow_forward_layer_order_and_keep_weights_with_biases():
    groups = parameter_groups(
        _model(),
        ["w_output", "b_hidden", "w_hidden", "b_output"],
    )

    assert groups == [
        ("w_hidden", "b_hidden"),
        ("w_output", "b_output"),
    ]


def test_parameter_groups_keep_all_gru_parameters_in_one_layer():
    params = [
        "gru_w_zr_memory",
        "gru_u_zr_memory",
        "gru_b_zr_memory",
        "gru_w_n_memory",
        "gru_u_n_memory",
        "gru_b_n_memory",
    ]
    model = SimpleNamespace(
        graph=SimpleNamespace(
            node=[SimpleNamespace(name="gru_memory", input=["input", *params])]
        )
    )

    assert parameter_groups(model, list(reversed(params))) == [tuple(params)]


def test_freeze_schedule_uses_full_suffix_and_head_without_duplicate_stages():
    groups = [
        ("w_first", "b_first"),
        ("w_second", "b_second"),
        ("w_output", "b_output"),
    ]

    stages = freeze_schedule(groups, epochs=10)

    assert [(stage.name, stage.start_epoch, stage.trainable_params) for stage in stages] == [
        (
            "full",
            0,
            ("w_first", "b_first", "w_second", "b_second", "w_output", "b_output"),
        ),
        ("suffix2", 4, ("w_second", "b_second", "w_output", "b_output")),
        ("head", 8, ("w_output", "b_output")),
    ]


def test_freeze_schedule_for_two_layers_switches_directly_to_head():
    stages = freeze_schedule([("w_hidden", "b_hidden"), ("w_out", "b_out")], epochs=5)

    assert [(stage.name, stage.start_epoch) for stage in stages] == [
        ("full", 0),
        ("head", 2),
    ]


def test_deep_models_freeze_layers_front_to_back():
    # FreezeOut-style: the first layer (the dearest to train) stops first, not
    # before epoch 2; the head learns alone from 75% as with shallow models.
    groups = [(f"w_{index}", f"b_{index}") for index in range(5)]

    stages = freeze_schedule(groups, epochs=10)

    assert [(stage.name, stage.start_epoch, len(stage.trainable_params) // 2) for stage in stages] == [
        ("full", 0, 5),
        ("prefix1", 2, 4),
        ("prefix2", 4, 3),
        ("prefix3", 6, 2),
        ("head", 8, 1),
    ]
    assert stages[1].trainable_params[:2] == ("w_1", "b_1")
    shallow = [("w_0",), ("w_1",), ("w_2",)]
    assert [stage.name for stage in freeze_schedule(shallow, epochs=10)] == ["full", "suffix2", "head"]
    assert [stage.name for stage in freeze_schedule(groups, epochs=10, mode="suffix")] == ["full", "suffix2", "head"]


def test_selective_policy_trains_blocks_whose_loss_is_unknown():
    policy = SelectiveBlockPolicy(final_keep_fraction=0.5)
    losses = {block: float(block) for block in range(20)}
    losses[3] = float("nan")
    chosen = policy.select(3, 10, losses, np.random.default_rng(0))
    assert 3 in chosen and len(chosen) < 20
    nothing_known = {block: float("nan") for block in range(20)}
    assert policy.select(3, 10, nothing_known, np.random.default_rng(0)) == set(range(20))
    assert policy.keep_share(2, 10) == 0.8 and abs(policy.keep_share(8, 10) - 0.5) < 1e-9


def test_freeze_schedule_keeps_tiny_or_disabled_jobs_full():
    groups = [("w_hidden", "b_hidden"), ("w_out", "b_out")]

    assert [stage.name for stage in freeze_schedule(groups, epochs=3)] == ["full"]
    assert [stage.name for stage in freeze_schedule(groups, epochs=12, enabled=False)] == ["full"]


def test_algorithmic_acceleration_requires_enough_batches_to_repay_approximation():
    groups = [("w_hidden", "b_hidden"), ("w_out", "b_out")]

    assert not algorithmic_acceleration_eligible(
        groups, epochs=6, samples=712, batch_size=128
    )
    assert algorithmic_acceleration_eligible(
        groups, epochs=6, samples=1024, batch_size=128
    )


def test_selective_policy_keeps_hard_blocks_and_seeded_exploration():
    policy = SelectiveBlockPolicy()
    losses = {block: float(block) for block in range(10)}

    selected = policy.select(
        epoch=2,
        epochs=8,
        losses=losses,
        rng=np.random.default_rng(17),
    )
    repeated = policy.select(
        epoch=2,
        epochs=8,
        losses=losses,
        rng=np.random.default_rng(17),
    )

    assert selected == repeated
    assert len(selected) == 8
    assert {5, 6, 7, 8, 9}.issubset(selected)
    assert len(selected.intersection({0, 1, 2, 3, 4})) >= 1


def test_selective_policy_runs_warmup_refresh_and_final_epochs_in_full():
    policy = SelectiveBlockPolicy()
    losses = {block: float(block) for block in range(10)}
    all_blocks = set(losses)

    assert policy.select(0, 8, losses, np.random.default_rng(1)) == all_blocks
    assert policy.select(1, 8, losses, np.random.default_rng(1)) == all_blocks
    assert policy.select(4, 8, losses, np.random.default_rng(1)) == all_blocks
    assert policy.select(7, 8, losses, np.random.default_rng(1)) == all_blocks


def test_selective_policy_does_not_select_without_complete_warmup_scores():
    policy = SelectiveBlockPolicy()

    assert policy.select(2, 8, {0: 1.0}, np.random.default_rng(1)) == {0}
