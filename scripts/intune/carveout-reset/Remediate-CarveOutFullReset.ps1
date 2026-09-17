<#
.SYNOPSIS
  Intune Remediation script for a resilient carve-out / tenant-migration full Windows reset.

.DESCRIPTION
  This script is intentionally self-contained because an Intune Remediations package provides one
  detection script and one remediation script; it does not guarantee ordering between separate
  remediation packages. A destructive reset workflow should therefore run its dependent operations
  in one controlled sequence:

    1. Validate explicit reset authorization and SYSTEM/64-bit execution context.
    2. Validate/repair WinRE. If necessary, rebuild a trailing Recovery partition without blindly
       shrinking C: again after a partial previous attempt.
    3. Inject active third-party storage-controller drivers into WinRE when they are not already
       present at the same or a newer version.
    4. Revalidate WinRE.
    5. Revalidate the MDM_RemoteWipe class, requested wipe method and provider instance immediately
       before changing BitLocker state.
    6. Suspend BitLocker protectors and invoke the local MDM_RemoteWipe.doWipeMethod through the
       Windows MDM WMI Bridge Provider.

  Rerun behaviour is a primary design goal. Persistent state is telemetry only; every run reassesses
  the actual disk/WinRE state and repairs forward. Examples handled by this script include:
  - C: was already shrunk by a previous attempt.
  - The old Recovery partition was already deleted.
  - A new Recovery partition was created but Winre.wim was not copied/registered.
  - WinRE is registered but disabled.
  - Storage drivers were already injected by a previous run.

  SAFETY MODEL
  -----------
  By default the device must carry a short-lived local authorization marker created by the companion
  Arm-CarveOutReset.ps1 script. This is a second safety boundary in addition to Intune assignment.
  Disable RequireAuthorizationMarker only if your operational controls provide an equivalent guard.

  Microsoft normally recommends using the native Intune Wipe action. This script is intended for the
  carve-out exception where the control-plane wipe cannot be relied on but the device can still run
  SYSTEM PowerShell. The final wipe is irreversible.

  Compatibility and safety hardening includes:
  - Windows PowerShell 5.1-safe native stderr capture for reagentc/manage-bde/diskpart paths.
  - RemoteWipe method metadata validation using CimClassMethods enumeration compatible with StrictMode.
  - PendingFileRenameOperations in the pending-reboot gate used before required repartitioning.
  - A -PreflightOnly lab/safety mode that runs the authorized preparation/validation workflow but
    stops before BitLocker wipe suspension and before any RemoteWipe method invocation.
  - Workflow telemetry updates preserve the existing Arm authorization values.
  - Reset authorization is revalidated after the final RemoteWipe provider preflight and before
    wipe-specific BitLocker suspension, so a Disarm/expiry during preparation fails closed.

.PARAMETER PreflightOnly
  Runs authorization, WinRE repair/readiness, storage-driver validation and final RemoteWipe provider
  preflight, then exits successfully without suspending BitLocker for wipe or invoking RemoteWipe.
  This is a NO-WIPE mode, not a read-only mode: normal WinRE preparation can still repair/repartition
  the Recovery environment when the current device state requires it.

.INTUNE SETTINGS
  Run this script using the logged-on credentials: No
  Run script in 64-bit PowerShell:             Yes (the script also self-corrects when possible)
  Enforce script signature check:              Follow your organisational signing policy

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Microsoft references:
  - MDM RemoteWipe class:
    https://learn.microsoft.com/windows/win32/dmwmibridgeprov/mdm-remotewipe
  - WMI Bridge scripting:
    https://learn.microsoft.com/windows/client-management/using-powershell-scripting-with-the-wmi-bridge-provider
  - WinRE servicing / partition guidance:
    https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-update-to-winre
  - Intune Remediations:
    https://learn.microsoft.com/intune/device-management/tools/deploy-remediations
#>

[CmdletBinding()]
param(
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ============================================================================
# Deployment configuration
# ============================================================================
$AuthorizationId = 'CARVEOUT-RESET-V1'
$RequireAuthorizationMarker = $true
$StatePath = 'HKLM:\SOFTWARE\CarveOutMigration\ResetWorkflow'

$TargetRecoverySizeMB = 2536
$MinimumRecoveryPartitionSizeMB = 2000
$MinimumRecoveryFreeSpaceMB = 250
$PreferredRecoveryLetter = 'R'

# Normal doWipeMethod is the safe default. Setting this to $true uses Microsoft's protected wipe,
# which performs a more intensive clean but can leave some device configurations unable to boot.
$UseProtectedWipe = $false

$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$EfiGptType      = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$MsrGptType      = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

$WorkingRoot = Join-Path $env:ProgramData 'CarveOutReset'
$WinREWorkingDirectory = Join-Path $WorkingRoot 'WinRE'
$StagedWinRE = Join-Path $WinREWorkingDirectory 'Winre.wim'
$DriverExportRoot = Join-Path $WorkingRoot 'WinREStorageDrivers'
$MountDirectory = Join-Path $WorkingRoot 'WinREMount'
$LogDirectory = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\CarveOutReset'
$LogFile = Join-Path $LogDirectory ("CarveOut-FullReset-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$script:BitLockerChangedForPartitionWork = $false
$script:WinREMounted = $false
$script:WipeAccepted = $false
$script:WipeBitLockerMountPoints = @()
$script:WorkflowMutex = $null

# ============================================================================
# 64-bit process correction
# ============================================================================
function Restart-In64BitPowerShellIfRequired {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $nativePowerShell = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $nativePowerShell)) {
            throw "64-bit Windows PowerShell was not found at $nativePowerShell"
        }

        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
        if ($PreflightOnly) { $arguments += '-PreflightOnly' }

        $process = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
}

Restart-In64BitPowerShellIfRequired

New-Item -Path $WorkingRoot -ItemType Directory -Force | Out-Null
New-Item -Path $WinREWorkingDirectory -ItemType Directory -Force | Out-Null
New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

# ============================================================================
# Common logging/state helpers
# ============================================================================
function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Ensure-StateKey {
    # Do not use New-Item -Force against an existing registry key here. In the Windows Registry
    # provider that can replace the item and remove existing values, including the Arm marker.
    if (-not (Test-Path -LiteralPath $StatePath)) {
        New-Item -Path $StatePath -Force | Out-Null
    }
}

function Set-WorkflowState {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$LastError = ''
    )

    Ensure-StateKey
    New-ItemProperty -Path $StatePath -Name 'Status' -PropertyType String -Value $Status -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'LastRunUtc' -PropertyType String -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'LastError' -PropertyType String -Value $LastError -Force | Out-Null
}

function Increment-AttemptCount {
    Ensure-StateKey
    $existing = 0
    try { $existing = [int](Get-ItemProperty -Path $StatePath -Name AttemptCount -ErrorAction Stop).AttemptCount } catch {}
    New-ItemProperty -Path $StatePath -Name 'AttemptCount' -PropertyType DWord -Value ($existing + 1) -Force | Out-Null
}

