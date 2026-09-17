<#
.SYNOPSIS
  Intune Remediations repair script for proactive WinRE wipe readiness.

.DESCRIPTION
  Repairs local Windows Recovery Environment prerequisites so a future Intune full wipe is not a
  "wipe and hope" event. The script NEVER invokes MDM_RemoteWipe and NEVER resets the device.

  Remediation sequence:
    1. Validate SYSTEM/64-bit execution and serialize all WinRE maintenance with a global mutex.
    2. Reassess and repair WinRE registration, partition capacity/free space and Winre.wim placement.
    3. Reuse partial previous work rather than blindly shrinking C: again.
    4. Inject active third-party boot/storage-controller drivers when WinRE does not contain the same
       or a newer package.
    5. Reassess WinRE after driver servicing; if servicing consumed the required free-space reserve,
       repair/resize again while preserving the already-serviced Winre.wim.
    6. Deep-validate WinRE mountability, component-store health, storage-driver coverage and the local
       MDM_RemoteWipe WMI Bridge surface WITHOUT calling a wipe method.

  The script is designed to be idempotent. A failed run can be retried: disk layout and WinRE state
  are rediscovered on every run, Winre.wim is staged before destructive partition work, existing free
  space is reused, and C: is only shrunk by the additional amount still required.

  Automatic partition rebuild is intentionally limited to GPT OS disks. Legacy MBR devices can be
  reported by the detection script, but unsafe partition surgery is not attempted here.

  Exit 0 = remediation completed and final readiness validation passed.
  Exit 1 = remediation could not establish wipe readiness; no wipe was invoked.

.INTUNE SETTINGS
  Run this script using the logged-on credentials: No
  Run script in 64-bit PowerShell:             Yes
  Enforce script signature check:              Follow organisational signing policy

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Microsoft references:
  - Intune Remediations:
    https://learn.microsoft.com/intune/device-management/tools/deploy-remediations
  - MDM_RemoteWipe:
    https://learn.microsoft.com/windows/win32/dmwmibridgeprov/mdm-remotewipe
  - WinRE servicing:
    https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-update-to-winre
  - Recovery partition sizing:
    https://learn.microsoft.com/windows-hardware/manufacture/desktop/configure-uefigpt-based-hard-drive-partitions
#>

[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ============================================================================
# Deployment configuration
# ============================================================================
$StatePath = 'HKLM:\SOFTWARE\WinREReadiness'
$TargetRecoverySizeMB = 2536
$MinimumRecoveryPartitionSizeMB = 750
$MinimumRecoveryFreeSpaceMB = 250
$PreferredRecoveryLetter = 'R'

$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$RecoveryMbrType = 39 # 0x27 Windows Recovery on MBR disks.
$EfiGptType      = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$MsrGptType      = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'

$WorkingRoot = Join-Path $env:ProgramData 'WinREReadiness'
$WinREWorkingDirectory = Join-Path $WorkingRoot 'WinRE'
$StagedWinRE = Join-Path $WinREWorkingDirectory 'Winre.wim'
$DriverExportRoot = Join-Path $WorkingRoot 'WinREStorageDrivers'
$MountDirectory = Join-Path $WorkingRoot 'WinREMount'
$BackupDirectory = Join-Path $WorkingRoot 'Backups'
$LogDirectory = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\WinREReadiness'
$LogFile = Join-Path $LogDirectory ('Remediate-WinREReadiness-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

$script:BitLockerChangedForPartitionWork = $false
$script:WinREMounted = $false
$script:WorkflowMutex = $null
$script:WorkflowMutexOwned = $false

# ============================================================================
# 64-bit process correction
# ============================================================================
function Restart-In64BitPowerShellIfRequired {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $nativePowerShell = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $nativePowerShell)) {
            throw "64-bit Windows PowerShell was not found at $nativePowerShell"
        }

        # Invoke directly so stdout/stderr continue back to Intune rather than being detached by Start-Process.
        & $nativePowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath
        exit $LASTEXITCODE
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

function Set-WorkflowState {
    param(
        [Parameter(Mandatory)][string]$Status,
        [string]$LastError = ''
    )

    New-Item -Path $StatePath -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'Status' -PropertyType String -Value $Status -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'LastRunUtc' -PropertyType String -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'LastError' -PropertyType String -Value $LastError -Force | Out-Null
}

function Increment-AttemptCount {
    New-Item -Path $StatePath -Force | Out-Null
    $existing = 0
    try { $existing = [int](Get-ItemProperty -Path $StatePath -Name AttemptCount -ErrorAction Stop).AttemptCount } catch {}
    New-ItemProperty -Path $StatePath -Name 'AttemptCount' -PropertyType DWord -Value ($existing + 1) -Force | Out-Null
}

function Test-IsLocalSystem {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ($identity.User -and $identity.User.Value -eq 'S-1-5-18')
}

function Invoke-Native {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @(),
        [int[]]$SuccessCodes = @(0),
        [switch]$ReturnOutput
    )

    Write-Log "Running: $FilePath $($Arguments -join ' ')"
    $output = & $FilePath @Arguments 2>&1
    $code = $LASTEXITCODE
    $text = $output | Out-String
    if ($text.Trim()) { Write-Log $text }
    Write-Log "Exit code: $code"

    if ($SuccessCodes -notcontains $code) {
        throw "$FilePath failed with exit code $code."
    }

    if ($ReturnOutput) { return $text }
}

