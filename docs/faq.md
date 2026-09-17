# FAQ

## Does the readiness remediation wipe a device?

No. It repairs and validates WinRE readiness and can make Recovery-partition changes, but it does not invoke RemoteWipe.

## Why is there a separate Arm script for the destructive Intune workflow?

Assignment mistakes happen. Requiring both Intune targeting and a short-lived local authorization marker creates an additional independent safety boundary.

## Can I remove the Arm requirement?

The code contains a configuration switch, but the public operating model assumes it remains enabled. Disabling it changes the safety model and should be treated as a deliberate fork requiring its own testing and controls.

## Why not just use Intune Wipe?

You should where it works. The destructive local workflow exists for controlled carve-out/migration exceptions where a device can run SYSTEM PowerShell but the standard control-plane wipe cannot be relied on.

## Why 2536 MB for a newly created Recovery partition?

It provides generous headroom for WinRE, storage-driver injection, and future servicing. Detection can still consider a smaller existing partition healthy if it meets the configured floor and free-space reserve.

## Why Windows PowerShell 5.1?

Intune/ConfigMgr Windows client automation commonly executes in Windows PowerShell 5.1. The scripts have been hardened for its native stderr and runtime quirks and are tested around that execution model.

## Can I run the scripts as my administrator account?

Administrative context is enough for some WinRE operations, but the device-scoped MDM WMI Bridge RemoteWipe path requires Local System. Use the documented deployment context.

## Does MDMBridge=OK prove the device is enrolled in Intune?

No. It proves the local WMI Bridge class/instance/method surface is available in the tested context. Enrollment/check-in and service delivery are separate concerns.
