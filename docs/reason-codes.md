# WinRE Wipe Readiness - Detection Codes

These codes are emitted by `Detect-WinREWipeReadiness.ps1`.

## Healthy

| Code | Meaning |
|---|---|
| `H000` | All required local readiness checks passed. |

## Execution / OS

| Code | Meaning | Typical action |
|---|---|---|
| `CTX001` | Detection is not running as Local System. | Configure Intune Remediations to run without logged-on credentials. |
| `CTX002` | Another WinRE readiness workflow held the global mutex. | Allow current run to finish and rerun. |
| `CTXW001` | A prior process abandoned the workflow mutex and the current run recovered ownership. | Warning only; review prior termination if unexpected. |
| `OS001` | Windows Server detected. | Package is intended for Windows client devices. |
| `DET999` | Unexpected detector failure before a more specific issue could be recorded. | Review local log. |

## ReAgent / WinRE registration

| Code | Meaning | Typical action |
|---|---|---|
| `RE001` | `reagentc /info` returned an error. | Remediation/review ReAgent configuration. |
| `RE002` | WinRE is not enabled. | Remediation re-registers/enables where possible. |
| `RE003` | Registered WinRE partition cannot be resolved. | Remediation attempts current-state recovery; inspect if it persists. |
| `REW001` | `ReAgent.xml` could not be parsed. | Warning; detector falls back where possible. |
| `REW002` | `ReAgent.xml` missing. | Warning; investigate if ReAgent state is otherwise unhealthy. |

## Recovery partition

| Code | Meaning | Typical action |
|---|---|---|
| `PART001` | Registered WinRE partition does not exist. | Remediation rebuild/re-register on supported GPT layout. |
| `PART002` | WinRE is registered on a different disk from the OS. | Manual review; not a normal supported state. |
| `PART003` | Registered partition is not identified as Windows Recovery. | Remediation may create/register a correct Recovery partition. |
| `PART004` | Recovery file system is not NTFS. | Rebuild Recovery partition. |
| `PART005` | Recovery partition is below configured size floor. | Remediation can create a larger trailing Recovery partition on GPT. |
| `PART006` | Recovery partition has less than required free-space reserve. | Remediation resize/rebuild. |
| `PART007` | Partition cannot contain current WIM plus required reserve. | Remediation resize/rebuild. |
| `PART008` | Recovery partition could not be safely inspected. | Review storage/access-path error. |
| `PARTW001` | GPT Recovery partition does not report `NoDefaultDriveLetter`. | Warning; review partition attributes if desired. |
| `PARTW002` | Recovery partition has a drive letter assigned. | Warning; remove unnecessary persistent access path. |

## WinRE image

| Code | Meaning | Typical action |
|---|---|---|
| `WIM001` | `Winre.wim` missing from registered Recovery location. | Remediation stages/repopulates from a valid source where possible. |
| `WIM002` | `Winre.wim` exists but DISM cannot read index 1. | Replace/rebuild WinRE image. |
| `WIM003` | Registered WinRE could not complete deep mount/validation. | Remediation/review ReAgent and WIM servicing state. |
| `WIM004` | DISM reports WinRE component-store corruption or health command failed. | Remediation attempts safe offline RestoreHealth; otherwise manual repair. |
| `WIM005` | DISM returned an inconclusive component-health result. | Review DISM log/local readiness log. |
| `MNTW001` | Stale audit mount could not be completely cleaned. | Warning; inspect DISM mounted-image state. |

## Storage drivers

| Code | Meaning | Typical action |
|---|---|---|
| `DRV001` | Active third-party storage driver could not be exported for verification. | Review PnPUtil/driver-store package. |
| `DRV002` | WinRE is missing or has an older required active storage driver package. | Remediation injects active package into WinRE. |
| `DRV003` | Offline WinRE driver inventory could not be verified. | Review DISM PowerShell module / image mount. |

## MDM RemoteWipe control surface

| Code | Meaning | Typical action |
|---|---|---|
| `MDM001` | Device-scoped `MDM_RemoteWipe` WMI Bridge class/instance is unavailable. | Review MDM/Windows management health; script deliberately does not invoke a wipe. |
| `MDM002` | `MDM_RemoteWipe` exists but `doWipeMethod` is not exposed. | Review Windows build/MDM WMI Bridge health. |

## Operational warnings

| Code | Meaning |
|---|---|
| `BLW001` | BitLocker status could not be read for telemetry. |
| `SYSW001` | Pending reboot detected. This does not make an already healthy WinRE unhealthy, but repartition remediation will wait for a reboot. |
