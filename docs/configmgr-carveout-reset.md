# ConfigMgr Carve-Out Reset

## Ordered task-sequence steps

| Order | Script | Purpose |
|---:|---|---|
| 1 | `Check-WinREDriveLetter.ps1` | Resolve a safe temporary Recovery access letter without stealing an unrelated volume letter. |
| 2 | `Repair-WinRE.ps1` | Validate, re-register, resize, relocate, or rebuild WinRE with retry-safe current-state logic. |
| 3 | `Inject-WinREStorageDrivers.ps1` | Ensure active third-party boot/storage drivers are present in WinRE. |
| 4 | `Invoke-RemoteWipe.ps1` | Validate final reset prerequisites, handle BitLocker, and invoke the local MDM RemoteWipe method. |

## Task-sequence settings

- Run as Local System.
- Prefer native 64-bit Windows PowerShell on x64 devices.
- Step 1 success: `0`.
- Step 2 success: `0`; `3010` means reboot before required repartitioning, then rerun the same workflow.
- Step 3 success: `0`.
- Step 4 success: `0`; optional `-Return3010` exists for control flows that explicitly require it.

## Retry behaviour

`Repair-WinRE.ps1` reassesses the disk every time. It can repair forward when:

- C: is already shrunk but no new Recovery partition exists.
- The old Recovery partition has already been removed.
- A new Recovery partition exists but the WIM has not been copied.
- The WIM exists but ReAgent registration/enablement is incomplete.
- A valid trailing Recovery partition already exists.

The persistent staged copy under `%ProgramData%\CarveOutReset\WinRE` is intentional so a rerun can recover after an interruption.

## RemoteWipe preflight

Before destructive use, run the final script with:

```powershell
.\Invoke-RemoteWipe.ps1 -PreflightOnly
```

This validates SYSTEM context, requested RemoteWipe method/provider, WinRE enabled state, and BitLocker telemetry without invoking the wipe.

## Storage-driver testing

A Hyper-V guest is useful for the inbox-driver negative path but does not prove Intel RST/VMD, AMD RAID, or vendor storage-driver injection. Test representative physical hardware before production.
