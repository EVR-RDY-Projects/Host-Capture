[CmdletBinding()]
param(
    [string]$CollectionRoot,
    [string]$CaseRoot,
    [string]$ToolRoot,
    [string]$CaptureName,
    [ValidateSet('Ask','Analysis','Timeline','Memory','All')]
    [string]$Mode = 'Ask',
    [ValidateSet('Native','External','Auto')]
    [string]$ParserSet = 'Native',
    [int]$MaxEventsPerLog = 5000,
    [int]$MaxTextContentBytes = 262144,
    [switch]$NoPrompt,
    [switch]$PlanOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = Split-Path -Parent $ScriptRoot
if (-not $CollectionRoot) { $CollectionRoot = Join-Path $ProjectRoot 'Collection' }
if (-not $CaseRoot) { $CaseRoot = Join-Path $ProjectRoot 'Cases' }
if (-not $ToolRoot) { $ToolRoot = Join-Path $ProjectRoot 'Tools' }

function New-Directory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Path $Path -Force | Out-Null
    }
}

function Write-Log {
    param([Parameter(Mandatory)][string]$Message)
    $line = '{0:u} {1}' -f (Get-Date), $Message
    Write-Host $line
    Add-Content -LiteralPath $script:LogFile -Value $line
}

function Find-Tool {
    param([Parameter(Mandatory)][string[]]$Names)
    foreach ($name in $Names) {
        foreach ($root in @((Join-Path $ToolRoot 'EZ'), (Join-Path $ToolRoot 'binaries'), $ToolRoot)) {
            $candidate = Join-Path $root $name
            if (Test-Path -LiteralPath $candidate) { return $candidate }
            if (Test-Path -LiteralPath $root) {
                $recursive = Get-ChildItem -LiteralPath $root -Recurse -File -Filter $name -ErrorAction SilentlyContinue | Select-Object -First 1
                if ($recursive) { return $recursive.FullName }
            }
        }
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) { return $cmd.Source }
    }
    return $null
}

function Invoke-Tool {
    param(
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Exe,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    Write-Log "Running $Label"
    & $Exe @Arguments >> $script:LogFile 2>&1
}

function Export-JsonFile {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    New-Directory (Split-Path -Parent $Path)
    $InputObject | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $Path -Encoding UTF8
}

function Get-FileInventory {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $root = (Resolve-Path -LiteralPath $Path).Path
    @(Get-ChildItem -LiteralPath $Path -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object {
        [pscustomobject]@{
            RelativePath = $_.FullName.Substring($root.Length).TrimStart('\')
            Name = $_.Name
            Extension = $_.Extension
            Length = $_.Length
            CreationTimeUtc = $_.CreationTimeUtc.ToString('o')
            LastWriteTimeUtc = $_.LastWriteTimeUtc.ToString('o')
            FullName = $_.FullName
        }
    })
}

function Convert-TextFolderNative {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$OutputPath)
    $txt = Join-Path $InputPath 'TXT'
    if (-not (Test-Path -LiteralPath $txt)) { return }
    $txtOut = Join-Path $OutputPath 'TXT'
    $jsonOut = Join-Path $txtOut 'json'
    New-Directory $txtOut
    New-Directory $jsonOut
    robocopy.exe $txt $txtOut /E /R:1 /W:1 >> $script:LogFile 2>&1
    $summary = @()
    Get-ChildItem -LiteralPath $txt -File -Filter '*.txt' -ErrorAction SilentlyContinue | ForEach-Object {
        $readBytes = [Math]::Min($_.Length, $MaxTextContentBytes)
        $buffer = New-Object byte[] $readBytes
        $stream = [IO.File]::OpenRead($_.FullName)
        try {
            [void]$stream.Read($buffer, 0, $readBytes)
        } finally {
            $stream.Dispose()
        }
        $content = [Text.Encoding]::Default.GetString($buffer)
        $truncated = $_.Length -gt $MaxTextContentBytes
        $lines = @(if ([string]::IsNullOrEmpty($content)) { @() } else { $content -split "`r?`n" })
        Export-JsonFile ([pscustomobject]@{
            Name = $_.Name
            Stem = $_.BaseName
            Length = $_.Length
            LineCount = $lines.Count
            Truncated = $truncated
            MaxTextContentBytes = $MaxTextContentBytes
            Content = $content
        }) (Join-Path $jsonOut "$($_.BaseName).json")
        $summary += [pscustomobject]@{
            Name = $_.Name
            Stem = $_.BaseName
            Length = $_.Length
            LineCount = $lines.Count
        }
    }
    Export-JsonFile $summary (Join-Path $txtOut 'txt_summary.json')
}

function Convert-EventLogsNative {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$OutputPath)
    foreach ($folder in @('Evt','Evtx')) {
        $eventPath = Join-Path $InputPath $folder
        if (-not (Test-Path -LiteralPath $eventPath)) { continue }
        $eventOut = Join-Path $OutputPath $folder
        New-Directory $eventOut
        Export-JsonFile (Get-FileInventory $eventPath) (Join-Path $eventOut 'eventlog_inventory.json')
        Get-ChildItem -LiteralPath $eventPath -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.evtx','.evt') } | ForEach-Object {
            $sourceFile = $_.FullName
            try {
                $events = @(Get-WinEvent -Path $sourceFile -MaxEvents $MaxEventsPerLog -ErrorAction Stop | ForEach-Object {
                    [pscustomobject]@{
                        TimeCreated = if ($_.TimeCreated) { $_.TimeCreated.ToUniversalTime().ToString('o') } else { $null }
                        Id = $_.Id
                        LevelDisplayName = $_.LevelDisplayName
                        ProviderName = $_.ProviderName
                        LogName = $_.LogName
                        MachineName = $_.MachineName
                        RecordId = $_.RecordId
                        Message = $_.Message
                    }
                })
            } catch {
                $events = @([pscustomobject]@{
                    Error = $_.Exception.Message
                    SourceFile = $sourceFile
                    Note = 'Native parser could not read this event log on the analyst host.'
                })
            }
            Export-JsonFile ([pscustomobject]@{
                SourceFile = $sourceFile
                MaxEvents = $MaxEventsPerLog
                Count = $events.Count
                Events = $events
            }) (Join-Path $eventOut "$($_.BaseName).json")
        }
    }
}

