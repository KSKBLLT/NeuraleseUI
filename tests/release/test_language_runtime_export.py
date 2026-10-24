"""Every Windows packaging entry point must ship and exercise language assets."""
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def test_every_windows_builder_stages_and_checks_language_runtime():
    for name in ("build_pruned.ps1", "build_local_runtime_payload.ps1", "build_local_runtime_payload.pruned.ps1", "prepare_windows_installer_payload.ps1"):
        source = (ROOT / "tools" / name).read_text(encoding="utf-8")
        assert "stage_language_runtime.py" in source, f"{name} omits language weights/dependencies"
        assert "check_language_runtime.py" in source, f"{name} never exercises the packaged language model"
        assert source.index("stage_language_runtime.py") < source.index("check_language_runtime.py") < source.index("Compress-Archive")


def test_runtime_cache_fingerprint_covers_language_assets_and_vendor():
    source = (ROOT / "tools/build_pruned.ps1").read_text(encoding="utf-8")
    roots = source.split("$sourceRoots = @(", 1)[1].split("\n)", 1)[0]
    assert '"models"' in roots and '"language_vendor"' in roots


def test_exported_backend_uses_only_packaged_interpreter():
    source = (ROOT / "scripts/language_models/onnx_language_backend.gd").read_text(encoding="utf-8")
    assert ".cache/neuralese-language-models/python-env" not in source
    assert 'submit_runtime_request' in source
    assert 'OS.create_process' not in source and 'FileAccess' not in source
    manager=(ROOT / 'scripts/run_manager.gd').read_text(encoding='utf-8')
    assert 'OS.has_feature("editor")' in manager
    assert 'await _local_python_path()' in manager
