# NoKape Host Capture and Processing Toolkit

This project is a KAPE-free successor pattern for the older CHIRON/PERCIVAL workflow.

- `Start-Capture.bat` runs the host-side collector.
- `Start-Process.bat` runs the analyst-side processor.
- `Collection` stores raw host captures.
- `Cases` stores parsed output.
- `Tools\binaries` is for optional live-response binaries such as DumpIt, RawCopy, Sysinternals, and Z2DMP.
- `Tools\EZ` is optional and out of the default path. Keep it empty unless those parsers are specifically approved.
- `Tools\plaso` may contain `log2timeline.exe` and `psort.exe` if timeline generation is needed.

## Capture

Run as administrator from removable media or a local staging folder:

```powershell
.\Start-Capture.bat
```

`Start-Capture.bat` auto-detects Windows XP / Server 2003 or hosts without PowerShell and falls back to `Capture\Start-HostCaptureLegacy.bat`. That legacy batch path is the XP-safe collector. The PowerShell collector is for newer hosts.

Useful non-interactive examples:

```powershell
.\Start-Capture.bat -Mode Full -Memory No -NoPrompt
.\Start-Capture.bat -Mode Full -Memory Yes -NoPrompt
.\Start-Capture.bat -Mode Critical -Memory No -NoPrompt
.\Start-Capture.bat -Mode Legacy -Memory No -Artifact No -NoPrompt
```

The collector does not invoke KAPE, EZ tools, Velociraptor, or DFIR ORC. It uses Windows-native commands and optional approved direct-copy/live-response tools when available. When `rawcopy64.exe` or `rawcopy.exe` is present, locked files and NTFS metadata are collected through RawCopy. Without RawCopy, the script still gathers what Windows can export or copy normally.

Every capture writes `capture-manifest.json`. On modern hosts it includes host details, mode/timing, commands, tool paths and SHA256 hashes, collected file hashes, skipped artifacts, and failures. The XP/2003 batch path writes a simpler XP-safe manifest and keeps detailed command/file activity in the root log.

For XP compatibility, keep approved XP-capable binaries in `Tools\binaries`, especially `rawcopy.exe`, `DumpIt.exe`, Sysinternals tools, and any other utilities you are authorized to use. The XP batch path does not require PowerShell, .NET, CIM, or `wevtutil`.

## Process

Place CHIRON-like captures produced by this tool under `Collection`, then run:

```powershell
.\Start-Process.bat
```

Or process everything without prompts:

```powershell
.\Start-Process.bat -Mode All -NoPrompt
```

By default the processor uses `-ParserSet Native`, which does not call EZ tools. It writes native JSON summaries, text-command JSONs, event-log JSONs where Windows can read the log, and inventory JSONs for binary artifact folders.

External parser mode is explicit:

```powershell
.\Start-Process.bat -Mode Analysis -ParserSet External -NoPrompt
```

Use that only if those tools are approved.

See `Docs\PERCIVAL-Parity.md` for the expected CSV/JSON outputs compared to the original PERCIVAL script.
See `Docs\Scenario-Matrix.md` for the checked run scenarios.

## Coverage

The capture script currently gathers:

- memory dumps, when DumpIt or winpmem is available
- system, network, account, service, process, scheduled task, WMI, VSS, and autorun enumeration
- event logs using `wevtutil`
- registry hives and user hives
- NTFS metadata where RawCopy is available
- prefetch, Amcache, RecentFileCache, shimcache SDB files, SRUM
- LNK files, jump lists, Windows Timeline databases
- selected browser history databases and profile artifacts
- scheduled task XML/job files
- Windows Defender support/history/quarantine artifacts
- Windows Error Reporting artifacts
- selected cloud-sync and remote-admin raw artifacts where paths exist
- hiberfil and pagefile in `Critical` mode

## Tool Migration

To reuse your old non-KAPE tooling, copy binaries from:

- `D:\WORK\Scripts\PERCIVAL\binaries` into `Tools\binaries`
- `D:\WORK\Scripts\PERCIVAL\EZ` into `Tools\EZ` only if those parser binaries are approved
- `D:\WORK\Scripts\PERCIVAL\plaso` into `Tools\plaso`

Do not copy the old `KAPE` folder. This toolkit does not call it.

Or run the helper:

```powershell
.\Tools\Install-ToolsFromLegacy.ps1
.\Tools\Install-ToolsFromLegacy.ps1 -IncludePlaso
```

Then verify the copied toolset and output contracts:

```powershell
.\Tools\Test-ToolkitParity.ps1
```
