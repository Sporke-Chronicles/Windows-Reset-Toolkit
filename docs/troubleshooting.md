# Troubleshooting

## Start with these captures

```powershell
reagentc /info

Get-Partition -DiskNumber 0 |
    Sort-Object Offset |
    Select-Object PartitionNumber,DriveLetter,Type,GptType,
        @{N='SizeMB';E={[math]::Round($_.Size/1MB,0)}},
        @{N='OffsetMB';E={[math]::Round($_.Offset/1MB,2)}} |
    Format-Table -AutoSize

Get-BitLockerVolume -MountPoint C: |
    Format-List MountPoint,VolumeStatus,ProtectionStatus
```

For readiness issues, also capture the latest sanitized JSON and log from:

```text
%ProgramData%\WinREReadiness\WinRE-Readiness.json
%ProgramData%\Microsoft\IntuneManagementExtension\Logs\WinREReadiness\
```

For carve-out reset issues:

```text
%ProgramData%\Microsoft\IntuneManagementExtension\Logs\CarveOutReset\
%ProgramData%\Microsoft\IntuneManagementExtension\Logs\HealthScripts.log
HKLM\SOFTWARE\CarveOutMigration\ResetWorkflow
```

## Detection says CTX001

The package is not running as Local System. In Intune Remediations, set **Run this script using the logged-on credentials** to **No**.

## WinRE is disabled

Run Detection to capture the reason codes, then allow the readiness remediation to re-register/enable WinRE. Do not manually repartition unless the automated remediation has failed and the disk state has been reviewed.

## Recovery partition is too small

The readiness/configmgr repair logic can rebuild a supported GPT trailing Recovery partition. A pending reboot, unsupported partition style, insufficient shrinkable space, or ambiguous layout can make it fail closed instead.

## DiskPart rescan warns after a successful shrink

A best-effort `diskpart rescan` can occasionally return a warning even though the preceding shrink completed. The v1.0.0 reference Intune test observed:

```text
DiskPart encountered an error starting the disk management services.
```

The workflow treated the rescan as a warning, then successfully created/formatted the 2536 MB Recovery partition and passed final validation. Do not treat a rescan warning alone as proof of failure. The decisive evidence is the subsequent partition operation and final WinRE/readiness validation. If partition creation or final validation fails, stop and capture the complete disk state before retrying.

## Preferred temporary drive letter is occupied

This is expected. The scripts should select another free candidate. Do not remove unrelated drive-letter assignments merely to satisfy the preferred letter.

## BitLocker is still suspended after a failed run

Treat this as a high-priority exception. Capture the log and current state before changing partitions again. Resume protection through your approved BitLocker operational process after understanding why the script's best-effort recovery did not complete.

## MDM001 / RemoteWipe provider missing

This means the local device-scoped WMI Bridge control surface could not be validated. Review Windows/MDM health and SYSTEM context. The readiness script does not prove actual Intune enrollment/check-in simply because the local class exists.

## Destructive Intune remediation says authorization missing

Check the workflow registry and verify `Armed=1`, the expected `AuthorizationId`, and an unexpired UTC timestamp. Do not bypass the authorization marker to make a failing test proceed.

## Disarmed Run remediation completes but no CarveOutReset log exists

This is the expected safe result.

When the endpoint is not armed, `Detect-CarveOutFullReset.ps1` outputs:

```text
Not authorized for carve-out reset.
```

and exits 0. Intune therefore does **not** launch the remediation script, so no `CarveOut-FullReset-*.log` is created.

To confirm the control path, inspect `HealthScripts.log` for the Detection output and a first Detection exit code of 0. In the reference Intune test, IME also reported no remediation exit code because remediation never ran.

## Windows Reset starts before the final remediation log can be captured

This can be normal. After `MDM_RemoteWipe.doWipeMethod` is accepted, Windows may transition into reset before the script/IME can persist or an operator can retrieve the final log lines. For the destructive path, successful entry into Windows Reset and successful reset completion are stronger acceptance evidence than the presence of a final `WipeTriggered` log line.

If the device remains in Windows and no reset starts, do not repeatedly trigger the remediation. Capture the latest CarveOutReset log, workflow registry state, `HealthScripts.log`, BitLocker state, and `reagentc /info` first.

## Pending reboot blocks partition work

Reboot through normal endpoint-management processes, then rerun. The readiness workflow intentionally does not reboot the endpoint automatically.

## NativeCommandError on Windows PowerShell 5.1

The public release wraps important native command paths so stderr text is evaluated together with the real process exit code. If a new direct native-command path is added by a future contribution, use the same controlled-capture pattern rather than relying on `$ErrorActionPreference='Stop'` around native stderr.
