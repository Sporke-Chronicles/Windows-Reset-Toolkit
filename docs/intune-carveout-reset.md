# Intune Carve-Out Full Reset

## When to use it

Use this workflow for a controlled endpoint migration/reset where the device can still execute SYSTEM PowerShell but the standard management-plane wipe cannot be relied on.

Where native Intune Wipe works normally, prefer the native action.

## Files

- `Arm-CarveOutReset.ps1` - creates a short-lived local authorization marker.
- `Detect-CarveOutFullReset.ps1` - returns exit 1 only while authorization is valid.
- `Remediate-CarveOutFullReset.ps1` - ordered preparation + destructive reset workflow.
- `Disarm-CarveOutReset.ps1` - revokes local authorization before wipe acceptance.

## Intune configuration

Create one **Remediations** package using:

- Detection: `scripts/intune/carveout-reset/Detect-CarveOutFullReset.ps1`
- Remediation: `scripts/intune/carveout-reset/Remediate-CarveOutFullReset.ps1`
- Run using logged-on credentials: **No**
- Run in 64-bit PowerShell: **Yes**
- Signature check: according to your code-signing policy

Create **Arm** and **Disarm** as device-scoped Intune PowerShell/Platform scripts running as SYSTEM in 64-bit PowerShell.

For the first validation in a tenant, keep the destructive Remediations package **unassigned** and use an on-demand **Run remediation** operation against one disposable test device. This prevents a schedule from repeatedly presenting the destructive package while the safety controls are being validated.

## Why the remediation is self-contained

WinRE repair, storage-driver servicing, final provider validation, BitLocker handling, and wipe are order-dependent. They run serially in one remediation invocation rather than relying on ordering across independent packages.

## Recommended first-time Intune validation

1. Take a hypervisor/device recovery checkpoint before the destructive test.
2. Confirm the endpoint is healthy with the readiness package (`Ready=true`, `H000`) or intentionally start from a known broken state if testing remediation.
3. Create the destructive Detection + Remediation package with no assignment.
4. While **Disarmed**, run the package on demand once.
5. Confirm Detection exits 0 with `Not authorized for carve-out reset.` and that remediation does **not** execute. No `CarveOut-FullReset-*.log` is expected because that log is created by the remediation script.
6. Deliver `Arm-CarveOutReset.ps1` through Intune as SYSTEM.
7. Verify locally that the workflow registry contains `Armed=1`, the expected `AuthorizationId`, a future expiry, `Status=Armed`, and no error.
8. Capture WinRE, Recovery-partition, readiness, and BitLocker state, then take the final checkpoint.
9. Run the destructive package on demand **once**.
10. Allow the Windows Reset to complete. Do not send a second remediation request while the first one is in progress.

The tested reference sequence was:

```text
Real Intune / IME
      |
      +--> Disarmed Detection -> exit 0 -> no remediation
      |
      +--> Arm Platform script -> Armed=1
      |
      +--> On-demand Run remediation
              |
              +--> Detection -> exit 1
              +--> Remediation as SYSTEM / 64-bit
              +--> WinRE + storage validation
              +--> RemoteWipe provider/method validation
              +--> final authorization revalidation
              +--> BitLocker suspension for wipe
              +--> MDM_RemoteWipe.doWipeMethod
              +--> Windows Reset
```

## Authorization configuration

The default authorization protocol identifier is:

```text
CARVEOUT-RESET-V1
```

For migration waves, you may choose a unique identifier, but it must be changed consistently in Arm, Detection, and Remediation before deployment and then retested.

## Preflight-only mode

For an authorized lab endpoint:

```powershell
.\Remediate-CarveOutFullReset.ps1 -PreflightOnly
```

This validates authorization, WinRE readiness/repair, storage-driver readiness, RemoteWipe method metadata/provider instance, and BitLocker telemetry, then stops before wipe-specific BitLocker suspension and before invoking RemoteWipe.

`-PreflightOnly` is **no-wipe**, not strictly read-only: WinRE preparation can still repair the Recovery environment if required.

## Logs and state

- Logs: `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\CarveOutReset\`
- IME orchestration evidence: `%ProgramData%\Microsoft\IntuneManagementExtension\Logs\HealthScripts.log`
- Workflow registry: `HKLM\SOFTWARE\CarveOutMigration\ResetWorkflow`

Important states include `Armed`, `Preflight`, `WinREReady`, `DriversReady`, `PreflightOnlyComplete`, `ReadyToWipe`, `WipeTriggered`, and `Failed`.

When Disarmed, Detection intentionally exits 0 and remediation is not launched. Therefore **no CarveOutReset remediation log is expected** for a successful disarmed safety test. `HealthScripts.log` can be used to confirm the Detection output and exit code.

After RemoteWipe is accepted, Windows may enter reset before the remediation process can persist or an operator can retrieve the final local log lines. Successful transition into Windows Reset and completion of the reset is the authoritative destructive-path acceptance evidence.

## Operational stop procedure

Before Windows accepts RemoteWipe:

1. Stop/remove the destructive assignment or avoid another on-demand request; and
2. Deliver `Disarm-CarveOutReset.ps1`.

The full-reset remediation checks authorization again immediately before wipe-specific BitLocker suspension. After Windows accepts RemoteWipe, Disarm cannot cancel the reset.

## Production use

For production waves:

- Use tightly controlled **device** targeting.
- Keep Arm delivery separate from the destructive Remediations package.
- Prefer one-time/on-demand execution where operationally practical.
- Remove the Arm assignment after the approved endpoints have been armed so a restored/re-enrolled endpoint is not unintentionally re-armed.
- Keep Disarm available as an emergency stop before wipe acceptance.
- Pilot every storage-controller/OEM family used in the environment.

## Final acceptance

A representative production hardware pilot should prove normal `doWipeMethod` reaches a completed Windows Reset without manual recovery intervention.
