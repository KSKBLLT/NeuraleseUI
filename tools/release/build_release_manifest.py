#!/usr/bin/env python3
from __future__ import annotations

import argparse
import hashlib
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any
from urllib.parse import urlparse


SCHEMA_VERSION = 1
MIN_ASSET_SIZE = 1024 * 1024
RELEASE_URL_PREFIX = (
    "https://github.com/hex358/neuralese-builder/releases/download/"
)
VERSION_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SHA_PATTERN = re.compile(r"^[0-9a-f]{40}$")


def _validate_version(version: str) -> str:
    value = version.strip()
    if VERSION_PATTERN.fullmatch(value) is None:
        raise ValueError("version must use N.N.N without prefixes or suffixes")
    return value


def _validate_commit_sha(value: str, label: str) -> str:
    checksum = value.strip()
    if SHA_PATTERN.fullmatch(checksum) is None:
        raise ValueError(f"{label} commit SHA must contain 40 lowercase hex characters")
    return checksum


def _validate_published_at(value: str) -> str:
    timestamp = value.strip()
    try:
        parsed = datetime.fromisoformat(timestamp.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("published-at must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None:
        raise ValueError("published-at must include a timezone")
    return timestamp


def _validate_asset_url(asset_url: str, version: str) -> str:
    value = asset_url.strip()
    parsed = urlparse(value)
    expected_prefix = f"{RELEASE_URL_PREFIX}v{version}/"
    if (
        parsed.scheme != "https"
        or parsed.netloc != "github.com"
        or not value.startswith(expected_prefix)
        or parsed.query
        or parsed.fragment
        or parsed.path.rsplit("/", 1)[-1] != "Neuralese-Setup.exe"
    ):
        raise ValueError(
            "asset URL must point to Neuralese-Setup.exe in the matching builder release"
        )
    return value


def _read_notes(notes_dir: Path) -> dict[str, str]:
    notes: dict[str, str] = {}
    for language in ("ru", "en", "kz"):
        path = notes_dir / f"{language}.md"
        if not path.exists():
            if language == "ru":
                raise ValueError("ru.md is required")
            continue
        text = path.read_text(encoding="utf-8").strip()
        if not text:
            raise ValueError(f"{language}.md must not be empty")
        notes[language] = text
    return notes


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def build_manifest(
    *,
    version: str,
    mandatory: bool,
    asset: Path | str,
    asset_url: str,
    notes_dir: Path | str,
    published_at: str,
    builder_commit_sha: str,
    setup_commit_sha: str,
) -> dict[str, Any]:
    normalized_version = _validate_version(version)
    asset_path = Path(asset)
    notes_path = Path(notes_dir)
    if not asset_path.is_file():
        raise ValueError(f"asset does not exist: {asset_path}")
    asset_size = asset_path.stat().st_size
    if asset_size < MIN_ASSET_SIZE:
        raise ValueError("asset must be at least 1 MiB")

    return {
        "schema_version": SCHEMA_VERSION,
        "version": normalized_version,
        "mandatory": bool(mandatory),
        "published_at": _validate_published_at(published_at),
        "builder_commit_sha": _validate_commit_sha(
            builder_commit_sha, "builder"
        ),
        "setup_commit_sha": _validate_commit_sha(setup_commit_sha, "setup"),
        "notes_markdown": _read_notes(notes_path),
        "downloads": {
            "windows": {
                "url": _validate_asset_url(asset_url, normalized_version),
                "size_bytes": asset_size,
                "sha256": _sha256(asset_path),
            }
        },
    }


def write_manifest(manifest: dict[str, Any], output: Path | str) -> None:
    output_path = Path(output)
    output_path.parent.mkdir(parents=True, exist_ok=True)
    content = json.dumps(manifest, ensure_ascii=False, indent=2) + "\n"
    temporary_path = output_path.with_name(f".{output_path.name}.tmp")
    temporary_path.write_text(content, encoding="utf-8", newline="\n")
    temporary_path.replace(output_path)


def _parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Build the signed-by-content Neuralese latest.json manifest."
    )
    parser.add_argument("--version", required=True)
    parser.add_argument("--mandatory", action="store_true")
    parser.add_argument("--asset", required=True, type=Path)
    parser.add_argument("--asset-url", required=True)
    parser.add_argument("--notes-dir", required=True, type=Path)
    parser.add_argument("--published-at", required=True)
    parser.add_argument("--builder-commit-sha", required=True)
    parser.add_argument("--setup-commit-sha", required=True)
    parser.add_argument("--output", required=True, type=Path)
    return parser.parse_args()


def main() -> int:
    args = _parse_args()
    manifest = build_manifest(
        version=args.version,
        mandatory=args.mandatory,
        asset=args.asset,
        asset_url=args.asset_url,
        notes_dir=args.notes_dir,
        published_at=args.published_at,
        builder_commit_sha=args.builder_commit_sha,
        setup_commit_sha=args.setup_commit_sha,
    )
    write_manifest(manifest, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
