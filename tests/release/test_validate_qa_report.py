import copy
import importlib.util
import json
from pathlib import Path

import pytest


MODULE_PATH = Path(__file__).parents[2] / "tools" / "release" / "validate_qa_report.py"
SPEC = importlib.util.spec_from_file_location("validate_qa_report", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


VERSION = "1.0.8"
INSTALLER_SHA = "a" * 64
BUILDER_SHA = "b" * 40
SETUP_SHA = "c" * 40


def valid_report() -> dict:
    return {
        "schema_version": 1,
        "version": VERSION,
        "installer_sha256": INSTALLER_SHA,
        "builder_commit_sha": BUILDER_SHA,
        "setup_commit_sha": SETUP_SHA,
        "tester": "Lyamon4",
        "tested_at": "2026-07-17T20:00:00Z",
        "windows_versions": ["Windows 10", "Windows 11"],
        "checks": {name: True for name in MODULE.REQUIRED_CHECKS},
        "evidence": ["https://github.com/hex358/neuralese-builder/issues/3"],
    }


def validate(report: dict) -> dict:
    return MODULE.validate_report(
        report,
        expected_version=VERSION,
        expected_installer_sha256=INSTALLER_SHA,
        expected_builder_commit_sha=BUILDER_SHA,
        expected_setup_commit_sha=SETUP_SHA,
    )


def test_valid_report_is_normalized_without_mutation() -> None:
    report = valid_report()
    before = copy.deepcopy(report)

    result = validate(report)

    assert result == report
    assert report == before


@pytest.mark.parametrize(
    ("mutation", "message"),
    [
        (lambda report: report["checks"].pop("rollback"), "checks keys"),
        (lambda report: report["checks"].__setitem__("rollback", False), "rollback"),
        (lambda report: report.__setitem__("installer_sha256", "d" * 64), "installer SHA"),
        (lambda report: report.__setitem__("version", "1.0.9"), "version"),
        (lambda report: report.__setitem__("evidence", []), "evidence"),
        (lambda report: report.__setitem__("evidence", ["file:///tmp/shot.png"]), "HTTPS"),
        (lambda report: report.__setitem__("windows_versions", ["Windows 11"]), "Windows 10"),
        (lambda report: report.__setitem__("tested_at", "2026-07-17T20:00:00"), "timezone"),
        (lambda report: report.__setitem__("extra", True), "top-level keys"),
    ],
)
def test_invalid_reports_are_rejected(mutation, message: str) -> None:
    report = valid_report()
    mutation(report)

    with pytest.raises(ValueError, match=message):
        validate(report)


def test_cli_validates_a_report(tmp_path: Path) -> None:
    report_path = tmp_path / "qa-report.json"
    report_path.write_text(json.dumps(valid_report()), encoding="utf-8")

    assert MODULE.main(
        [
            "--report",
            str(report_path),
            "--expected-version",
            VERSION,
            "--expected-installer-sha256",
            INSTALLER_SHA,
            "--expected-builder-commit-sha",
            BUILDER_SHA,
            "--expected-setup-commit-sha",
            SETUP_SHA,
        ]
    ) == 0
