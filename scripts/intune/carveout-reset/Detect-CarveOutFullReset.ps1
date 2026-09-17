<#
.SYNOPSIS
  Detection script for the carve-out full-reset Intune Remediation package.

.DESCRIPTION
  Exit 1 means the device is explicitly armed and the remediation should run.
  Exit 0 means the device is not authorized for reset, so remediation is suppressed.

  Detection intentionally does not attempt to decide whether the device "still needs" a reset after
  it is armed. As long as the original Windows installation is alive and the authorization marker is
  valid, the remediation is allowed to retry. This makes a failed first attempt recoverable.

  Keep output short: Intune Remediations reports only a limited amount of script output.

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Run as Local System in 64-bit Windows PowerShell.
#>

$ErrorActionPreference = 'SilentlyContinue'

# ---------------------------
# Deployment configuration - must match the Arm and Remediation scripts.
# ---------------------------
$AuthorizationId = 'CARVEOUT-RESET-V1'
$RequireAuthorizationMarker = $true
$StatePath = 'HKLM:\SOFTWARE\CarveOutMigration\ResetWorkflow'

function Test-Authorization {
    if (-not $RequireAuthorizationMarker) { return $true }
    if (-not (Test-Path $StatePath)) { return $false }

    $state = Get-ItemProperty -Path $StatePath -ErrorAction SilentlyContinue
    if (-not $state) { return $false }

    $propertyNames = @($state.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'Armed' -or $propertyNames -notcontains 'AuthorizationId' -or $propertyNames -notcontains 'AuthorizationExpiresUtc') { return $false }
    if ([int]$state.Armed -ne 1) { return $false }
    if ($state.AuthorizationId -ne $AuthorizationId) { return $false }
    if ([string]::IsNullOrWhiteSpace([string]$state.AuthorizationExpiresUtc)) { return $false }

    try {
        $expires = [datetime]::Parse([string]$state.AuthorizationExpiresUtc).ToUniversalTime()
        if ((Get-Date).ToUniversalTime() -gt $expires) { return $false }
    }
    catch { return $false }

    return $true
}

if (-not (Test-Authorization)) {
    Write-Output 'Not authorized for carve-out reset.'
    exit 0
}

$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
if (-not $identity.User -or $identity.User.Value -ne 'S-1-5-18') {
    Write-Output 'Reset is authorized, but this package is not configured to run as SYSTEM.'
    exit 1
}

$status = (Get-ItemProperty -Path $StatePath -Name Status -ErrorAction SilentlyContinue).Status
if ([string]::IsNullOrWhiteSpace($status)) { $status = 'Authorized' }
Write-Output "Reset authorized. CurrentStatus=$status"
exit 1
