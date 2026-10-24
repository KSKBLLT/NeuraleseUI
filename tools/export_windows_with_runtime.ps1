param(
    [string]$ProjectRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path,
    [string]$GodotExe = "D:\SteamLibrary\steamapps\common\Godot Engine\godot.windows.opt.tools.64.exe",
    [string]$Preset = "Windows Desktop",
    [string]$Output = "",
    [switch]$SkipExportSmokeTest
)

$ErrorActionPreference = "Stop"

if (!(Test-Path $GodotExe)) {
    throw "Godot executable not found: $GodotExe"
}

$ProjectRoot = (Resolve-Path -LiteralPath $ProjectRoot).Path
$OutputPath = ""
if ($Output.Trim() -ne "") {
    $OutputPath = if ([System.IO.Path]::IsPathRooted($Output)) {
        [System.IO.Path]::GetFullPath($Output)
    }
    else {
        [System.IO.Path]::GetFullPath((Join-Path $ProjectRoot $Output))
    }

    $OutputDirectory = Split-Path -Parent $OutputPath
    New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null

    # Never let the installer silently reuse an executable from an older checkout.
    if (Test-Path -LiteralPath $OutputPath) {
        Remove-Item -LiteralPath $OutputPath -Force
    }
}

function Get-GodotProcesses([string]$exePath) {
    Get-Process -ErrorAction SilentlyContinue | Where-Object {
        try {
            [string]::Equals($_.Path, $exePath, [System.StringComparison]::OrdinalIgnoreCase)
        }
        catch {
            $false
        }
    }
}

function Wait-NewGodotProcesses([string]$exePath, [int[]]$beforeIds, [datetime]$startedAt) {
    # The Steam Godot tools executable can return control before its worker process
    # has finished first-scan/export work. Wait for newly spawned Godot processes
    # to disappear before continuing to installer packaging.
    $quietRounds = 0
    while ($quietRounds -lt 3) {
        $running = @(
            Get-GodotProcesses $exePath | Where-Object {
                ($beforeIds -notcontains $_.Id) -or ($_.StartTime -ge $startedAt.AddSeconds(-2))
            }
        )

        if ($running.Count -eq 0) {
            $quietRounds += 1
            Start-Sleep -Milliseconds 500
            continue
        }

        $quietRounds = 0
        Start-Sleep -Milliseconds 500
    }
}

$args = @("--headless", "--path", $ProjectRoot, "--export-release", $Preset)
if ($OutputPath -ne "") {
    $args += $OutputPath
}

$beforeGodotIds = @(Get-GodotProcesses $GodotExe | Select-Object -ExpandProperty Id)
$startedAt = Get-Date
& $GodotExe @args
$exitCode = $LASTEXITCODE
Wait-NewGodotProcesses $GodotExe $beforeGodotIds $startedAt

if ($exitCode -ne 0) {
    throw "Godot export failed with exit code $exitCode"
}

if ($OutputPath -ne "") {
    if (!(Test-Path -LiteralPath $OutputPath)) {
        throw "Godot export did not create the expected executable: $OutputPath"
    }

    $ExportedFile = Get-Item -LiteralPath $OutputPath
    if ($ExportedFile.LastWriteTimeUtc -lt $startedAt.ToUniversalTime().AddSeconds(-2)) {
        throw "Godot export returned a stale executable: $OutputPath"
    }
    if ($ExportedFile.Length -lt 1MB) {
        throw "Godot export produced an unexpectedly small executable: $OutputPath"
    }
}

if (!$SkipExportSmokeTest) {
    if ($OutputPath.Trim() -eq "") {
        throw "Export smoke test requires an explicit -Output path. Pass -SkipExportSmokeTest only when the preset output cannot be resolved here."
    }

    $smokeLog = Join-Path ([IO.Path]::GetTempPath()) ("neuralese-export-smoke-{0}.log" -f [Guid]::NewGuid().ToString("N"))
    $smokeProcess = $null
    try {
        $smokeProcess = Start-Process `
            -FilePath $OutputPath `
            -ArgumentList @(
                "--position", "-32000,-32000",
                "--log-file", $smokeLog
            ) `
            -WindowStyle Hidden `
            -PassThru

        # Exercise the real viewport/layout path. A 1x1 window hid exported-only
        # camera lifecycle crashes because the background never rendered normally.
        if ($smokeProcess.WaitForExit(30000)) {
            throw "Exported executable exited during its startup smoke test with code $($smokeProcess.ExitCode)"
        }

        Stop-Process -Id $smokeProcess.Id -Force
        $smokeProcess.WaitForExit()
        $smokeProcess = $null

        if (!(Test-Path -LiteralPath $smokeLog)) {
            throw "Exported executable smoke test did not produce a Godot log"
        }

        $fatalMarkers = @(
            "SCRIPT ERROR: Parse Error",
            "SCRIPT ERROR: Compile Error",
            "Failed to load script",
            "Failed loading resource:",
            "Zoom level must be different from 0"
        )
        $fatalLines = @(Select-String -LiteralPath $smokeLog -SimpleMatch -Pattern $fatalMarkers)
        if ($fatalLines.Count -gt 0) {
            $details = ($fatalLines | ForEach-Object { $_.Line.Trim() }) -join [Environment]::NewLine
            throw "Exported executable contains startup script/resource failures:$([Environment]::NewLine)$details"
        }
    }
    finally {
        if ($smokeProcess -ne $null -and !$smokeProcess.HasExited) {
            Stop-Process -Id $smokeProcess.Id -Force -ErrorAction SilentlyContinue
            $smokeProcess.WaitForExit()
        }
        if (Test-Path -LiteralPath $smokeLog) {
            Remove-Item -LiteralPath $smokeLog -Force
        }
    }
}

Write-Host "Neuralese Windows export completed: $OutputPath"
