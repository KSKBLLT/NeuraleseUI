import hashlib
import json
from pathlib import Path

import pytest

from tools.release.build_release_manifest import build_manifest, write_manifest


VERSION = "1.0.8"
ASSET_URL = (
    "https://github.com/hex358/neuralese-builder/releases/download/"
    "v1.0.8/Neuralese-Setup.exe"
)
PUBLISHED_AT = "2026-07-16T18:30:00Z"
BUILDER_SHA = "b" * 40
SETUP_SHA = "c" * 40


def _fixture(tmp_path: Path) -> tuple[Path, Path, bytes]:
    asset = tmp_path / "Neuralese-Setup.exe"
    asset_bytes = b"MZ" + (b"\0" * (1024 * 1024))
    asset.write_bytes(asset_bytes)
    notes = tmp_path / "notes"
    notes.mkdir()
    (notes / "ru.md").write_text(
        "**Что нового**\n\n- Исправления\n", encoding="utf-8"
    )
    (notes / "en.md").write_text("**What's new**\n\n- Fixes\n", encoding="utf-8")
    return asset, notes, asset_bytes


def _build(tmp_path: Path, **overrides):
    if "asset" in overrides and "notes_dir" in overrides:
        asset = overrides.pop("asset")
        notes = overrides.pop("notes_dir")
    else:
        asset, notes, _ = _fixture(tmp_path)
    kwargs = {
        "version": VERSION,
        "mandatory": False,
        "asset": asset,
        "asset_url": ASSET_URL,
        "notes_dir": notes,
        "published_at": PUBLISHED_AT,
        "builder_commit_sha": BUILDER_SHA,
        "setup_commit_sha": SETUP_SHA,
    }
    kwargs.update(overrides)
    return build_manifest(**kwargs)


def test_builds_manifest_from_real_asset(tmp_path: Path):
    asset, notes, asset_bytes = _fixture(tmp_path)

    manifest = build_manifest(
        version=VERSION,
        mandatory=False,
        asset=asset,
        asset_url=ASSET_URL,
        notes_dir=notes,
        published_at=PUBLISHED_AT,
        builder_commit_sha=BUILDER_SHA,
        setup_commit_sha=SETUP_SHA,
    )

    assert manifest == {
        "schema_version": 1,
        "version": VERSION,
        "mandatory": False,
        "published_at": PUBLISHED_AT,
        "builder_commit_sha": BUILDER_SHA,
        "setup_commit_sha": SETUP_SHA,
        "notes_markdown": {
            "ru": "**Что нового**\n\n- Исправления",
            "en": "**What's new**\n\n- Fixes",
        },
        "downloads": {
            "windows": {
                "url": ASSET_URL,
                "size_bytes": len(asset_bytes),
                "sha256": hashlib.sha256(asset_bytes).hexdigest(),
            }
        },
    }


def test_writes_deterministic_utf8_json_with_trailing_newline(tmp_path: Path):
    manifest = _build(tmp_path)
    first = tmp_path / "first.json"
    second = tmp_path / "second.json"

    write_manifest(manifest, first)
    write_manifest(manifest, second)

    first_bytes = first.read_bytes()
    assert first_bytes == second.read_bytes()
    assert first_bytes.endswith(b"\n")
    assert "Что нового" in first.read_text(encoding="utf-8")
    assert json.loads(first_bytes) == manifest


@pytest.mark.parametrize("version", ["1.0", "v1.0.8", "1.0.8-beta", "01.0.8", ""])
def test_rejects_invalid_versions(tmp_path: Path, version: str):
    with pytest.raises(ValueError, match="version"):
        _build(tmp_path, version=version)


def test_requires_nonempty_russian_notes(tmp_path: Path):
    asset, notes, _ = _fixture(tmp_path)
    (notes / "ru.md").write_text("  \n", encoding="utf-8")
    with pytest.raises(ValueError, match="ru.md"):
        _build(tmp_path, asset=asset, notes_dir=notes)


def test_rejects_asset_smaller_than_one_megabyte(tmp_path: Path):
    asset, notes, _ = _fixture(tmp_path)
    asset.write_bytes(b"MZ")
    with pytest.raises(ValueError, match="1 MiB"):
        _build(tmp_path, asset=asset, notes_dir=notes)


@pytest.mark.parametrize(
    "url",
    [
        "http://github.com/hex358/neuralese-builder/releases/download/v1.0.8/Neuralese-Setup.exe",
        "https://example.com/Neuralese-Setup.exe",
        "https://github.com/hex358/other/releases/download/v1.0.8/Neuralese-Setup.exe",
    ],
)
def test_rejects_urls_outside_builder_releases(tmp_path: Path, url: str):
    with pytest.raises(ValueError, match="asset URL"):
        _build(tmp_path, asset_url=url)


@pytest.mark.parametrize("commit_sha", ["a" * 39, "A" * 40, "not-a-sha"])
def test_rejects_invalid_commit_shas(tmp_path: Path, commit_sha: str):
    with pytest.raises(ValueError, match="commit SHA"):
        _build(tmp_path, builder_commit_sha=commit_sha)


def test_rejects_invalid_published_at(tmp_path: Path):
    with pytest.raises(ValueError, match="published-at"):
        _build(tmp_path, published_at="yesterday")
