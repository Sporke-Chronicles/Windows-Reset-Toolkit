<#
.SYNOPSIS
  Cancels local authorization for the carve-out full-reset Intune Remediation workflow.

.DESCRIPTION
  Sets the workflow's local authorization marker to a fail-closed state. Use this as an emergency
  brake for a device or migration wave before RemoteWipe has been accepted.

  Removing a device from an Intune assignment is still recommended, but that change can take time to
  reach the endpoint. This script provides a second local control: Detection will return compliant and
  the Remediation script will refuse to wipe while Armed is 0.

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Run as Local System. This cannot cancel a wipe that Windows has already accepted.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$StatePath = 'HKLM:\SOFTWARE\CarveOutMigration\ResetWorkflow'

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.User -or $identity.User.Value -ne 'S-1-5-18') {
        throw 'This disarm script must run as Local System.'
    }

    New-Item -Path $StatePath -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'Armed' -PropertyType DWord -Value 0 -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'AuthorizationExpiresUtc' -PropertyType String -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'Status' -PropertyType String -Value 'Disarmed' -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'LastError' -PropertyType String -Value '' -Force | Out-Null

    Write-Output 'Carve-out reset authorization has been disarmed locally. A wipe already accepted by Windows cannot be cancelled.'
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
