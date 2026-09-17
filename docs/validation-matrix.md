# Validation Matrix

This document separates **observed reference evidence** from capabilities that still require environment-specific validation.

## Reference environment

Reference VM: Windows 10 Pro 22H2 / build 19045, Hyper-V, GPT/UEFI layout, BitLocker enabled. The same VM was also enrolled into a real Microsoft Intune tenant for the final Management Extension tests.

> The reference OS identifies the environment used for validation; it is not a statement of Microsoft lifecycle support. Validate the toolkit on the Windows versions and OEM/storage platforms used in your estate.

## Local / SYSTEM lab evidence

| Scenario | Result | Notes |
|---|---|---|
| Wrong-context readiness detection | PASS | Interactive execution returned `CTX001`. |
| WinRE-disabled readiness detection | PASS | SYSTEM Detection returned remediation-needed with `RE002,RE003`. |
| Undersized Recovery repair | PASS | 541 MB Recovery was replaced with a 2536 MB trailing Recovery partition; C: was shrunk only by additional required space. |
| Existing healthy Recovery reuse | PASS | 2536 MB Recovery was reused to re-register/re-enable WinRE with no repartitioning. |
| Readiness post-remediation | PASS | `Ready=True;HealthCode=H000`; WIM, mount, component, MDM, and BitLocker checks passed. |
| Temporary-letter collision | PASS | Legitimate R: volume survived; detector/remediator used another temporary letter. |
| BitLocker around partition repair | PASS | Protection resumed and reported FullyEncrypted/On after repair. |
| Hyper-V inbox storage-driver path | PASS | No third-party injection required. |
| Manual WinRE boot / OS disk visibility | PASS | Disk and expected partitions visible in WinRE. |
| ConfigMgr RemoteWipe SYSTEM preflight | PASS | `doWipeMethod` and provider instance validated with BitLocker still On. |
| ConfigMgr destructive normal wipe | PASS | Windows Reset was observed progressing under the validated local workflow. |
| Intune Arm/Detect/Disarm controls | PASS | Detection sequence 0 -> 1 -> 0 behaved as designed. |
| Direct disarmed full-reset remediation | PASS | Failed at authorization before WinRE/BitLocker/wipe work. |
| Authorized full-reset preflight | PASS | Provider/method validation passed; BitLocker remained On. |
| Authorization persistence through telemetry | PASS | Arm marker survived preflight after the registry-state hardening. |
| Local SYSTEM full-reset orchestration | PASS | Normal RemoteWipe triggered and Windows Reset completed successfully. |

## Real Intune / IME evidence

| Scenario | Result | Observed evidence |
|---|---|---|
| Real Intune readiness Detection | PASS | IME executed Detection against an endpoint with WinRE Disabled and an original 541 MB Recovery partition. |
| Detection -> Remediation transition | PASS | Intune launched the readiness remediation after the unhealthy Detection result. |
| Recovery repair through IME | PASS | Remediation staged a valid `Winre.wim`, replaced the 541 MB Recovery partition, shrank C: only by the additional required amount, created a 2536 MB GPT Recovery partition, registered WinRE, and resumed BitLocker. |
| Post-remediation readiness through Intune | PASS | Subsequent Detection reported `Ready=true`, `HealthCode=H000`, WinRE Enabled on Disk0/Part4, 2536 MB Recovery, 2074 MB free, valid WIM, mount OK, component store OK, MDM bridge OK, and BitLocker FullyEncrypted/On. |
| Repeated healthy Detection | PASS | Subsequent IME Detection runs remained healthy and idempotent. |
| Disarmed destructive package suppression | PASS | IME logged `Not authorized for carve-out reset.`, Detection exit code 0, and no remediation execution. No carve-out remediation log was created. |
| Arm delivered through Intune | PASS | Intune Platform script created `Armed=1`, `AuthorizationId=CARVEOUT-RESET-V1`, future expiry, `Status=Armed`, and no error. |
| Authorized destructive Detection -> Remediation | PASS | On-demand Intune remediation crossed the authorization gate and launched the destructive workflow. |
| Intune-driven RemoteWipe / Windows Reset | PASS | The VM entered and completed Windows Reset successfully. The reset can begin before the final remediation log is retrievable. |

## Still requires representative environment validation

| Scenario | Status |
|---|---|
| Intel RST/VMD positive driver injection | Not proven by the Hyper-V inbox-driver reference lab. |
| AMD RAID positive driver injection | Not proven by the Hyper-V inbox-driver reference lab. |
| Vendor third-party NVMe/storage positive injection | Test where present. |
| Windows 11 / OEM model families | Pilot representative devices before broad use. |
| Non-standard multi-disk/Recovery layouts | Manual review and targeted testing required. |
| MBR/dynamic-disk/custom OEM Recovery layouts | Outside the primary automated repair target; validate or handle manually. |

## Interpretation

A PASS demonstrates the corresponding code path under the stated reference state. It is not a guarantee for every Windows/OEM/storage configuration. The positive third-party storage-driver injection path must be validated on hardware that actually uses those controller packages.
