# Script Reference

| Script | Platform | Destructive capability | Typical result |
|---|---|---|---|
| `Detect-WinREWipeReadiness.ps1` | Intune | No wipe; temporary mounts/access paths only | Exit 0 ready / 1 remediate |
| `Remediate-WinREWipeReadiness.ps1` | Intune | Can rebuild Recovery partition; no wipe | Exit 0 ready / 1 failed |
| `Arm-CarveOutReset.ps1` | Intune | No | Creates expiring authorization marker |
| `Detect-CarveOutFullReset.ps1` | Intune | No | Exit 1 only when authorized |
| `Remediate-CarveOutFullReset.ps1` | Intune | **Yes** | Prepares endpoint and invokes normal RemoteWipe |
| `Disarm-CarveOutReset.ps1` | Intune | No | Revokes authorization before wipe acceptance |
| `Check-WinREDriveLetter.ps1` | ConfigMgr | No destructive disk change | Safe temporary letter / TS variable |
| `Repair-WinRE.ps1` | ConfigMgr | Can rebuild Recovery partition | WinRE healthy or explicit failure/3010 |
| `Inject-WinREStorageDrivers.ps1` | ConfigMgr | Services WinRE image | Required drivers present |
| `Invoke-RemoteWipe.ps1` | ConfigMgr | **Yes** | Preflight or RemoteWipe acceptance |

All production device-scoped workflows should use Local System. See each script's comment-based help for parameters and return codes.
