[CmdletBinding()]
param(
    [ValidateSet('Ask','Full','Legacy','Critical')]
    [string]$Mode = 'Ask',

    [ValidateSet('Ask','Yes','No')]
    [string]$Memory = 'Ask',

    [ValidateSet('Ask','Yes','No')]
    [string]$Artifact = 'Ask',

    [string]$OutputRoot,
    [string]$ToolRoot,
    [string]$SourceDrive = $env:SystemDrive,
    [switch]$NoPrompt,
    [switch]$SkipOpNotes,
    [switch]$UseNoKapeSuffix,
    [switch]$PlanOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$ScriptRoot = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$ProjectRoot = Split-Path -Parent $ScriptRoot
if (-not $OutputRoot) { $OutputRoot = Join-Path $ProjectRoot 'Collection' }
if (-not $ToolRoot) { $ToolRoot = Join-Path $ProjectRoot 'Tools' }
$script:CollectorVersion = '0.2.0'
$script:ManifestCommands = New-Object System.Collections.Generic.List[object]
$script:ManifestTools = New-Object System.Collections.Generic.List[object]
$script:ManifestFiles = New-Object System.Collections.Generic.List[object]
$script:ManifestFailures = New-Object System.Collections.Generic.List[object]
$script:ManifestSkipped = New-Object System.Collections.Generic.List[object]
$script:SeenTools = @{}

function Test-IsAdmin {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-DotNet45 {
    try {
        $release = (Get-ItemProperty 'HKLM:\Software\Microsoft\Net Framework Setup\NDP\v4\Full' -ErrorAction Stop).Release
        return ($release -ge 378389)
    } catch {
        return $false
    }
}

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

function Get-SafeFileHash {
    param([Parameter(Mandatory)][string]$Path)
    try {
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $cmd = Get-Command Get-FileHash -ErrorAction SilentlyContinue
            if ($cmd) {
                return (Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash
            }
            $sha = [Security.Cryptography.SHA256]::Create()
            $stream = [IO.File]::OpenRead($Path)
            try {
                return ([BitConverter]::ToString($sha.ComputeHash($stream)) -replace '-', '')
            } finally {
                $stream.Dispose()
                $sha.Dispose()
            }
        }
    } catch {
        return $null
    }
    return $null
}

function Add-ManifestFailure {
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string]$Message,
        [string]$Path
    )
    $script:ManifestFailures.Add([pscustomobject]@{
        TimeUtc = (Get-Date).ToUniversalTime().ToString('o')
        Action = $Action
        Path = $Path
        Message = $Message
    })
}

function Add-ManifestSkipped {
    param(
        [Parameter(Mandatory)][string]$Artifact,
        [Parameter(Mandatory)][string]$Reason,
        [string]$Path
    )
    $script:ManifestSkipped.Add([pscustomobject]@{
        TimeUtc = (Get-Date).ToUniversalTime().ToString('o')
        Artifact = $Artifact
        Path = $Path
        Reason = $Reason
    })
}

function Add-ManifestTool {
    param([Parameter(Mandatory)][string]$Path)
    try {
        $resolved = (Resolve-Path -LiteralPath $Path -ErrorAction Stop).Path
    } catch {
        return
    }
    if ($script:SeenTools.ContainsKey($resolved)) { return }
    $script:SeenTools[$resolved] = $true
    $version = $null
    try { $version = [Diagnostics.FileVersionInfo]::GetVersionInfo($resolved).FileVersion } catch { }
    $script:ManifestTools.Add([pscustomobject]@{
        Name = [IO.Path]::GetFileName($resolved)
        Path = $resolved
        Version = $version
        SHA256 = Get-SafeFileHash -Path $resolved
    })
}

function Add-ManifestCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [string]$OutFile,
        [int]$ExitCode = -2147483648
    )
    $script:ManifestCommands.Add([pscustomobject]@{
        TimeUtc = (Get-Date).ToUniversalTime().ToString('o')
        Name = $Name
        Command = $Command
        OutFile = $OutFile
        ExitCode = if ($ExitCode -eq -2147483648) { $null } else { $ExitCode }
    })
}

function Add-ManifestFile {
    param(
        [Parameter(Mandatory)][string]$DestinationPath,
        [string]$SourcePath,
        [string]$Artifact
    )
    if (-not (Test-Path -LiteralPath $DestinationPath -PathType Leaf)) { return }
    try {
        $item = Get-Item -LiteralPath $DestinationPath -ErrorAction Stop
        $script:ManifestFiles.Add([pscustomobject]@{
            Artifact = $Artifact
            SourcePath = $SourcePath
            DestinationPath = $item.FullName
            RelativePath = $item.FullName.Substring($script:OutPath.Length).TrimStart('\')
            Length = $item.Length
            CreationTimeUtc = $item.CreationTimeUtc.ToString('o')
            LastWriteTimeUtc = $item.LastWriteTimeUtc.ToString('o')
            SHA256 = Get-SafeFileHash -Path $item.FullName
        })
    } catch {
        Add-ManifestFailure -Action 'inventory-file' -Path $DestinationPath -Message $_.Exception.Message
    }
}

function Add-FinalFileInventory {
    $known = @{}
    foreach ($entry in $script:ManifestFiles) { $known[$entry.DestinationPath] = $true }
    Get-ChildItem -LiteralPath $script:OutPath -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ne 'capture-manifest.json' -and -not $known.ContainsKey($_.FullName) } |
        ForEach-Object {
            Add-ManifestFile -DestinationPath $_.FullName -Artifact 'final-scan'
        }
}

