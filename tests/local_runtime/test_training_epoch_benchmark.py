from __future__ import annotations

from benchmark_training_epochs import (
    epoch_rows_from_events,
    execution_seed,
    interleaved_order,
    summarize,
)


def test_epoch_rows_contain_only_epoch_measurements_and_required_metadata():
    events = [
        {
            "phase": "state",
            "data": {
                "epoch": 1,
                "data": {
                    "epoch_seconds": 0.125,
                    "eval_seconds": 0.025,
                    "train_loss": 1.25,
                    "val_loss": 1.5,
                    "val_acc": 0.75,
                    "length": 4,
                    "available_batches": 5,
                    "coverage": 0.8,
                    "freeze_stage": "head",
                },
            },
        }
    ]
    metadata = {
        "scenario": "fake",
        "graph_fingerprint": "abc",
        "input_shape": [128, 4],
        "input_dtype": "float32",
        "target_shape": [128],
        "target_dtype": "int64",
        "batch_size": 128,
        "threads": 1,
        "python_version": "3.11",
        "numpy_version": "1.26",
        "ort_version": "1.19",
        "cpu": "test",
        "rss_mib": 42.0,
        "seed": 7,
        "configuration": "safe",
        "execution_index": 0,
        "algorithmic_acceleration": True,
    }

    rows = epoch_rows_from_events(events, metadata, discard_warmup=False)

    assert len(rows) == 1
    row = rows[0]
    for key in (
        "scenario", "graph_fingerprint", "input_shape", "input_dtype",
        "target_shape", "target_dtype", "epoch", "batches", "loss",
        "train_only_ms", "eval_ms", "batch_size", "threads",
        "python_version", "numpy_version", "ort_version", "cpu", "rss_mib",
        "available_batches", "coverage", "freeze_stage", "val_acc", "val_loss",
        "algorithmic_acceleration",
    ):
        assert key in row
    assert "prepare_ms" not in row
    assert "export_ms" not in row
    assert row["train_only_ms"] == 100.0
    assert row["coverage"] == 0.8
    assert row["freeze_stage"] == "head"


def test_summary_keeps_acceleration_cohorts_and_final_quality_separate():
    base = {
        "record_type": "epoch",
        "scenario": "fake",
        "configuration": "optimized",
        "session_option_variant": "safe",
        "responsiveness_max_gap_ms": 1.0,
        "train_cpu_ms": 9.0,
        "eval_ms": 0.0,
        "evaluated": False,
        "available_batches": 10,
        "freeze_stage": "full",
    }
    rows = []
    for acceleration, train_ms, val_acc, val_loss, coverage in (
        (False, 10.0, 0.80, 0.50, 1.0),
        (True, 7.0, 0.76, 0.56, 0.8),
    ):
        for epoch in (1, 2):
            rows.append({
                **base,
                "algorithmic_acceleration": acceleration,
                "execution_index": 0,
                "epoch": epoch,
                "train_only_ms": train_ms,
                "coverage": coverage,
                "val_acc": val_acc if epoch == 2 else 0.0,
                "val_loss": val_loss if epoch == 2 else 0.0,
            })

    summaries = summarize(rows)

    assert len(summaries) == 2
    accelerated = next(row for row in summaries if row["algorithmic_acceleration"])
    assert accelerated["coverage_p50"] == 0.8
    assert accelerated["final_val_acc_p50"] == 0.76
    assert accelerated["final_val_loss_p50"] == 0.56


def test_interleaved_order_uses_abba_for_each_repetition():
    assert interleaved_order(2) == ["A", "B", "B", "A", "A", "B", "B", "A"]


def test_paired_abba_executions_share_seeds_with_their_counterpart():
    assert [execution_seed(17, index, paired=True) for index in range(4)] == [
        17,
        17,
        18,
        18,
    ]
    assert [execution_seed(17, index, paired=False) for index in range(4)] == [
        17,
        18,
        19,
        20,
    ]