function Test-ResetAuthorization {
    if (-not $RequireAuthorizationMarker) { return $true }
    if (-not (Test-Path $StatePath)) { return $false }

    $state = Get-ItemProperty -Path $StatePath -ErrorAction SilentlyContinue
    if (-not $state) { return $false }

    # Set-StrictMode makes direct access to a missing registry property an error. Check property
    # presence first so a partially-created/stale marker is treated as unauthorized, not as a crash.
    $propertyNames = @($state.PSObject.Properties.Name)
    if ($propertyNames -notcontains 'Armed' -or $propertyNames -notcontains 'AuthorizationId' -or $propertyNames -notcontains 'AuthorizationExpiresUtc') {
        return $false
    }
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

function Test-IsLocalSystem {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ($identity.User -and $identity.User.Value -eq 'S-1-5-18')
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    $oldPreference = $ErrorActionPreference
    $output = @()
    $code = $null

    try {
        # Windows PowerShell 5.1 can surface native stderr as NativeCommandError when the caller uses
        # ErrorActionPreference=Stop. Capture under Continue and let the caller apply exit-code policy.
        $ErrorActionPreference = 'Continue'
        $output = @(& $FilePath @Arguments 2>&1)
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $lines = @($output | ForEach-Object { $_.ToString() })
    return [pscustomobject]@{
        ExitCode = [int]$code
        Lines    = $lines
        Text     = ($lines -join [Environment]::NewLine)
    }
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @(),
        [int[]]$SuccessCodes = @(0),
        [switch]$ReturnOutput
    )

    Write-Log "Running: $FilePath $($Arguments -join ' ')"
    $native = Invoke-NativeCapture -FilePath $FilePath -Arguments $Arguments
    if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
    Write-Log "Exit code: $($native.ExitCode)"

    if ($SuccessCodes -notcontains $native.ExitCode) {
        throw "$FilePath failed with exit code $($native.ExitCode)."
    }

    if ($ReturnOutput) { return $native.Text }
}

function Invoke-DiskPart {
    param([Parameter(Mandatory)][string[]]$Lines)

    $scriptPath = Join-Path $env:TEMP ("carveout-diskpart-{0}.txt" -f ([guid]::NewGuid().Guid))
    try {
        $Lines | Out-File -FilePath $scriptPath -Encoding ascii -Force
        Write-Log "DiskPart script:`r`n$($Lines -join "`r`n")"
        $native = Invoke-NativeCapture -FilePath 'diskpart.exe' -Arguments @('/s',$scriptPath)
        $text = $native.Text
        if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Log $text }
        Write-Log "DiskPart exit code: $($native.ExitCode)"

        if ($native.ExitCode -ne 0 -or $text -match 'Virtual Disk Service error|DiskPart has encountered an error|The arguments specified for this command are not valid') {
            throw "DiskPart reported a failure (exit code $($native.ExitCode))."
        }
    }
    finally {
        Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue
    }
}

function Update-StorageView {
    param([Parameter(Mandatory)][int]$DiskNumber)

    try { Update-HostStorageCache -ErrorAction SilentlyContinue } catch {}
    try { Invoke-DiskPart -Lines @('rescan',"select disk $DiskNumber") } catch { Write-Log "DiskPart rescan warning: $($_.Exception.Message)" 'WARN' }
    Start-Sleep -Seconds 2
}

function Test-PendingReboot {
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { return $true }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { return $true }
    try {
        $sm = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        if ($sm.PendingFileRenameOperations) { return $true }
    }
    catch {}
    return $false
}

# ============================================================================
# WinRE discovery and temporary-access helpers
# ============================================================================
function Get-WinREState {
    $native = Invoke-NativeCapture -FilePath 'reagentc.exe' -Arguments @('/info')
    $text = $native.Text
    Write-Log "reagentc /info exit code: $($native.ExitCode)"
    if (-not [string]::IsNullOrWhiteSpace($text)) { Write-Log $text }
    if ($native.ExitCode -ne 0) { throw "reagentc /info failed with exit code $($native.ExitCode)." }

    $diskNumber = $null
    $partitionNumber = $null
    if ($text -match '(?i)harddisk(\d+)\\partition(\d+)\\Recovery\\WindowsRE') {
        $diskNumber = [int]$matches[1]
        $partitionNumber = [int]$matches[2]
    }

    return [pscustomobject]@{
        Enabled = ($text -match 'Windows RE status:\s+Enabled')
        DiskNumber = $diskNumber
        PartitionNumber = $partitionNumber
        Text = $text
    }
}

function Test-IsRecoveryPartition {
    param([Parameter(Mandatory)]$Partition)
    if ($Partition.GptType -and $Partition.GptType.ToString().ToLowerInvariant() -eq $RecoveryGptType) { return $true }
    if ($Partition.Type -and $Partition.Type.ToString() -eq 'Recovery') { return $true }
    return $false
}

function Get-RecoveryPartitions {
    param([Parameter(Mandatory)][int]$DiskNumber)
    return @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Where-Object { Test-IsRecoveryPartition -Partition $_ } | Sort-Object Offset)
}

function Get-TemporaryDriveLetterCandidates {
    param([string]$PreferredLetter = $PreferredRecoveryLetter)

    $candidates = @($PreferredLetter,'R','S','T','U','V','W','X','Y','Z') |
        ForEach-Object { if ($_ -and $_ -match '^[A-Za-z]$') { $_.ToUpperInvariant() } } |
        Select-Object -Unique

    return @($candidates | Select-Object -Unique)
}