function Convert-InventoryNative {
    param(
        [Parameter(Mandatory)][string]$InputPath,
        [Parameter(Mandatory)][string]$OutputPath,
        [Parameter(Mandatory)][string[]]$Folders
    )
    foreach ($folder in $Folders) {
        $source = Join-Path $InputPath $folder
        if (-not (Test-Path -LiteralPath $source)) { continue }
        $dest = Join-Path $OutputPath $folder
        New-Directory $dest
        Export-JsonFile ([pscustomobject]@{
            Parser = 'NativeInventory'
            Folder = $folder
            Note = 'Binary artifact inventory only. Full semantic parsing requires a custom parser for this artifact type.'
            Files = Get-FileInventory $source
        }) (Join-Path $dest "$($folder)_inventory.json")
    }
}

function Run-NativeAnalysis {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$OutputPath)
    Write-Log 'Running native analysis mode'
    Export-JsonFile ([pscustomobject]@{
        Capture = $InputPath
        Case = $OutputPath
        ParserSet = 'Native'
        GeneratedUtc = (Get-Date).ToUniversalTime().ToString('o')
        EzToolsUsed = $false
    }) (Join-Path $OutputPath 'native-analysis-manifest.json')
    Convert-TextFolderNative -InputPath $InputPath -OutputPath $OutputPath
    Convert-EventLogsNative -InputPath $InputPath -OutputPath $OutputPath
    Convert-InventoryNative -InputPath $InputPath -OutputPath $OutputPath -Folders @(
        'Registry','File_System','Prefetch','Amcache','Jumplist','LNK',
        'Shellbags','Appcompatcache','ActivitiesCache','Shim','SRUM','Browsers',
        'ScheduledTasks','Defender','WER','CloudStorage','RemoteAdmin','Critical'
    )
}

