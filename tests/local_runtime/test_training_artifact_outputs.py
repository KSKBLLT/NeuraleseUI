from __future__ import annotations

from pathlib import Path

import onnx
import pytest

from neuralese_local import train_task
from neuralese_local.training_capabilities import _probe_model


@pytest.mark.parametrize("artifact_format", ["onnx", "ort"])
def test_training_artifact_fetches_only_loss_but_eval_keeps_predictions(
    tmp_path: Path, artifact_format: str
):
    _, artifacts = train_task._load_ort_training_api()
    if artifact_format == "ort":
        from neuralese_local.training_capabilities import probe_capabilities

        capabilities = probe_capabilities()
        if not (capabilities.ort_format_generation and capabilities.ort_format_loading):
            pytest.skip("installed ORT Training cannot generate and load ORT-format artifacts")
    model = _probe_model()

    train_task._generate_training_artifacts(
        tmp_path,
        artifacts,
        model,
        ["weight", "bias"],
        "cross_entropy",
        artifacts.OptimType.AdamW,
        artifact_format=artifact_format,
        nominal_checkpoint=False,
        output_contract=train_task.TRAINING_OUTPUT_CONTRACT,
    )

    assert train_task.TRAINING_OUTPUT_CONTRACT == "train_loss_only_eval_predictions_v1"
    if artifact_format == "ort":
        assert (tmp_path / "training_model.ort").is_file()
        assert (tmp_path / "eval_model.ort").is_file()
        return

    training = onnx.load(tmp_path / "training_model.onnx")
    evaluation = onnx.load(tmp_path / "eval_model.onnx")
    training_outputs = [item.name for item in training.graph.output]
    assert "loss" in training_outputs[0].lower()
    assert "output" not in training_outputs
    assert len(evaluation.graph.output) == 2
    assert evaluation.graph.output[-1].name == "output"


def test_unknown_output_contract_is_rejected_before_generation(tmp_path: Path):
    _, artifacts = train_task._load_ort_training_api()

    with pytest.raises(ValueError, match="unsupported training output contract"):
        train_task._generate_training_artifacts(
            tmp_path,
            artifacts,
            _probe_model(),
            ["weight", "bias"],
            "cross_entropy",
            artifacts.OptimType.AdamW,
            output_contract="stale_contract",
        )
