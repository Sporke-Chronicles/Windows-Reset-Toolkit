# Safety Model

This repository includes scripts capable of changing disk partitions and initiating an irreversible Windows reset. Safety is therefore part of the architecture rather than an operational afterthought.

## Intune readiness is a no-wipe workflow

`Remediate-WinREWipeReadiness.ps1` can repair WinRE and may rebuild a Recovery partition when required, but it does not invoke the RemoteWipe method and does not intentionally reboot the endpoint.

## Destructive Intune reset requires two controls

The carve-out reset workflow requires:

1. A device to be targeted by the relevant Intune deployment/remediation.
2. A valid, unexpired local Arm marker with the expected `AuthorizationId`.

Missing, malformed, mismatched, expired, or disarmed authorization suppresses Detection. The remediation script independently checks authorization if invoked directly.

## Last reversible boundary

The full-reset remediation validates authorization at the beginning and again after the final WinRE/RemoteWipe preflight, immediately before wipe-specific BitLocker suspension. If an operator Disarms the endpoint or the marker expires during preparation, the workflow fails closed before the irreversible action.

## BitLocker

- Readiness detection treats normal BitLocker protection as telemetry, not a fault.
- WinRE partition remediation suspends OS BitLocker only when partition changes are required and resumes it before returning.
- Full reset suspends protected BitLocker volumes only after WinRE and the requested RemoteWipe method/provider have been validated.
- If the wipe invocation fails before Windows accepts it, the script attempts to resume volumes changed by that invocation.

## Partition repair

- Recovery partitions are identified by Windows Recovery partition metadata, not arbitrary position alone.
- A non-Recovery partition is not blindly deleted.
- `Winre.wim` is staged before destructive Recovery-partition replacement.
- Current contiguous free space is measured on every run; C: is shrunk only by additional required capacity.
- Retry paths are designed to recover forward from interrupted shrink/delete/create/copy/register stages.
- Unsupported or ambiguous states fail closed.

## Temporary drive letters

The scripts treat the preferred Recovery letter as a hint. If it is legitimately occupied, another free candidate is used. A temporary access path is removed only when it belongs to the Recovery partition being serviced.

## Protected wipe

Normal planned migration uses `doWipeMethod`. Protected wipe is not the default because Microsoft documents stronger persistence characteristics and possible bootability risk for some device configurations.

## Operational stop procedure

Before Windows accepts RemoteWipe, stop a migration wave by:

1. Removing/pausing the destructive assignment where practical; and
2. Delivering `Disarm-CarveOutReset.ps1` to the affected endpoint or wave.

After Windows has accepted the wipe, Disarm cannot cancel it.