function Run-ExternalAnalysis {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$OutputPath)

    foreach ($rawFolder in @('TXT','Registry','File_System','Prefetch','Evtx','Evt','Amcache','Jumplist','LNK','ActivitiesCache','Shim','SRUM')) {
        $source = Join-Path $InputPath $rawFolder
        if (Test-Path -LiteralPath $source) {
            New-Directory (Join-Path $OutputPath $rawFolder)
        }
    }

    $prefetch = Join-Path $InputPath 'Prefetch'
    $prefetchOut = Join-Path $OutputPath 'Prefetch'
    $pecmd = Find-Tool @('PECmd.exe')
    if ($pecmd -and (Test-Path -LiteralPath $prefetch)) {
        New-Directory $prefetchOut
        Invoke-Tool 'PECmd prefetch parser' $pecmd @('-d', $prefetch, '--csv', $prefetchOut, '--json', $prefetchOut, '--jsonpretty')
    }

    $evtxecmd = Find-Tool @('EvtxECmd.exe')
    foreach ($eventFolder in @('Evt','Evtx')) {
        $eventPath = Join-Path $InputPath $eventFolder
        $eventOut = Join-Path $OutputPath $eventFolder
        if ($evtxecmd -and (Test-Path -LiteralPath $eventPath)) {
            New-Directory $eventOut
            Invoke-Tool "EvtxECmd $eventFolder parser" $evtxecmd @('-d', $eventPath, '--csv', $eventOut, '--json', $eventOut)
        }
    }

    $registry = Join-Path $InputPath 'Registry'
    $registryOut = Join-Path $OutputPath 'Registry'
    $recmd = Find-Tool @('RECmd.exe')
    if ($recmd -and (Test-Path -LiteralPath $registry)) {
        New-Directory $registryOut
        $batchRoot = Join-Path (Split-Path -Parent $recmd) 'BatchExamples'
        foreach ($batch in @('RegistryASEPs.reb','UserActivity.reb','SoftwareASEPs.reb','BasicSystemInfo.reb')) {
            $batchPath = Join-Path $batchRoot $batch
            if (Test-Path -LiteralPath $batchPath) {
                Invoke-Tool "RECmd $batch" $recmd @('--bn', $batchPath, '-d', $registry, '--csv', $registryOut, '--json', $registryOut, '--nl')
            }
        }
    }

    $mftRoot = Join-Path $InputPath 'File_System'
    $mftOut = Join-Path $OutputPath 'File_System'
    $mftecmd = Find-Tool @('MFTECmd.exe')
    if ($mftecmd -and (Test-Path -LiteralPath $mftRoot)) {
        New-Directory $mftOut
        Get-ChildItem -LiteralPath $mftRoot -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\$MFT' -or $_.Name -eq '$MFT' } |
            Where-Object { $_.Name -notmatch '\$LogFile' } |
            ForEach-Object { Invoke-Tool 'MFTECmd MFT parser' $mftecmd @('-f', $_.FullName, '--csv', $mftOut, '--csvf', 'MFT.csv', '--json', $mftOut, '--jsonf', 'MFT.json') }
    }

    $amcache = Join-Path $InputPath 'Amcache'
    $amcacheOut = Join-Path $OutputPath 'Amcache'
    $amcacheParser = Find-Tool @('AmcacheParser.exe')
    $recentParser = Find-Tool @('RecentFileCacheParser.exe')
    if (Test-Path -LiteralPath $amcache) {
        New-Directory $amcacheOut
        $amcacheHive = Join-Path $amcache 'Amcache.hve'
        $recentFile = Join-Path $amcache 'RecentFileCache.bcf'
        if ($amcacheParser -and (Test-Path -LiteralPath $amcacheHive)) {
            Invoke-Tool 'Amcache parser' $amcacheParser @('-f', $amcacheHive, '--csv', $amcacheOut, '--csvf', 'amcache.csv')
        }
        if ($recentParser -and (Test-Path -LiteralPath $recentFile)) {
            Invoke-Tool 'RecentFileCache parser' $recentParser @('-f', $recentFile, '--csv', $amcacheOut, '--csvf', 'RecentFileCache.csv', '--json', $amcacheOut, '--jsonpretty')
        }
    }

    $jump = Join-Path $InputPath 'Jumplist'
    $jumpOut = Join-Path $OutputPath 'Jumplist'
    $jlecmd = Find-Tool @('JLECmd.exe')
    if ($jlecmd -and (Test-Path -LiteralPath $jump)) {
        Get-ChildItem -LiteralPath $jump -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $userOut = Join-Path $jumpOut $_.Name
            New-Directory $userOut
            Invoke-Tool "JLECmd jumplist parser $($_.Name)" $jlecmd @('-d', $_.FullName, '--csv', $userOut, '--json', $userOut, '--jsonpretty')
        }
    }

    $lnk = Join-Path $InputPath 'LNK'
    $lnkOut = Join-Path $OutputPath 'LNK'
    $lecmd = Find-Tool @('LECmd.exe')
    if ($lecmd -and (Test-Path -LiteralPath $lnk)) {
        New-Directory $lnkOut
        Invoke-Tool 'LECmd shortcut parser' $lecmd @('-d', $lnk, '--csv', $lnkOut, '--json', $lnkOut, '--jsonpretty')
    }

    $shellbagsOut = Join-Path $OutputPath 'Shellbags'
    $sbecmd = Find-Tool @('SBECmd.exe')
    if ($sbecmd -and (Test-Path -LiteralPath $registry)) {
        New-Directory $shellbagsOut
        Invoke-Tool 'SBECmd shellbags parser' $sbecmd @('-d', $registry, '--csv', $shellbagsOut, '--json', $shellbagsOut, '--dedupe')
    }

    $appcompatOut = Join-Path $OutputPath 'Appcompatcache'
    $appcompat = Find-Tool @('AppCompatCacheParser.exe')
    $systemHive = Join-Path $registry 'SYSTEM'
    if ($appcompat -and (Test-Path -LiteralPath $systemHive)) {
        New-Directory $appcompatOut
        $hasSystemLogs = [bool](Get-ChildItem -LiteralPath $registry -File -Filter 'SYSTEM.log*' -ErrorAction SilentlyContinue)
        $args = @('-f', $systemHive, '--csv', $appcompatOut, '--csvf', 'appcompatcache.csv')
        if (-not $hasSystemLogs) { $args += '-nl' }
        Invoke-Tool 'AppCompatCache parser' $appcompat $args
    }

    $activity = Join-Path $InputPath 'ActivitiesCache'
    $activityOut = Join-Path $OutputPath 'ActivitiesCache'
    $wxtcmd = Find-Tool @('WxTCmd.exe')
    if ($wxtcmd -and (Test-Path -LiteralPath $activity)) {
        Get-ChildItem -LiteralPath $activity -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $userOut = Join-Path $activityOut $_.Name
            New-Directory $userOut
            Get-ChildItem -LiteralPath $_.FullName -Recurse -File -Filter 'ActivitiesCache.db' -ErrorAction SilentlyContinue |
                ForEach-Object { Invoke-Tool "WxTCmd Windows Timeline parser $($_.Name)" $wxtcmd @('-f', $_.FullName, '--csv', $userOut) }
        }
    }

    $txt = Join-Path $InputPath 'TXT'
    if (Test-Path -LiteralPath $txt) {
        robocopy.exe $txt (Join-Path $OutputPath 'TXT') /E /R:1 /W:1 >> $script:LogFile 2>&1
    }
}

