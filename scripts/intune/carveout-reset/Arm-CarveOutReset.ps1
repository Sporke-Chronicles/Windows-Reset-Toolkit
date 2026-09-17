<#
.SYNOPSIS
  Arms a Windows device for the carve-out full-reset Intune Remediation workflow.

.DESCRIPTION
  This optional safety script creates a short-lived local authorization marker. The corresponding
  Intune Detection and Remediation scripts refuse to reset a device unless this marker is present,
  carries the expected AuthorizationId, and has not expired.

  Why use an arm marker when Intune assignment groups already scope devices?
  Because a wipe is irreversible. Requiring both assignment AND a local authorization marker gives
  the workflow a second independent safety boundary and makes accidental broad assignment less likely
  to reset unintended devices.

  Deploy this script only to the carve-out devices that are ready to be reset. The default marker is
  valid for seven days. Change AuthorizationId consistently in all three Intune scripts for each
  migration wave if you want per-wave authorization.

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Run as SYSTEM. For Intune Platform Scripts, configure "Run this script using the logged on
  credentials" = No.
#>

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------
# Deployment configuration
# ---------------------------
$AuthorizationId = 'CARVEOUT-RESET-V1'
$AuthorizationValidityHours = 168
$StatePath = 'HKLM:\SOFTWARE\CarveOutMigration\ResetWorkflow'

try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not $identity.User -or $identity.User.Value -ne 'S-1-5-18') {
        throw 'This authorization script must run as Local System.'
    }

    New-Item -Path $StatePath -Force | Out-Null
    $expires = (Get-Date).ToUniversalTime().AddHours($AuthorizationValidityHours).ToString('o')

    New-ItemProperty -Path $StatePath -Name 'Armed' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'AuthorizationId' -PropertyType String -Value $AuthorizationId -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'AuthorizationExpiresUtc' -PropertyType String -Value $expires -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'Status' -PropertyType String -Value 'Armed' -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'LastError' -PropertyType String -Value '' -Force | Out-Null

    Write-Output "Carve-out reset armed. AuthorizationId=$AuthorizationId; ExpiresUtc=$expires"
    exit 0
}
catch {
    Write-Error $_.Exception.Message
    exit 1
}
