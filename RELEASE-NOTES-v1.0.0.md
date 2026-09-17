# Windows Reset Toolkit v1.0.0

**Release date:** 2026-09-17

v1.0.0 is the first public release of the Windows Reset Toolkit: a set of Windows PowerShell workflows for assessing and repairing WinRE readiness, preparing Recovery partitions and storage drivers, and performing tightly controlled ConfigMgr or Intune-driven Windows resets.

## Included workflows

### Intune WinRE Wipe Readiness

- Detects local reset-readiness issues without invoking a wipe.
- Repairs supported WinRE registration, Recovery-partition, component-store, and storage-driver conditions.
- Produces machine-readable readiness telemetry including `Ready` and `HealthCode`.

### Intune Carve-Out Full Reset

- Uses an explicit short-lived Arm marker before destructive remediation can run.
- Suppresses remediation while Disarmed.
- Revalidates authorization at the last reversible boundary before wipe-specific BitLocker suspension.
- Validates WinRE, storage readiness, and the requested `MDM_RemoteWipe` method/provider before invoking normal `doWipeMethod`.
- Includes a no-wipe `-PreflightOnly` validation mode.

### ConfigMgr Carve-Out Reset

- Provides ordered scripts for temporary Recovery access, WinRE repair, storage-driver servicing, and local RemoteWipe.
- Includes retry-safe Recovery-partition repair and BitLocker-aware handling.

## Reference validation completed for v1.0.0

The release was validated in a disposable Hyper-V Windows client VM and then through a real Microsoft Intune tenant.

The real Intune test deliberately started from an unhealthy endpoint with WinRE Disabled and an original 541 MB Recovery partition. Intune/IME:

1. detected the unhealthy WinRE state;
2. launched remediation;
3. staged and validated `Winre.wim`;
4. replaced the undersized Recovery partition with a 2536 MB GPT Recovery partition;
5. registered and enabled WinRE;
6. returned BitLocker to FullyEncrypted/On;
7. subsequently reported `Ready=true` / `HealthCode=H000` with WIM, mount, component store, MDM bridge, and Recovery free-space checks healthy.

The destructive safety model was then validated through real Intune:

- an on-demand run while Disarmed exited Detection 0 and did not launch remediation;
- the Arm control was delivered through Intune and created a valid `CARVEOUT-RESET-V1` marker;
- the authorized on-demand Detection -> Remediation workflow invoked the normal RemoteWipe path and Windows Reset completed successfully.

Local/SYSTEM testing also covered idempotent Recovery reuse, recovery-from-partial-state scenarios, occupied temporary drive-letter handling, BitLocker restoration, RemoteWipe provider/method preflight, and destructive reset execution.

## Important validation boundary

The reference Hyper-V environment uses inbox Microsoft storage drivers. Positive injection of third-party Intel RST/VMD, AMD RAID, and vendor NVMe/storage drivers requires representative physical hardware and remains an environment-specific pilot requirement.

Windows 11 and OEM-specific Recovery layouts should likewise be piloted before broad deployment.

## Logging behavior during a successful reset

A successful `MDM_RemoteWipe.doWipeMethod` call can transition Windows into Reset before the remediation process or an operator can retrieve the final local log lines. For the destructive path, successful Windows Reset progression/completion is the authoritative outcome; the absence of a final `WipeTriggered` log line alone is not a failure.

## Safety

This project includes scripts that can modify disk partitions and intentionally reset Windows. Read `docs/safety-model.md`, use disposable validation devices, use device-scoped targeting, and keep Arm/Disarm controls operational before production rollout.

## Versioning

Public script filenames are intentionally stable and do not contain release numbers. Repository releases and the root `VERSION` file carry Semantic Versioning. The first public release is `v1.0.0`.
