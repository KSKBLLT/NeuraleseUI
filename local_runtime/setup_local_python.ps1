param(
    [string]$Python = "python"
)

$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $MyInvocation.MyCommand.Path
$Venv = Join-Path $Root "python"

$Version = & $Python -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')"
if ($Version -ne "3.11") {
    throw "FullyLocal ORT Training currently needs Python 3.11. Got Python $Version from '$Python'."
}

if (Test-Path -LiteralPath $Venv) {
    # venv does not uninstall distributions whose package names changed. Always
    # rebuild the isolated runtime so stale dist-info cannot survive an upgrade.
    Remove-Item -LiteralPath $Venv -Recurse -Force
}
& $Python -m venv $Venv
& (Join-Path $Venv "Scripts\python.exe") -m pip install --upgrade pip
& (Join-Path $Venv "Scripts\python.exe") -m pip install --no-cache-dir -r (Join-Path $Root "requirements.txt")
& (Join-Path $Venv "Scripts\python.exe") (Join-Path (Split-Path -Parent $Root) "tools\write_local_runtime_package_manifest.py") `
    --requirements (Join-Path $Root "requirements.txt") `
    --output (Join-Path $Root "runtime_packages.lock.json")

Write-Host "FullyLocal Python runtime installed at $Venv"
