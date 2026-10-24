param(
    [Parameter(Mandatory = $true)]
    [string]$MsiPath,
    [string]$ExpectedVersion = "",
    [string]$ExpectedExeSha256 = "",
    [string]$LogDirectory = ""
)

$ErrorActionPreference = "Stop"

$MsiPath = (Resolve-Path -LiteralPath $MsiPath).Path
if ($LogDirectory.Trim() -eq "") {
    $LogDirectory = Join-Path $env:RUNNER_TEMP "managed-msi-test"
}
New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null

$installRoot = Join-Path $env:ProgramFiles "Neuralese"
$installedExe = Join-Path $installRoot "Neuralese.exe"
$runtimeManifest = Join-Path $installRoot "local_runtime\windows-x64\.neuralese_runtime_manifest.json"
$runtimePython = Join-Path $installRoot "local_runtime\windows-x64\python\python.exe"
$desktopShortcut = Join-Path $env:PUBLIC "Desktop\Neuralese.lnk"
$startMenuShortcut = Join-Path $env:ProgramData "Microsoft\Windows\Start Menu\Programs\Neuralese.lnk"
$sentinelRoot = Join-Path $env:ProgramData "Neuralese\ManagedMsiSmoke"
$sentinel = Join-Path $sentinelRoot "keep.txt"

function Invoke-MsiExec([string[]]$Arguments, [string]$Name, [int]$TimeoutSeconds = 480) {
    Write-Host "START $Name"
    $started = Get-Date
    $lastHeartbeat = $started
    $process = Start-Process -FilePath "$env:SystemRoot\System32\msiexec.exe" -ArgumentList $Arguments -PassThru
    while (-not $process.HasExited) {
        $now = Get-Date
        if (($now - $started).TotalSeconds -ge $TimeoutSeconds) {
            $process.Kill($true)
            throw "$Name exceeded its $TimeoutSeconds second timeout"
        }
        if (($now - $lastHeartbeat).TotalSeconds -ge 30) {
            Write-Host "WAIT $Name ($([int]($now - $started).TotalSeconds)s)"
            $lastHeartbeat = $now
        }
        Start-Sleep -Seconds 1
        $process.Refresh()
    }
    if ($process.ExitCode -notin @(0, 3010)) {
        throw "$Name failed with Windows Installer exit code $($process.ExitCode)"
    }
    Write-Host "PASS $Name ($([int]((Get-Date) - $started).TotalSeconds)s)"
}

function Assert-Exists([string]$Path, [string]$Description) {
    if (-not (Test-Path -LiteralPath $Path)) {
        throw "$Description is missing: $Path"
    }
}

function Assert-NotExists([string]$Path, [string]$Description) {
    if (Test-Path -LiteralPath $Path) {
        throw "$Description still exists: $Path"
    }
}

function Find-ManagedArpEntries() {
    $roots = @(
        "HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall",
        "HKLM:\Software\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall"
    )
    $entries = @()
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        foreach ($key in Get-ChildItem -LiteralPath $root) {
            $item = Get-ItemProperty -LiteralPath $key.PSPath
            if ($item.DisplayName -eq "Neuralese (Managed)") {
                $entries += $item
            }
        }
    }
    return @($entries)
}

function Start-NeuraleseDesktopSmoke() {
    $stdoutLog = Join-Path $LogDirectory "neuralese.stdout.log"
    $stderrLog = Join-Path $LogDirectory "neuralese.stderr.log"
    $process = Start-Process -FilePath $installedExe `
        -ArgumentList @("--rendering-method", "gl_compatibility", "--quit-after", "180", "--verbose") `
        -RedirectStandardOutput $stdoutLog `
        -RedirectStandardError $stderrLog `
        -PassThru
    if (-not $process.WaitForExit(90000)) {
        $process.Kill($true)
        throw "Installed Neuralese did not finish its bounded desktop startup within 90 seconds"
    }
    if ($process.ExitCode -ne 0) {
        throw "Installed Neuralese desktop startup failed with exit code $($process.ExitCode); inspect $stdoutLog and $stderrLog"
    }
}

if ((Find-ManagedArpEntries).Count -ne 0 -or (Test-Path -LiteralPath $installRoot)) {
    throw "Refusing to test over an existing Neuralese managed installation"
}

try {
    New-Item -ItemType Directory -Path $sentinelRoot -Force | Out-Null
    Set-Content -LiteralPath $sentinel -Value "school-data-must-survive" -Encoding ascii

    Invoke-MsiExec @(
        "/i", $MsiPath,
        "/qn", "/norestart",
        "/l*v", (Join-Path $LogDirectory "install.log")
    ) "Real MSI silent install"

    Assert-Exists $installedExe "Installed Neuralese executable"
    Assert-Exists $runtimeManifest "Installed runtime manifest"
    Assert-Exists $runtimePython "Installed Python runtime"
    Assert-Exists (Join-Path $installRoot ".neuralese-managed-install") "Managed install marker"
    Assert-Exists $desktopShortcut "Common desktop shortcut"
    Assert-Exists $startMenuShortcut "Common Start Menu shortcut"
    if ((Get-Item -LiteralPath $installedExe).Length -le 10MB) {
        throw "Installed Neuralese executable is unexpectedly small"
    }
    if ($ExpectedExeSha256.Trim() -ne "") {
        $installedExeSha = (Get-FileHash -LiteralPath $installedExe -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($installedExeSha -ne $ExpectedExeSha256.ToLowerInvariant()) {
            throw "Installed Neuralese executable does not match the freshly exported application"
        }
    }

    $arpEntries = @(Find-ManagedArpEntries)
    if ($arpEntries.Count -ne 1) {
        throw "Expected one managed ARP entry; found $($arpEntries.Count)"
    }
    if ($ExpectedVersion.Trim() -ne "" -and $arpEntries[0].DisplayVersion -ne $ExpectedVersion) {
        throw "Expected ARP version $ExpectedVersion; found $($arpEntries[0].DisplayVersion)"
    }

    Start-NeuraleseDesktopSmoke

    Invoke-MsiExec @(
        "/x", $MsiPath,
        "/qn", "/norestart",
        "/l*v", (Join-Path $LogDirectory "uninstall.log")
    ) "Real MSI silent uninstall"

    Assert-NotExists $installRoot "Managed install root"
    Assert-NotExists $desktopShortcut "Common desktop shortcut"
    Assert-NotExists $startMenuShortcut "Common Start Menu shortcut"
    Assert-Exists $sentinel "External school data sentinel"
    if ((Find-ManagedArpEntries).Count -ne 0) {
        throw "Managed ARP entry remained after uninstall"
    }

    Write-Host "PASS real-managed-msi-smoke"
}
finally {
    foreach ($entry in @(Find-ManagedArpEntries)) {
        if ($entry.PSChildName -match '^\{[0-9A-Fa-f-]+\}$') {
            try {
                Invoke-MsiExec @("/x", $entry.PSChildName, "/qn", "/norestart") "Cleanup uninstall" 300
            }
            catch {
                Write-Warning $_
            }
        }
    }
    Remove-Item -LiteralPath $installRoot -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $desktopShortcut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $startMenuShortcut -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $sentinelRoot -Recurse -Force -ErrorAction SilentlyContinue
}