function Find-Tool {
    param([Parameter(Mandatory)][string[]]$Names)
    foreach ($name in $Names) {
        $candidate = Join-Path (Join-Path $ToolRoot 'binaries') $name
        if (Test-Path -LiteralPath $candidate) {
            Add-ManifestTool -Path $candidate
            return $candidate
        }
        $cmd = Get-Command $name -ErrorAction SilentlyContinue
        if ($cmd) {
            Add-ManifestTool -Path $cmd.Source
            return $cmd.Source
        }
    }
    return $null
}

function Get-ToolCommand {
    param(
        [Parameter(Mandatory)][string[]]$Names,
        [Parameter(Mandatory)][string]$Fallback
    )
    $tool = Find-Tool $Names
    if ($tool) { return ('"{0}"' -f $tool) }
    return $Fallback
}

function Invoke-AndCapture {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][string]$OutFile
    )
    Write-Log "Running $Name"
    $exitCode = $null
    try {
        cmd.exe /d /c $Command > $OutFile 2>&1
        $exitCode = $LASTEXITCODE
    } catch {
        Add-Content -LiteralPath $OutFile -Value $_.Exception.Message
        Add-ManifestFailure -Action "command:$Name" -Path $OutFile -Message $_.Exception.Message
    }
    Add-ManifestCommand -Name $Name -Command $Command -OutFile $OutFile -ExitCode $exitCode
    if ($exitCode -ne $null -and $exitCode -ne 0) {
        Add-ManifestFailure -Action "command:$Name" -Path $OutFile -Message "Exit code $exitCode"
    }
    Add-ManifestFile -SourcePath $Command -DestinationPath $OutFile -Artifact 'TXT'
}

function Copy-WithFallback {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string]$OutputName,
        [string]$Artifact = 'file-copy'
    )
    New-Directory $Destination
    if (-not (Test-Path -LiteralPath $Source -PathType Leaf) -and $Source -notmatch '^[A-Za-z]:[0-9]+$') {
        Add-ManifestSkipped -Artifact $Artifact -Path $Source -Reason 'Source path not present'
        return
    }
    $rawCopy = if ([Environment]::Is64BitOperatingSystem) {
        Find-Tool @('rawcopy64.exe','rawcopy.exe')
    } else {
        Find-Tool @('rawcopy.exe')
    }

    if ($rawCopy) {
        $args = @("/FileNamePath:$Source", "/OutputPath:$Destination")
        if ($OutputName) { $args += "/OutputName:$OutputName" }
        Write-Log "Raw copying $Source"
        & $rawCopy @args >> $script:LogFile 2>&1
        $destFile = if ($OutputName) { Join-Path $Destination $OutputName } else { Join-Path $Destination ([IO.Path]::GetFileName($Source)) }
        if (Test-Path -LiteralPath $destFile -PathType Leaf) {
            Add-ManifestFile -SourcePath $Source -DestinationPath $destFile -Artifact $Artifact
        } else {
            Add-ManifestFailure -Action 'rawcopy' -Path $Source -Message 'Rawcopy completed but destination file was not found.'
        }
        return
    }

    try {
        Write-Log "Copying $Source"
        if (Test-Path -LiteralPath $Source) {
            $destFile = Join-Path $Destination ($(if ($OutputName) { $OutputName } else { [IO.Path]::GetFileName($Source) }))
            Copy-Item -LiteralPath $Source -Destination $destFile -Force -ErrorAction Stop
            Add-ManifestFile -SourcePath $Source -DestinationPath $destFile -Artifact $Artifact
        }
    } catch {
        Write-Log "Copy failed for $Source : $($_.Exception.Message)"
        Add-ManifestFailure -Action 'copy' -Path $Source -Message $_.Exception.Message
    }
}

function Copy-TreeWithRobocopy {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination,
        [string[]]$FilePatterns = @('*'),
        [string[]]$Options = @('/E'),
        [string]$Artifact = 'file-copy'
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        Add-ManifestSkipped -Artifact $Artifact -Path $Source -Reason 'Source path not present'
        return
    }
    New-Directory $Destination
    $before = @{}
    if (Test-Path -LiteralPath $Destination) {
        Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue | ForEach-Object { $before[$_.FullName] = $true }
    }
    $args = @($Source, $Destination) + $FilePatterns + $Options + @('/R:1','/W:1')
    Write-Log "Robocopying $Artifact from $Source"
    robocopy.exe @args >> $LogFile 2>&1
    $exitCode = $LASTEXITCODE
    Add-ManifestCommand -Name "robocopy:$Artifact" -Command ("robocopy.exe " + ($args -join ' ')) -OutFile $Destination -ExitCode $exitCode
    if ($exitCode -ge 8) {
        Add-ManifestFailure -Action "robocopy:$Artifact" -Path $Source -Message "Robocopy exit code $exitCode"
    }
    Get-ChildItem -LiteralPath $Destination -Recurse -File -ErrorAction SilentlyContinue |
        Where-Object { -not $before.ContainsKey($_.FullName) } |
        ForEach-Object { Add-ManifestFile -SourcePath $Source -DestinationPath $_.FullName -Artifact $Artifact }
}

function Export-Json {
    param(
        [Parameter(Mandatory)]$InputObject,
        [Parameter(Mandatory)][string]$Path
    )
    try {
        $InputObject | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $Path -Encoding UTF8
    } catch {
        Set-Content -LiteralPath $Path -Value $_.Exception.Message -Encoding UTF8
    }
}

