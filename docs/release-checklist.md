# Public Release Checklist

Use this before creating the public `v1.0.0` Git tag.

## Legal / ownership

- [ ] Confirm the code may be published publicly and is not restricted employer/customer/partner IP.
- [ ] Confirm MIT is the intended license and adjust copyright/attribution if required.
- [x] Remove internal lab hostnames, tenant/policy identifiers, recovery material, credentials, and raw validation logs from the release package.

## Validation

- [x] Windows PowerShell 5.1 lab validation of core WinRE repair paths.
- [x] BitLocker suspend/resume validation around Recovery partition repair.
- [x] Temporary drive-letter collision validation.
- [x] Local RemoteWipe method/provider preflight validation.
- [x] Arm/Detect/Disarm authorization validation.
- [x] Authorization persistence through full-reset preflight.
- [x] Local SYSTEM destructive RemoteWipe and successful Windows Reset completion.
- [x] Genuine Intune Management Extension readiness Detection -> Remediation validation.
- [x] Genuine Intune remediation of WinRE Disabled / 541 MB Recovery to `Ready=true` / `H000`.
- [x] Genuine Intune Disarmed destructive-package suppression (Detection exit 0; remediation not launched).
- [x] Genuine Intune delivery of the Arm control.
- [x] Genuine Intune authorized Detection -> Remediation -> RemoteWipe -> successful Windows Reset.
- [x] Retain third-party RST/VMD/RAID positive-injection testing as a documented hardware-specific limitation until representative hardware is available.

## Repository quality completed in this release pass

- [x] Functional production scripts frozen; documentation/release pass did not modify script bytes.
- [x] Regenerated/verified `SCRIPT-SHA256SUMS.txt` against the frozen scripts.
- [x] Static safety invariants checked for wipe-call placement, authorization-ID consistency, and absence of hard-coded lab paths in production scripts.
- [x] Markdown local-link validation completed.
- [x] GitHub workflow/issue YAML parsed successfully.
- [x] Sanitization scan completed for known lab hostnames, tenant/policy IDs, raw recovery material, development file references, and internal lab paths.
- [x] `CHANGELOG.md` set to the v1.0.0 release date.
- [x] v1.0.0 release notes created.

## Gates to run on the GitHub repository before tagging

- [ ] Push the release candidate and confirm the **PowerShell CI** GitHub Actions workflow is green.
- [ ] Confirm Windows PowerShell 5.1 syntax validation passes in CI.
- [ ] Confirm PSScriptAnalyzer reports no Error-severity findings in CI.
- [ ] Confirm Pester static safety tests pass in CI.
- [ ] Create a signed/annotated Git tag `v1.0.0` according to maintainer policy.
- [ ] Publish the GitHub Release using `RELEASE-NOTES-v1.0.0.md` after legal/ownership and CI gates are complete.
