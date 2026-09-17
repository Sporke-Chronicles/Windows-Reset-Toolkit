# Intune WinRE Wipe Readiness

## Purpose

This package turns WinRE health into a proactive endpoint control. It answers: **if this device needs a full wipe later, are the local recovery prerequisites healthy now?**

The scripts never initiate a wipe.

## Files

- `scripts/intune/readiness/Detect-WinREWipeReadiness.ps1`
- `scripts/intune/readiness/Remediate-WinREWipeReadiness.ps1`

## What `Ready=True` means

At assessment time the detector has confirmed:

1. SYSTEM execution context.
2. WinRE enabled with resolvable registration.
3. Registered Windows Recovery partition present.
4. NTFS Recovery file system.
5. Readable `Winre.wim`.
6. Configured free-space reserve.
7. Registered WinRE can be mounted.
8. DISM `/CheckHealth` reports no component-store corruption.
9. Selected active third-party storage-driver packages are present in WinRE at the same or newer version.
10. Device-scoped `MDM_RemoteWipe` class/instance exists and exposes `doWipeMethod` without invoking it.

## Intune settings

Create a Remediations package with:

- Detection: `Detect-WinREWipeReadiness.ps1`
- Remediation: `Remediate-WinREWipeReadiness.ps1`
- Run using logged-on credentials: **No**
- Run in 64-bit PowerShell: **Yes**
- Signature check: according to your code-signing policy

Do not add an automatic reboot to this package. If a pending reboot blocks required repartitioning, resolve the reboot through normal endpoint operations and allow the next run to continue.

## Output

Healthy example:

```text
Ready=True;Code=H000;WinRE=Enabled;Part=2536MB/2074MBfree;WIM=True;Mount=OK;Component=OK;Drivers=InboxOrNA(0/0);MDM=OK;BL=FullyEncrypted/On;Reboot=False
```

Detailed telemetry is stored under:

- `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\WinREReadiness\`
- `%ProgramData%\WinREReadiness\WinRE-Readiness.json`
- `HKLM\SOFTWARE\WinREReadiness`

## Reference Intune validation

The v1.0.0 reference test enrolled the original disposable VM state into Intune with:

- WinRE Disabled;
- no registered WinRE location;
- an original 541 MB trailing Recovery partition;
- BitLocker enabled.

Real Intune Detection reported remediation required. IME then ran the remediation, which staged a valid `Winre.wim`, replaced the undersized Recovery partition, shrank C: only by the additional required amount, created a 2536 MB Recovery partition, registered/enabled WinRE, validated the WIM/component store/storage path, and resumed BitLocker.

A subsequent real Intune Detection produced:

```text
Ready=true
HealthCode=H000
WinREStatus=Enabled
WinRELocation=Disk0/Part4
RecoverySizeMB=2536
RecoveryFreeMB=2074
RecoveryFileSystem=NTFS
WinREWimValid=true
WinREMount=OK
ComponentStore=OK
DriverStatus=InboxOrNA
MDMBridge=OK
BitLocker=FullyEncrypted/On
PendingReboot=false
Issues=[]
Warnings=[]
```

This validates the Intune/IME orchestration for the inbox-storage Hyper-V reference path. It does not replace representative physical-hardware testing for positive third-party storage-driver injection.

## Scheduling

Detection performs deeper checks than a lightweight registry probe. Start with a small representative pilot. Daily, every few days, or weekly scheduling can be appropriate depending on wipe-readiness priority and endpoint impact.

## Interpretation

`Ready=True` validates local prerequisites at the last assessment. It does not guarantee future MDM delivery, network connectivity, enrollment health, or hardware survival.

See [Reason Codes](reason-codes.md) and [Troubleshooting](troubleshooting.md).
