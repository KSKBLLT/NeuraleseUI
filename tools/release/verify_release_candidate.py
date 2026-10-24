#!/usr/bin/env python3
"""Verify immutable Windows release candidate assets before promotion."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Sequence


VERSION_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
TOP_LEVEL_KEYS = {
    "schema_version",
    "version",
    "mandatory",
    "published_at",
    "builder_commit_sha",
    "setup_commit_sha",
    "notes_markdown",
    "downloads",
}
PACKAGE_KEYS = {"url", "size_bytes", "sha256"}


def _sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def _load_json(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_reject_duplicate_keys)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"unable to read {path.name}: {error}") from error
    if not isinstance(value, dict):
        raise ValueError(f"{path.name} must contain a JSON object")
    return value


def _validate_notes(value: Any) -> None:
    if not isinstance(value, dict) or not value or not set(value).issubset({"ru", "en", "kz"}):
        raise ValueError("release notes have invalid keys")
    if "ru" not in value:
        raise ValueError("Russian release notes are required")
    for language, text in value.items():
        if not isinstance(text, str) or not text.strip():
            raise ValueError(f"release notes for {language} must not be empty")


def _validate_published_at(value: Any) -> None:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("manifest published_at must be a non-empty ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("manifest published_at must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("manifest published_at must include a timezone")


def verify_candidate(
    *,
    installer: Path | str,
    manifest_path: Path | str,
    expected_version: str,
    expected_builder_commit_sha: str,
    expected_setup_commit_sha: str,
    qa_report: Path | str | None = None,
) -> dict[str, Any]:
    installer_path = Path(installer)
    manifest_file = Path(manifest_path)
    if not installer_path.is_file():
        raise ValueError("installer does not exist")
    manifest = _load_json(manifest_file)
    if set(manifest) != TOP_LEVEL_KEYS:
        raise ValueError("manifest top-level keys do not match the release schema")
    if type(manifest["schema_version"]) is not int or manifest["schema_version"] != 1:
        raise ValueError("manifest schema_version must be integer 1")
    if type(manifest["mandatory"]) is not bool:
        raise ValueError("manifest mandatory must be boolean")

    version = manifest["version"]
    if not isinstance(version, str) or VERSION_PATTERN.fullmatch(version) is None:
        raise ValueError("manifest version has an invalid format")
    if version != expected_version:
        raise ValueError("manifest version does not match the candidate")
    builder_sha = manifest["builder_commit_sha"]
    setup_sha = manifest["setup_commit_sha"]
    if not isinstance(builder_sha, str) or COMMIT_PATTERN.fullmatch(builder_sha) is None:
        raise ValueError("manifest builder commit SHA has an invalid format")
    if not isinstance(setup_sha, str) or COMMIT_PATTERN.fullmatch(setup_sha) is None:
        raise ValueError("manifest setup commit SHA has an invalid format")
    if builder_sha != expected_builder_commit_sha:
        raise ValueError("manifest builder commit does not match the candidate")
    if setup_sha != expected_setup_commit_sha:
        raise ValueError("manifest setup commit does not match the setup lock")
    _validate_published_at(manifest["published_at"])
    _validate_notes(manifest["notes_markdown"])

    downloads = manifest["downloads"]
    if not isinstance(downloads, dict) or set(downloads) != {"windows"}:
        raise ValueError("manifest downloads must contain only windows")
    package = downloads["windows"]
    if not isinstance(package, dict) or set(package) != PACKAGE_KEYS:
        raise ValueError("manifest Windows package keys do not match the schema")
    expected_url = (
        "https://github.com/hex358/neuralese-builder/releases/download/"
        f"v{expected_version}/Neuralese-Setup.exe"
    )
    if package["url"] != expected_url:
        raise ValueError("manifest installer URL does not match the candidate tag")
    actual_size = installer_path.stat().st_size
    if type(package["size_bytes"]) is not int or package["size_bytes"] != actual_size:
        raise ValueError("manifest installer size does not match the downloaded bytes")
    actual_sha = _sha256(installer_path)
    if not isinstance(package["sha256"], str) or SHA256_PATTERN.fullmatch(package["sha256"]) is None:
        raise ValueError("manifest installer SHA has an invalid format")
    if package["sha256"] != actual_sha:
        raise ValueError("manifest installer SHA does not match the downloaded bytes")

    if qa_report is not None:
        validator_path = Path(__file__).with_name("validate_qa_report.py")
        spec = importlib.util.spec_from_file_location("validate_qa_report", validator_path)
        if spec is None or spec.loader is None:
            raise ValueError("unable to load QA report validator")
        validator = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(validator)
        report = validator.load_report(Path(qa_report))
        validator.validate_report(
            report,
            expected_version=version,
            expected_installer_sha256=actual_sha,
            expected_builder_commit_sha=builder_sha,
            expected_setup_commit_sha=setup_sha,
        )
    return manifest


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--installer", required=True, type=Path)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-builder-commit-sha", required=True)
    parser.add_argument("--expected-setup-commit-sha", required=True)
    parser.add_argument("--qa-report", type=Path)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    verify_candidate(
        installer=args.installer,
        manifest_path=args.manifest,
        expected_version=args.expected_version,
        expected_builder_commit_sha=args.expected_builder_commit_sha,
        expected_setup_commit_sha=args.expected_setup_commit_sha,
        qa_report=args.qa_report,
    )
    print("Release candidate assets are valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