function Get-OsInfo {
    try {
        $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    } catch {
        try { $os = Get-WmiObject Win32_OperatingSystem -ErrorAction Stop } catch { $os = $null }
    }
    if ($os) {
        return [pscustomobject]@{
            Caption = $os.Caption
            Version = $os.Version
            BuildNumber = $os.BuildNumber
            ServicePack = $os.CSDVersion
            Architecture = $os.OSArchitecture
        }
    }
    return [pscustomobject]@{
        Caption = $null
        Version = [Environment]::OSVersion.Version.ToString()
        BuildNumber = [Environment]::OSVersion.Version.Build
        ServicePack = $null
        Architecture = if ([Environment]::Is64BitOperatingSystem) { '64-bit' } else { '32-bit' }
    }
}

function Write-CaptureManifest {
    param([datetime]$Finished = (Get-Date))
    Add-FinalFileInventory
    $manifestPath = Join-Path $script:OutPath 'capture-manifest.json'
    $duration = New-TimeSpan -Start $script:CollectionStart -End $Finished
    Export-Json -InputObject ([ordered]@{
        Tool = 'NoKapeHostCapture'
        Version = $script:CollectorVersion
        ComputerName = $env:COMPUTERNAME
        User = $env:USERNAME
        IsAdmin = Test-IsAdmin
        OS = Get-OsInfo
        Architecture = @{
            Process = $env:PROCESSOR_ARCHITECTURE
            Is64BitOperatingSystem = [Environment]::Is64BitOperatingSystem
            Is64BitProcess = [Environment]::Is64BitProcess
        }
        RequestedMode = $Mode
        EffectiveMode = $script:EffectiveMode
        MemoryRequested = $script:EffectiveMemory
        ArtifactsRequested = $script:EffectiveArtifact
        SourceDrive = $SourceDrive
        Started = $script:CollectionStart.ToUniversalTime().ToString('o')
        Finished = $Finished.ToUniversalTime().ToString('o')
        ElapsedSeconds = [Math]::Round($duration.TotalSeconds, 3)
        Output = $script:OutPath
        KapeUsed = $false
        EzToolsUsed = $false
        ExternalCollectorsUsed = $false
        Commands = @($script:ManifestCommands)
        Tools = @($script:ManifestTools)
        Files = @($script:ManifestFiles)
        Skipped = @($script:ManifestSkipped)
        Failures = @($script:ManifestFailures)
    }) -Path $manifestPath
}

function Collect-Memory {
    $dumpName = '{0}--{1}.raw' -f $env:COMPUTERNAME, $Timestamp
    $dumpPath = Join-Path $OutPath $dumpName
    $dumpIt = if ([Environment]::Is64BitOperatingSystem) {
        Find-Tool @('DumpIt64.exe','winpmem2_1.exe','DumpIt.exe')
    } else {
        Find-Tool @('DumpIt.exe','winpmem2_1.exe')
    }

    if (-not $dumpIt) {
        Write-Log 'Memory capture skipped: no DumpIt/winpmem binary found in Tools\binaries or PATH.'
        Add-ManifestSkipped -Artifact 'memory' -Reason 'No DumpIt/winpmem binary found in Tools\binaries or PATH.'
        return
    }

    Write-Log "Starting memory capture with $([IO.Path]::GetFileName($dumpIt))"
    if ((Split-Path -Leaf $dumpIt) -like 'winpmem*') {
        & $dumpIt $dumpPath >> $LogFile 2>&1
        Add-ManifestCommand -Name 'memory' -Command ('"{0}" "{1}"' -f $dumpIt, $dumpPath) -OutFile $dumpPath -ExitCode $LASTEXITCODE
        Add-ManifestFile -SourcePath 'physical-memory' -DestinationPath $dumpPath -Artifact 'memory'
    } else {
        $zdmpPath = [IO.Path]::ChangeExtension($dumpPath, '.zdmp')
        & $dumpIt /Q /N /J /R /O $zdmpPath >> $LogFile 2>&1
        Add-ManifestCommand -Name 'memory' -Command ('"{0}" /Q /N /J /R /O "{1}"' -f $dumpIt, $zdmpPath) -OutFile $zdmpPath -ExitCode $LASTEXITCODE
        Add-ManifestFile -SourcePath 'physical-memory' -DestinationPath $zdmpPath -Artifact 'memory'
    }
    Write-Log 'Memory capture finished.'
}

