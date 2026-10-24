param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$GameDir = "D:\neuraleseinstaller\game",
    [string]$OutputZip = "D:\neuraleseinstaller\game.zip",
    [string]$Platform = "windows-x64"
)

$ErrorActionPreference = "Stop"

$stageRoot = Join-Path $ProjectRoot ".runtime_payload_build\$Platform"
$manifestPath = Join-Path $stageRoot "runtime_manifest.json"

if (!(Test-Path -LiteralPath $manifestPath)) {
    throw "Runtime stage manifest missing: $manifestPath. Run tools\build_pruned.ps1 -SkipPayloadZip before preparing the installer payload."
}
if (!(Test-Path -LiteralPath $GameDir)) {
    throw "Game directory missing: $GameDir"
}

$manifest = Get-Content -LiteralPath $manifestPath -Raw | ConvertFrom-Json
if ($manifest.pruned -ne $true) {
    throw "Installer payload requires a pruned runtime stage."
}
if ([int]$manifest.files_final -gt 5000) {
    throw "Runtime stage looks unpruned ($($manifest.files_final) files)."
}

$gameExe = Join-Path $GameDir "Neuralese.exe"
if (!(Test-Path -LiteralPath $gameExe)) {
    throw "Game executable missing: $gameExe"
}

$destRoot = Join-Path $GameDir "local_runtime\$Platform"
if (Test-Path -LiteralPath $destRoot) {
    Remove-Item -LiteralPath $destRoot -Recurse -Force
}
New-Item -ItemType Directory -Force -Path $destRoot | Out-Null

Copy-Item -Path (Join-Path $stageRoot "*") -Destination $destRoot -Recurse -Force

# Keep the archived Python/dependencies, but always ship this checkout's code.
$pythonExe = Join-Path $destRoot "python\python.exe"
if (!(Test-Path -LiteralPath $pythonExe)) {
    throw "Prepared installer runtime has no Python executable: $pythonExe"
}
$sourcePackage = Join-Path $ProjectRoot "local_runtime\neuralese_local"
$codeFingerprint = & $pythonExe (Join-Path $ProjectRoot "tools\stage_runtime_code.py") $sourcePackage $destRoot
if ($LASTEXITCODE -ne 0) { throw "Current runtime code compilation failed" }

# The versioned base archive can predate the language feature. Always overlay
# this checkout's model and its small bundled libraries before exercising it.
& $pythonExe (Join-Path $ProjectRoot "tools\language_models\stage_language_runtime.py") --source-runtime (Join-Path $ProjectRoot "local_runtime") --destination-runtime $destRoot --platform $Platform
if ($LASTEXITCODE -ne 0) { throw "Installer language runtime staging failed" }
& $pythonExe -I (Join-Path $ProjectRoot "tools\language_models\check_language_runtime.py") --runtime $destRoot
if ($LASTEXITCODE -ne 0) { throw "Installer offline language runtime smoke test failed" }

$sourceDatasets = Join-Path $ProjectRoot "local_runtime\datasets"
$destDatasets = Join-Path $destRoot "datasets"
if (!(Test-Path -LiteralPath $sourceDatasets)) {
    throw "Builtin dataset source is missing: $sourceDatasets"
}
if (Test-Path -LiteralPath $destDatasets) {
    Remove-Item -LiteralPath $destDatasets -Recurse -Force
}
Copy-Item -LiteralPath $sourceDatasets -Destination $destDatasets -Recurse -Force

$requiredBuiltinDatasets = @(
    "cifar10\train.npz",
    "eco_ai\train.npz",
    "iris\train.npz",
    "mnist\train.npz",
    "titanic\train.npz"
)
foreach ($relativeDatasetPath in $requiredBuiltinDatasets) {
    $datasetPath = Join-Path $destDatasets $relativeDatasetPath
    if (!(Test-Path -LiteralPath $datasetPath)) {
        throw "Prepared installer runtime is missing builtin dataset: $relativeDatasetPath. CIFAR-10 is not in git: build it with python local_runtime\tools\build_builtin_datasets.py before building the app."
    }
}
# Every dataset the app lists, not only the ones named above.
& $pythonExe (Join-Path $ProjectRoot "local_runtime\tools\check_builtin_datasets.py") --datasets $destDatasets --project-root $ProjectRoot
if ($LASTEXITCODE -ne 0) {
    throw "Prepared installer runtime is missing builtin datasets (see above). Build them before building the app."
}

$installedManifest = @{
    platform = $Platform
    installed_at = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    pruned = $true
    source_fingerprint = [string]$manifest.source_fingerprint
    source = "installer_payload"
    datasets_source = "checkout"
    code_source = "checkout"
    code_fingerprint = [string]$codeFingerprint
} | ConvertTo-Json -Compress
Set-Content -LiteralPath (Join-Path $destRoot ".neuralese_runtime_manifest.json") -Value $installedManifest -Encoding UTF8

# Exercise the packaged bytecode, datasets, and native ORT libraries together.
$trainingTest = Join-Path $ProjectRoot "tests\local_runtime\test_classification_training_e2e.py"
& $pythonExe -c "import os,runpy,sys; root,test=sys.argv[1:]; sys.path.insert(0,root); os.environ['NEURALESE_TEST_RUNTIME_ROOT']=root; sys.argv=[test]; runpy.run_path(test,run_name='__main__')" $destRoot $trainingTest
if ($LASTEXITCODE -ne 0) { throw "Packaged runtime classification training smoke test failed" }

# Imports in the smoke test recreate dependency bytecode caches. They are not
# runtime inputs and their deep paths can exceed legacy WiX path limits.
Get-ChildItem -LiteralPath $destRoot -Recurse -Directory -Filter "__pycache__" -Force -ErrorAction SilentlyContinue |
    Remove-Item -Recurse -Force

if (Test-Path -LiteralPath $OutputZip) {
    Remove-Item -LiteralPath $OutputZip -Force
}

$items = Get-ChildItem -LiteralPath $GameDir | Select-Object -ExpandProperty FullName
Compress-Archive -Path $items -DestinationPath $OutputZip -CompressionLevel Optimal

Write-Host "Prepared Neuralese installer game payload:"
Write-Host "  game dir:  $GameDir"
Write-Host "  output:    $OutputZip"
Write-Host "  runtime:   $destRoot"
Write-Host "  source_fingerprint: $($manifest.source_fingerprint)"
Write-Host "  files:     $($manifest.files_final)"
Write-Host ""
Write-Host "Important: export Neuralese.exe with tools\export_windows_with_runtime.ps1 before this step so the installer payload contains the current executable."
