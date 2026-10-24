import hashlib
import importlib.util
import json
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).parents[2] / "tools" / "release" / "verify_release_candidate.py"
SPEC = importlib.util.spec_from_file_location("verify_release_candidate", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


def write_candidate(tmp_path: Path) -> tuple[Path, Path, dict]:
    installer = tmp_path / "Neuralese-Setup.exe"
    installer.write_bytes(b"MZ" + b"candidate" * 100)
    manifest = {
        "schema_version": 1,
        "version": "1.0.8",
        "mandatory": False,
        "published_at": "2026-07-17T20:00:00Z",
        "builder_commit_sha": "b" * 40,
        "setup_commit_sha": "c" * 40,
        "notes_markdown": {"ru": "Release notes"},
        "downloads": {
            "windows": {
                "url": "https://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Neuralese-Setup.exe",
                "size_bytes": installer.stat().st_size,
                "sha256": hashlib.sha256(installer.read_bytes()).hexdigest(),
            }
        },
    }
    manifest_path = tmp_path / "latest.json"
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    return installer, manifest_path, manifest


def verify(installer: Path, manifest: Path) -> dict:
    return MODULE.verify_candidate(
        installer=installer,
        manifest_path=manifest,
        expected_version="1.0.8",
        expected_builder_commit_sha="b" * 40,
        expected_setup_commit_sha="c" * 40,
    )


def test_valid_candidate_matches_exact_bytes(tmp_path: Path) -> None:
    installer, manifest_path, manifest = write_candidate(tmp_path)

    assert verify(installer, manifest_path) == manifest


def test_valid_candidate_accepts_matching_qa_report(tmp_path: Path) -> None:
    installer, manifest_path, manifest = write_candidate(tmp_path)
    qa_report = {
        "schema_version": 1,
        "version": manifest["version"],
        "installer_sha256": manifest["downloads"]["windows"]["sha256"],
        "builder_commit_sha": manifest["builder_commit_sha"],
        "setup_commit_sha": manifest["setup_commit_sha"],
        "tester": "QA",
        "tested_at": "2026-07-17T20:00:00Z",
        "windows_versions": ["Windows 10", "Windows 11"],
        "checks": {
            "visual_layout": True,
            "release_notes": True,
            "progress_states": True,
            "optional_update": True,
            "mandatory_update": True,
            "network_failures": True,
            "checksum_rejection": True,
            "rollback": True,
            "user_data_preserved": True,
            "shortcuts_and_uninstall": True,
        },
        "evidence": ["https://example.com/evidence"],
    }
    qa_path = tmp_path / "qa-report.json"
    qa_path.write_text(json.dumps(qa_report), encoding="utf-8")

    assert MODULE.verify_candidate(
        installer=installer,
        manifest_path=manifest_path,
        expected_version="1.0.8",
        expected_builder_commit_sha="b" * 40,
        expected_setup_commit_sha="c" * 40,
        qa_report=qa_path,
    ) == manifest


@pytest.mark.parametrize(
    ("mutate", "message"),
    [
        (lambda installer, _path, _manifest: installer.write_bytes(b"MZchanged"), "size"),
        (lambda _installer, _path, manifest: manifest.__setitem__("version", "1.0.9"), "version"),
        (lambda _installer, _path, manifest: manifest.__setitem__("setup_commit_sha", "d" * 40), "setup"),
        (lambda _installer, _path, manifest: manifest["downloads"]["windows"].__setitem__("sha256", "0" * 64), "SHA"),
        (lambda _installer, _path, manifest: manifest.__setitem__("published_at", "not-a-date"), "published_at"),
        (lambda _installer, _path, manifest: manifest.__setitem__("extra", True), "keys"),
    ],
)
def test_candidate_mismatches_are_rejected(tmp_path: Path, mutate, message: str) -> None:
    installer, manifest_path, manifest = write_candidate(tmp_path)
    mutate(installer, manifest_path, manifest)
    manifest_path.write_text(json.dumps(manifest), encoding="utf-8")

    with pytest.raises(ValueError, match=message):
        verify(installer, manifest_path)