function Run-Timeline {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$OutputPath)
    $plaso = Join-Path $ToolRoot 'plaso'
    $log2timeline = Join-Path $plaso 'log2timeline.exe'
    $psort = Join-Path $plaso 'psort.exe'
    if (-not (Test-Path -LiteralPath $log2timeline) -or -not (Test-Path -LiteralPath $psort)) {
        Write-Log 'Timeline skipped: Tools\plaso\log2timeline.exe and psort.exe were not found.'
        return
    }

    $timelineOut = Join-Path $OutputPath 'timeline'
    New-Directory $timelineOut
    $dump = Join-Path $timelineOut "$((Split-Path -Leaf $InputPath)).dump"
    $csv = Join-Path $timelineOut "$((Split-Path -Leaf $InputPath)).csv"
    Invoke-Tool 'log2timeline' $log2timeline @($dump, $InputPath)
    Invoke-Tool 'psort timeline csv' $psort @('-z', 'EST', '-o', 'l2tcsv', '-w', $csv, $dump, "date > '2020-03-01 00:00:00'")
}

function Run-Memory {
    param([Parameter(Mandatory)][string]$InputPath, [Parameter(Mandatory)][string]$OutputPath)
    $memory = Join-Path $InputPath 'Memory'
    $memorySearchRoot = if (Test-Path -LiteralPath $memory) { $memory } else { $InputPath }
    $uncompress = if ([Environment]::Is64BitOperatingSystem) {
        Find-Tool @('Z2DMP_uncompress_dmp64.exe','Z2DMP_uncompress_dmp.exe')
    } else {
        Find-Tool @('Z2DMP_uncompress_dmp.exe')
    }
    Get-ChildItem -LiteralPath $memorySearchRoot -File -Filter '*.zdmp' -ErrorAction SilentlyContinue | ForEach-Object {
        if ($uncompress) {
            $dest = Join-Path $OutputPath "$((Split-Path -Leaf $InputPath)).dmp"
            Invoke-Tool 'Z2DMP memory decompression' $uncompress @($_.FullName, $dest)
        } else {
            Write-Log "Compressed memory present but no Z2DMP tool found: $($_.FullName)"
        }
    }
    Get-ChildItem -LiteralPath $memorySearchRoot -File -Filter '*.raw' -ErrorAction SilentlyContinue |
        Copy-Item -Destination $OutputPath -Force
}

