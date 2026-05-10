# PERCIVAL Output Parity

The processor is designed to consume the CHIRON-like capture layout. There are now two processing paths:

- `-ParserSet Native` is the default and uses no EZ tools.
- `-ParserSet External` uses the old EZ-style tools if they are explicitly allowed.

If EZ tools are out of play, use `Native`. Native mode produces our own JSON contract from the same CHIRON artifacts, but it cannot reproduce every semantic PERCIVAL JSON because formats like Prefetch, MFT, LNK, Jump Lists, Shellbags, Amcache, and registry plugins require dedicated parsers.

## JSON Outputs

PERCIVAL emits JSON for these parser stages:

- `Prefetch`: `PECmd.exe -d ... --csv ... --json ... --jsonpretty`
- `Amcache`: `RecentFileCacheParser.exe ... --csv ... --json ... --jsonpretty`
- `Evt` or `Evtx`: `EvtxECmd.exe -d ... --csv ... --json ...`
- `Registry`: `RECmd.exe --bn ... --csv ... --json ...`
- `File_System`: `MFTECmd.exe ... --csvf MFT.csv --jsonf MFT.json`
- `Jumplist\<user>`: `JLECmd.exe ... --csv ... --json ... --jsonpretty`
- `Shellbags`: `SBECmd.exe ... --csv ... --json ... --dedupe`
- `LNK`: `LECmd.exe ... --csv ... --json ... --jsonpretty`

The external processor uses the same parser switches for those stages. Native mode does not call these tools.

## CSV-Only Outputs

PERCIVAL emits CSV only for these stages:

- `Amcache\amcache.csv` from `AmcacheParser.exe`
- `Appcompatcache\appcompatcache.csv` from `AppCompatCacheParser.exe`
- `ActivitiesCache\<user>` from `WxTCmd.exe`
- `timeline\<capture>.csv` from Plaso `psort.exe`

The external processor mirrors that behavior. Native mode emits inventories/manifests instead.

## Native Outputs

Native mode emits:

- `native-analysis-manifest.json`
- `TXT\json\<command>.json`
- `TXT\txt_summary.json`
- `Evtx\<log>.json` or `Evt\<log>.json`, when the analyst host can read the log with `Get-WinEvent`
- `<artifact>\<artifact>_inventory.json` for binary artifact folders such as `Registry`, `File_System`, `Prefetch`, `Amcache`, `Jumplist`, `LNK`, `ActivitiesCache`, `Shim`, `SRUM`, `ScheduledTasks`, `Defender`, `WER`, `CloudStorage`, and `RemoteAdmin`

These are intentionally honest outputs: when a binary format is not parsed, the JSON says it is an inventory, not a decoded artifact.

## Case Folder Naming

PERCIVAL writes results to:

```text
Cases\<capture folder name>\
```

The new processor does the same. For a CHIRON-style capture named:

```text
HOST--yyyy.MM.dd.HH.mm.--LEGACY
```

the processor writes:

```text
Cases\HOST--yyyy.MM.dd.HH.mm.--LEGACY\
```

## Memory

PERCIVAL finds root-level `.zdmp` files, decompresses them with `Z2DMP_uncompress_dmp64.exe`, and writes:

```text
Cases\<capture>\<capture>.dmp
```

The new processor follows that root-level `.dmp` convention.

## Known Dependency Boundary

The processor can only produce the same semantic JSONs when the same parser executables are explicitly approved and available under `Tools\EZ` and `Tools\binaries`. Missing parsers are skipped and recorded in `process.log`. Native mode remains the default and does not use EZ tools.
