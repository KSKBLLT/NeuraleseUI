#!/usr/bin/env python3
"""Validate the manual Windows QA evidence required for release promotion."""

from __future__ import annotations

import argparse
import json
import re
from datetime import datetime
from pathlib import Path
from typing import Any, Mapping, Sequence
from urllib.parse import urlparse


SCHEMA_VERSION = 1
VERSION_PATTERN = re.compile(r"^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")
COMMIT_PATTERN = re.compile(r"^[0-9a-f]{40}$")
REQUIRED_WINDOWS_VERSIONS = {"Windows 10", "Windows 11"}
REQUIRED_CHECKS = (
    "visual_layout",
    "release_notes",
    "progress_states",
    "optional_update",
    "mandatory_update",
    "network_failures",
    "checksum_rejection",
    "rollback",
    "user_data_preserved",
    "shortcuts_and_uninstall",
)
TOP_LEVEL_KEYS = {
    "schema_version",
    "version",
    "installer_sha256",
    "builder_commit_sha",
    "setup_commit_sha",
    "tester",
    "tested_at",
    "windows_versions",
    "checks",
    "evidence",
}


def _require_pattern(value: Any, pattern: re.Pattern[str], label: str) -> str:
    if not isinstance(value, str) or pattern.fullmatch(value) is None:
        raise ValueError(f"{label} has an invalid format")
    return value


def _validate_timestamp(value: Any) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ValueError("tested_at must be a non-empty ISO-8601 timestamp")
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise ValueError("tested_at must be an ISO-8601 timestamp") from error
    if parsed.tzinfo is None or parsed.utcoffset() is None:
        raise ValueError("tested_at must include a timezone")
    return value


def _validate_evidence(value: Any) -> list[str]:
    if not isinstance(value, list) or not value:
        raise ValueError("evidence must contain at least one HTTPS URL")
    normalized: list[str] = []
    for item in value:
        if not isinstance(item, str):
            raise ValueError("every evidence item must be an HTTPS URL")
        parsed = urlparse(item)
        if parsed.scheme != "https" or not parsed.netloc or parsed.username or parsed.password:
            raise ValueError("every evidence item must be an HTTPS URL")
        normalized.append(item)
    return normalized


def validate_report(
    report: Mapping[str, Any],
    *,
    expected_version: str,
    expected_installer_sha256: str,
    expected_builder_commit_sha: str,
    expected_setup_commit_sha: str,
) -> dict[str, Any]:
    if not isinstance(report, Mapping):
        raise ValueError("QA report must be a JSON object")
    if set(report) != TOP_LEVEL_KEYS:
        raise ValueError("QA report top-level keys do not match the schema")
    if type(report["schema_version"]) is not int or report["schema_version"] != SCHEMA_VERSION:
        raise ValueError("schema_version must be integer 1")

    version = _require_pattern(report["version"], VERSION_PATTERN, "version")
    installer_sha = _require_pattern(report["installer_sha256"], SHA256_PATTERN, "installer SHA")
    builder_sha = _require_pattern(report["builder_commit_sha"], COMMIT_PATTERN, "builder commit SHA")
    setup_sha = _require_pattern(report["setup_commit_sha"], COMMIT_PATTERN, "setup commit SHA")
    if version != expected_version:
        raise ValueError("QA report version does not match the candidate")
    if installer_sha != expected_installer_sha256:
        raise ValueError("QA report installer SHA does not match the candidate")
    if builder_sha != expected_builder_commit_sha:
        raise ValueError("QA report builder commit SHA does not match the candidate")
    if setup_sha != expected_setup_commit_sha:
        raise ValueError("QA report setup commit SHA does not match the candidate")

    tester = report["tester"]
    if not isinstance(tester, str) or not tester.strip():
        raise ValueError("tester must be a non-empty string")
    tested_at = _validate_timestamp(report["tested_at"])

    windows_versions = report["windows_versions"]
    if (
        not isinstance(windows_versions, list)
        or len(windows_versions) != len(REQUIRED_WINDOWS_VERSIONS)
        or set(windows_versions) != REQUIRED_WINDOWS_VERSIONS
    ):
        raise ValueError("windows_versions must contain exactly Windows 10 and Windows 11")

    checks = report["checks"]
    if not isinstance(checks, Mapping) or set(checks) != set(REQUIRED_CHECKS):
        raise ValueError("checks keys do not match the required QA matrix")
    for name in REQUIRED_CHECKS:
        if checks[name] is not True:
            raise ValueError(f"QA check {name} must be true")

    return {
        "schema_version": SCHEMA_VERSION,
        "version": version,
        "installer_sha256": installer_sha,
        "builder_commit_sha": builder_sha,
        "setup_commit_sha": setup_sha,
        "tester": tester,
        "tested_at": tested_at,
        "windows_versions": list(windows_versions),
        "checks": dict(checks),
        "evidence": _validate_evidence(report["evidence"]),
    }


def _reject_duplicate_keys(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
    result: dict[str, Any] = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key: {key}")
        result[key] = value
    return result


def load_report(path: Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"), object_pairs_hook=_reject_duplicate_keys)
    except (OSError, json.JSONDecodeError) as error:
        raise ValueError(f"unable to read QA report: {error}") from error
    if not isinstance(value, dict):
        raise ValueError("QA report must be a JSON object")
    return value


def _parse_args(argv: Sequence[str] | None = None) -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--report", required=True, type=Path)
    parser.add_argument("--expected-version", required=True)
    parser.add_argument("--expected-installer-sha256", required=True)
    parser.add_argument("--expected-builder-commit-sha", required=True)
    parser.add_argument("--expected-setup-commit-sha", required=True)
    return parser.parse_args(argv)


def main(argv: Sequence[str] | None = None) -> int:
    args = _parse_args(argv)
    report = load_report(args.report)
    validate_report(
        report,
        expected_version=args.expected_version,
        expected_installer_sha256=args.expected_installer_sha256,
        expected_builder_commit_sha=args.expected_builder_commit_sha,
        expected_setup_commit_sha=args.expected_setup_commit_sha,
    )
    print("QA report is valid")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
