[CmdletBinding()]
param(
    [string]$LegacyPercivalRoot = 'D:\WORK\Scripts\PERCIVAL',
    [switch]$IncludePlaso
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$toolRoot = $PSScriptRoot
$binarySource = Join-Path $LegacyPercivalRoot 'binaries'
$ezSource = Join-Path $LegacyPercivalRoot 'EZ'
$plasoSource = Join-Path $LegacyPercivalRoot 'plaso'
$binaryDest = Join-Path $toolRoot 'binaries'
$ezDest = Join-Path $toolRoot 'EZ'
$plasoDest = Join-Path $toolRoot 'plaso'

foreach ($path in @($binaryDest, $ezDest)) {
    if (-not (Test-Path -LiteralPath $path)) {
        New-Item -ItemType Directory -Path $path -Force | Out-Null
    }
}

if (-not (Test-Path -LiteralPath $LegacyPercivalRoot)) {
    throw "Legacy PERCIVAL root not found: $LegacyPercivalRoot"
}

if (Test-Path -LiteralPath $binarySource) {
    robocopy.exe $binarySource $binaryDest /E /XD KAPE /XF kape.exe gkape.exe *.tkape *.mkape Kape.layout /R:1 /W:1
}

if (Test-Path -LiteralPath $ezSource) {
    robocopy.exe $ezSource $ezDest /E /XD KAPE /XF kape.exe gkape.exe *.tkape *.mkape Kape.layout /R:1 /W:1
}

$aliases = @{
    'psfile.exe.exe' = 'psfile.exe'
    'robocopy.exe.exe' = 'robocopy.exe'
    'tee.exe.exe' = 'tee.exe'
}

foreach ($alias in $aliases.GetEnumerator()) {
    $source = Join-Path $binaryDest $alias.Key
    $dest = Join-Path $binaryDest $alias.Value
    if ((Test-Path -LiteralPath $source) -and -not (Test-Path -LiteralPath $dest)) {
        Copy-Item -LiteralPath $source -Destination $dest -Force
    }
}

if ($IncludePlaso -and (Test-Path -LiteralPath $plasoSource)) {
    if (-not (Test-Path -LiteralPath $plasoDest)) {
        New-Item -ItemType Directory -Path $plasoDest -Force | Out-Null
    }
    robocopy.exe $plasoSource $plasoDest /E /R:1 /W:1
}

Write-Host "Tool import complete. KAPE executables and KAPE module/target files were excluded."
