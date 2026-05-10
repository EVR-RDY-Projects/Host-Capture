# Host Capture

Host Capture is a Windows forensic collection and processing framework evolved from the CHIRON/PERCIVAL workflow.

This version provides a KAPE-free host collector and a native processing path that does not use EZ tools by default.

## Quick Start

Run capture as administrator from trusted removable media or a local staging folder:

```powershell
.\Start-Capture.bat
```

Process CHIRON-style captures on an analyst workstation:

```powershell
.\Start-Process.bat -Mode All -NoPrompt
```

## Architecture

### Capture Module

- Runs directly from a trusted drive.
- Preserves CHIRON-style collection names and folder layout.
- Collects volatile state, registry hives, event logs, NTFS metadata, execution artifacts, user activity artifacts, browser artifacts, and selected modern Windows artifacts.
- Supports optional memory capture when approved memory capture binaries are present.
- Falls back to a batch-only XP/Server 2003 collector when needed.
- Writes `capture-manifest.json` with host details, timing, commands, tool hashes, collected file hashes, skipped artifacts, and failures on modern hosts.

### Processing Module

- Ingests CHIRON-style capture folders.
- Defaults to native processing with no EZ parser execution.
- Emits JSON summaries, text-command JSON, event-log JSON where readable, and artifact inventory JSON.
- External parser mode exists only for explicitly approved tool use.

## Important Boundaries

- KAPE is not used.
- EZ tools are not used by default.
- Velociraptor and DFIR ORC are not required dependencies.
- XP support is for capture only; processing is intended for an analyst workstation.
- Third-party binaries are not shipped in this repo. Optional approved binaries belong under `Tools\binaries`, `Tools\EZ`, or `Tools\plaso`, which are ignored by git.

See [Docs/README.md](Docs/README.md) for full usage and parity notes.