function Collect-SystemEnumeration {
    $txt = Join-Path $OutPath 'TXT'
    New-Directory $txt

    $psList = Get-ToolCommand @('pslist64.exe','pslist.exe') 'pslist.exe'
    $handle = Get-ToolCommand @('handle.exe') 'handle.exe'
    $listDlls = Get-ToolCommand @('listdlls.exe') 'listdlls.exe'
    $psLoggedOn = Get-ToolCommand @('psloggedon64.exe','psloggedon.exe') 'psloggedon.exe'
    $logonSessions = Get-ToolCommand @('logonsessions.exe') 'logonsessions.exe'
    $psFile = Get-ToolCommand @('psfile.exe','psfile.exe.exe') 'psfile.exe'
    $autoruns = Get-ToolCommand @('autorunsc64.exe','autorunsc.exe') 'autorunsc.exe'
    $gplist = Get-ToolCommand @('gplist.exe') 'gplist.exe'

    $commands = [ordered]@{
        'uptime' = 'systeminfo | find "Time:"'
        'ipconfig_all' = 'ipconfig /all'
        'netstat' = 'netstat -ano'
        'netstat_r' = 'netstat -r'
        'arpcache' = 'arp -a'
        'pslist' = "$psList -m /accepteula"
        'tasklist_svc' = 'tasklist /svc /fo csv'
        'handlesummary' = "$handle -s /accepteula"
        'handles' = "$handle -a /accepteula"
        'net_file' = 'net file'
        'loadeddlls' = "$listDlls -r /accepteula"
        'ipconfig_displaydns' = 'ipconfig /displaydns'
        'psloggedon' = "$psLoggedOn /accepteula"
        'logonsessions' = "$logonSessions -c -p /accepteula"
        'net_sessions' = 'net sessions'
        'psfile' = "$psFile /accepteula"
        'autoruns' = "$autoruns -a * -c /accepteula"
        'gplist' = $gplist
        'atjobs' = 'at'
        'nbtstat_sessions' = 'nbtstat -S'
        'nbtstat_cache' = 'nbtstat -c'
        'net_view' = 'net view'
        'net_view_localhost' = 'net view 127.0.0.1'
        'net_user' = 'net user'
        'net_share' = 'net share'
        'net_use' = 'net use'
        'net_localgroup' = 'net localgroup'
        'net_group_administrators' = 'net group "administrators"'
        'net_localgroup_users' = 'net localgroup "users"'
        'net_localgroup_guests' = 'net localgroup "guests"'
        'net_localgroup_rdp' = 'net localgroup "remote desktop users"'
        'net_localgroup_administrators' = 'net localgroup "administrators"'
        'net_statistics_workstation' = 'net statistics workstation'
        'net_statistics_server' = 'net statistics server'
        'schtasks' = 'schtasks /query /v /fo csv'
        'driverquery' = 'driverquery /v /fo csv'
        'driverquery_signed' = 'driverquery /si /fo csv'
        'gpresult' = 'gpresult /z'
        'netsh_interface_dump' = 'netsh interface dump'
        'netsh_show_helper' = 'netsh show helper'
        'vssadmin_list_writers' = 'vssadmin list writers'
        'vssadmin_list_providers' = 'vssadmin list providers'
        'vssadmin_list_shadows' = 'vssadmin list shadows'
        'wmic_process' = 'wmic process get name,commandline,processid,parentprocessid,sessionid,executablepath /format:csv'
        'wmic_csproduct' = 'wmic csproduct get vendor,name,identifyingnumber /format:csv'
        'wmic_serial' = 'wmic bios get serialnumber'
        'wmic_primiscadapters' = 'wmic /namespace:\\root\wmi path MSNdis_CurrentPacketFilter get /format:csv'
        'wmic_computersystem' = 'wmic computersystem get * /format:csv'
        'wmic_logicaldisk' = 'wmic logicaldisk get name,description,drivetype,filesystem,freespace,size,volumeserialnumber,volumename /format:csv'
        'wmic_partition' = 'wmic partition get caption,diskindex,index,size,blocksize,primarypartition,status,type /format:csv'
        'wmic_nic' = 'wmic nic get adaptertype,name,macaddress,servicename /format:csv'
        'wmic_nicconfig' = 'wmic nicconfig get * /format:csv'
        'wmic_onboarddevice' = 'wmic onboarddevice get description,devicetype,enabled,status /format:csv'
        'wmic_useraccount' = 'wmic useraccount list full /format:csv'
        'wmic_netlogin' = 'wmic netlogin get lastlogon,numberoflogons,name,userid,flags /format:csv'
        'wmic_group' = 'wmic group get name,domain,description,SID /format:csv'
        'wmic_service' = 'wmic service get * /format:list'
        'wmic_jobs' = 'wmic job list full /format:csv'
        'wmic_startup' = 'wmic startup list full /format:csv'
        'wmic_ntdomain_brief' = 'wmic ntdomain list brief /format:csv'
        'wmic_eventfilter' = 'wmic /namespace:\\root\subscription path __EventFilter get /format:csv'
        'wmic_eventconsumer' = 'wmic /namespace:\\root\subscription path __EventConsumer get /format:csv'
        'wmic_filtertoconsumer' = 'wmic /namespace:\\root\subscription path __FilterToConsumerBinding get /format:csv'
    }

    foreach ($item in $commands.GetEnumerator()) {
        Invoke-AndCapture -Name $item.Key -Command $item.Value -OutFile (Join-Path $txt "$($item.Key).txt")
    }
}