function Invoke-DiskPart {
    param([Parameter(Mandatory)][string[]]$Lines)

    $scriptPath = Join-Path $env:TEMP ("winre-readiness-diskpart-{0}.txt" -f ([guid]::NewGuid().Guid))
    try {
        $Lines | Out-File -FilePath $scriptPath -Encoding ascii -Force
        Write-Log "DiskPart script:`r`n$($Lines -join "`r`n")"
        $output = & diskpart.exe /s $scriptPath 2>&1
        $code = $LASTEXITCODE
        $text = $output | Out-String
        Write-Log $text
        Write-Log "DiskPart exit code: $code"

        if ($code -ne 0 -or $text -match 'Virtual Disk Service error|DiskPart has encountered an error|The arguments specified for this command are not valid') {
            throw "DiskPart reported a failure (exit code $code)."
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
    return $false
}

# ============================================================================
# WinRE discovery and temporary-access helpers
# ============================================================================

# ============================================================================
# Language-independent WinRE state discovery
# ============================================================================
function Get-WinREState {
    $output = & reagentc.exe /info 2>&1
    $code = $LASTEXITCODE
    $text = $output | Out-String
    Write-Log "reagentc /info exit code: $code"
    Write-Log $text

    $diskNumber = $null
    $partitionNumber = $null
    $enabledFromXml = $null
    $xmlLocationPath = ''
    $xmlPartitionGuid = ''
    $xmlOffset = $null
    $bcdId = ''

    if ($text -match '(?i)harddisk(\d+)\\partition(\d+)\\Recovery\\WindowsRE') {
        $diskNumber = [int]$matches[1]
        $partitionNumber = [int]$matches[2]
    }

    $xmlPath = Join-Path $env:WINDIR 'System32\Recovery\ReAgent.xml'
    if (Test-Path -LiteralPath $xmlPath) {
        try {
            [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
            $root = $xml.WindowsRE
            if ($root) {
                $installState = $null
                if ($root.InstallState -and $root.InstallState.state -ne $null) { $installState = [int]$root.InstallState.state }
                if ($root.WinreLocation) {
                    $xmlLocationPath = [string]$root.WinreLocation.path
                    $xmlPartitionGuid = [string]$root.WinreLocation.guid
                    if ([string]$root.WinreLocation.offset -match '^\d+$') { $xmlOffset = [int64]$root.WinreLocation.offset }
                }
                if ($root.WinreBCD) { $bcdId = [string]$root.WinreBCD.id }
                $zeroGuid = '{00000000-0000-0000-0000-000000000000}'
                $enabledFromXml = ($installState -eq 1 -and -not [string]::IsNullOrWhiteSpace($xmlLocationPath) -and -not [string]::IsNullOrWhiteSpace($bcdId) -and $bcdId -ne $zeroGuid)
            }
        }
        catch { Write-Log "ReAgent.xml parse warning: $($_.Exception.Message)" 'WARN' }
    }

    if ($null -eq $partitionNumber) {
        try {
            $osPart = Get-Partition -DriveLetter ($env:SystemDrive.TrimEnd(':')) -ErrorAction Stop
            $parts = @(Get-Partition -DiskNumber $osPart.DiskNumber -ErrorAction Stop)
            $candidate = $null
            if (-not [string]::IsNullOrWhiteSpace($xmlPartitionGuid) -and $xmlPartitionGuid -ne '{00000000-0000-0000-0000-000000000000}') {
                $candidate = $parts | Where-Object { $_.Guid -and $_.Guid.ToString().Trim('{}').ToLowerInvariant() -eq $xmlPartitionGuid.Trim('{}').ToLowerInvariant() } | Select-Object -First 1
            }
            if (-not $candidate -and $null -ne $xmlOffset) {
                $candidate = $parts | Where-Object { [int64]$_.Offset -eq [int64]$xmlOffset } | Select-Object -First 1
            }
            if ($candidate) {
                $diskNumber = $candidate.DiskNumber
                $partitionNumber = $candidate.PartitionNumber
            }
        }
        catch { Write-Log "ReAgent.xml location resolution warning: $($_.Exception.Message)" 'WARN' }
    }

    $enabled = $false
    if ($null -ne $enabledFromXml) { $enabled = [bool]$enabledFromXml }
    elseif ($text -match '(?i)Windows RE status:\s+Enabled') { $enabled = $true }

    return [pscustomobject]@{
        Enabled = $enabled
        ReAgentExitCode = $code
        DiskNumber = $diskNumber
        PartitionNumber = $partitionNumber
        Text = $text
    }
}

function Test-IsRecoveryPartition {
    param([Parameter(Mandatory)]$Partition)
    if ($Partition.GptType -and $Partition.GptType.ToString().ToLowerInvariant() -eq $RecoveryGptType) { return $true }
    try { if ($null -ne $Partition.MbrType -and [int]$Partition.MbrType -eq $RecoveryMbrType) { return $true } } catch {}
    if ($Partition.Type -and $Partition.Type.ToString() -eq 'Recovery') { return $true }
    return $false
}

function Get-RecoveryPartitions {
    param([Parameter(Mandatory)][int]$DiskNumber)
    return @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Where-Object { Test-IsRecoveryPartition -Partition $_ } | Sort-Object Offset)
}

function Get-TemporaryDriveLetterCandidates {
    param([string]$PreferredLetter = $PreferredRecoveryLetter)
    return @(@($PreferredLetter,'R','S','T','U','V','W','X','Y','Z') |
        ForEach-Object { if ($_ -and $_ -match '^[A-Za-z]$') { $_.ToUpperInvariant() } } |
        Select-Object -Unique)
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
    param([Parameter(Mandatory)]$Partition,[Parameter(Mandatory)][string]$Letter)

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
        }
        finally {
            if ($assignedByUs -and -not (Test-Path "$candidate`:\")) {
                try { Remove-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$candidate`:\" -ErrorAction Stop }
                catch {
                    try { Invoke-DiskPart -Lines @("select disk $($Partition.DiskNumber)","select partition $($Partition.PartitionNumber)","remove letter=$candidate noerr") } catch {}
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
        $status = & manage-bde.exe -status $env:SystemDrive 2>&1
        $text = $status | Out-String
        Write-Log $text
        if ($text -match 'Protection Status:\s+Protection On') {
            $output = & manage-bde.exe -protectors -disable $env:SystemDrive -RebootCount 0 2>&1
            $code = $LASTEXITCODE
            Write-Log ($output | Out-String)
            if ($code -ne 0) { throw "manage-bde failed with exit code $code." }
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
        $output = & manage-bde.exe -protectors -disable $env:SystemDrive -RebootCount 0 2>&1
        $code = $LASTEXITCODE
        Write-Log ($output | Out-String)
        if ($code -ne 0) { throw "manage-bde failed with exit code $code." }
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
            [void](& manage-bde.exe -protectors -enable $env:SystemDrive 2>&1)
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

    # Existing healthy or reusable WinRE can be validated on MBR as well, but automatic partition
    # delete/shrink/create operations are deliberately limited to GPT. Legacy layouts that need
    # partition surgery are surfaced for manual handling instead of being guessed at.
    if ($disk.PartitionStyle -ne 'GPT') {
        throw 'WinRE requires partition repair, but automatic repartitioning is supported only on GPT OS disks.'
    }

    # Microsoft recommends a reboot before WinRE repartitioning. Intune Remediations should not issue
    # reboot commands, so fail this attempt and allow operational tooling to restart the device before
    # the remediation is rerun.
    $currentOsForGate = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $currentDiskForGate = Get-Disk -Number $disk.Number -ErrorAction Stop
    $nextForGate = Get-PartitionImmediatelyAfterOS -Disk $currentDiskForGate -OsPartition $currentOsForGate
    if ($nextForGate -and (Test-IsRecoveryPartition -Partition $nextForGate)) {
        $nextForGateSizeMB = [math]::Floor($nextForGate.Size / 1MB)
        if ($nextForGateSizeMB -ge $MinimumRecoveryPartitionSizeMB) {
            throw "An adequately sized Recovery partition ($nextForGateSizeMB MB) exists immediately after C: but could not be safely validated/reused. Destructive partition repair is not permitted."
        }
    }

    if (Test-PendingReboot) {
        throw 'A pending reboot is present and WinRE repartitioning is required. Restart the device, then rerun remediation.'
    }

    $oldFrontRecovery = $recoveryPartitions | Where-Object { $_.Offset -lt $osPartition.Offset } | Sort-Object Offset | Select-Object -First 1

    try {
        $script:BitLockerChangedForPartitionWork = Suspend-OSBitLockerForPartitionWork

        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $disable = & reagentc.exe /disable 2>&1
            $disableCode = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $disableText = (($disable | ForEach-Object { [string]$_ }) -join "`r`n")
        Write-Log $disableText
        if ($disableCode -ne 0 -and $disableText -notmatch '(?i)already disabled') { throw 'reagentc /disable failed before repartitioning.' }

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
# WinRE WIM backup before servicing
# ============================================================================
function Backup-RegisteredWinRE {
    param([Parameter(Mandatory)]$WinREState)

    if ($null -eq $WinREState.DiskNumber -or $null -eq $WinREState.PartitionNumber) {
        throw 'Cannot back up WinRE because ReAgent does not expose a registered partition.'
    }

    $partition = Get-Partition -DiskNumber $WinREState.DiskNumber -PartitionNumber $WinREState.PartitionNumber -ErrorAction Stop
    $letter = Get-SafeTemporaryDriveLetter
    $access = $null
    try {
        $access = Add-TemporaryRecoveryAccessPath -Partition $partition -Letter $letter
        $source = "$($access.Letter):\Recovery\WindowsRE\Winre.wim"
        if (-not (Test-WimFile -Path $source)) { throw 'Registered Winre.wim could not be validated before backup.' }

        New-Item -Path $BackupDirectory -ItemType Directory -Force | Out-Null
        $backup = Join-Path $BackupDirectory ('Winre.wim.bak-{0}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $source -Destination $backup -Force
        Write-Log "Backed up Winre.wim to $backup."

        Get-ChildItem -LiteralPath $BackupDirectory -Filter 'Winre.wim.bak-*' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending | Select-Object -Skip 3 | Remove-Item -Force -ErrorAction SilentlyContinue
        return $backup
    }
    finally {
        if ($access) { Remove-TemporaryRecoveryAccessPath -Partition $partition -Letter $access.Letter -Added $access.Added }
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

    [void](Backup-RegisteredWinRE -WinREState $state)

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
# Component-store repair (safe commit/discard model)
# ============================================================================
function Ensure-WinREComponentStoreHealthy {
    Write-Log '--- Phase: WinRE component-store validation/repair ---'
    Set-WorkflowState -Status 'ComponentValidation'

    $state = Get-WinREState
    if (-not $state.Enabled) { throw 'WinRE must be enabled before component-store validation.' }

    [void](Backup-RegisteredWinRE -WinREState $state)
    $needsCommit = $false

    try {
        Mount-RegisteredWinRE
        $check = Invoke-Native -FilePath 'dism.exe' -Arguments @('/English',"/Image:$MountDirectory",'/Cleanup-Image','/CheckHealth') -ReturnOutput
        if ($check -match '(?i)No component store corruption detected') {
            Write-Log 'WinRE component store reports healthy.'
            Unmount-RegisteredWinRE
            return
        }

        if ($check -notmatch '(?i)component store.*repairable|component store corruption|cannot be repaired') {
            throw 'DISM /CheckHealth did not return a conclusive WinRE component-store state.'
        }

        Write-Log 'WinRE component store reports corruption. Attempting offline RestoreHealth with local component sources only.' 'WARN'
        Invoke-Native -FilePath 'dism.exe' -Arguments @('/English',"/Image:$MountDirectory",'/Cleanup-Image','/RestoreHealth','/LimitAccess')

        $post = Invoke-Native -FilePath 'dism.exe' -Arguments @('/English',"/Image:$MountDirectory",'/Cleanup-Image','/CheckHealth') -ReturnOutput
        if ($post -notmatch '(?i)No component store corruption detected') {
            throw 'WinRE component-store repair did not produce a clean /CheckHealth result.'
        }

        $needsCommit = $true
        Unmount-RegisteredWinRE -Commit
        Write-Log 'WinRE component-store repair committed successfully.'
    }
    catch {
        if ($script:WinREMounted) {
            try { Unmount-RegisteredWinRE } catch {}
        }
        throw
    }

    if ($needsCommit) {
        # ReAgentC cycling re-establishes WinRE state after an image servicing commit on encrypted PCs.
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/disable') -SuccessCodes @(0)
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/enable') -SuccessCodes @(0)
        if (-not (Get-WinREState).Enabled) { throw 'WinRE did not re-enable after component-store repair.' }
    }
}

# ============================================================================
# Final non-destructive readiness assurance
# ============================================================================
function Test-MDMRemoteWipeBridgeReady {
    $namespace = 'root\cimv2\mdm\dmmap'
    $class = Get-CimClass -Namespace $namespace -ClassName 'MDM_RemoteWipe' -ErrorAction Stop
    if ($null -eq $class.CimClassMethods['doWipeMethod']) { throw 'MDM_RemoteWipe does not expose doWipeMethod.' }
    $instance = Get-CimInstance -Namespace $namespace -ClassName 'MDM_RemoteWipe' -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" -ErrorAction Stop
    if (-not $instance) { throw 'MDM_RemoteWipe device-scoped WMI Bridge instance is unavailable.' }
    return $true
}

function Invoke-FinalReadinessValidation {
    Write-Log '--- Phase: final non-destructive wipe-readiness validation ---'
    Set-WorkflowState -Status 'FinalValidation'

    $state = Get-WinREState
    if (-not $state.Enabled -or $null -eq $state.DiskNumber -or $null -eq $state.PartitionNumber) {
        throw 'WinRE is not enabled and fully registered after remediation.'
    }

    $osDrive = $env:SystemDrive.TrimEnd(':')
    $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $disk = Get-Disk -Number $osPartition.DiskNumber -ErrorAction Stop
    if ($state.DiskNumber -ne $disk.Number) { throw 'WinRE is registered on a different disk from the OS.' }

    $partition = Get-Partition -DiskNumber $state.DiskNumber -PartitionNumber $state.PartitionNumber -ErrorAction Stop
    if (-not (Test-IsRecoveryPartition -Partition $partition)) { throw 'Registered WinRE partition is not identified as a Windows Recovery partition.' }

    $letter = Get-SafeTemporaryDriveLetter
    $health = Get-RecoveryPartitionHealth -Partition $partition -Letter $letter
    if (-not $health.Healthy) {
        throw "Recovery partition failed final health check. Size=$($health.SizeMB) MB Free=$($health.FreeMB) MB WimValid=$($health.WimValid)."
    }

    [void](Test-MDMRemoteWipeBridgeReady)

    $drivers = @(Get-ActiveThirdPartyStorageDrivers)
    $packages = @()
    if ($drivers.Count -gt 0) {
        $packages = @(Export-StorageDriverPackages -Drivers $drivers)
        if ($packages.Count -ne $drivers.Count) { throw 'Not every active third-party storage driver could be exported for final verification.' }
    }

    try {
        Mount-RegisteredWinRE

        $component = Invoke-Native -FilePath 'dism.exe' -Arguments @('/English',"/Image:$MountDirectory",'/Cleanup-Image','/CheckHealth') -ReturnOutput
        if ($component -notmatch '(?i)No component store corruption detected') {
            throw 'WinRE component-store health is not clean according to DISM /CheckHealth.'
        }

        if ($drivers.Count -gt 0) {
            $offline = @(Get-OfflineWinREDrivers)
            if ($offline.Count -eq 0) { throw 'Offline WinRE driver inventory could not be read during final validation.' }
            foreach ($package in $packages) {
                if (-not (Test-PackageAlreadyPresent -Package $package -OfflineDrivers $offline)) {
                    throw "WinRE final validation is missing the active storage package required by $($package.DeviceName)."
                }
            }
        }

        Unmount-RegisteredWinRE
    }
    catch {
        try { Unmount-RegisteredWinRE } catch {}
        throw
    }
    finally {
        Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    return [pscustomobject]@{
        RecoverySizeMB = $health.SizeMB
        RecoveryFreeMB = $health.FreeMB
        RequiredDrivers = $drivers.Count
        MDMBridge = 'OK'
        ComponentStore = 'OK'
    }
}

function Write-ReadyTelemetry {
    param([Parameter(Mandatory)]$Final)

    New-Item -Path $StatePath -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'Ready' -PropertyType DWord -Value 1 -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'HealthCode' -PropertyType String -Value 'H000' -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'WinREStatus' -PropertyType String -Value 'Enabled' -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'DriverStatus' -PropertyType String -Value 'OK' -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'MDMBridge' -PropertyType String -Value 'OK' -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'RecoverySizeMB' -PropertyType String -Value ([string]$Final.RecoverySizeMB) -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'RecoveryFreeMB' -PropertyType String -Value ([string]$Final.RecoveryFreeMB) -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'LastRemediationUtc' -PropertyType String -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force | Out-Null
    New-ItemProperty -Path $StatePath -Name 'LastRemediationResult' -PropertyType String -Value 'Ready' -Force | Out-Null
}

# ============================================================================
# Main workflow - deliberately contains no RemoteWipe invocation
# ============================================================================
try {
    Write-Log '=== Starting proactive WinRE wipe-readiness remediation ==='
    Write-Log "Log file: $LogFile"

    if (-not (Test-IsLocalSystem)) { throw 'Remediation must run as Local System.' }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    if ([int]$os.ProductType -ne 1) { throw 'Windows Server is not supported by this readiness workflow.' }
    Write-Log "OS=$($os.Caption) $($os.Version) build $($os.BuildNumber); 64BitProcess=$([Environment]::Is64BitProcess); PowerShell=$($PSVersionTable.PSVersion)"

    $script:WorkflowMutex = New-Object System.Threading.Mutex($false,'Global\WinREReadinessWorkflow')
    $acquired = $false
    try { $acquired = $script:WorkflowMutex.WaitOne([TimeSpan]::FromSeconds(120),$false) }
    catch [System.Threading.AbandonedMutexException] {
        $acquired = $true
        Write-Log 'A previous WinRE readiness process abandoned the workflow mutex; ownership was recovered.' 'WARN'
    }
    if (-not $acquired) { throw 'Another WinRE readiness workflow instance is already running.' }
    $script:WorkflowMutexOwned = $true

    Increment-AttemptCount
    Set-WorkflowState -Status 'Preflight'

    # Validate the local MDM wipe control surface before making any partition changes. This does not
    # invoke a wipe method; it only proves that the device-scoped RemoteWipe class/instance exists.
    [void](Test-MDMRemoteWipeBridgeReady)

    # First pass repairs registration/partition/WIM capacity from current state.
    Ensure-WinREHealthy
    Set-WorkflowState -Status 'WinREReady'

    # Inject only storage packages that the active Windows installation actually relies on and that
    # are missing or older inside WinRE.
    Ensure-WinREStorageDrivers
    Set-WorkflowState -Status 'DriversReady'

    # Driver servicing can grow Winre.wim. Re-check partition free space after the commit. If the
    # 250 MB servicing reserve is no longer met, this second pass rebuilds/resizes while preserving
    # the already-serviced WIM, rather than leaving the endpoint marginal.
    Ensure-WinREHealthy
    Set-WorkflowState -Status 'PostDriverWinREReady'

    # Repair component-store corruption only when DISM explicitly reports it and only commit if the
    # post-repair image validates. Failed repairs are discarded, leaving the original WIM in place.
    Ensure-WinREComponentStoreHealthy
    Set-WorkflowState -Status 'ComponentReady'

    $final = Invoke-FinalReadinessValidation
    Write-ReadyTelemetry -Final $final
    Set-WorkflowState -Status 'Ready'

    Write-Output "WinRE readiness remediated. Ready=True;Code=H000;Part=$($final.RecoverySizeMB)MB/$($final.RecoveryFreeMB)MBfree;Drivers=$($final.RequiredDrivers);MDM=OK;NoWipeInvoked=True"
    exit 0
}
catch {
    $message = $_.Exception.Message
    Write-Log "ERROR: $message" 'ERROR'
    Write-Log ($_ | Out-String) 'ERROR'
    Resume-OSBitLockerAfterPartitionWork

    try {
        New-Item -Path $StatePath -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'Ready' -PropertyType DWord -Value 0 -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'LastRemediationUtc' -PropertyType String -Value ((Get-Date).ToUniversalTime().ToString('o')) -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'LastRemediationResult' -PropertyType String -Value 'Failed' -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'LastError' -PropertyType String -Value $message -Force | Out-Null
        Set-WorkflowState -Status 'Failed' -LastError $message
    }
    catch {}

    $short = $message
    if ($short.Length -gt 1500) { $short = $short.Substring(0,1500) }
    Write-Output "WinRE readiness remediation failed;NoWipeInvoked=True;Error=$short"
    exit 1
}
finally {
    try { if ($script:WinREMounted) { Unmount-RegisteredWinRE } } catch {}
    Resume-OSBitLockerAfterPartitionWork
    Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue

    if ($script:WorkflowMutex) {
        if ($script:WorkflowMutexOwned) {
            try { $script:WorkflowMutex.ReleaseMutex() } catch { Write-Log "Unable to release workflow mutex: $($_.Exception.Message)" 'WARN' }
        }
        try { $script:WorkflowMutex.Dispose() } catch {}
        $script:WorkflowMutex = $null
        $script:WorkflowMutexOwned = $false
    }
}
