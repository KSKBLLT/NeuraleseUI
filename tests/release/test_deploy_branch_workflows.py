from pathlib import Path


PROJECT_ROOT = Path(__file__).parents[2]


def _read(relative_path: str) -> str:
    return (PROJECT_ROOT / relative_path).read_text(encoding="utf-8")


def test_deploy_branches_build_windows_installers() -> None:
    workflow = _read(".github/workflows/build-windows-branch.yml")

    assert "branches: [alim, pilot-deploy, prod-deploy]" in workflow
    assert "Verify commit CI status" in workflow
    assert "name: neuralese-windows-${{ github.ref_name }}-${{ github.sha }}" in workflow


def test_deploy_branches_build_verified_macos_dmgs() -> None:
    workflow = _read(".github/workflows/build-macos-branch.yml")

    assert "branches: [pilot-deploy, prod-deploy]" in workflow
    assert "runs-on: macos-14" in workflow
    assert "Godot_v4.7.1-stable_macos.universal.zip" in workflow
    assert "Verify commit CI status" in workflow
    assert '--export-release macOS "$APP_PATH"' in workflow
    assert "codesign --verify --deep --strict" in workflow
    assert "hdiutil verify" in workflow
    assert "name: neuralese-macos-${{ github.ref_name }}-${{ github.sha }}" in workflow


def test_deploy_builds_cannot_publish_public_releases() -> None:
    for relative_path in (
        ".github/workflows/build-windows-branch.yml",
        ".github/workflows/build-macos-branch.yml",
    ):
        workflow = _read(relative_path)

        assert "contents: read" in workflow
        assert "contents: write" not in workflow
        assert "gh release" not in workflow
        assert "softprops/action-gh-release" not in workflow


def test_full_verification_runs_on_deploy_branches() -> None:
    workflow = _read(".github/workflows/test-updater.yml")

    assert "branches: [dev, main, pilot-deploy, prod-deploy]" in workflow
    assert "python -m tools.node_dev check" in workflow
    assert 'godot-check --godot-bin "$env:GODOT_BIN" --timeout 300' in workflow
    assert "tests/integration/run_update_integration.sh" in workflow
    assert "needs: [python, godot, local-runtime, whitespace]" in workflow
    assert "python -m pytest tests/local_runtime -v" in workflow
    assert "if: always()" in workflow


def test_pull_request_whitespace_check_uses_actual_base_branch() -> None:
    workflow = _read(".github/workflows/test-updater.yml")

    assert "GITHUB_BASE_REF" in workflow
    assert "EVENT_BEFORE" in workflow
    assert "git merge-base origin/main HEAD" not in workflow


def test_godot_runner_reports_all_failures() -> None:
    runner = _read("tests/godot/run_all.sh")

    assert 'failures+=("$file")' in runner
    assert "Godot test failures" in runner
    assert "exit 1" in runner
