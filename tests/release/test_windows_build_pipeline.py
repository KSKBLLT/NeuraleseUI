from pathlib import Path


PROJECT_ROOT = Path(__file__).parents[2]


def _read(relative_path: str) -> str:
    return (PROJECT_ROOT / relative_path).read_text(encoding="utf-8")


def test_windows_build_uses_the_current_checkout() -> None:
    script = _read("build.ps1")

    assert 'D:\\NRLSE\\nnets\\teachneurons' not in script
    assert "$ProjectRoot = (Resolve-Path $PSScriptRoot).Path" in script
    assert 'Join-Path $ProjectRoot "tools\\export_windows_with_runtime.ps1"' in script


def test_windows_build_passes_the_fresh_payload_and_brand_assets_to_setup() -> None:
    script = _read("build.ps1")

    assert 'Join-Path $InstallerRoot "game.zip"' in script
    assert 'Join-Path $ProjectRoot "neuralese.png"' in script
    assert "-PayloadZip $PayloadZip" in script
    assert "-LogoPng $LogoPng" in script


def test_windows_export_rejects_missing_or_stale_output() -> None:
    script = _read("tools/export_windows_with_runtime.ps1")

    assert "Remove-Item -LiteralPath $OutputPath -Force" in script
    assert 'throw "Godot export did not create the expected executable' in script
    assert 'throw "Godot export returned a stale executable' in script


def test_windows_executables_use_neuralese_icons() -> None:
    project = _read("project.godot")
    presets = _read("export_presets.cfg")

    assert 'config/windows_native_icon="res://icon.ico"' in project
    assert 'application/modify_resources=true' in presets
    assert 'application/icon="res://icon.ico"' in presets
    assert (PROJECT_ROOT / "icon.ico").stat().st_size > 1024


def test_managed_msi_workflow_installs_the_real_exported_application() -> None:
    workflow = _read(".github/workflows/build-managed-msi.yml")

    assert "MANAGED_MSI_PATH=" in workflow
    assert "MANAGED_EXE_SHA256=" in workflow
    assert "tools\\test_managed_msi.ps1" in workflow
    assert "Test real managed MSI installation" in workflow
    assert "timeout-minutes: 20" in workflow
    assert "if: always()" in workflow


def test_real_msi_smoke_test_covers_install_launch_identity_and_uninstall() -> None:
    script = _read("tools/test_managed_msi.ps1")

    assert 'msiexec.exe' in script
    assert '"/i"' in script
    assert '"--rendering-method", "gl_compatibility"' in script
    assert '"--headless"' not in script
    assert '"--quit-after", "180"' in script
    assert "RedirectStandardOutput" in script
    assert "RedirectStandardError" in script
    assert '"/x"' in script
    assert "ExpectedExeSha256" in script
    assert "Get-FileHash" in script
    assert "WaitForExit" in script
    assert "Kill($true)" in script
    assert 'Neuralese.exe' in script
    assert 'Neuralese.lnk' in script
    assert 'Find-ManagedArpEntries' in script


def test_installer_payload_overlays_current_builtin_datasets() -> None:
    script = _read("tools/prepare_windows_installer_payload.ps1")

    assert 'Join-Path $ProjectRoot "local_runtime\\datasets"' in script
    assert 'Join-Path $destRoot "datasets"' in script
    assert 'Copy-Item -LiteralPath $sourceDatasets' in script
    assert '"eco_ai\\train.npz"' in script
    assert '"cifar10\\train.npz"' in script
    assert (PROJECT_ROOT / "local_runtime/datasets/eco_ai/train.npz").is_file()
    # The packed copy is checked against every dataset the app lists.
    check = script.index("check_builtin_datasets.py")
    assert script.index("Copy-Item -LiteralPath $sourceDatasets") < check < script.index("Compress-Archive")
    assert "--datasets $destDatasets" in script


def test_every_runtime_build_refuses_missing_builtin_datasets() -> None:
    # CIFAR-10 is not in git; a build must stop before staging anything without it.
    first_staging_step = {
        "build.ps1": "if ($dev)",
        "tools/build_pruned.ps1": "Remove-DirectoryWithRetry $stageRoot",
        "tools/build_local_runtime_payload.ps1": "Remove-Item -LiteralPath $stageRoot",
        "tools/build_local_runtime_payload.pruned.ps1": "Remove-Item -LiteralPath $stageRoot",
    }
    for path, staging in first_staging_step.items():
        script = _read(path)
        check = script.index("tools\\check_builtin_datasets.py")
        assert check < script.index(staging), path
        assert "if ($LASTEXITCODE -ne 0)" in script[check:script.index(staging)], path


def test_ci_builds_builtin_datasets_before_packaging() -> None:
    for name in ("build-windows-branch", "release-windows", "build-managed-msi"):
        workflow = _read(f".github/workflows/{name}.yml")
        step = workflow.index("- name: Build and check builtin datasets")
        assert workflow.index("- name: Restore builtin CIFAR-10 dataset") < step, name
        assert step < workflow.index("prepare_windows_installer_payload.ps1"), name
        assert "local_runtime/datasets/cifar10/train.npz" in workflow, name
        assert "local_runtime\\tools\\check_builtin_datasets.py" in workflow[step:], name


def test_installer_compiles_and_tests_checkout_runtime_before_archiving() -> None:
    script = _read("tools/prepare_windows_installer_payload.ps1")
    assert '$codeFingerprint = & $pythonExe' in script
    assert script.index('tools\\stage_runtime_code.py') < script.index("Compress-Archive")
    assert script.index("test_classification_training_e2e.py") < script.index("Compress-Archive")
    assert 'code_source = "checkout"' in script
    assert 'throw "Packaged runtime classification training smoke test failed"' in script


def test_exe_release_can_skip_msi_packaging_without_skipping_ci_gate() -> None:
    workflow = _read(".github/workflows/build-windows-branch.yml")
    assert "build_msi:" in workflow and "default: true" in workflow
    assert "if: github.event_name != 'workflow_dispatch' || inputs.build_msi" in workflow
    gate = workflow.split("- name: Verify commit CI status", 1)[1].split(
        "- name: Restore Godot download cache", 1
    )[0]
    assert "build_msi" not in gate
    assert "successful Verify check" in gate
