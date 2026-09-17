# Changelog

All notable public changes to this project will be documented in this file.
The project follows [Semantic Versioning](https://semver.org/).

## [1.0.0] - 2026-09-17

### Added

- Proactive WinRE wipe-readiness detection for Microsoft Intune Remediations.
- Non-wipe WinRE readiness remediation with retry-safe GPT Recovery partition repair.
- Storage-controller driver validation and conditional WinRE injection.
- ConfigMgr task-sequence workflow for drive-letter safety, WinRE repair, storage-driver servicing, and local RemoteWipe.
- Intune carve-out reset workflow with explicit Arm/Disarm authorization, fail-closed detection, workflow mutex, final authorization revalidation, BitLocker-aware reset handling, and `-PreflightOnly` validation mode.
- Windows PowerShell 5.1 native-command handling hardened for `reagentc.exe`, `diskpart.exe`, and BitLocker tooling.
- Public documentation, validation matrix, troubleshooting guidance, static safety tests, and GitHub Actions CI.

### Validated in the reference environment

- Real Intune Management Extension Detection -> Remediation delivery from WinRE Disabled / 541 MB Recovery to `Ready=True` / `H000` with a 2536 MB Recovery partition.
- Real Intune fail-closed destructive detection while Disarmed: Detection exited 0 and remediation was not launched.
- Real Intune delivery of the Arm control and preservation of the `CARVEOUT-RESET-V1` authorization marker.
- Real Intune authorized Detection -> destructive Remediation -> `doWipeMethod` -> successful Windows Reset.
- Local/SYSTEM idempotency, temporary-drive-letter collision handling, BitLocker recovery, RemoteWipe provider preflight, and destructive reset paths.

### Release note

This is the first public version. Internal development version numbers and engineering changelogs are intentionally not carried into the public history.
