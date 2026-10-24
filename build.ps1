param(
    [switch]$dev,
    [string]$InstallerRoot = "D:\neuraleseinstaller",
    [string]$GodotExe = "D:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe",
    [string]$DevOutput = "D:\ex\Neuralese.exe"
)

$ErrorActionPreference = "Stop"
$ProjectRoot = (Resolve-Path $PSScriptRoot).Path

$BuildPrunedScript = Join-Path $ProjectRoot "tools\build_pruned.ps1"
$ExportScript = Join-Path $ProjectRoot "tools\export_windows_with_runtime.ps1"
$PreparePayloadScript = Join-Path $ProjectRoot "tools\prepare_windows_installer_payload.ps1"
$LogoPng = Join-Path $ProjectRoot "neuralese.png"
$WindowsIcon = Join-Path $ProjectRoot "icon.ico"

foreach ($RequiredPath in @(
    $BuildPrunedScript,
    $ExportScript,
    $PreparePayloadScript,
    $LogoPng,
    $WindowsIcon
)) {
    if (!(Test-Path -LiteralPath $RequiredPath)) {
        throw "Required build input is missing: $RequiredPath"
    }
}

# The app ships every builtin dataset. CIFAR-10 is too large for git, so each
# checkout builds it once: local_runtime\tools\build_builtin_datasets.py.
# The check needs only the standard library.
$CheckPython = Join-Path $ProjectRoot "local_runtime\python\python.exe"
if (!(Test-Path -LiteralPath $CheckPython)) {
    $CheckPython = "python"
}
& $CheckPython (Join-Path $ProjectRoot "local_runtime\tools\check_builtin_datasets.py")
if ($LASTEXITCODE -ne 0) {
    throw "Builtin datasets are missing (see above). Build them before building the app."
}

if ($dev) {
    Write-Host "Building the current checkout for development." -ForegroundColor Cyan
    & $ExportScript `
        -ProjectRoot $ProjectRoot `
        -GodotExe $GodotExe `
        -Output $DevOutput
    exit 0
}

if (!(Test-Path -LiteralPath $InstallerRoot)) {
    throw "Installer checkout not found: $InstallerRoot"
}

$InstallerBuildScript = Join-Path $InstallerRoot "build.ps1"
$GameDir = Join-Path $InstallerRoot "game"
$GameExe = Join-Path $GameDir "Neuralese.exe"
$PayloadZip = Join-Path $InstallerRoot "game.zip"
$InstallerOutput = Join-Path $InstallerRoot "release\Neuralese-Setup.exe"

if (!(Test-Path -LiteralPath $InstallerBuildScript)) {
    throw "Installer build script not found: $InstallerBuildScript"
}

New-Item -ItemType Directory -Path $GameDir -Force | Out-Null

Write-Host "Building the current checkout for production." -ForegroundColor Green
Write-Host "  project:   $ProjectRoot"
Write-Host "  installer: $InstallerRoot"

& $BuildPrunedScript `
    -ProjectRoot $ProjectRoot `
    -Platform "windows-x64" `
    -SkipSmokeTest `
    -SkipPayloadZip

& $ExportScript `
    -ProjectRoot $ProjectRoot `
    -GodotExe $GodotExe `
    -Output $GameExe

& $PreparePayloadScript `
    -ProjectRoot $ProjectRoot `
    -GameDir $GameDir `
    -OutputZip $PayloadZip `
    -Platform "windows-x64"

& $InstallerBuildScript `
    -PayloadZip $PayloadZip `
    -LogoPng $LogoPng `
    -AppName "Neuralese" `
    -GameExeName "Neuralese.exe"

if (!(Test-Path -LiteralPath $InstallerOutput)) {
    throw "Installer build completed without the expected executable: $InstallerOutput"
}

Write-Host "Windows installer completed: $InstallerOutput" -ForegroundColor Green