function Test-DriveLetterApparentlyFree {
    param([Parameter(Mandatory)][string]$Letter)

    if (Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue) { return $false }
    if (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue) { return $false }
    if (Get-PSDrive -Name $Letter -PSProvider FileSystem -ErrorAction SilentlyContinue) { return $false }
    try { if (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Letter`:'" -ErrorAction Stop) { return $false } } catch {}
    try {
        $mountedNames = @((Get-ItemProperty 'HKLM:\SYSTEM\MountedDevices' -ErrorAction Stop).PSObject.Properties.Name)
        if ($mountedNames -contains "\DosDevices\$Letter`:") { return $false }
    } catch {}
    return $true
}

function Get-SafeTemporaryDriveLetter {
    param([string]$PreferredLetter = $PreferredRecoveryLetter)
    foreach ($candidate in @(Get-TemporaryDriveLetterCandidates -PreferredLetter $PreferredLetter)) {
        if (Test-DriveLetterApparentlyFree -Letter $candidate) { return $candidate }
    }
    throw 'No apparently free temporary drive letter is available from R: through Z:.'
}

function Add-TemporaryRecoveryAccessPath {
    param(
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][string]$Letter
    )

    if ($Partition.DriveLetter) {
        return [pscustomobject]@{ Letter = $Partition.DriveLetter.ToString(); Added = $false }
    }

    $attemptErrors = New-Object 'System.Collections.Generic.List[string]'
    foreach ($candidate in @(Get-TemporaryDriveLetterCandidates -PreferredLetter $Letter)) {
        if (-not (Test-DriveLetterApparentlyFree -Letter $candidate)) {
            Write-Log "Temporary drive letter $candidate`: appears to be in use; trying the next candidate." 'WARN'
            continue
        }

        $assignedByUs = $false
        try {
            Write-Log "Assigning temporary drive letter $candidate`: to Disk $($Partition.DiskNumber) Partition $($Partition.PartitionNumber)."
            try {
                Add-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$candidate`:\" -ErrorAction Stop
                $assignedByUs = $true
            }
            catch {
                Write-Log "Add-PartitionAccessPath failed for $candidate`:; using DiskPart fallback. Error: $($_.Exception.Message)" 'WARN'
                try {
                    Invoke-DiskPart -Lines @(
                        "select disk $($Partition.DiskNumber)",
                        "select partition $($Partition.PartitionNumber)",
                        "assign letter=$candidate"
                    )
                    $assignedByUs = $true
                }
                catch {
                    [void]$attemptErrors.Add("$candidate`: $($_.Exception.Message)")
                    Write-Log "Temporary drive letter $candidate`: could not be assigned; trying the next candidate. Error: $($_.Exception.Message)" 'WARN'
                    continue
                }
            }

            Start-Sleep -Seconds 1
            if (Test-Path "$candidate`:\") {
                if ($candidate -ne $Letter) { Write-Log "Preferred temporary letter $Letter`: was unavailable; using $candidate`: instead." 'WARN' }
                return [pscustomobject]@{ Letter = $candidate; Added = $true }
            }

            [void]$attemptErrors.Add("$candidate`: assignment completed but the path was not accessible")
            Write-Log "Temporary drive letter $candidate`: was assigned but did not become accessible; trying the next candidate." 'WARN'
        }
        finally {
            if ($assignedByUs -and -not (Test-Path "$candidate`:\")) {
                try { Remove-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$candidate`:\" -ErrorAction Stop }
                catch {
                    try {
                        Invoke-DiskPart -Lines @(
                            "select disk $($Partition.DiskNumber)",
                            "select partition $($Partition.PartitionNumber)",
                            "remove letter=$candidate noerr"
                        )
                    } catch {}
                }
            }
        }
    }

    $detail = if ($attemptErrors.Count -gt 0) { ' Attempts: ' + ($attemptErrors.ToArray() -join '; ') } else { '' }
    throw "No temporary Recovery drive letter from R: through Z: could be assigned safely.$detail"
}

function Remove-TemporaryRecoveryAccessPath {
    param(
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][string]$Letter,
        [Parameter(Mandatory)][bool]$Added
    )

    if (-not $Added) { return }
    try {
        Remove-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$Letter`:\" -ErrorAction Stop
    }
    catch {
        Write-Log "Remove-PartitionAccessPath failed; using DiskPart fallback. Error: $($_.Exception.Message)" 'WARN'
        try {
            Invoke-DiskPart -Lines @(
                "select disk $($Partition.DiskNumber)",
                "select partition $($Partition.PartitionNumber)",
                "remove letter=$Letter noerr"
            )
        }
        catch { Write-Log "Unable to remove temporary letter $Letter`: $($_.Exception.Message)" 'WARN' }
    }
}

function Test-WimFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        [void](Invoke-Native -FilePath 'dism.exe' -Arguments @('/English','/Get-WimInfo',"/WimFile:$Path") -SuccessCodes @(0) -ReturnOutput)
        return $true
    }
    catch {
        Write-Log "WIM validation failed for '$Path': $($_.Exception.Message)" 'WARN'
        return $false
    }
}

function Copy-WinREFromPartitionToStage {
    param(
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][string]$Letter
    )

    $access = $null
    try {
        $access = Add-TemporaryRecoveryAccessPath -Partition $Partition -Letter $Letter
        $path = "$($access.Letter):\Recovery\WindowsRE\Winre.wim"
        if (Test-WimFile -Path $path) {
            Copy-Item -LiteralPath $path -Destination $StagedWinRE -Force
            Write-Log "Staged Winre.wim from Disk $($Partition.DiskNumber) Partition $($Partition.PartitionNumber)."
            return $true
        }
    }
    finally {
        if ($access) { Remove-TemporaryRecoveryAccessPath -Partition $Partition -Letter $access.Letter -Added $access.Added }
    }
    return $false
}

function Stage-WinREImage {
    param(
        [Parameter(Mandatory)]$WinREState,
        [Parameter(Mandatory)][int]$OsDiskNumber,
        [Parameter(Mandatory)][string]$Letter
    )

    if ($null -ne $WinREState.DiskNumber -and $null -ne $WinREState.PartitionNumber -and $WinREState.DiskNumber -eq $OsDiskNumber) {
        try {
            $registered = Get-Partition -DiskNumber $WinREState.DiskNumber -PartitionNumber $WinREState.PartitionNumber -ErrorAction Stop
            if ((Test-IsRecoveryPartition -Partition $registered) -and (Copy-WinREFromPartitionToStage -Partition $registered -Letter $Letter)) {
                return $StagedWinRE
            }
        }
        catch { Write-Log "Registered WinRE image could not be staged: $($_.Exception.Message)" 'WARN' }
    }

    foreach ($localPath in @("$env:WINDIR\System32\Recovery\Winre.wim","$env:SystemDrive\Recovery\WindowsRE\Winre.wim")) {
        if (Test-WimFile -Path $localPath) {
            Copy-Item -LiteralPath $localPath -Destination $StagedWinRE -Force
            Write-Log "Staged Winre.wim from $localPath."
            return $StagedWinRE
        }
    }

    foreach ($partition in @(Get-RecoveryPartitions -DiskNumber $OsDiskNumber | Sort-Object Offset -Descending)) {
        try {
            if (Copy-WinREFromPartitionToStage -Partition $partition -Letter $Letter) { return $StagedWinRE }
        }
        catch { Write-Log "Recovery partition $($partition.PartitionNumber) could not be inspected: $($_.Exception.Message)" 'WARN' }
    }

    if (Test-WimFile -Path $StagedWinRE) {
        Write-Log 'Using Winre.wim retained from a previous partial workflow attempt.' 'WARN'
        return $StagedWinRE
    }

    return $null
}

function Get-RecoveryPartitionHealth {
    param(
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][string]$Letter
    )

    $access = $null
    try {
        $access = Add-TemporaryRecoveryAccessPath -Partition $Partition -Letter $Letter
        $volume = Get-Volume -DriveLetter $access.Letter -ErrorAction Stop
        $winrePath = "$($access.Letter):\Recovery\WindowsRE\Winre.wim"
        $wimValid = Test-WimFile -Path $winrePath
        $sizeMB = [math]::Floor($Partition.Size / 1MB)
        $freeMB = [math]::Floor($volume.SizeRemaining / 1MB)

        return [pscustomobject]@{
            SizeMB = $sizeMB
            FreeMB = $freeMB
            WimValid = $wimValid
            Healthy = ($sizeMB -ge $MinimumRecoveryPartitionSizeMB -and $freeMB -ge $MinimumRecoveryFreeSpaceMB -and $wimValid)
        }
    }
    finally {
        if ($access) { Remove-TemporaryRecoveryAccessPath -Partition $Partition -Letter $access.Letter -Added $access.Added }
    }
}

function Register-AndEnableRecoveryPartition {
    param(
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][string]$Letter,
        [Parameter(Mandatory)][string]$SourceWinRE
    )

    $access = $null
    try {
        $access = Add-TemporaryRecoveryAccessPath -Partition $Partition -Letter $Letter
        $directory = "$($access.Letter):\Recovery\WindowsRE"
        $path = Join-Path $directory 'Winre.wim'
        New-Item -Path $directory -ItemType Directory -Force | Out-Null

        if (-not (Test-WimFile -Path $path)) {
            if (-not (Test-WimFile -Path $SourceWinRE)) { throw 'No valid staged Winre.wim is available.' }
            $volume = Get-Volume -DriveLetter $access.Letter -ErrorAction Stop
            $requiredBytes = (Get-Item -LiteralPath $SourceWinRE -Force -ErrorAction Stop).Length + ($MinimumRecoveryFreeSpaceMB * 1MB)
            if ($volume.SizeRemaining -lt $requiredBytes) {
                throw 'Existing Recovery partition is too small for Winre.wim plus the required free-space reserve.'
            }
            Copy-Item -LiteralPath $SourceWinRE -Destination $path -Force
            Write-Log "Copied staged Winre.wim to $directory."
        }

        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/setreimage','/path',$directory) -SuccessCodes @(0)
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/enable') -SuccessCodes @(0)

        $state = Get-WinREState
        if (-not $state.Enabled) { throw 'WinRE did not report Enabled after registration.' }
        if ($state.DiskNumber -ne $Partition.DiskNumber -or $state.PartitionNumber -ne $Partition.PartitionNumber) {
            throw "WinRE registered to unexpected Disk/Partition $($state.DiskNumber)/$($state.PartitionNumber)."
        }

        $volume = Get-Volume -DriveLetter $access.Letter -ErrorAction Stop
        $freeMB = [math]::Floor($volume.SizeRemaining / 1MB)
        $sizeMB = [math]::Floor($Partition.Size / 1MB)
        if ($sizeMB -lt $MinimumRecoveryPartitionSizeMB -or $freeMB -lt $MinimumRecoveryFreeSpaceMB -or -not (Test-WimFile -Path $path)) {
            throw 'Recovery partition does not meet the configured health thresholds after registration.'
        }

        return $true
    }
    finally {
        if ($access) { Remove-TemporaryRecoveryAccessPath -Partition $Partition -Letter $access.Letter -Added $access.Added }
    }
}

# ============================================================================
# BitLocker helpers for partition work
# ============================================================================
function Suspend-OSBitLockerForPartitionWork {
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        $status = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-status',$env:SystemDrive)
        if (-not [string]::IsNullOrWhiteSpace($status.Text)) { Write-Log $status.Text }
        if ($status.ExitCode -ne 0) { throw "manage-bde status failed with exit code $($status.ExitCode)." }

        if ($status.Text -match 'Protection Status:\s+Protection On') {
            $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-disable',$env:SystemDrive,'-RebootCount','0')
            if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
            if ($native.ExitCode -ne 0) { throw "manage-bde failed with exit code $($native.ExitCode)." }
            return $true
        }
        return $false
    }

    $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($volume.ProtectionStatus.ToString() -notin @('On','1')) { return $false }

    try {
        Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 0 -ErrorAction Stop | Out-Null
    }
    catch {
        $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-disable',$env:SystemDrive,'-RebootCount','0')
        if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
        if ($native.ExitCode -ne 0) { throw "manage-bde failed with exit code $($native.ExitCode)." }
    }

    $check = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($check.ProtectionStatus.ToString() -in @('On','1')) { throw 'BitLocker protection is still enabled on C:.' }
    return $true
}

