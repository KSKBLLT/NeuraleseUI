$ErrorActionPreference = 'Stop'

$launcher = Join-Path $PSScriptRoot 'run.ps1'
if (-not (Test-Path -LiteralPath $launcher -PathType Leaf)) {
    throw "Missing proxy launcher: $launcher"
}

function Invoke-Verification([string]$Profile) {
    $output = (& $launcher -Profile $Profile -VerifyOnly 2>&1 | Out-String)
    if ($LASTEXITCODE -ne 0) {
        throw "Proxy verification for '$Profile' returned exit code $LASTEXITCODE`n$output"
    }
    return $output
}

$output = Invoke-Verification 'yernar'

$required = @(
    'Godot: 4.7.1',
    'Vulkan device: llvmpipe',
    'Renderer: Mobile',
    'Resolution: 1280x720',
    'WSL CPUs: 4',
    'WSL memory: 4 GB',
    'WSL swap: 0',
    'CPU set: 0-3',
    'Effective CPU list: 0-3'
)

foreach ($needle in $required) {
    if (-not $output.Contains($needle)) {
        throw "Verification output is missing '$needle'.`n$output"
    }
}

$tortureOutput = Invoke-Verification 'torture'
foreach ($needle in @('CPU set: 0-1', 'Effective CPU list: 0-1')) {
    if (-not $tortureOutput.Contains($needle)) {
        throw "Torture verification output is missing '$needle'.`n$tortureOutput"
    }
}

Write-Host 'PASS low-performance llvmpipe proxy verification'
