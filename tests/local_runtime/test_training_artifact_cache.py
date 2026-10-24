from __future__ import annotations

from pathlib import Path

import pytest

from neuralese_local.training_artifact_cache import (
    ArtifactCache,
    CACHE_SCHEMA_VERSION,
    artifact_fingerprint,
)


def _build_fake_artifacts(target: Path, marker: bytes = b"valid") -> None:
    target.mkdir(parents=True, exist_ok=True)
    for name in (
        "training_model.onnx",
        "eval_model.onnx",
        "optimizer_model.onnx",
        "checkpoint",
    ):
        (target / name).write_bytes(marker + b":" + name.encode("ascii"))


def test_fingerprint_is_canonical_and_sensitive_to_training_contract():
    capability = {"ort_version": "1.2.3", "architecture": "x86_64"}
    first = artifact_fingerprint(
        {"nodes": [{"type": "Dense", "shape": [4, 3]}], "meta": {"b": 2, "a": 1}},
        ["weight", "bias"],
        "cross_entropy",
        "adamw",
        capability,
    )
    reordered = artifact_fingerprint(
        {"meta": {"a": 1, "b": 2}, "nodes": [{"shape": [4, 3], "type": "Dense"}]},
        ["bias", "weight"],
        "cross_entropy",
        "adamw",
        {"architecture": "x86_64", "ort_version": "1.2.3"},
    )

    assert first == reordered
    assert first != artifact_fingerprint(
        {"nodes": [{"type": "Dense", "shape": [4, 4]}], "meta": {"a": 1, "b": 2}},
        ["weight", "bias"],
        "cross_entropy",
        "adamw",
        capability,
    )
    assert first != artifact_fingerprint(
        {"nodes": [{"type": "Dense", "shape": [4, 3]}], "meta": {"a": 1, "b": 2}},
        ["weight", "bias"],
        "mse",
        "adamw",
        capability,
    )


def test_cache_builds_once_and_returns_validated_paths(tmp_path):
    cache = ArtifactCache(tmp_path)
    calls = []
    spec = {"fingerprint": "abc123", "loss": "cross_entropy"}

    def builder(target):
        calls.append(target)
        _build_fake_artifacts(target)

    first = cache.get_or_create(spec, builder)
    second = cache.get_or_create(spec, builder)

    assert len(calls) == 1
    assert first.directory == second.directory
    assert first.cache_hit is False
    assert second.cache_hit is True
    assert first.training_model.read_bytes().startswith(b"valid")
    assert first.checkpoint.is_file()


def test_corrupt_entry_is_rebuilt_exactly_once(tmp_path):
    cache = ArtifactCache(tmp_path)
    calls = 0

    def builder(target):
        nonlocal calls
        calls += 1
        _build_fake_artifacts(target, marker=f"build-{calls}".encode("ascii"))

    entry = cache.get_or_create({"fingerprint": "corruption"}, builder)
    entry.training_model.write_bytes(b"corrupt")
    rebuilt = cache.get_or_create({"fingerprint": "corruption"}, builder)
    cache.get_or_create({"fingerprint": "corruption"}, builder)

    assert calls == 2
    assert rebuilt.training_model.read_bytes().startswith(b"build-2")


def test_failed_build_never_exposes_partial_entry(tmp_path):
    cache = ArtifactCache(tmp_path)

    def builder(target):
        target.mkdir(parents=True, exist_ok=True)
        (target / "training_model.onnx").write_bytes(b"partial")
        raise RuntimeError("builder failed")

    with pytest.raises(RuntimeError, match="builder failed"):
        cache.get_or_create({"fingerprint": "failed"}, builder)

    assert not (tmp_path / "failed").exists()
    assert not list(tmp_path.glob("failed.building.*"))


def test_old_cache_schema_is_rebuilt_once(tmp_path):
    cache = ArtifactCache(tmp_path)
    target = tmp_path / "old-contract"
    _build_fake_artifacts(target, marker=b"old")
    (target / "manifest.json").write_text(
        '{"schema": %d, "fingerprint": "old-contract", "files": {}}'
        % (CACHE_SCHEMA_VERSION - 1),
        encoding="utf-8",
    )
    calls = 0

    def builder(directory):
        nonlocal calls
        calls += 1
        _build_fake_artifacts(directory, marker=b"new")

    first = cache.get_or_create({"fingerprint": "old-contract"}, builder)
    second = cache.get_or_create({"fingerprint": "old-contract"}, builder)

    assert calls == 1
    assert first.cache_hit is False
    assert second.cache_hit is True