New-Directory $CaseRoot
$EffectiveMode = $Mode
if ($EffectiveMode -eq 'Ask' -and -not $NoPrompt) {
    Write-Host "`nWhat mode would you like to run:"
    Write-Host '1 : Analysis'
    Write-Host '2 : Timeline'
    Write-Host '3 : Uncompress'
    Write-Host '4 : Exit'
    $modeAnswer = Read-Host 'Select Mode, then press ENTER'
    $EffectiveMode = switch ($modeAnswer) {
        '1' { 'Analysis' }
        '2' { 'Timeline' }
        '3' { 'Memory' }
        '4' { 'Exit' }
        default { 'Ask' }
    }
    if ($EffectiveMode -eq 'Ask') { exit 1 }
    if ($EffectiveMode -eq 'Exit') { exit 0 }
}
if ($EffectiveMode -eq 'Ask') { $EffectiveMode = 'All' }

$captures = @(Get-ChildItem -LiteralPath $CollectionRoot -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^\.|^Tools$' } |
    Sort-Object LastWriteTime)

if ($CaptureName) {
    $captures = @($captures | Where-Object { $_.Name -like $CaptureName })
}

if (-not $captures) {
    Write-Error "No captures found under $CollectionRoot"
    exit 1
}

if (-not $NoPrompt -and -not $CaptureName -and $captures.Count -gt 1) {
    Write-Host "`nCaptures:"
    for ($i = 0; $i -lt $captures.Count; $i++) {
        Write-Host ("{0}. {1}" -f ($i + 1), $captures[$i].Name)
    }
    $answer = Read-Host 'Select capture number or all'
    if ($answer -notmatch '^(a|all)$') {
        $selected = [int]$answer - 1
        $captures = @($captures[$selected])
    }
}

foreach ($capture in $captures) {
    $casePath = Join-Path $CaseRoot $capture.Name
    if ($PlanOnly) {
        [pscustomobject]@{
            Capture = $capture.FullName
            Case = $casePath
            RequestedMode = $Mode
            EffectiveMode = $EffectiveMode
            ParserSet = $ParserSet
        } | Format-List
        continue
    }
    New-Directory $casePath
    $script:LogFile = Join-Path $casePath 'process.log'
    Set-Content -LiteralPath $LogFile -Value "NoKape processing log for $($capture.Name)"
    Write-Log "Processing $($capture.FullName)"
    if ($EffectiveMode -in @('Analysis','All')) {
        if ($ParserSet -eq 'Native') {
            Run-NativeAnalysis -InputPath $capture.FullName -OutputPath $casePath
        } elseif ($ParserSet -eq 'External') {
            Run-ExternalAnalysis -InputPath $capture.FullName -OutputPath $casePath
        } else {
            Run-NativeAnalysis -InputPath $capture.FullName -OutputPath $casePath
            Run-ExternalAnalysis -InputPath $capture.FullName -OutputPath $casePath
        }
    }
    if ($EffectiveMode -in @('Timeline','All')) { Run-Timeline -InputPath $capture.FullName -OutputPath $casePath }
    if ($EffectiveMode -in @('Memory','All')) { Run-Memory -InputPath $capture.FullName -OutputPath $casePath }
    Write-Log "Finished $($capture.Name)"
}
