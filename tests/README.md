# Tests

The included Pester tests are intentionally non-destructive and static. They check repository safety invariants such as authorization-ID consistency and the location of RemoteWipe method invocation.

They do **not** replace Windows lab testing. Storage, WinRE, BitLocker, and RemoteWipe behaviour must still be exercised on disposable Windows systems and representative physical hardware.
