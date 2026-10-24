from __future__ import annotations

import json

from neuralese_local.training_artifact_cache import ArtifactCache, artifact_fingerprint
from neuralese_local.training_capabilities import (
    CAPABILITY_SCHEMA_VERSION,
    TrainingCapabilities,
    capability_key,
    choose_artifact_format,
    load_capabilities,
    _probe_reusable_cpu_ortvalue_inputs,
)


def test_artifact_format_falls_back_unless_generation_and_loading_work():
    assert choose_artifact_format(False, False, 10.0, 1.0) == "onnx"
    assert choose_artifact_format(True, False, 10.0, 1.0) == "onnx"
    assert choose_artifact_format(True, True, 10.0, 12.0) == "onnx"
    assert choose_artifact_format(True, True, 10.0, 4.0) == "ort"


def test_artifact_format_is_part_of_structural_cache_key():
    model = {"nodes": ["dense"]}
    onnx_key = artifact_fingerprint(model, ["weight"], "mse", "adam", {"format": "onnx"})
    ort_key = artifact_fingerprint(model, ["weight"], "mse", "adam", {"format": "ort"})
    assert onnx_key != ort_key


def test_capability_cache_rejects_another_runtime(tmp_path):
    path = tmp_path / "capabilities.json"
    caps = TrainingCapabilities(
        key=capability_key("1.2.3"),
        ort_version="1.2.3",
        nominal_checkpoint=False,
        ort_format_generation=False,
        ort_format_loading=False,
        artifact_format="onnx",
    )
    path.write_text(
        json.dumps({"schema": CAPABILITY_SCHEMA_VERSION, "capabilities": caps.__dict__}),
        encoding="utf-8",
    )
    assert load_capabilities(path, "1.2.3") == caps
    assert load_capabilities(path, "9.9.9") is None


def test_ortvalue_probe_reports_a_reason_on_failure(monkeypatch):
    import onnxruntime as ort

    monkeypatch.setattr(
        ort.OrtValue,
        "ortvalue_from_numpy",
        lambda _source: (_ for _ in ()).throw(RuntimeError("unsupported")),
    )

    supported, reason = _probe_reusable_cpu_ortvalue_inputs()

    assert supported is False
    assert "unsupported" in reason


def test_artifact_cache_validates_selected_ort_files(tmp_path):
    cache = ArtifactCache(tmp_path / "cache")

    def build(directory):
        for filename in (
            "training_model.ort",
            "eval_model.ort",
            "optimizer_model.ort",
            "checkpoint",
        ):
            (directory / filename).write_bytes(filename.encode("ascii"))

    entry = cache.get_or_create(
        {"fingerprint": "ort-entry", "artifact_format": "ort"},
        build,
    )
    assert entry.training_model.name == "training_model.ort"
    assert entry.eval_model.name == "eval_model.ort"
    assert entry.optimizer_model.name == "optimizer_model.ort"
