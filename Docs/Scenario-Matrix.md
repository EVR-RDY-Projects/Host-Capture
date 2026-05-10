# Scenario Matrix

These scenarios were checked against the current scripts.

## Capture

The capture script was validated with `-PlanOnly` so no live host artifacts were acquired.

| Scenario | Command Shape | Expected Result | Status |
| --- | --- | --- | --- |
| Admin guard | run without admin and without `-PlanOnly` | exits with admin-required message | Pass |
| XP/no-PowerShell fallback | `Start-Capture.bat` on XP/2003 or no `powershell.exe` | invokes `Capture\Start-HostCaptureLegacy.bat` | Static pass |
| .NET 4.5+ gate | launcher checks `NDP\v4\Full\Release >= 378389` | modern PowerShell path only used when .NET 4.5+ exists | Static pass |
| Legacy artifacts, no memory | `-Mode Legacy -Memory No -Artifact Yes -NoPrompt -PlanOnly` | plans `--LEGACY`, memory `No`, artifact `Yes` | Pass |
| Full replacement, memory yes | `-Mode Full -Memory Yes -Artifact Yes -UseNoKapeSuffix -NoPrompt -PlanOnly` | plans `--NOKAPE`, memory `Yes`, artifact `Yes` | Pass |
| Critical | `-Mode Critical -Memory No -Artifact Yes -NoPrompt -PlanOnly` | plans `--CRITICAL` | Pass |
| Artifact bypass | `-Mode Legacy -Memory No -Artifact No -NoPrompt -PlanOnly` | plans artifacts skipped, op-notes path remains available | Pass |
| Interactive CHIRON-style prompts | piped choices for mode, memory, artifact | resolves `Ask` values to selected mode/options | Pass |
| Legacy no-prompt arguments | fallback batch with `-Memory No -Artifact No -NoPrompt -PlanOnly` | parses arguments without PowerShell/.NET assumptions | Static pass |
| Manifest quality | modern non-plan captures | final manifest includes timing, commands, tool hashes, file hashes, skipped artifacts, and failures | Static pass |

## Process

The processor was tested against a fake CHIRON-style collection under `_scenario\Collection`.

| Scenario | Command Shape | Expected Result | Status |
| --- | --- | --- | --- |
| Analysis plan | `-Mode Analysis -NoPrompt -PlanOnly` | plans analysis for selected capture(s) | Pass |
| Timeline plan | `-Mode Timeline -NoPrompt -PlanOnly` | plans timeline mode | Pass |
| Memory plan | `-Mode Memory -NoPrompt -PlanOnly` | plans memory/uncompress mode | Pass |
| Ask with no prompt | `-Mode Ask -NoPrompt -PlanOnly` | resolves to `All` | Pass |
| Interactive menu analysis | pipe `1` to `-Mode Ask -PlanOnly` | resolves to `Analysis` | Pass |
| Interactive menu exit | pipe `4` to `-Mode Ask -PlanOnly` | exits `0` | Pass |
| Single capture | one collection directory | no `.Count` strict-mode error | Pass |
| Multiple capture select | pipe mode then capture number | processes selected capture only | Pass |
| Capture filter | `-CaptureName 'HOST2*'` | processes matching capture only | Pass |
| No parser tools installed | real `Analysis`, `Timeline`, `Memory`, `All` runs | creates case/log, copies `TXT`, logs missing Plaso/Z2DMP, skips missing parsers | Pass |

## Boundaries

- Live capture was not run in this pass because it requires administrator privileges and collects from the current host.
- Third-party parser execution is out of the default path. Missing or unapproved tools are skipped and logged.
- KAPE normal-mode VHDX processing is intentionally not reproduced.
