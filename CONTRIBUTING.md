# Contributing

Contributions are welcome, especially fixes that improve fail-closed behaviour, hardware compatibility, telemetry, and test coverage.

## Before opening a pull request

1. Describe the Windows versions and hardware/controller families used for validation.
2. Explain any safety-boundary impact, especially around partition deletion/shrink, BitLocker, authorization, or `MDM_RemoteWipe`.
3. Run `tools/Test-PowerShellSyntax.ps1` in Windows PowerShell 5.1.
4. Run the static Pester tests under `tests/`.
5. Run PSScriptAnalyzer and address errors.
6. Never test destructive paths on a device that is not disposable or fully recoverable.
7. Do not include secrets, recovery keys, tenant data, or raw customer logs.

## Compatibility

Public scripts should remain compatible with Windows PowerShell 5.1 unless a major release explicitly changes that requirement.

## Versioning

Do not add version numbers to script filenames. Public release versioning is handled through Git tags, `VERSION`, and `CHANGELOG.md`.