function Collect-EventLogs {
    $evtx = Join-Path $OutPath 'Evtx'
    New-Directory $evtx
    $logs = [ordered]@{
        'Application' = 'Application.evtx'
        'Security' = 'Security.evtx'
        'System' = 'System.evtx'
        'Windows PowerShell' = 'Windows PowerShell.evtx'
        'Microsoft-Windows-PowerShell/Operational' = 'Microsoft-Windows-PowerShell%4Operational.evtx'
        'Microsoft-Windows-WinRM/Operational' = 'Microsoft-Windows-WinRM%4Operational.evtx'
        'Microsoft-Windows-WMI-Activity/Operational' = 'Microsoft-Windows-WMI-Activity%4Operational.evtx'
        'Microsoft-Windows-TaskScheduler/Operational' = 'Microsoft-Windows-TaskScheduler%4Operational.evtx'
        'Microsoft-Windows-TerminalServices-LocalSessionManager/Operational' = 'Microsoft-Windows-TerminalServices-LocalSessionManager%4Operational.evtx'
        'Microsoft-Windows-TerminalServices-RemoteConnectionManager/Operational' = 'Microsoft-Windows-TerminalServices-RemoteConnectionManager%4Operational.evtx'
        'Microsoft-Windows-TerminalServices-RDPClient/Operational' = 'Microsoft-Windows-TerminalServices-RDPClient%4Operational.evtx'
        'Microsoft-Windows-Bits-Client/Operational' = 'Microsoft-Windows-Bits-Client%4Operational.evtx'
        'Microsoft-Windows-Windows Defender/Operational' = 'Microsoft-Windows-Windows Defender%4Operational.evtx'
        'Microsoft-Windows-Windows Firewall With Advanced Security/Firewall' = 'Microsoft-Windows-Windows Firewall With Advanced Security%4Firewall.evtx'
        'Microsoft-Windows-SMBClient/Connectivity' = 'Microsoft-Windows-SMBClient%4Connectivity.evtx'
        'Microsoft-Windows-SMBClient/Security' = 'Microsoft-Windows-SMBClient%4Security.evtx'
        'Microsoft-Windows-SMBServer/Security' = 'Microsoft-Windows-SMBServer%4Security.evtx'
        'Microsoft-Windows-Sysmon/Operational' = 'Microsoft-Windows-Sysmon%4Operational.evtx'
    }

    foreach ($entry in $logs.GetEnumerator()) {
        $dest = Join-Path $evtx $entry.Value
        $log = $entry.Key
        Write-Log "Exporting event log $log"
        wevtutil.exe epl $log $dest /ow:true >> $LogFile 2>&1
        Add-ManifestCommand -Name "eventlog:$log" -Command ("wevtutil.exe epl `"{0}`" `"{1}`" /ow:true" -f $log, $dest) -OutFile $dest -ExitCode $LASTEXITCODE
        if (Test-Path -LiteralPath $dest -PathType Leaf) {
            Add-ManifestFile -SourcePath $log -DestinationPath $dest -Artifact 'Evtx'
        } else {
            Add-ManifestSkipped -Artifact 'Evtx' -Path $log -Reason 'Event channel missing or export failed'
        }
    }
}

function Collect-Registry {
    $reg = Join-Path $OutPath 'Registry'
    New-Directory $reg
    foreach ($hive in @('SAM','SECURITY','SOFTWARE','SYSTEM','DEFAULT')) {
        $source = Join-Path $env:WINDIR "System32\config\$hive"
        Copy-WithFallback -Source $source -Destination $reg -Artifact 'Registry'
        foreach ($suffix in @('.LOG','.LOG1','.LOG2')) {
            Copy-WithFallback -Source "$source$suffix" -Destination $reg -Artifact 'Registry'
        }
    }

    foreach ($profile in Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        $userDir = Join-Path $reg $profile.Name
        New-Directory $userDir
        Copy-WithFallback -Source (Join-Path $profile.FullName 'NTUSER.DAT') -Destination $userDir -Artifact 'Registry'
        Copy-WithFallback -Source (Join-Path $profile.FullName 'NTUSER.DAT.LOG1') -Destination $userDir -Artifact 'Registry'
        Copy-WithFallback -Source (Join-Path $profile.FullName 'NTUSER.DAT.LOG2') -Destination $userDir -Artifact 'Registry'
        Copy-WithFallback -Source (Join-Path $profile.FullName 'AppData\Local\Microsoft\Windows\UsrClass.dat') -Destination $userDir -Artifact 'Registry'
        Copy-WithFallback -Source (Join-Path $profile.FullName 'AppData\Local\Microsoft\Windows\UsrClass.dat.LOG1') -Destination $userDir -Artifact 'Registry'
        Copy-WithFallback -Source (Join-Path $profile.FullName 'AppData\Local\Microsoft\Windows\UsrClass.dat.LOG2') -Destination $userDir -Artifact 'Registry'
    }

    $setupApi = Join-Path $env:WINDIR 'Inf\setupapi.dev.log'
    if (Test-Path -LiteralPath $setupApi) {
        Copy-WithFallback -Source $setupApi -Destination $reg -Artifact 'Registry'
    } else {
        Get-ChildItem -LiteralPath $env:WINDIR -Filter 'setupapi*' -File -ErrorAction SilentlyContinue |
            ForEach-Object { Copy-WithFallback -Source $_.FullName -Destination $reg -Artifact 'Registry' }
    }
}

function Collect-NtfsMetadata {
    $fs = Join-Path $OutPath 'File_System'
    New-Directory $fs
    Invoke-AndCapture -Name 'dirwalk' -Command 'tree C:\ /F /A' -OutFile (Join-Path $fs "$env:COMPUTERNAME-dirwalk.txt")

    $mmls = Find-Tool @('mmls.exe')
    $mbrUtil = Find-Tool @('MBRUtil.exe')
    $ftk = Find-Tool @('ftkimager_CLI_version.exe')
    if ($ftk) {
        $physicalDisks = & $ftk --list-drives 2>&1 | Where-Object { $_ -match '^\\\\\.' -and $_ -notmatch 'USB' } | ForEach-Object { ($_ -split '\s+')[0] }
        foreach ($disk in $physicalDisks) {
        $diskName = $disk.Replace('\\.\','')
            if ($mmls) {
                $mmlsOut = Join-Path $fs "mmls-$diskName.txt"
                & $mmls $disk > $mmlsOut 2>&1
                Add-ManifestCommand -Name 'mmls' -Command ('"{0}" "{1}"' -f $mmls, $disk) -OutFile $mmlsOut -ExitCode $LASTEXITCODE
                Add-ManifestFile -SourcePath $disk -DestinationPath $mmlsOut -Artifact 'File_System'
            }
            if ($mbrUtil) {
                $mbrOut = Join-Path $fs "$diskName.dat"
                & $mbrUtil "/SH=$mbrOut" >> $LogFile 2>&1
                Add-ManifestCommand -Name 'MBRUtil' -Command ('"{0}" "/SH={1}"' -f $mbrUtil, $mbrOut) -OutFile $mbrOut -ExitCode $LASTEXITCODE
                Add-ManifestFile -SourcePath $disk -DestinationPath $mbrOut -Artifact 'File_System'
            }
        }
    }

    try {
        $volumes = Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction Stop |
            Select-Object -ExpandProperty DeviceID
    } catch {
        $volumes = Get-WmiObject Win32_LogicalDisk -Filter "DriveType=3" -ErrorAction SilentlyContinue |
            Select-Object -ExpandProperty DeviceID
    }
    foreach ($device in $volumes) {
        $volume = $device.TrimEnd(':')
        Copy-WithFallback -Source "$volume`:0" -Destination $fs -OutputName "`$MFT_$volume" -Artifact 'File_System'
        Copy-WithFallback -Source "$volume`:2" -Destination $fs -OutputName "`$MFT_${volume}_`$LogFile" -Artifact 'File_System'
        $extusn = if ([Environment]::Is64BitOperatingSystem) {
            Find-Tool @('extranctusnjournal64.exe','extractusjournal64.exe','extractusjournal.exe')
        } else {
            Find-Tool @('extractusjournal.exe')
        }
        if ($extusn) {
            & $extusn "/DevicePath:$volume`:" "/OutputPath:$fs" >> $LogFile 2>&1
            Add-ManifestCommand -Name 'USNJournal' -Command ('"{0}" "/DevicePath:{1}:" "/OutputPath:{2}"' -f $extusn, $volume, $fs) -OutFile $fs -ExitCode $LASTEXITCODE
        } else {
            Add-ManifestSkipped -Artifact 'USNJournal' -Path "$volume`:" -Reason 'extractusjournal tool not present'
        }
    }
}

function Collect-ExecutionArtifacts {
    $prefetch = Join-Path $OutPath 'Prefetch'
    New-Directory $prefetch
    Copy-TreeWithRobocopy -Source "$env:WINDIR\Prefetch" -Destination $prefetch -Options @('/E') -Artifact 'Prefetch'

    $amcache = Join-Path $OutPath 'Amcache'
    New-Directory $amcache
    $amcacheRoot = Join-Path $env:WINDIR 'AppCompat\Programs'
    foreach ($name in @('Amcache.hve','Amcache.hve.LOG1','Amcache.hve.LOG2','RecentFileCache.bcf')) {
        Copy-WithFallback -Source (Join-Path $amcacheRoot $name) -Destination $amcache -Artifact 'Amcache'
    }

    $shim = Join-Path $OutPath 'Shim'
    New-Directory $shim
    Copy-TreeWithRobocopy -Source "$env:WINDIR\AppPatch" -Destination $shim -FilePatterns @('sysmain.sdb') -Options @() -Artifact 'Shim'
    Copy-TreeWithRobocopy -Source "$env:WINDIR\AppPatch\Custom" -Destination $shim -Options @('/E') -Artifact 'Shim'
    Copy-TreeWithRobocopy -Source "$env:WINDIR\AppPatch\AppPatch64\Custom" -Destination $shim -Options @('/E') -Artifact 'Shim'

    $srum = Join-Path $OutPath 'SRUM'
    New-Directory $srum
    Copy-WithFallback -Source (Join-Path $env:WINDIR 'System32\sru\SRUDB.dat') -Destination $srum -Artifact 'SRUM'
}

function Collect-UserActivity {
    $lnkRoot = Join-Path $OutPath 'LNK'
    $jumpRoot = Join-Path $OutPath 'Jumplist'
    $activityRoot = Join-Path $OutPath 'ActivitiesCache'
    New-Directory $lnkRoot
    New-Directory $jumpRoot
    New-Directory $activityRoot

    foreach ($profile in Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        $recent = Join-Path $profile.FullName 'AppData\Roaming\Microsoft\Windows\Recent'
        if (Test-Path -LiteralPath $recent) {
            Copy-TreeWithRobocopy -Source $recent -Destination (Join-Path $lnkRoot $profile.Name) -FilePatterns @('*.lnk') -Options @('/S') -Artifact 'LNK'
            Copy-TreeWithRobocopy -Source (Join-Path $recent 'AutomaticDestinations') -Destination (Join-Path $jumpRoot "$($profile.Name)\AutomaticDestinations") -Options @('/E') -Artifact 'Jumplist'
            Copy-TreeWithRobocopy -Source (Join-Path $recent 'CustomDestinations') -Destination (Join-Path $jumpRoot "$($profile.Name)\CustomDestinations") -Options @('/E') -Artifact 'Jumplist'
        } else {
            Add-ManifestSkipped -Artifact 'LNK' -Path $recent -Reason 'Recent folder not present'
        }
        $activity = Join-Path $profile.FullName 'AppData\Local\ConnectedDevicesPlatform'
        if (Test-Path -LiteralPath $activity) {
            Copy-TreeWithRobocopy -Source $activity -Destination (Join-Path $activityRoot $profile.Name) -FilePatterns @('ActivitiesCache.db*') -Options @('/S') -Artifact 'ActivitiesCache'
        } else {
            Add-ManifestSkipped -Artifact 'ActivitiesCache' -Path $activity -Reason 'ConnectedDevicesPlatform folder not present'
        }
    }
}

function Collect-BrowserArtifacts {
    $browserRoot = Join-Path $OutPath 'Browsers'
    New-Directory $browserRoot
    foreach ($profile in Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        $dest = Join-Path $browserRoot $profile.Name
        New-Directory $dest
        $chrome = Join-Path $profile.FullName 'AppData\Local\Google\Chrome\User Data'
        $edge = Join-Path $profile.FullName 'AppData\Local\Microsoft\Edge\User Data'
        $firefox = Join-Path $profile.FullName 'AppData\Roaming\Mozilla\Firefox\Profiles'
        foreach ($root in @($chrome,$edge)) {
            if (Test-Path -LiteralPath $root) {
                Copy-TreeWithRobocopy -Source $root -Destination (Join-Path $dest ([IO.Path]::GetFileName((Split-Path $root -Parent)))) -FilePatterns @('Bookmarks','History','Cookies','Login Data','Preferences','Web Data') -Options @('/S') -Artifact 'Browsers'
            } else {
                Add-ManifestSkipped -Artifact 'Browsers' -Path $root -Reason 'Browser profile path not present'
            }
        }
        if (Test-Path -LiteralPath $firefox) {
            Copy-TreeWithRobocopy -Source $firefox -Destination (Join-Path $dest 'Firefox') -FilePatterns @('places.sqlite*','cookies.sqlite*','formhistory.sqlite*','favicons.sqlite*','downloads.sqlite*') -Options @('/S') -Artifact 'Browsers'
        } else {
            Add-ManifestSkipped -Artifact 'Browsers' -Path $firefox -Reason 'Firefox profile path not present'
        }
    }
}

function Collect-ModernRawArtifacts {
    $tasks = Join-Path $OutPath 'ScheduledTasks'
    New-Directory $tasks
    Copy-TreeWithRobocopy -Source (Join-Path $env:WINDIR 'System32\Tasks') -Destination $tasks -Options @('/E') -Artifact 'ScheduledTasks'
    Copy-TreeWithRobocopy -Source (Join-Path $env:WINDIR 'Tasks') -Destination $tasks -FilePatterns @('*.job') -Options @('/S') -Artifact 'ScheduledTasks'

    $defender = Join-Path $OutPath 'Defender'
    New-Directory $defender
    Copy-TreeWithRobocopy -Source (Join-Path $env:ProgramData 'Microsoft\Windows Defender\Support') -Destination (Join-Path $defender 'Support') -Options @('/E') -Artifact 'Defender'
    Copy-TreeWithRobocopy -Source (Join-Path $env:ProgramData 'Microsoft\Windows Defender\Scans\History') -Destination (Join-Path $defender 'ScansHistory') -Options @('/E') -Artifact 'Defender'
    Copy-TreeWithRobocopy -Source (Join-Path $env:ProgramData 'Microsoft\Windows Defender\Quarantine') -Destination (Join-Path $defender 'Quarantine') -Options @('/E') -Artifact 'Defender'

    $wer = Join-Path $OutPath 'WER'
    New-Directory $wer
    Copy-TreeWithRobocopy -Source (Join-Path $env:ProgramData 'Microsoft\Windows\WER') -Destination (Join-Path $wer 'ProgramData') -Options @('/E') -Artifact 'WER'
    foreach ($profile in Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        Copy-TreeWithRobocopy -Source (Join-Path $profile.FullName 'AppData\Local\Microsoft\Windows\WER') -Destination (Join-Path $wer $profile.Name) -Options @('/E') -Artifact 'WER'
    }

    $cloud = Join-Path $OutPath 'CloudStorage'
    New-Directory $cloud
    foreach ($profile in Get-ChildItem -LiteralPath 'C:\Users' -Directory -ErrorAction SilentlyContinue) {
        foreach ($path in @(
            (Join-Path $profile.FullName 'OneDrive'),
            (Join-Path $profile.FullName 'Dropbox'),
            (Join-Path $profile.FullName 'Google Drive'),
            (Join-Path $profile.FullName 'Box')
        )) {
            if (Test-Path -LiteralPath $path) {
                $safeName = ($path.Substring($profile.FullName.Length).TrimStart('\') -replace '[\\/:*?"<>| ]','_')
                Copy-TreeWithRobocopy -Source $path -Destination (Join-Path $cloud "$($profile.Name)\$safeName") -FilePatterns @('desktop.ini','*.lnk','*.log','*.db','*.sqlite','*.json','*.ini','*.dat') -Options @('/S') -Artifact 'CloudStorage'
            } else {
                Add-ManifestSkipped -Artifact 'CloudStorage' -Path $path -Reason 'Cloud storage path not present'
            }
        }
    }

    $remote = Join-Path $OutPath 'RemoteAdmin'
    New-Directory $remote
    $remotePaths = New-Object System.Collections.Generic.List[string]
    foreach ($base in @($env:ProgramData, $env:ProgramFiles, ${env:ProgramFiles(x86)})) {
        if (-not $base) { continue }
        foreach ($child in @('TeamViewer','AnyDesk','ScreenConnect Client*','Splashtop')) {
            $remotePaths.Add((Join-Path $base $child))
        }
    }
    foreach ($path in $remotePaths) {
        Get-Item -Path $path -ErrorAction SilentlyContinue | ForEach-Object {
            Copy-TreeWithRobocopy -Source $_.FullName -Destination (Join-Path $remote $_.Name) -FilePatterns @('*.log','*.txt','*.conf','*.ini','*.json','*.xml','*.db') -Options @('/S') -Artifact 'RemoteAdmin'
        }
    }
}

function Collect-CriticalFiles {
    Copy-WithFallback -Source "$SourceDrive\hiberfil.sys" -Destination (Join-Path $OutPath 'hiberfil') -Artifact 'Critical'
    Copy-WithFallback -Source "$SourceDrive\pagefile.sys" -Destination (Join-Path $OutPath 'pagefile') -Artifact 'Critical'
}

function Collect-OpNotes {
    if ($SkipOpNotes) { return }
    $notesPath = Join-Path $OutputRoot 'Opnotes.csv'
    $osInfo = Get-OsInfo
    $fields = [ordered]@{
        Date = if ($NoPrompt) { Get-Date -Format yyyyMMdd } else { Read-Host "Today's Date (eg. 01Jan2020)" }
        Hostname = $env:COMPUTERNAME
        OS = $osInfo.Caption
        Build = $osInfo.Version
        Mode = $script:EffectiveMode
        Start_Time = $script:CollectionStart.ToString('HHmm')
        Finish_Time = (Get-Date).ToString('HHmm')
        Building = if ($NoPrompt) { '' } else { Read-Host 'Enter Building and Room Number' }
        Location = if ($NoPrompt) { '' } else { Read-Host 'Enter Physical Location of system' }
        Purpose = if ($NoPrompt) { '' } else { Read-Host 'Enter System Purpose' }
        Drive = if ($NoPrompt) { '' } else { Read-Host 'Enter Collection Hard Drive' }
        Analyst = if ($NoPrompt) { $env:USERNAME } else { Read-Host 'Enter Analyst Name' }
        Successful = if ($NoPrompt) { 'unknown' } else { Read-Host 'Was Collection Successful? (y/n)' }
        Notes = if ($NoPrompt) { '' } else { Read-Host 'Enter other notes' }
    }
    [pscustomobject]$fields | Export-Csv -LiteralPath $notesPath -NoTypeInformation -Append -Force
}

if (-not $PlanOnly -and -not (Test-IsAdmin)) {
    Write-Error 'Admin privileges are required. Right click Start-Capture.bat and choose Run as administrator.'
    exit 1
}

$script:CollectionStart = Get-Date
$EffectiveMode = $Mode
if ($EffectiveMode -eq 'Ask' -and -not $NoPrompt) {
    Write-Host "`nArtifact collection type:"
    Write-Host '1 - NORMAL MODE replacement: KAPE-free CHIRON-style collection'
    Write-Host '2 - LEGACY MODE: force CHIRON legacy-style collection'
    Write-Host '3 - CRITICAL MODE: legacy-style collection plus hiberfil/pagefile'
    $modeAnswer = Read-Host 'Select your choice, then press ENTER'
    $EffectiveMode = switch ($modeAnswer) {
        '1' { 'Full' }
        '2' { 'Legacy' }
        '3' { 'Critical' }
        default { 'Legacy' }
    }
}
if ($EffectiveMode -eq 'Ask') { $EffectiveMode = 'Legacy' }
if ($EffectiveMode -eq 'Full' -and -not (Test-DotNet45)) {
    Write-Host '...NET Framework 4.5+ NOT FOUND. Downgrading to LEGACY mode.'
    $EffectiveMode = 'Legacy'
}
$script:EffectiveMode = $EffectiveMode

$Timestamp = (Get-Date -Format 'yyyy.MM.dd.HH.mm') + '.'
$suffix = if ($EffectiveMode -eq 'Critical') { 'CRITICAL' } elseif ($UseNoKapeSuffix) { 'NOKAPE' } else { 'LEGACY' }
$OutPath = Join-Path $OutputRoot ('{0}--{1}--{2}' -f $env:COMPUTERNAME, $Timestamp, $suffix)
$script:OutPath = $OutPath
New-Directory $OutputRoot
New-Directory $OutPath
$script:LogFile = Join-Path $OutPath ('{0}-{1}.log' -f $env:COMPUTERNAME, $Timestamp)
Set-Content -LiteralPath $LogFile -Value "NoKape host capture log for $env:COMPUTERNAME"

Export-Json -InputObject ([ordered]@{
    Tool = 'NoKapeHostCapture'
    Version = $script:CollectorVersion
    ComputerName = $env:COMPUTERNAME
    User = $env:USERNAME
    RequestedMode = $Mode
    EffectiveMode = $EffectiveMode
    SourceDrive = $SourceDrive
    Started = $CollectionStart.ToString('o')
    Output = $OutPath
    KapeUsed = $false
}) -Path (Join-Path $OutPath 'capture-manifest.json')

Write-Log "Capture output: $OutPath"
if ($Memory -eq 'Ask' -and -not $NoPrompt) {
    $answer = Read-Host 'Conduct memory capture? (y/n)'
    $Memory = if ($answer -match '^(y|yes)$') { 'Yes' } else { 'No' }
}

if ($Artifact -eq 'Ask' -and -not $NoPrompt) {
    $answer = Read-Host 'Conduct artifact capture? (y/n)'
    $Artifact = if ($answer -match '^(y|yes)$') { 'Yes' } else { 'No' }
}
if ($Artifact -eq 'Ask') { $Artifact = 'Yes' }
$script:EffectiveMemory = $Memory
$script:EffectiveArtifact = $Artifact

if ($PlanOnly) {
    [pscustomobject]@{
        Output = $OutPath
        Memory = $Memory
        Artifact = $Artifact
        RequestedMode = $Mode
        EffectiveMode = $EffectiveMode
        Suffix = $suffix
        KapeUsed = $false
    } | Format-List
    exit 0
}

if ($Memory -eq 'Yes') { Collect-Memory }

if ($Artifact -eq 'Yes' -and $EffectiveMode -in @('Full','Legacy')) {
    Collect-SystemEnumeration
    Collect-EventLogs
    Collect-Registry
    Collect-NtfsMetadata
    Collect-ExecutionArtifacts
    Collect-UserActivity
    Collect-BrowserArtifacts
    Collect-ModernRawArtifacts
}

if ($Artifact -eq 'Yes' -and $EffectiveMode -eq 'Critical') {
    Collect-SystemEnumeration
    Collect-EventLogs
    Collect-Registry
    Collect-NtfsMetadata
    Collect-ExecutionArtifacts
    Collect-CriticalFiles
}

Collect-OpNotes
Write-Log 'Capture complete.'
Write-CaptureManifest
Write-Host "`nOutput: $OutPath"
