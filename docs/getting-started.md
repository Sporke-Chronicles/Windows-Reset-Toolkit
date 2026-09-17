# Getting Started

## Choose the workflow first

### 1. Proactive wipe readiness, no wipe

Use `scripts/intune/readiness/` when the goal is to know **before an incident or migration** whether local WinRE prerequisites are healthy.

- `Detect-WinREWipeReadiness.ps1` assesses readiness.
- `Remediate-WinREWipeReadiness.ps1` repairs supported conditions.
- Neither script invokes RemoteWipe or resets Windows.

Start with [Intune WinRE Readiness](intune-winre-readiness.md).

### 2. ConfigMgr/co-management carve-out

Use `scripts/configmgr/` as an ordered task-sequence workflow:

1. `Check-WinREDriveLetter.ps1`
2. `Repair-WinRE.ps1`
3. `Inject-WinREStorageDrivers.ps1`
4. `Invoke-RemoteWipe.ps1`

Start with [ConfigMgr Carve-Out Reset](configmgr-carveout-reset.md).

### 3. Intune-controlled carve-out reset

Use `scripts/intune/carveout-reset/` when the endpoint can still execute Intune Remediations/SYSTEM PowerShell and a controlled local RemoteWipe is required.

The public safety model requires both assignment and a local short-lived authorization marker:

1. `Arm-CarveOutReset.ps1`
2. `Detect-CarveOutFullReset.ps1`
3. `Remediate-CarveOutFullReset.ps1`
4. `Disarm-CarveOutReset.ps1` when a wave must be stopped before wipe acceptance.

Start with [Intune Carve-Out Reset](intune-carveout-reset.md).

## Before production

Read [Prerequisites](prerequisites.md), [Safety Model](safety-model.md), [Lab Validation](lab-validation.md), and [Production Rollout](production-rollout.md).
