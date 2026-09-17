# Lab Validation

Use disposable VMs/devices or hardware with a known recovery path. Capture sanitized logs, `reagentc /info`, partition layout, and BitLocker state for each scenario.

## Minimum readiness tests

- Healthy endpoint -> Detection exit 0 / `H000`.
- Wrong execution context -> `CTX001`.
- WinRE disabled -> Detection exit 1; remediation re-enables/re-registers safely.
- Undersized trailing Recovery -> remediation stages WIM, rebuilds Recovery, and returns BitLocker to its original protected state.
- Healthy Recovery + WinRE disabled -> remediation reuses the existing partition without shrink/delete/create.
- Legitimately occupied preferred temporary drive letter -> another candidate is used and the unrelated volume remains untouched.
- Post-remediation Detection -> `Ready=True;Code=H000`.

## Minimum ConfigMgr tests

- Safe drive-letter selection with preferred letter unused and occupied.
- Healthy WinRE idempotent rerun with no partition change.
- Undersized Recovery repair.
- Recovery absent with available shrink space.
- Storage-driver inbox/NA path.
- SYSTEM preflight for RemoteWipe.
- Manual WinRE boot and OS-disk visibility.
- Normal destructive `doWipeMethod` reaches reset/OOBE on representative hardware.

## Minimum Intune carve-out authorization tests

- No Arm -> Detection exit 0 and remediation does not launch.
- Confirm IME `HealthScripts.log` records the unauthorized Detection and exit 0.
- Arm delivered through Intune -> registry contains the expected authorization ID and future expiry.
- Arm -> Detection exit 1.
- Disarm -> Detection exit 0.
- Direct remediation while disarmed -> fail before WinRE/BitLocker/wipe work.
- Authorized `-PreflightOnly` -> exit 0, Arm values preserved, provider/method validated, BitLocker still protected.
- Destructive authorized remediation -> Windows Reset completes successfully.

## Real Intune end-to-end reference test

The v1.0.0 reference release completed the following with actual Intune/IME delivery:

1. Enrolled the original VM state with WinRE Disabled and a 541 MB Recovery partition.
2. Intune Detection identified the unhealthy state.
3. Intune remediation rebuilt Recovery to 2536 MB and enabled WinRE.
4. Post-remediation Detection returned `Ready=true` / `H000` with BitLocker FullyEncrypted/On.
5. Destructive package run while Disarmed returned Detection exit 0 and did not launch remediation.
6. Arm was delivered through Intune.
7. Authorized on-demand Remediation initiated and completed Windows Reset successfully.

## Representative hardware matrix

Test at least one endpoint for every production storage/controller family:

- Microsoft inbox AHCI/NVMe.
- Intel RST/VMD.
- AMD RAID where present.
- Vendor NVMe/storage drivers where present.
- BitLocker/device-encrypted and unencrypted devices.
- Common OEM Recovery layouts used in your estate.

## Interrupted-run testing

For high-assurance deployment, intentionally interrupt and retry around major partition stages in a disposable lab. Verify a rerun repairs forward without repeatedly shrinking C: or deleting unrelated partitions.
