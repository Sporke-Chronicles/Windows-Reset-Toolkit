# Windows Reset Toolkit

A Windows PowerShell toolkit for **WinRE readiness, resilient Recovery-partition repair, storage-driver coverage, ConfigMgr carve-out resets, and controlled Intune-driven full resets**.

> [!CAUTION]
> Parts of this repository can deliberately trigger a full Windows reset. Read the [Safety Model](docs/safety-model.md), validate on disposable devices, and use tightly controlled targeting before production deployment.

## Why this project exists

A remote wipe can fail for reasons that are local to the endpoint: WinRE can be disabled or misregistered, the Recovery partition can be undersized, required storage-controller drivers can be missing from WinRE, or a reset workflow can change BitLocker state too early.

This toolkit separates the problem into three practical workflows:

| Need | Recommended workflow | Destructive? |
|---|---|---:|
| Continuously assess whether WinRE is locally ready for a future wipe | [Intune WinRE Readiness](docs/intune-winre-readiness.md) | No |
| Repair WinRE readiness proactively | [Intune WinRE Readiness](docs/intune-winre-readiness.md) | No wipe; partition repair may occur |
| Reset a ConfigMgr/co-managed endpoint during a carve-out | [ConfigMgr Carve-Out Reset](docs/configmgr-carveout-reset.md) | Yes, final step |
| Perform a tightly authorized Intune-driven carve-out reset | [Intune Carve-Out Reset](docs/intune-carveout-reset.md) | Yes |

## Quick start

1. Read [Prerequisites](docs/prerequisites.md) and [Safety Model](docs/safety-model.md).
2. Choose a workflow in [Getting Started](docs/getting-started.md).
3. Run the relevant [Lab Validation](docs/lab-validation.md) cases on sacrificial devices or VMs.
4. Review the [Validation Matrix](docs/validation-matrix.md) to understand what has and has not been proven in the reference lab.
5. Pilot on representative physical hardware before broad rollout.

## Repository layout

```text
scripts/
  intune/
    readiness/          Proactive detection/remediation; never invokes a wipe.
    carveout-reset/     Arm/Detect/Remediate/Disarm controlled reset workflow.
  configmgr/            Ordered ConfigMgr task-sequence scripts.

docs/                   Deployment, safety, testing, troubleshooting, and reference guides.
tools/                  Lab/CI helper scripts; not required in production.
tests/                  Static safety and repository tests.
.github/                 CI workflow, issue forms, and pull-request template.
```

## Key safety properties

- The Intune readiness remediation **does not invoke a wipe API**.
- Destructive Intune remediation requires a short-lived local Arm marker in addition to assignment or on-demand execution.
- Authorization is revalidated again at the last reversible boundary before wipe-specific BitLocker suspension.
- The ConfigMgr and Intune repair paths stage `Winre.wim` before destructive partition work and reassess current disk state on every run.
- A legitimate occupied temporary drive letter is not stolen; another candidate is selected.
- Normal planned migrations use `doWipeMethod`; protected wipe is not the default.
- Partition repair is fail-closed on unsupported/unsafe conditions.

See [Safety Model](docs/safety-model.md) for the complete sequence.

## Supported execution model

The validated target is Windows client with Windows PowerShell 5.1, running device-scoped operations as **Local System** and using **64-bit PowerShell** on 64-bit Windows. The toolkit is not intended for Windows Server.

The Recovery-partition repair automation is designed around GPT/UEFI Windows client layouts. See [Limitations](docs/limitations.md).

## Native Intune Wipe remains preferred

Where the standard Intune Wipe action works reliably, use the native management-plane action. The carve-out reset workflow is intended for controlled migration/recovery scenarios where a device can still execute SYSTEM PowerShell but the normal control-plane wipe cannot be relied on.

## Public release versioning

Script filenames are intentionally **not versioned**. Git tags and the root `VERSION` file carry release versioning. This keeps ConfigMgr/Intune package references stable across updates.

Current public release: **v1.0.0**.

## Validation status

The reference validation includes both local/SYSTEM lab execution and **real Microsoft Intune Management Extension delivery**. The Intune reference test started from WinRE Disabled with an undersized 541 MB Recovery partition, detected the unhealthy state through Intune, repaired it to a healthy 2536 MB Recovery partition, returned `Ready=True` / `H000`, proved that the destructive package remains inert while Disarmed, delivered the Arm control through Intune, and then completed an authorized Intune-driven Windows Reset successfully.

Representative positive third-party Intel RST/VMD, AMD RAID, and vendor storage-driver injection still requires suitable physical hardware. Windows 11 and OEM-specific layouts should also be piloted before broad production deployment. See [Validation Matrix](docs/validation-matrix.md).

## Security and sensitive logs

Do not post raw BitLocker recovery material, tenant identifiers, credentials, customer data, or unredacted production logs in GitHub issues. See [SECURITY.md](SECURITY.md).

## Release notes

See [RELEASE-NOTES-v1.0.0.md](RELEASE-NOTES-v1.0.0.md) for the first public release summary and validation boundaries.
Maintainers can also review [RELEASE-VALIDATION-v1.0.0.md](RELEASE-VALIDATION-v1.0.0.md) for the release-candidate evidence and remaining pre-tag gates.

## License

MIT. Before publishing a fork or derivative publicly, confirm that you have the right to publish all included code and adjust copyright/attribution if required.