function Resume-OSBitLockerAfterPartitionWork {
    if (-not $script:BitLockerChangedForPartitionWork) { return }
    try {
        if (Get-Command Resume-BitLocker -ErrorAction SilentlyContinue) {
            Resume-BitLocker -MountPoint $env:SystemDrive -ErrorAction Stop | Out-Null
        }
        else {
            $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-enable',$env:SystemDrive)
            if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
            if ($native.ExitCode -ne 0) { throw "manage-bde could not resume BitLocker on $env:SystemDrive. Exit code $($native.ExitCode)." }
        }
        Write-Log 'Resumed BitLocker protection after WinRE partition maintenance.'
    }
    catch { Write-Log "Failed to resume BitLocker after partition work: $($_.Exception.Message)" 'WARN' }
    finally { $script:BitLockerChangedForPartitionWork = $false }
}

# ============================================================================
# Partition repair helpers
# ============================================================================
function Get-GapAfterOSBytes {
    param([Parameter(Mandatory)]$Disk,[Parameter(Mandatory)]$OsPartition)

    $osEnd = [int64]($OsPartition.Offset + $OsPartition.Size)
    $next = @(Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop | Where-Object { $_.Offset -ge $osEnd } | Sort-Object Offset | Select-Object -First 1)

    # Keep all disk-extent arithmetic as Int64. Windows PowerShell 5.1 can otherwise
    # bind [Math]::Max(0,<large byte count>) to the Int32 overload and fail for gaps >2 GB.
    $boundary = if ($next.Count -gt 0) { [int64]$next[0].Offset } else { [int64]$Disk.Size }
    $gap = [int64]($boundary - $osEnd)
    if ($gap -lt 0) { return [int64]0 }
    return $gap
}

function Get-PartitionImmediatelyAfterOS {
    param([Parameter(Mandatory)]$Disk,[Parameter(Mandatory)]$OsPartition)
    $osEnd = [int64]($OsPartition.Offset + $OsPartition.Size)
    return Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop | Where-Object { $_.Offset -ge $osEnd } | Sort-Object Offset | Select-Object -First 1
}

function Remove-RecoveryPartition {
    param([Parameter(Mandatory)]$Partition)
    Invoke-DiskPart -Lines @(
        "select disk $($Partition.DiskNumber)",
        "select partition $($Partition.PartitionNumber)",
        'delete partition override'
    )
}

function Get-RecoveryStartAlignment {
    param([Parameter(Mandatory)]$OsPartition)

    # DiskPart's offset= value is expressed in KB. Align new Recovery partitions to a 1 MB
    # boundary at or after the actual end of C:. Resize-Partition can leave C: ending on a
    # valid logical-sector boundary that is not an exact KB/MB boundary, so requiring exact
    # divisibility is unnecessarily restrictive.
    $osEnd = [int64]($OsPartition.Offset + $OsPartition.Size)
    $alignmentBytes = [int64](1MB)
    $remainder = [int64]($osEnd % $alignmentBytes)
    $paddingBytes = if ($remainder -eq 0) { [int64]0 } else { [int64]($alignmentBytes - $remainder) }
    $startBytes = [int64]($osEnd + $paddingBytes)
    $offsetKB = [int64]($startBytes / 1KB)

    return [pscustomobject]@{
        OsEndBytes   = $osEnd
        StartBytes   = $startBytes
        PaddingBytes = $paddingBytes
        OffsetKB     = $offsetKB
    }
}

function Resize-OSForRecoveryGap {
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)]$OsPartition,
        [Parameter(Mandatory)][int64]$RequiredGapBytes
    )

    $currentGap = Get-GapAfterOSBytes -Disk $Disk -OsPartition $OsPartition
    $alignment = Get-RecoveryStartAlignment -OsPartition $OsPartition
    $effectiveRequiredGapBytes = [int64]($RequiredGapBytes + $alignment.PaddingBytes)
    Write-Log "Contiguous gap after C: is $([math]::Floor($currentGap/1MB)) MB; Recovery size required is $([math]::Ceiling($RequiredGapBytes/1MB)) MB; alignment padding is $($alignment.PaddingBytes) bytes; total required is $([math]::Ceiling($effectiveRequiredGapBytes/1MB)) MB."
    if ($currentGap -ge $effectiveRequiredGapBytes) {
        Write-Log 'Existing gap is sufficient after alignment; C: will not be shrunk again.'
        return
    }

    $additionalMB = [math]::Ceiling(($effectiveRequiredGapBytes - $currentGap + 16MB) / 1MB)
    $shrinkBytes = [int64]($additionalMB * 1MB)
    $osDrive = $env:SystemDrive.TrimEnd(':')
    $supported = Get-PartitionSupportedSize -DriveLetter $osDrive -ErrorAction Stop
    $newSize = [int64]($OsPartition.Size - $shrinkBytes)

    Write-Log "Shrinking C: by $additionalMB MB from current state; target size $([math]::Round($newSize/1GB,2)) GB."
    if ($newSize -lt $supported.SizeMin) { throw 'C: cannot be safely shrunk enough to create the Recovery partition.' }

    Resize-Partition -DriveLetter $osDrive -Size $newSize -ErrorAction Stop
    Update-StorageView -DiskNumber $Disk.Number

    $osNow = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $diskNow = Get-Disk -Number $Disk.Number -ErrorAction Stop
    $gapNow = Get-GapAfterOSBytes -Disk $diskNow -OsPartition $osNow
    $postAlignment = Get-RecoveryStartAlignment -OsPartition $osNow
    $postRequiredGapBytes = [int64]($RequiredGapBytes + $postAlignment.PaddingBytes)
    if ($gapNow -lt $postRequiredGapBytes) {
        throw 'Required aligned contiguous free space was not available after resizing C:.'
    }
}

function New-RecoveryPartitionAfterOS {
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)]$OsPartition,
        [Parameter(Mandatory)][int]$SizeMB,
        [Parameter(Mandatory)][string]$Letter
    )

    $alignment = Get-RecoveryStartAlignment -OsPartition $OsPartition
    $requiredWithPadding = [int64](($SizeMB * 1MB) + $alignment.PaddingBytes)
    $availableGap = Get-GapAfterOSBytes -Disk $Disk -OsPartition $OsPartition
    if ($availableGap -lt $requiredWithPadding) {
        throw "The free extent after C: is too small for a $SizeMB MB Recovery partition after alignment."
    }
    Write-Log "Creating Recovery partition after C:. Size=$SizeMB MB, OffsetKB=$($alignment.OffsetKB), AlignmentPaddingBytes=$($alignment.PaddingBytes), TemporaryLetter=$Letter`:"

    Invoke-DiskPart -Lines @(
        "select disk $($Disk.Number)",
        "create partition primary size=$SizeMB offset=$($alignment.OffsetKB)",
        'format quick fs=ntfs label="Windows RE tools"',
        'set id=de94bba4-06d1-4d40-a16a-bfd50179d6ac',
        'gpt attributes=0x8000000000000001'
    )

    Update-StorageView -DiskNumber $Disk.Number
    $osNow = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
    $osNowEnd = $osNow.Offset + $osNow.Size
    $newPartition = Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop |
        Where-Object { (Test-IsRecoveryPartition -Partition $_) -and [int64]$_.Offset -eq [int64]$alignment.StartBytes } |
        Select-Object -First 1

    if (-not $newPartition) { throw 'New Recovery partition could not be identified after creation.' }
    $leadingGap = [int64]($newPartition.Offset - $osNowEnd)
    if ($leadingGap -lt 0 -or $leadingGap -gt 1MB) { throw "New Recovery partition is not immediately after C:. Leading gap=$leadingGap bytes." }
    Write-Log "New Recovery partition begins $leadingGap bytes after C:."

    # Recovery GPT attributes can cause Windows to suppress a temporary drive letter during
    # a storage refresh. Assign and verify the access path explicitly instead of trusting the
    # DriveLetter property returned immediately after DiskPart.
    $access = Add-TemporaryRecoveryAccessPath -Partition $newPartition -Letter $Letter
    if (-not $access -or -not (Test-Path "$($access.Letter):\")) { throw 'New Recovery partition could not be mounted temporarily.' }
    Write-Log "Temporary Recovery access path $($access.Letter): is accessible after partition creation."
    $freshPartition = Get-Partition -DiskNumber $newPartition.DiskNumber -PartitionNumber $newPartition.PartitionNumber -ErrorAction Stop
    $freshPartition | Add-Member -NotePropertyName TemporaryLetter -NotePropertyValue $access.Letter -Force
    return $freshPartition
}

function Test-SccmFrontRecoveryLayout {
    param([int]$DiskNumber,$CandidateFrontRecovery,$OsPartition)

    if (-not $CandidateFrontRecovery -or $CandidateFrontRecovery.PartitionNumber -ne 1 -or $CandidateFrontRecovery.Offset -ge $OsPartition.Offset) { return $false }
    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Sort-Object PartitionNumber)
    $efi = $parts | Where-Object { $_.GptType -and $_.GptType.ToString().ToLowerInvariant() -eq $EfiGptType } | Select-Object -First 1
    $msr = $parts | Where-Object { $_.GptType -and $_.GptType.ToString().ToLowerInvariant() -eq $MsrGptType } | Select-Object -First 1
    return ($efi -and $msr -and $CandidateFrontRecovery.Offset -lt $efi.Offset -and $efi.Offset -lt $msr.Offset -and $msr.Offset -lt $OsPartition.Offset)
}

