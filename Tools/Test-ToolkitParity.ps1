[CmdletBinding()]
param(
    [string]$Root,
    [switch]$RequireExternalParsers
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
if (-not $Root) { $Root = Split-Path -Parent $ScriptRoot }

$binaryRoot = Join-Path $Root 'Tools\binaries'
$ezRoot = Join-Path $Root 'Tools\EZ'
$captureRoot = Join-Path $Root 'Capture'

function Test-PathStatus {
    param(
        [Parameter(Mandatory)][string]$Category,
        [Parameter(Mandatory)][string]$Path
    )
    [pscustomobject]@{
        Category = $Category
        Item = $Path.Replace($Root, '').TrimStart('\')
        Present = Test-Path -LiteralPath $Path
    }
}

$results = New-Object System.Collections.Generic.List[object]

$captureTools = @(
    'DumpIt.exe',
    'DumpIt64.exe',
    'rawcopy.exe',
    'rawcopy64.exe',
    'robocopy.exe',
    'pslist.exe',
    'pslist64.exe',
    'psfile.exe',
    'psloggedon.exe',
    'psloggedon64.exe',
    'handle.exe',
    'listdlls.exe',
    'logonsessions.exe',
    'autorunsc.exe',
    'autorunsc64.exe',
    'sigcheck.exe',
    'sigcheck64.exe',
    'sigcheck_xp.exe',
    'ftkimager_CLI_version.exe',
    'mmls.exe',
    'MBRUtil.exe',
    'extractusnjournal.exe',
    'extranctusnjournal64.exe',
    'Z2DMP_uncompress_dmp.exe',
    'Z2DMP_uncompress_dmp64.exe'
)

foreach ($tool in $captureTools) {
    $results.Add((Test-PathStatus 'capture-tool' (Join-Path $binaryRoot $tool)))
}

$jsonParsers = @(
    'PECmd.exe',
    'RecentFileCacheParser.exe',
    'EvtxExplorer\EvtxECmd.exe',
    'RegistryExplorer\RECmd.exe',
    'MFTECmd.exe',
    'JLECmd.exe',
    'ShellBagsExplorer\SBECmd.exe',
    'LECmd.exe'
)

foreach ($tool in $jsonParsers) {
    $status = Test-PathStatus 'external-json-parser-optional' (Join-Path $ezRoot $tool)
    if ($RequireExternalParsers) { $status.Category = 'external-json-parser-required' }
    $results.Add($status)
}

$csvParsers = @(
    'AmcacheParser.exe',
    'AppCompatCacheParser.exe',
    'WxTCmd.exe'
)

foreach ($tool in $csvParsers) {
    $status = Test-PathStatus 'external-csv-parser-optional' (Join-Path $ezRoot $tool)
    if ($RequireExternalParsers) { $status.Category = 'external-csv-parser-required' }
    $results.Add($status)
}

$requiredScripts = @(
    'Start-Capture.bat',
    'Start-Process.bat',
    'Capture\Start-HostCapture.ps1',
    'Capture\Start-HostCaptureLegacy.bat',
    'Capture\XP_COMMANDS.txt',
    'Capture\MODERN_COMMANDS.txt',
    'Process\Start-HostProcess.ps1'
)

foreach ($script in $requiredScripts) {
    $results.Add((Test-PathStatus 'script' (Join-Path $Root $script)))
}

$kapeArtifacts = Get-ChildItem -LiteralPath (Join-Path $Root 'Tools') -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -match '^(kape|gkape)(\.|$)|\.(tkape|mkape)$|^Kape\.layout$' }

$results.Add([pscustomobject]@{
    Category = 'kape-exclusion'
    Item = 'No KAPE executables/modules/layouts copied'
    Present = -not [bool]$kapeArtifacts
})

$expectedLegacyNames = Get-Content -LiteralPath (Join-Path $captureRoot 'MODERN_COMMANDS.txt') |
    Where-Object { $_ -and $_ -notmatch '^;' } |
    ForEach-Object { ($_ -split '\s+', 2)[0] }

$chironNames = @(
    'uptime','netstat','arpcache','pslist','tasklist_svc','handlesummary','handles',
    'net_file','loadeddlls','ipconfig_all','netstat_r','ipconfig_displaydns',
    'psloggedon','logonsessions','net_sessions','psfile','autoruns','gplist',
    'atjobs','nbtstat_sessions','nbtstat_cache','net_view','net_view_localhost',
    'net_user','net_share','net_use','net_localgroup','net_group_administrators',
    'net_localgroup_users','net_localgroup_guests','net_localgroup_rdp',
    'net_localgroup_administrators','net_statistics_workstation',
    'net_statistics_server','schtasks','driverquery','driverquery_signed',
    'gpresult','netsh_interface_dump','netsh_show_helper','vssadmin_list_writers',
    'vssadmin_list_providers','vssadmin_list_shadows','wmic_process',
    'wmic_csproduct','wmic_serial','wmic_primiscadapters','wmic_computersystem',
    'wmic_logicaldisk','wmic_partition','wmic_nic','wmic_nicconfig',
    'wmic_onboarddevice','wmic_useraccount','wmic_netlogin','wmic_group',
    'wmic_service','wmic_jobs','wmic_startup','wmic_ntdomain_brief',
    'wmic_eventfilter','wmic_eventconsumer','wmic_filtertoconsumer'
)

foreach ($name in $chironNames) {
    $results.Add([pscustomobject]@{
        Category = 'modern-command-name'
        Item = $name
        Present = $expectedLegacyNames -contains $name
    })
}

$xpNames = Get-Content -LiteralPath (Join-Path $captureRoot 'XP_COMMANDS.txt') |
    Where-Object { $_ -and $_ -notmatch '^;' } |
    ForEach-Object { ($_ -split '\s+', 2)[0] }

foreach ($name in $chironNames[0..42]) {
    $results.Add([pscustomobject]@{
        Category = 'xp-command-name'
        Item = $name
        Present = $xpNames -contains $name
    })
}

$missing = $results | Where-Object {
    -not $_.Present -and (
        $_.Category -notmatch '-optional$'
    )
}
$results | Sort-Object Category,Item | Format-Table -AutoSize

if ($missing) {
    Write-Host "`nMissing parity items:" -ForegroundColor Red
    $missing | Sort-Object Category,Item | Format-Table -AutoSize
    exit 1
}

Write-Host "`nToolkit parity check passed." -ForegroundColor Green
