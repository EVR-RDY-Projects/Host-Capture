# CHIRON Behavior Map

This notes how the new KAPE-free collector mirrors `D:\WORK\CHIRONv2e`.

## Entry Flow

Old CHIRON:

- `CHIRON.bat` requires administrator privileges.
- Creates `Collection\<COMPUTERNAME>--yyyy.MM.dd.HH.mm.`
- Creates a root log named `<COMPUTERNAME>-yyyy.MM.dd.HH.mm..log`
- Writes runtime values to `scripts\path.txt`
- Prompts for memory collection.
- Prompts for artifact collection.
- Renames the collection folder to one of:
  - `<COMPUTERNAME>--yyyy.MM.dd.HH.mm.--CHIRON`
  - `<COMPUTERNAME>--yyyy.MM.dd.HH.mm.--LEGACY`
  - `<COMPUTERNAME>--yyyy.MM.dd.HH.mm.--CRITICAL`

New collector:

- `Start-Capture.bat` requires administrator privileges.
- On XP / Server 2003 or hosts without PowerShell, `Start-Capture.bat` falls back to `Capture\Start-HostCaptureLegacy.bat`.
- Like CHIRON normal mode, the launcher checks for .NET Framework 4.5+ before using the PowerShell collector. If .NET 4.5+ is missing, it falls back to the legacy batch collector.
- Uses the same timestamp shape, including the trailing dot.
- Defaults to `--LEGACY` for `Full` and `Legacy` because this replacement does not produce a KAPE VHDX.
- Uses `--CRITICAL` for critical captures.
- Places the log at collection root using the CHIRON log naming pattern.
- Writes an enriched `capture-manifest.json` with host details, mode, timing, commands, tool hashes, collected file hashes, skipped artifacts, and failures.

## Memory

Old CHIRON:

- `MemCap.bat` runs `DumpIt.exe` or `DumpIt64.exe`.
- Output is stored at collection root as `<COMPUTERNAME>--yyyy.MM.dd.HH.mm..zdmp`.

New collector:

- Uses `DumpIt64.exe`, `DumpIt.exe`, or `winpmem2_1.exe` when present.
- DumpIt output is root-level `.zdmp` using the CHIRON naming pattern.
- winpmem output is root-level `.raw`.

## Legacy Artifact Folders

Old `LEGACYCOMMON.bat` creates:

- `Registry`
- `File_System`
- `Prefetch`
- `TXT`
- `Shim`
- `Evtx` or `Evt`
- `SRUM`, when applicable
- `Jumplist`, when applicable
- `Amcache`, when applicable
- `ActivitiesCache`, when applicable
- `LNK\<user>`

New collector uses the same folder names. It uses `Evtx` for modern Windows event logs.
The XP-safe batch collector uses `Evt` for XP/2003 event logs, matching CHIRON.

The modern collector also adds raw artifact folders that do not break CHIRON/PERCIVAL compatibility:

- `ScheduledTasks`
- `Defender`
- `WER`
- `CloudStorage`
- `RemoteAdmin`

## TXT Enumeration Names

The new collector mirrors CHIRON's `LEGACY_Commands64.txt` output names, including:

- `uptime.txt`
- `netstat.txt`
- `arpcache.txt`
- `pslist.txt`
- `tasklist_svc.txt`
- `handlesummary.txt`
- `handles.txt`
- `net_file.txt`
- `loadeddlls.txt`
- `ipconfig_all.txt`
- `netstat_r.txt`
- `ipconfig_displaydns.txt`
- `psloggedon.txt`
- `logonsessions.txt`
- `net_sessions.txt`
- `psfile.txt`
- `autoruns.txt`
- `gplist.txt`
- `atjobs.txt`
- `nbtstat_sessions.txt`
- `nbtstat_cache.txt`
- `net_view.txt`
- `net_view_localhost.txt`
- `net_user.txt`
- `net_share.txt`
- `net_use.txt`
- `net_localgroup.txt`
- `net_group_administrators.txt`
- `net_localgroup_users.txt`
- `net_localgroup_guests.txt`
- `net_localgroup_rdp.txt`
- `net_localgroup_administrators.txt`
- `net_statistics_workstation.txt`
- `net_statistics_server.txt`
- `schtasks.txt`
- `driverquery.txt`
- `driverquery_signed.txt`
- `gpresult.txt`
- `netsh_interface_dump.txt`
- `netsh_show_helper.txt`
- `vssadmin_list_writers.txt`
- `vssadmin_list_providers.txt`
- `vssadmin_list_shadows.txt`
- all `wmic_*.txt` files from the original 64-bit command manifest

## File System Artifacts

Old CHIRON:

- Saves `File_System\<COMPUTERNAME>-dirwalk.txt`
- Saves `$MFT_<drive>`
- Saves `$MFT_<drive>_$LogFile`
- Runs `extractusnjournal` when available.
- Runs `mmls` and `MBRUtil` for physical disks.

New collector follows the same output naming where the optional tools are present.

## Critical Mode

Old CHIRON:

- Runs legacy collection first.
- Copies `C:\hiberfil.sys` into `hiberfil`
- Copies `C:\pagefile.sys` into `pagefile`
- Folder suffix is `--CRITICAL`

New collector:

- Runs the same broad collection groups.
- Copies hiberfil/pagefile into the same folder names.
- Uses `--CRITICAL`.

## Not Mirrored

- KAPE targets/modules and KAPE VHDX output are intentionally not used.
- The original `scripts\kape.txt` scratch file is not created because there is no KAPE handoff.
- The old network/CD-ROM collection-source branches are not implemented yet.
- The PowerShell collector is not XP-safe by itself; XP compatibility comes from the batch fallback.
- EZ parsers are not used by default. Native processing creates JSON/inventory output, but full semantic parity for Prefetch, MFT, LNK, JumpLists, Shellbags, Amcache, and registry plugins requires custom native parsers.