function Remove-OldFrontRecoveryBestEffort {
    param([int]$DiskNumber,$OldFrontRecovery,$OsPartition,[int]$NewRecoveryPartitionNumber)

    if (-not $OldFrontRecovery -or $OldFrontRecovery.PartitionNumber -eq $NewRecoveryPartitionNumber) { return }
    if (-not (Test-SccmFrontRecoveryLayout -DiskNumber $DiskNumber -CandidateFrontRecovery $OldFrontRecovery -OsPartition $OsPartition)) {
        Write-Log 'An older Recovery partition remains, but it does not match the known SCCM front-Recovery layout and will not be deleted.' 'WARN'
        return
    }

    try {
        Write-Log "Removing obsolete SCCM front Recovery partition $($OldFrontRecovery.PartitionNumber) after new WinRE validation."
        Remove-RecoveryPartition -Partition $OldFrontRecovery
    }
    catch { Write-Log "Old front Recovery cleanup failed; new WinRE remains valid. Error: $($_.Exception.Message)" 'WARN' }
}

function Ensure-WinREHealthy {
    Write-Log '--- Phase: WinRE health/partition repair ---'
    Set-WorkflowState -Status 'WinREValidation'

    $osDrive = $env:SystemDrive.TrimEnd(':')
    $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $disk = Get-Disk -Number $osPartition.DiskNumber -ErrorAction Stop
    if ($disk.PartitionStyle -ne 'GPT') { throw 'This workflow supports GPT OS disks only.' }

    $state = Get-WinREState
    $recoveryPartitions = @(Get-RecoveryPartitions -DiskNumber $disk.Number)
    $letter = Get-SafeTemporaryDriveLetter

    $registeredPartition = $null
    if ($null -ne $state.DiskNumber -and $null -ne $state.PartitionNumber -and $state.DiskNumber -eq $disk.Number) {
        try {
            $candidate = Get-Partition -DiskNumber $state.DiskNumber -PartitionNumber $state.PartitionNumber -ErrorAction Stop
            if (Test-IsRecoveryPartition -Partition $candidate) { $registeredPartition = $candidate }
        }
        catch {}
    }

    if ($registeredPartition -and $state.Enabled) {
        try {
            $health = Get-RecoveryPartitionHealth -Partition $registeredPartition -Letter $letter
            Write-Log "Registered WinRE health: Size=$($health.SizeMB) MB, Free=$($health.FreeMB) MB, WimValid=$($health.WimValid)."
            if ($health.Healthy) {
                # Remove any stale persistent stage left by a prior interrupted repair. The
                # registered Recovery partition has already been health-validated at this point.
                Remove-Item -LiteralPath $StagedWinRE -Force -ErrorAction SilentlyContinue
                Write-Log 'WinRE is already healthy; no partition change is required.'
                return
            }
        }
        catch {
            Write-Log "Registered WinRE health validation could not be completed: $($_.Exception.Message)" 'ERROR'
            throw 'WinRE is enabled and registered, but Recovery health validation was blocked. Destructive partition repair is not permitted.'
        }
    }

    $staged = Stage-WinREImage -WinREState $state -OsDiskNumber $disk.Number -Letter $letter
    if (-not $staged) { throw 'No valid Winre.wim could be located or recovered from a previous staging attempt.' }
    # Winre.wim normally carries Hidden/System attributes; use -Force for reliable metadata reads.
    $stagedSizeMB = [math]::Ceiling((Get-Item -LiteralPath $staged -Force -ErrorAction Stop).Length / 1MB)

    # Reuse a sufficiently large trailing Recovery partition first. This is the normal recovery path
    # after a previous run created the partition but failed before registration.
    $osEnd = $osPartition.Offset + $osPartition.Size
    foreach ($candidate in @($recoveryPartitions | Where-Object { $_.Offset -ge $osEnd } | Sort-Object Offset -Descending)) {
        if ([math]::Floor($candidate.Size / 1MB) -lt $MinimumRecoveryPartitionSizeMB) { continue }
        $reuseSucceeded = $false
        try {
            Write-Log "Attempting reuse of trailing Recovery partition $($candidate.PartitionNumber)."
            $reuseSucceeded = [bool](Register-AndEnableRecoveryPartition -Partition $candidate -Letter $letter -SourceWinRE $staged)
        }
        catch {
            Write-Log "Trailing Recovery partition $($candidate.PartitionNumber) could not be reused: $($_.Exception.Message)" 'WARN'
            continue
        }

        if ($reuseSucceeded) {
            # A validated reuse is terminal success. Best-effort cleanup of a legacy front Recovery
            # partition must never fall through into repartitioning after WinRE is already healthy.
            try {
                $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
                $oldFront = $recoveryPartitions | Where-Object { $_.Offset -lt $osPartition.Offset } | Sort-Object Offset | Select-Object -First 1
                Remove-OldFrontRecoveryBestEffort -DiskNumber $disk.Number -OldFrontRecovery $oldFront -OsPartition $osPartition -NewRecoveryPartitionNumber $candidate.PartitionNumber
            }
            catch { Write-Log "Post-reuse legacy Recovery cleanup warning: $($_.Exception.Message)" 'WARN' }
            return
        }
    }

    # If an adequately sized Recovery partition exists immediately after C: but reuse/validation did
    # not succeed, fail closed. A mount-letter or validation problem must never trigger deletion of an
    # otherwise correctly sized Recovery partition.
    $currentOsForGate = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $currentDiskForGate = Get-Disk -Number $disk.Number -ErrorAction Stop
    $nextForGate = Get-PartitionImmediatelyAfterOS -Disk $currentDiskForGate -OsPartition $currentOsForGate
    if ($nextForGate -and (Test-IsRecoveryPartition -Partition $nextForGate)) {
        $nextForGateSizeMB = [math]::Floor($nextForGate.Size / 1MB)
        if ($nextForGateSizeMB -ge $MinimumRecoveryPartitionSizeMB) {
            throw "An adequately sized Recovery partition ($nextForGateSizeMB MB) exists immediately after C: but could not be safely validated/reused. Destructive partition repair is not permitted."
        }
    }

    # Microsoft recommends a reboot before WinRE repartitioning. Intune Remediations should not issue
    # reboot commands, so fail this attempt and allow operational tooling to restart the device before
    # the remediation is rerun.
    if (Test-PendingReboot) {
        throw 'A pending reboot is present and WinRE repartitioning is required. Restart the device, then rerun remediation.'
    }

    $oldFrontRecovery = $recoveryPartitions | Where-Object { $_.Offset -lt $osPartition.Offset } | Sort-Object Offset | Select-Object -First 1

    try {
        $script:BitLockerChangedForPartitionWork = Suspend-OSBitLockerForPartitionWork

        $disable = Invoke-NativeCapture -FilePath 'reagentc.exe' -Arguments @('/disable')
        $disableText = $disable.Text
        if (-not [string]::IsNullOrWhiteSpace($disableText)) { Write-Log $disableText }
        Write-Log "reagentc /disable exit code: $($disable.ExitCode)"
        if ($disable.ExitCode -ne 0 -and $disableText -notmatch '(?i)already disabled') { throw 'reagentc /disable failed before repartitioning.' }

        Update-StorageView -DiskNumber $disk.Number
        $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
        $disk = Get-Disk -Number $disk.Number -ErrorAction Stop

        $nextPartition = Get-PartitionImmediatelyAfterOS -Disk $disk -OsPartition $osPartition
        if ($nextPartition -and (Test-IsRecoveryPartition -Partition $nextPartition)) {
            $nextSizeMB = [math]::Floor($nextPartition.Size / 1MB)
            if ($nextSizeMB -lt $MinimumRecoveryPartitionSizeMB) {
                Write-Log "Replacing undersized Recovery partition $($nextPartition.PartitionNumber) directly after C:, size $nextSizeMB MB."
                Remove-RecoveryPartition -Partition $nextPartition
                Update-StorageView -DiskNumber $disk.Number
                $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
                $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
            }
            else {
                throw "Recovery partition $($nextPartition.PartitionNumber) is already $nextSizeMB MB and will not be deleted automatically after failed validation/reuse."
            }
        }

        $minimumFromWimMB = $stagedSizeMB + $MinimumRecoveryFreeSpaceMB + 64
        $newSizeMB = [int][math]::Max($TargetRecoverySizeMB,$minimumFromWimMB)
        Resize-OSForRecoveryGap -Disk $disk -OsPartition $osPartition -RequiredGapBytes ([int64]($newSizeMB * 1MB))

        $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
        $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
        $newRecovery = New-RecoveryPartitionAfterOS -Disk $disk -OsPartition $osPartition -SizeMB $newSizeMB -Letter $letter
        $activeTemporaryLetter = if ($newRecovery.PSObject.Properties['TemporaryLetter']) { [string]$newRecovery.TemporaryLetter } else { $letter }

        $directory = "$activeTemporaryLetter`:\Recovery\WindowsRE"
        New-Item -Path $directory -ItemType Directory -Force | Out-Null
        Copy-Item -LiteralPath $staged -Destination (Join-Path $directory 'Winre.wim') -Force

        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/setreimage','/path',$directory) -SuccessCodes @(0)
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/enable') -SuccessCodes @(0)

        $finalState = Get-WinREState
        if (-not $finalState.Enabled -or $finalState.DiskNumber -ne $newRecovery.DiskNumber -or $finalState.PartitionNumber -ne $newRecovery.PartitionNumber) {
            throw 'WinRE did not register/enable against the newly-created Recovery partition.'
        }

        # Remove the temporary letter now. Subsequent health validation remounts it independently.
        try {
            Remove-PartitionAccessPath -DiskNumber $newRecovery.DiskNumber -PartitionNumber $newRecovery.PartitionNumber -AccessPath "$activeTemporaryLetter`:\" -ErrorAction Stop
        }
        catch {
            Invoke-DiskPart -Lines @(
                "select disk $($newRecovery.DiskNumber)",
                "select partition $($newRecovery.PartitionNumber)",
                "remove letter=$activeTemporaryLetter noerr"
            )
        }

        $newRecovery = Get-Partition -DiskNumber $newRecovery.DiskNumber -PartitionNumber $newRecovery.PartitionNumber -ErrorAction Stop
        $validationLetter = Get-SafeTemporaryDriveLetter
        $health = Get-RecoveryPartitionHealth -Partition $newRecovery -Letter $validationLetter
        if (-not $health.Healthy) { throw 'New Recovery partition failed final health validation.' }

        # New WinRE health has already been validated. Legacy front-Recovery cleanup is optional
        # and must not convert a successful repair into a failed remediation.
        try {
            $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
            Remove-OldFrontRecoveryBestEffort -DiskNumber $disk.Number -OldFrontRecovery $oldFrontRecovery -OsPartition $osPartition -NewRecoveryPartitionNumber $newRecovery.PartitionNumber
        }
        catch { Write-Log "Post-rebuild legacy Recovery cleanup warning: $($_.Exception.Message)" 'WARN' }
    }
    finally {
        Resume-OSBitLockerAfterPartitionWork
    }
}

