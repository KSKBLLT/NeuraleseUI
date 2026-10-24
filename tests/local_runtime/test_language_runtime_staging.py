import json
from pathlib import Path
import shutil

import pytest

from tools.language_models.stage_language_runtime import stage

ROOT = Path(__file__).resolve().parents[2]
RUNTIME = ROOT / "local_runtime"


def test_windows_export_contains_verified_model_and_native_offline_dependencies(tmp_path):
    runtime = tmp_path / "export with spaces/local_runtime/windows-x64"
    result = stage(RUNTIME, runtime, "windows-x64")
    assert result["source_hash"] == "6f27137365b90aaa97a3992a6ada4a060916a88e4742423a4b5b4424f7bebb76"
    assert (runtime / "models/clean1000/decoder.onnx").stat().st_size == 80536584
    assert list((runtime / "language_vendor/windows-x64/tokenizers").glob("*.pyd"))
    assert (runtime / "language_vendor/common/jinja2/sandbox.py").is_file()
    assert (runtime / "language_vendor/common/markupsafe/_native.py").is_file()
    assert not (runtime / "language_vendor/macos-arm64").exists()
    assert not list(runtime.rglob("*.safetensors"))
    assert result["dependency_bytes"] < 9 * 1024 * 1024


def test_corrupted_vendor_aborts_before_publishing_an_export(tmp_path):
    source = tmp_path / "source"
    (source / "models").mkdir(parents=True)
    # The checkpoint is unchanged; only one small library is damaged.
    (source / "models/clean1000").symlink_to(RUNTIME / "models/clean1000", target_is_directory=True)
    shutil.copytree(RUNTIME / "language_vendor", source / "language_vendor")
    (source / "language_vendor/common/jinja2/sandbox.py").write_text("broken")
    target = tmp_path / "export"
    with pytest.raises(ValueError, match="missing or corrupt"):
        stage(source, target, "windows-x64")
    assert not (target / "models/clean1000/decoder.onnx").exists()


def test_packaged_vendor_files_match_recorded_hashes():
    import hashlib
    import subprocess
    vendor = RUNTIME / "language_vendor"
    manifest = json.loads((vendor / "manifest.json").read_text(encoding="utf-8"))
    for package in manifest["packages"]:
        for name, record in package["files"].items():
            path = vendor / package["platform"] / name
            assert hashlib.sha256(path.read_bytes()).hexdigest() == record["sha256"]
            # A worktree can retain CRLF while an earlier git add normalized
            # the blob. Check the actual bytes another PC will receive too.
            relative = path.relative_to(ROOT).as_posix()
            stored = subprocess.check_output(["git", "show", ":" + relative], cwd=ROOT)
            assert hashlib.sha256(stored).hexdigest() == record["sha256"], relative
