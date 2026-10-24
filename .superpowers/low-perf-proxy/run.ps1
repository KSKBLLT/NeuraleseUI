[CmdletBinding()]
param(
    [ValidateSet('yernar', 'torture', 'stress')]
    [string]$Profile = 'yernar',

    [switch]$VerifyOnly,

    [ValidateRange(0, 1000000)]
    [int]$ProbeFrames = 0,

    [switch]$Stress,

    [switch]$ConnectionProbe,

    [ValidateRange(1, 3600)]
    [int]$StressSeconds = 180
)

$ErrorActionPreference = 'Stop'

function Convert-ToWslPath([string]$WindowsPath) {
    $fullPath = [System.IO.Path]::GetFullPath($WindowsPath)
    if ($fullPath -notmatch '^(?<drive>[A-Za-z]):\\(?<tail>.*)$') {
        throw "Only local drive paths can be converted for WSL: $WindowsPath"
    }
    $drive = $Matches['drive'].ToLowerInvariant()
    $tail = $Matches['tail'].Replace('\', '/')
    return "/mnt/$drive/$tail"
}

$repoRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..\..')).Path
$proxyLinux = Convert-ToWslPath $PSScriptRoot
$repoLinux = Convert-ToWslPath $repoRoot
$linuxLauncher = "$proxyLinux/run-wsl-llvmpipe.sh"

$arguments = @(
    '-d', 'Ubuntu', '--', 'bash', $linuxLauncher,
    '--profile', $Profile,
    '--repo', $repoLinux
)

if ($VerifyOnly) {
    $arguments += '--verify-only'
}
if ($ProbeFrames -gt 0) {
    $arguments += @('--probe-frames', $ProbeFrames.ToString())
}
if ($Stress) {
    $arguments += @('--stress', '--stress-seconds', $StressSeconds.ToString())
}
if ($ConnectionProbe) {
    $arguments += '--connection-probe'
}

& wsl.exe @arguments
$exitCode = $LASTEXITCODE
if ($exitCode -ne 0) {
    throw "Low-performance proxy failed with exit code $exitCode."
}
exit 0