# ============================================================================
# WinRE storage-driver servicing
# ============================================================================
function Get-ActiveThirdPartyStorageDrivers {
    $drivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
        $_.InfName -and $_.DriverProviderName -and $_.DriverProviderName -notmatch '(?i)^Microsoft' -and (
            $_.DeviceClass -in @('SCSIAdapter','HDC') -or
            ($_.DeviceClass -eq 'System' -and $_.DeviceName -match '(?i)VMD|Volume Management Device')
        ) -and (
            $_.DeviceName -match '(?i)RAID|RST|Rapid Storage|VMD|Volume Management Device|SATA|AHCI|NVMe|Storage|Controller|iaStor' -or
            $_.InfName -match '(?i)iaStor|vmd|rst|raid|nvme|sata'
        )
    } | Sort-Object InfName -Unique)

    foreach ($driver in $drivers) {
        Write-Log ("Active storage driver: Device='{0}', Provider='{1}', Inf='{2}', Version='{3}'" -f $driver.DeviceName,$driver.DriverProviderName,$driver.InfName,$driver.DriverVersion)
    }
    return $drivers
}

function Export-StorageDriverPackages {
    param([Parameter(Mandatory)][object[]]$Drivers)

    if (Test-Path -LiteralPath $DriverExportRoot) { Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $DriverExportRoot -ItemType Directory -Force | Out-Null
    $packages = New-Object System.Collections.Generic.List[object]

    foreach ($driver in $Drivers) {
        $target = Join-Path $DriverExportRoot ([IO.Path]::GetFileNameWithoutExtension(($driver.InfName -replace '[^A-Za-z0-9_.-]','_')))
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        try {
            Invoke-Native -FilePath 'pnputil.exe' -Arguments @('/export-driver',$driver.InfName,$target) -SuccessCodes @(0)
            $infs = @(Get-ChildItem -LiteralPath $target -Filter '*.inf' -File -Recurse -ErrorAction Stop)
            if ($infs.Count -eq 0) { throw 'No INF file was exported.' }
            [void]$packages.Add([pscustomobject]@{
                LiveVersion = $driver.DriverVersion
                DeviceName = $driver.DeviceName
                ExportPath = $target
                OriginalInfNames = @($infs | ForEach-Object { $_.Name.ToLowerInvariant() } | Select-Object -Unique)
            })
        }
        catch { Write-Log "Could not export $($driver.InfName): $($_.Exception.Message)" 'WARN' }
    }
    # Avoid a Windows PowerShell 5.1 Generic.List/array-subexpression binder defect.
    return $packages.ToArray()
}

function Cleanup-StaleWinREMount {
    if (Test-Path -LiteralPath $MountDirectory) {
        if (@(Get-ChildItem -LiteralPath $MountDirectory -Force -ErrorAction SilentlyContinue).Count -gt 0) {
            try { Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/unmountre','/path',$MountDirectory,'/discard') -SuccessCodes @(0) }
            catch {
                try { Invoke-Native -FilePath 'dism.exe' -Arguments @('/Unmount-Image',"/MountDir:$MountDirectory",'/Discard') -SuccessCodes @(0,2,50) } catch {}
            }
            try { Invoke-Native -FilePath 'dism.exe' -Arguments @('/Cleanup-Wim') -SuccessCodes @(0,2) } catch {}
            Remove-Item -LiteralPath $MountDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    New-Item -Path $MountDirectory -ItemType Directory -Force | Out-Null
}

function Mount-RegisteredWinRE {
    Cleanup-StaleWinREMount
    Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/mountre','/path',$MountDirectory) -SuccessCodes @(0)
    $script:WinREMounted = $true
}

function Unmount-RegisteredWinRE {
    param([switch]$Commit)

    if (-not $script:WinREMounted) { return }
    if ($Commit) {
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/unmountre','/path',$MountDirectory,'/commit') -SuccessCodes @(0)
    }
    else {
        try { Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/unmountre','/path',$MountDirectory,'/discard') -SuccessCodes @(0) }
        catch { Invoke-Native -FilePath 'dism.exe' -Arguments @('/Unmount-Image',"/MountDir:$MountDirectory",'/Discard') -SuccessCodes @(0,2,50) }
    }
    $script:WinREMounted = $false
    Remove-Item -LiteralPath $MountDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-OfflineWinREDrivers {
    if (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue) {
        try { return @(Get-WindowsDriver -Path $MountDirectory -All -ErrorAction Stop) }
        catch { Write-Log "Get-WindowsDriver failed: $($_.Exception.Message)" 'WARN' }
    }
    return @()
}

function Convert-ToVersionSafe {
    param([string]$Value)
    try { return [version]$Value } catch { return [version]'0.0.0.0' }
}

function Test-PackageAlreadyPresent {
    param($Package,[object[]]$OfflineDrivers)

    if ($OfflineDrivers.Count -eq 0) { return $false }
    $liveVersion = Convert-ToVersionSafe $Package.LiveVersion
    foreach ($offline in $OfflineDrivers) {
        if (-not $offline.OriginalFileName) { continue }
        $name = [IO.Path]::GetFileName($offline.OriginalFileName).ToLowerInvariant()
        if ($Package.OriginalInfNames -notcontains $name) { continue }
        if ((Convert-ToVersionSafe $offline.Version) -ge $liveVersion) { return $true }
    }
    return $false
}

function Ensure-WinREStorageDrivers {
    Write-Log '--- Phase: WinRE storage-driver validation/injection ---'
    Set-WorkflowState -Status 'DriverValidation'

    $state = Get-WinREState
    if (-not $state.Enabled) { throw 'WinRE must be enabled before storage-driver servicing.' }

    $drivers = @(Get-ActiveThirdPartyStorageDrivers)
    if ($drivers.Count -eq 0) {
        Write-Log 'No active third-party storage-controller driver requires injection.'
        return
    }

    $packages = @(Export-StorageDriverPackages -Drivers $drivers)
    if ($packages.Count -eq 0) { throw 'Active third-party storage drivers were detected but none could be exported.' }

    try {
        Mount-RegisteredWinRE
        $offline = @(Get-OfflineWinREDrivers)
        $toInject = @($packages | Where-Object { -not (Test-PackageAlreadyPresent -Package $_ -OfflineDrivers $offline) })

        if ($toInject.Count -eq 0) {
            Write-Log 'Required storage drivers are already present in WinRE at the same or a newer version.'
            Unmount-RegisteredWinRE
            return
        }

        foreach ($package in $toInject) {
            Write-Log "Injecting storage package for $($package.DeviceName)."
            Invoke-Native -FilePath 'dism.exe' -Arguments @(
                "/Image:$MountDirectory",'/Add-Driver',"/Driver:$($package.ExportPath)",'/Recurse'
            ) -SuccessCodes @(0)
        }

        $post = @(Get-OfflineWinREDrivers)
        if ($post.Count -gt 0) {
            foreach ($package in $toInject) {
                if (-not (Test-PackageAlreadyPresent -Package $package -OfflineDrivers $post)) {
                    throw "Post-injection validation failed for $($package.DeviceName)."
                }
            }
        }

        Unmount-RegisteredWinRE -Commit
    }
    catch {
        try { Unmount-RegisteredWinRE } catch {}
        throw
    }
    finally {
        Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # Microsoft recommends cycling WinRE after servicing on BitLocker/device-encrypted PCs.
    Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/disable') -SuccessCodes @(0)
    Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/enable') -SuccessCodes @(0)
    if (-not (Get-WinREState).Enabled) { throw 'WinRE is not enabled after driver servicing.' }
}

# ============================================================================
# Final local RemoteWipe
# ============================================================================
function Test-BitLockerProtectionOn {
    param($ProtectionStatus)
    if ($null -eq $ProtectionStatus) { return $false }
    return ($ProtectionStatus.ToString() -in @('On','1'))
}

function Suspend-BitLockerForWipe {
    $changed = New-Object System.Collections.Generic.List[string]

    if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        foreach ($volume in @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.MountPoint })) {
            Write-Log ("BitLocker {0}: VolumeType={1}, VolumeStatus={2}, ProtectionStatus={3}" -f `
                $volume.MountPoint, $volume.VolumeType, $volume.VolumeStatus, $volume.ProtectionStatus)

            if (-not (Test-BitLockerProtectionOn $volume.ProtectionStatus)) { continue }

            Write-Log "Suspending BitLocker protectors on $($volume.MountPoint) with RebootCount 0."
            try {
                Suspend-BitLocker -MountPoint $volume.MountPoint -RebootCount 0 -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Suspend-BitLocker failed on $($volume.MountPoint); trying manage-bde. Error: $($_.Exception.Message)" 'WARN'
                $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-disable',$volume.MountPoint,'-RebootCount','0')
                if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
                if ($native.ExitCode -ne 0) { throw "Unable to suspend BitLocker on $($volume.MountPoint); manage-bde exit code $($native.ExitCode)." }
            }

            $check = Get-BitLockerVolume -MountPoint $volume.MountPoint -ErrorAction Stop
            if (Test-BitLockerProtectionOn $check.ProtectionStatus) { throw "BitLocker remains protected on $($volume.MountPoint)." }
            [void]$changed.Add($volume.MountPoint)
        }
        return $changed.ToArray()
    }

    $status = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-status',$env:SystemDrive)
    if (-not [string]::IsNullOrWhiteSpace($status.Text)) { Write-Log $status.Text }
    if ($status.ExitCode -ne 0) { throw "manage-bde status failed with exit code $($status.ExitCode)." }

    if ($status.Text -match 'Protection Status:\s+Protection On') {
        $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-disable',$env:SystemDrive,'-RebootCount','0')
        if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
        if ($native.ExitCode -ne 0) { throw 'Unable to suspend OS BitLocker with manage-bde.' }
        [void]$changed.Add($env:SystemDrive)
    }
    return $changed.ToArray()
}

function Resume-WipeBitLockerBestEffort {
    foreach ($mountPoint in @($script:WipeBitLockerMountPoints)) {
        try {
            if (Get-Command Resume-BitLocker -ErrorAction SilentlyContinue) {
                Resume-BitLocker -MountPoint $mountPoint -ErrorAction Stop | Out-Null
            }
            else {
                $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-enable',$mountPoint)
                if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
                if ($native.ExitCode -ne 0) { throw "manage-bde could not resume BitLocker on $mountPoint. Exit code $($native.ExitCode)." }
            }
            Write-Log "Resumed BitLocker on $mountPoint because the wipe was not accepted." 'WARN'
        }
        catch { Write-Log "Unable to resume BitLocker on ${mountPoint}: $($_.Exception.Message)" 'WARN' }
    }
    $script:WipeBitLockerMountPoints = @()
}

function Get-RemoteWipeMethodName {
    if ($UseProtectedWipe) { return 'doWipeProtectedMethod' }
    return 'doWipeMethod'
}

function Assert-RemoteWipeMethodAvailable {
    param([Parameter(Mandatory)][ValidateSet('doWipeMethod','doWipeProtectedMethod')][string]$MethodName)

    $namespaceName = 'root\cimv2\mdm\dmmap'
    $className = 'MDM_RemoteWipe'

    Write-Log "Validating that $className exposes method $MethodName."

    try {
        $class = Get-CimClass -Namespace $namespaceName -ClassName $className -ErrorAction Stop
    }
    catch {
        throw "$className class metadata query failed: $($_.Exception.Message)"
    }

    if (-not $class) {
        throw "$className class metadata was not returned by the WMI Bridge Provider."
    }

    # CimClassMethods is a CimReadOnlyKeyedCollection<CimMethodDeclaration>. Windows PowerShell 5.1
    # does not expose a PowerShell-visible .Keys property; StrictMode would therefore throw. Enumerate
    # the declarations and compare Name instead for Windows PowerShell 5.1 StrictMode compatibility.
    $methodNames = @(
        foreach ($method in @($class.CimClassMethods)) {
            if ($null -ne $method -and -not [string]::IsNullOrWhiteSpace([string]$method.Name)) {
                [string]$method.Name
            }
        }
    )

    if ($methodNames.Count -gt 0) {
        Write-Log ("{0} methods exposed: {1}" -f $className, ($methodNames -join ', '))
    }
    else {
        Write-Log "$className class metadata returned no method declarations." 'WARN'
    }

    if (-not ($methodNames -contains $MethodName)) {
        throw "$className does not expose required method $MethodName."
    }
}

function Get-RemoteWipeInstance {
    Write-Log 'Validating the MDM RemoteWipe WMI Bridge instance.'
    $instance = Get-CimInstance -Namespace 'root\cimv2\mdm\dmmap' -ClassName 'MDM_RemoteWipe' -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" -ErrorAction Stop
    if (-not $instance) { throw 'MDM_RemoteWipe WMI Bridge instance is unavailable.' }
    return $instance
}

function Invoke-RemoteWipe {
    param(
        [Parameter(Mandatory)]$Instance,
        [Parameter(Mandatory)][ValidateSet('doWipeMethod','doWipeProtectedMethod')][string]$MethodName
    )

    $session = $null
    try {
        $session = New-CimSession
        $parameters = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
        $parameter = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create('param','','String','In')
        [void]$parameters.Add($parameter)

        Write-Log "Invoking MDM_RemoteWipe.$MethodName."
        $result = $session.InvokeMethod('root\cimv2\mdm\dmmap',$Instance,$MethodName,$parameters)
        Write-Log ($result | Out-String)

        $returnValue = $null
        if ($result -and $result.PSObject.Properties.Name -contains 'ReturnValue') {
            if ($result.ReturnValue -is [ValueType]) { $returnValue = [int]$result.ReturnValue }
            elseif ($result.ReturnValue -and $result.ReturnValue.PSObject.Properties.Name -contains 'Value') { $returnValue = [int]$result.ReturnValue.Value }
            else {
                $returnText = $result.ReturnValue | Out-String
                if ($returnText -match 'ReturnValue\s*=\s*(\d+)') { $returnValue = [int]$matches[1] }
            }
        }

        if ($null -ne $returnValue -and $returnValue -ne 0) { throw "RemoteWipe returned $returnValue." }
        if ($null -eq $returnValue) { Write-Log 'RemoteWipe returned without exception but no parseable ReturnValue was exposed.' 'WARN' }
    }
    finally {
        if ($session) { Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue }
    }
}

function Write-BitLockerTelemetry {
    if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        foreach ($volume in @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.MountPoint })) {
            Write-Log ("Preflight BitLocker {0}: VolumeType={1}, VolumeStatus={2}, ProtectionStatus={3}" -f `
                $volume.MountPoint, $volume.VolumeType, $volume.VolumeStatus, $volume.ProtectionStatus)
        }
        return
    }

    $status = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-status',$env:SystemDrive)
    if (-not [string]::IsNullOrWhiteSpace($status.Text)) { Write-Log $status.Text }
    if ($status.ExitCode -ne 0) { throw "Preflight manage-bde status failed with exit code $($status.ExitCode)." }
}

function Assert-FinalResetPreflight {
    Write-Log '--- Phase: final local RemoteWipe preflight ---'

    $state = Get-WinREState
    if (-not $state.Enabled) { throw 'Final reset refused because WinRE is not enabled.' }

    $methodName = Get-RemoteWipeMethodName
    Assert-RemoteWipeMethodAvailable -MethodName $methodName
    $instance = Get-RemoteWipeInstance

    Write-BitLockerTelemetry

    return [pscustomobject]@{
        MethodName = $methodName
        Instance   = $instance
    }
}

function Invoke-FinalReset {
    # Re-run provider/method/WinRE preflight immediately before changing BitLocker state. This closes
    # the gap where the WMI class exists but the required wipe method is not actually exposed.
    $preflight = Assert-FinalResetPreflight

    # Revalidate the Arm marker at the last reversible boundary. Preparation can take long enough for
    # an operator to Disarm the endpoint or for a short-lived authorization to expire. Do not suspend
    # BitLocker or invoke RemoteWipe if authorization is no longer valid.
    if (-not (Test-ResetAuthorization)) {
        Write-Log 'Reset authorization was revoked or expired during final preflight; refusing wipe.' 'WARN'
        throw 'Reset authorization was revoked or expired before RemoteWipe.'
    }

    Set-WorkflowState -Status 'ReadyToWipe'

    if ($UseProtectedWipe) {
        Write-Log 'Protected wipe is enabled. Microsoft warns this method can leave some devices unable to boot.' 'WARN'
    }

    $script:WipeBitLockerMountPoints = @(Suspend-BitLockerForWipe)
    try {
        Invoke-RemoteWipe -Instance $preflight.Instance -MethodName $preflight.MethodName
        $script:WipeAccepted = $true
        Set-WorkflowState -Status 'WipeTriggered'
        Write-Log 'RemoteWipe request was accepted. Windows should begin the reset workflow.'
    }
    catch {
        if (-not $script:WipeAccepted) { Resume-WipeBitLockerBestEffort }
        throw
    }
}

# ============================================================================
# Main workflow
# ============================================================================
try {
    Write-Log '=== Starting Intune carve-out full-reset remediation ==='
    Write-Log "Log file: $LogFile"

    if (-not (Test-IsLocalSystem)) { throw 'Remediation must run as Local System.' }
    if (-not (Test-ResetAuthorization)) { throw 'Reset authorization is missing, mismatched, or expired.' }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ([int]$os.ProductType -ne 1) { throw 'Windows Server is not supported by this reset workflow.' }
    Write-Log "OS=$($os.Caption) $($os.Version) build $($os.BuildNumber); 64BitProcess=$([Environment]::Is64BitProcess); PowerShell=$($PSVersionTable.PSVersion)"

    # Prevent overlapping Intune runs or a manual invocation from modifying partitions concurrently.
    $script:WorkflowMutex = New-Object System.Threading.Mutex($false,'Global\CarveOutFullResetWorkflow')
    if (-not $script:WorkflowMutex.WaitOne(0,$false)) { throw 'Another carve-out reset workflow instance is already running.' }

    Increment-AttemptCount
    Set-WorkflowState -Status 'Preflight'

    Ensure-WinREHealthy
    Set-WorkflowState -Status 'WinREReady'

    Ensure-WinREStorageDrivers
    Set-WorkflowState -Status 'DriversReady'

    # One final WinRE check immediately before the irreversible step.
    if (-not (Get-WinREState).Enabled) { throw 'WinRE final validation failed immediately before wipe.' }

    if ($PreflightOnly) {
        $preflight = Assert-FinalResetPreflight
        Set-WorkflowState -Status 'PreflightOnlyComplete'
        Write-Log "PRECHECK SUCCESS: authorization, WinRE, storage-driver readiness, RemoteWipe method $($preflight.MethodName), provider instance and BitLocker telemetry validated. No wipe was invoked and BitLocker was not suspended for wipe."
        Write-Output 'Carve-out full-reset preflight passed. No wipe was invoked.'
        exit 0
    }

    Invoke-FinalReset

    # The device can reboot/reset before this line is reached. If it remains running, a zero exit code
    # tells Intune that the remediation action itself completed successfully.
    Write-Output 'Carve-out reset prepared and RemoteWipe request accepted.'
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Log "ERROR: $message" 'ERROR'
    Write-Log ($_ | Out-String) 'ERROR'

    if (-not $script:WipeAccepted -and $script:WipeBitLockerMountPoints.Count -gt 0) {
        Resume-WipeBitLockerBestEffort
    }
    Resume-OSBitLockerAfterPartitionWork

    try { Set-WorkflowState -Status 'Failed' -LastError $message } catch {}
    Write-Error $message
    exit 1
}
finally {
    try {
        if ($script:WinREMounted) { Unmount-RegisteredWinRE }
    }
    catch {}

    Resume-OSBitLockerAfterPartitionWork

    if ($script:WorkflowMutex) {
        try { $script:WorkflowMutex.ReleaseMutex() } catch {}
        $script:WorkflowMutex.Dispose()
    }
}
