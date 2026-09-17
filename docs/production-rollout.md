# Production Rollout

## Recommended rings

1. **Disposable lab** - validate failure, retry, and destructive paths.
2. **Representative hardware pilot** - every storage-controller/OEM family.
3. **Small production wave** - tightly scoped targeting and active monitoring.
4. **Expanded waves** - only after reviewing reset completion, logs, and exception patterns.

## Readiness package

Deploy broadly before a migration where practical. Use Device status/export to identify endpoints with WinRE, partition, storage-driver, or MDM-control-surface issues early.

## Destructive Intune package

- Use tightly controlled **device** groups or one-time/on-demand execution.
- Keep the destructive Remediations package separate from the Arm delivery mechanism.
- Arm only endpoints that are approved and ready to reset.
- Remove the Arm assignment after approved endpoints have received the marker so a restored/re-enrolled endpoint is not automatically re-armed.
- Keep Disarm available as the local stop control before wipe acceptance.
- Do not issue repeated on-demand remediation requests while a destructive run is already in progress.
- Monitor Intune reporting, `HealthScripts.log`, local workflow state, and available local logs for failures before retrying.
- Remember that a successful wipe may enter Windows Reset before final local remediation log lines can be captured.

## ConfigMgr task sequence

Handle `3010` from WinRE repair as a reboot-required state. Reboot, then rerun rather than bypassing the pending-reboot safety gate without a deliberate engineering decision.

## Change control

Any change to partition selection/deletion, shrink calculations, BitLocker, authorization, RemoteWipe invocation, or storage-driver selection should trigger a fresh lab matrix and representative hardware pilot.
