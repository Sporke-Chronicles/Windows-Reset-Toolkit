# v1.0.0 Release Validation Record

**Release candidate date:** 2026-09-17

This record summarizes the validation evidence and repository-quality checks used for the v1.0.0 public release candidate.

## Functional validation

### WinRE readiness

- PASS - unhealthy WinRE detection under Local System.
- PASS - 541 MB trailing Recovery replacement with a 2536 MB GPT Recovery partition.
- PASS - reuse of an already-healthy Recovery partition without repartitioning.
- PASS - temporary drive-letter collision handling without modifying the unrelated volume.
- PASS - BitLocker returned to FullyEncrypted/On after partition maintenance.
- PASS - WinRE WIM validation, mount, DISM component-store check, and inbox-storage path.
- PASS - `Ready=true` / `HealthCode=H000` after repair.

### Real Intune / IME validation

- PASS - Intune Detection identified WinRE Disabled / unresolved registration on the original VM state.
- PASS - Intune launched readiness remediation and completed Recovery/WinRE repair.
- PASS - post-remediation Intune Detection returned `H000` with WinRE Enabled, 2536 MB Recovery, valid WIM/mount/component store, MDM bridge OK, and BitLocker FullyEncrypted/On.
- PASS - destructive package run while Disarmed returned Detection exit 0 and remediation did not launch.
- PASS - Arm control delivered through Intune created `CARVEOUT-RESET-V1` authorization with a future expiry.
- PASS - authorized on-demand Intune Detection -> Remediation initiated RemoteWipe and Windows Reset completed successfully.

### ConfigMgr/local reset validation

- PASS - WinRE repair/idempotency and retry paths.
- PASS - storage inbox/NA path.
- PASS - RemoteWipe provider/method preflight.
- PASS - destructive normal reset path initiated successfully.

## Known validation boundary

Positive injection of third-party Intel RST/VMD, AMD RAID, and vendor NVMe/storage drivers was not possible in the Hyper-V reference environment and remains a representative-hardware pilot requirement.

Windows 11 and OEM-specific Recovery layouts should also be validated before broad rollout.

## Final repository pass

The release-pass build performed the following checks:

- PASS - production script bytes unchanged during the final documentation/release pass.
- PASS - `SCRIPT-SHA256SUMS.txt` matches all 10 production scripts.
- PASS - static safety invariants for wipe-call placement, readiness no-wipe behavior, authorization-ID consistency, and final authorization revalidation.
- PASS - no hard-coded `C:\Lab\WinRE` path in production scripts.
- PASS - local Markdown links resolve.
- PASS - GitHub Actions / issue-template YAML parses successfully.
- PASS - sanitization scan for known lab hostname, tenant/policy identifiers, conversation artifact IDs, internal names, engineering-version labels, and BitLocker recovery-password patterns.
- PASS - basic PowerShell lexical delimiter/string/comment balance for repository `.ps1` files.

The release-pass build environment is Linux and does not contain Windows PowerShell 5.1, PSScriptAnalyzer, or Pester. The repository therefore retains the GitHub Actions **PowerShell CI** workflow as the final platform-specific gate after first push.

## Remaining pre-tag gates

1. Confirm public-release ownership/IP and MIT licensing are approved.
2. Push the release candidate to GitHub.
3. Require the `PowerShell CI` workflow to pass Windows PowerShell 5.1 syntax validation, PSScriptAnalyzer Error-severity scan, and Pester static tests.
4. Create the `v1.0.0` tag only after those gates pass.
5. Publish the GitHub Release using `RELEASE-NOTES-v1.0.0.md`.
