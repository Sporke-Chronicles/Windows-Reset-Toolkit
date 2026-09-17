# Prerequisites

## Common

- Windows client, not Windows Server.
- Administrator/SYSTEM execution for storage, BitLocker, WinRE, and WMI Bridge operations.
- 64-bit Windows PowerShell on 64-bit Windows.
- A tested backup/recovery plan and disposable lab devices before destructive validation.
- Sufficient free/shrinkable OS-partition capacity when a new Recovery partition must be created.

## Intune Remediations

- Intune licensing and tenant configuration that supports Remediations.
- Scripts configured to run using the logged-on credentials: **No**.
- Scripts configured to run in 64-bit PowerShell: **Yes**.
- Device-scoped targeting.
- For destructive carve-out reset, a tightly controlled migration-wave group plus the Arm marker.

## ConfigMgr

- Task sequence running in the normal Local System context.
- Native 64-bit PowerShell task-sequence steps on x64 Windows.
- Handle return code `3010` from `Repair-WinRE.ps1` as a reboot-needed condition before required partition work.

## Recovery partition automation

Automated destructive partition repair is intended for supported GPT/UEFI Windows client layouts. MBR and unusual/multi-disk layouts should be reviewed manually. See [Limitations](limitations.md).

## Representative hardware testing

Virtual-machine validation is not enough to prove third-party storage-driver handling. Pilot at least one endpoint for every storage-controller family used in production, especially Intel RST/VMD, AMD RAID, and vendor storage/NVMe drivers.
