# Build neuralese_bt.exe (see neuralese_bt.cs) into windows-x64/.
#
# Needs a developer machine with the Roslyn C# compiler (Visual Studio or Build
# Tools), the .NET Framework 4.8 reference assemblies and a Windows 10/11 SDK.
# The built exe needs none of that: .NET Framework 4.8 is part of Windows.
param(
    [string]$Csc = "",
    [string]$Sdk = ""
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path

if (-not $Csc) {
    $vswhere = "${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
    if (Test-Path $vswhere) {
        $vs = & $vswhere -latest -products * -requires Microsoft.Component.MSBuild -property installationPath
        if ($vs) { $Csc = Join-Path $vs "MSBuild\Current\Bin\Roslyn\csc.exe" }
    }
}
if (-not $Csc -or -not (Test-Path $Csc)) { throw "Roslyn csc.exe not found; pass -Csc <path>." }

$ref = "${env:ProgramFiles(x86)}\Reference Assemblies\Microsoft\Framework\.NETFramework\v4.8"
if (-not (Test-Path $ref)) { throw ".NET Framework 4.8 reference assemblies not found at $ref" }

if (-not $Sdk) {
    $union = "${env:ProgramFiles(x86)}\Windows Kits\10\UnionMetadata"
    $Sdk = Get-ChildItem $union -Directory |
        Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' -and (Test-Path (Join-Path $_.FullName "Windows.winmd")) } |
        Sort-Object { [version]$_.Name } | Select-Object -Last 1 | ForEach-Object { $_.FullName }
}
$winmd = Join-Path $Sdk "Windows.winmd"
if (-not (Test-Path $winmd)) { throw "Windows.winmd not found; pass -Sdk <UnionMetadata\version>." }

$fw = "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319"
$out = Join-Path $here "windows-x64"
New-Item -ItemType Directory -Force $out | Out-Null

& $Csc -nologo -nostdlib -noconfig -optimize+ -platform:anycpu `
    "-out:$(Join-Path $out 'neuralese_bt.exe')" `
    "-r:$ref\mscorlib.dll" "-r:$ref\System.dll" "-r:$ref\System.Core.dll" `
    "-r:$ref\Facades\System.Runtime.dll" "-r:$ref\Facades\System.Threading.Tasks.dll" `
    "-r:$ref\Facades\System.Runtime.InteropServices.WindowsRuntime.dll" `
    "-r:$fw\System.Runtime.WindowsRuntime.dll" "-r:$winmd" `
    (Join-Path $here "neuralese_bt.cs")
if ($LASTEXITCODE -ne 0) { throw "csc failed ($LASTEXITCODE)" }
Write-Output "built $(Join-Path $out 'neuralese_bt.exe')"
