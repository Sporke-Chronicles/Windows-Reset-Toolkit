## Summary

Describe the change and why it is needed.

## Safety impact

- [ ] No change to partition selection/deletion/shrink logic
- [ ] No change to BitLocker handling
- [ ] No change to authorization/Arm/Disarm behaviour
- [ ] No change to RemoteWipe invocation
- [ ] No change to storage-driver selection/injection

If any box above cannot be checked, describe the new safety model and lab evidence.

## Validation

- [ ] Windows PowerShell 5.1 syntax check passed
- [ ] PSScriptAnalyzer Error scan passed
- [ ] Pester static tests passed
- [ ] Relevant Windows lab tests passed
- [ ] Representative hardware testing completed where required
- [ ] Logs/examples are sanitized
