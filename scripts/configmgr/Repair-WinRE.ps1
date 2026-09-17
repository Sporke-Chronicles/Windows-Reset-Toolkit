<#
.SYNOPSIS
  Repairs, relocates, or rebuilds the Windows Recovery Environment (WinRE) partition for a reset workflow.

.DESCRIPTION
  Designed for ConfigMgr task sequences and, importantly, for safe reruns after a partial failure.

  Key design characteristics:
  - Does not require exactly four partitions. It identifies the OS disk and Recovery partitions by
    GPT type and the registered ReAgentC location.
  - Does not assume "WinRE enabled" means the partition is healthy. It validates the Recovery
    partition size, available free space, and Winre.wim presence.
  - Does not treat "large enough but disabled" as success. It re-registers and enables WinRE.
  - Reuses a healthy or partially-created trailing Recovery partition when possible.
  - Before destructive changes, stages Winre.wim in a persistent local working directory so a rerun
    can continue even if a previous attempt already deleted the old Recovery partition.
  - Calculates how much C: actually needs to shrink from the current disk state. It never blindly
    shrinks C: by the same amount on every run.
  - Recovers from common partial states: C: already shrunk, old Recovery already deleted, new
    Recovery already created but Winre.wim not copied, or WinRE registered but not enabled.
  - Only removes the old front-of-disk Recovery partition after the new WinRE is enabled and only
    when the old partition matches the known SCCM front-Recovery layout.
  - Suspends BitLocker only while partition changes are performed and resumes it before returning.

  Microsoft recommends at least 250 MB free in the WinRE partition for WinRE servicing. The default
  target here remains intentionally larger (2536 MB) to leave room for WinRE, future servicing, and
  injected storage drivers.

.PARAMETER TargetRecoverySizeMB
  Preferred size for a newly-created Recovery partition. Default: 2536 MB.

.PARAMETER MinimumRecoveryPartitionSizeMB
  Existing Recovery partitions at or above this size may be reused if they also have enough free
  space and a valid Winre.wim. Default: 2000 MB.

.PARAMETER MinimumRecoveryFreeSpaceMB
  Required free space after Winre.wim is present. Default: 250 MB.

.PARAMETER PreferredRecoveryLetter
  Preferred temporary drive letter for Recovery partition maintenance. The script automatically
  selects another free letter if this one is legitimately in use.

.PARAMETER IgnorePendingReboot
  Allows repartitioning when common pending-reboot indicators exist. The default is to return 3010
  before partition changes because Microsoft recommends rebooting before WinRE repartition work.

.RETURN CODES
  0    = WinRE is healthy and enabled, or repair completed successfully.
  1    = Generic failure.
  2    = Unsafe/unsupported disk condition.
  3    = BitLocker suspend failure.
  4    = No usable Winre.wim could be located or staged.
  5    = Partition operation failed.
  6    = ReAgentC registration/enable validation failed.
  7    = Fail-closed validation state; no destructive partition changes were attempted.
  3010 = A reboot is recommended before repartitioning.

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Microsoft WinRE servicing/partition guidance:
  https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-update-to-winre
#>

[CmdletBinding()]
param(
    [ValidateRange(750, 32768)]
    [int]$TargetRecoverySizeMB = 2536,

    [ValidateRange(500, 32768)]
    [int]$MinimumRecoveryPartitionSizeMB = 2000,

    [ValidateRange(100, 4096)]
    [int]$MinimumRecoveryFreeSpaceMB = 250,

    [ValidatePattern('^[A-Z]$')]
    [string]$PreferredRecoveryLetter = 'R',

    [switch]$IgnorePendingReboot
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Restart-In64BitPowerShellIfRequired {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $nativePowerShell = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $nativePowerShell)) {
            throw "64-bit Windows PowerShell was not found at $nativePowerShell"
        }

        $arguments = @(
            '-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath),
            '-TargetRecoverySizeMB',$TargetRecoverySizeMB,
            '-MinimumRecoveryPartitionSizeMB',$MinimumRecoveryPartitionSizeMB,
            '-MinimumRecoveryFreeSpaceMB',$MinimumRecoveryFreeSpaceMB,
            '-PreferredRecoveryLetter',$PreferredRecoveryLetter
        )
        if ($IgnorePendingReboot) { $arguments += '-IgnorePendingReboot' }

        $process = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
}

Restart-In64BitPowerShellIfRequired

$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$EfiGptType      = '{c12a7328-f81f-11d2-ba4b-00a0c93ec93b}'
$MsrGptType      = '{e3c9e316-0b5c-4db8-817d-f92df00215ae}'
$LogDirectory = Join-Path $env:WINDIR 'Logs\WinRE'
$LogFile = Join-Path $LogDirectory ("Resize-WinRE-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$WorkingDirectory = Join-Path $env:ProgramData 'CarveOutReset\WinRE'
$StagedWinRE = Join-Path $WorkingDirectory 'Winre.wim'
$TemporaryLetter = $null
$BitLockerWasSuspendedByScript = $false

New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
New-Item -Path $WorkingDirectory -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Exit-WithCode {
    param([int]$Code, [string]$Message)
    if ($Message) {
        $level = if ($Code -in @(0,3010)) { 'INFO' } else { 'ERROR' }
        Write-Log $Message $level
    }
    Write-Log "Exiting with code $Code."
    exit $Code
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Invoke-NativeCapture {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter()][string[]]$Arguments = @()
    )

    # Windows PowerShell 5.1 can promote text written by a native executable to stderr into a
    # terminating NativeCommandError when the script-wide ErrorActionPreference is Stop. Capture
    # native stdout/stderr under Continue so the caller can evaluate the real process exit code and
    # message instead of aborting before its safety logic runs.
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $raw = & $FilePath @Arguments 2>&1
        $code = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    $text = (($raw | ForEach-Object { [string]$_ }) -join "`r`n")
    return [pscustomobject]@{
        ExitCode = [int]$code
        Text     = [string]$text
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
    $code = $native.ExitCode
    $text = $native.Text
    if ($text.Trim()) { Write-Log $text }
    Write-Log "Exit code: $code"

    if ($SuccessCodes -notcontains $code) {
        throw "$FilePath failed with exit code $code."
    }

    if ($ReturnOutput) { return $text }
}

function Invoke-DiskPart {
    param([Parameter(Mandatory)][string[]]$Lines)

    $scriptPath = Join-Path $env:TEMP ("winre-diskpart-{0}.txt" -f ([guid]::NewGuid().Guid))
    try {
        $Lines | Out-File -FilePath $scriptPath -Encoding ascii -Force
        Write-Log "DiskPart script:`r`n$($Lines -join "`r`n")"
        $native = Invoke-NativeCapture -FilePath 'diskpart.exe' -Arguments @('/s',$scriptPath)
        $code = $native.ExitCode
        $text = $native.Text
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
    try {
        Invoke-DiskPart -Lines @('rescan', "select disk $DiskNumber")
    }
    catch {
        # A rescan failure is logged but Get-Disk/Get-Partition below are authoritative and may still succeed.
        Write-Log "DiskPart rescan warning: $($_.Exception.Message)" 'WARN'
    }
    Start-Sleep -Seconds 2
}

function Test-PendingReboot {
    $pending = New-Object System.Collections.Generic.List[string]

    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') {
        [void]$pending.Add('CBS RebootPending')
    }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') {
        [void]$pending.Add('Windows Update RebootRequired')
    }

    try {
        $sessionManager = Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction Stop
        if ($sessionManager.PendingFileRenameOperations) {
            [void]$pending.Add('PendingFileRenameOperations')
        }
    }
    catch {}

    if ($pending.Count -gt 0) {
        Write-Log "Pending reboot indicators detected: $($pending -join ', ')." 'WARN'
        return $true
    }

    return $false
}

function Get-WinREState {
    $native = Invoke-NativeCapture -FilePath 'reagentc.exe' -Arguments @('/info')
    $code = $native.ExitCode
    $text = $native.Text
    Write-Log "reagentc /info exit code: $code"
    Write-Log $text

    $enabled = ($text -match 'Windows RE status:\s+Enabled')
    $diskNumber = $null
    $partitionNumber = $null

    if ($text -match '(?i)harddisk(\d+)\\partition(\d+)\\Recovery\\WindowsRE') {
        $diskNumber = [int]$matches[1]
        $partitionNumber = [int]$matches[2]
    }

    return [pscustomobject]@{
        Enabled = $enabled
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

    # Honour a task-sequence preference first when present, but never treat it as authoritative.
    try {
        $ts = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop
        $tsLetter = $ts.Value('WinRETempDriveLetter')
        if ($tsLetter -match '^[A-Z]$') {
            $candidates = @($tsLetter.ToUpperInvariant()) + @($candidates | Where-Object { $_ -ne $tsLetter.ToUpperInvariant() })
        }
    }
    catch {}

    return @($candidates | Select-Object -Unique)
}

function Test-DriveLetterApparentlyFree {
    param([Parameter(Mandatory)][string]$Letter)

    if (Get-Partition -DriveLetter $Letter -ErrorAction SilentlyContinue) { return $false }
    if (Get-Volume -DriveLetter $Letter -ErrorAction SilentlyContinue) { return $false }
    if (Get-PSDrive -Name $Letter -PSProvider FileSystem -ErrorAction SilentlyContinue) { return $false }

    try {
        if (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$Letter`:'" -ErrorAction Stop) { return $false }
    }
    catch {}

    try {
        $mountedNames = @((Get-ItemProperty 'HKLM:\SYSTEM\MountedDevices' -ErrorAction Stop).PSObject.Properties.Name)
        if ($mountedNames -contains "\DosDevices\$Letter`:") { return $false }
    }
    catch {}

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
                Add-PartitionAccessPath `
                    -DiskNumber $Partition.DiskNumber `
                    -PartitionNumber $Partition.PartitionNumber `
                    -AccessPath "$candidate`:\" `
                    -ErrorAction Stop
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
                if ($candidate -ne $Letter) {
                    Write-Log "Preferred temporary letter $Letter`: was unavailable; using $candidate`: instead." 'WARN'
                }
                return [pscustomobject]@{ Letter = $candidate; Added = $true }
            }

            [void]$attemptErrors.Add("$candidate`: assignment completed but the path was not accessible")
            Write-Log "Temporary drive letter $candidate`: was assigned but did not become accessible; trying the next candidate." 'WARN'
        }
        finally {
            if ($assignedByUs -and -not (Test-Path "$candidate`:\")) {
                try {
                    Remove-PartitionAccessPath -DiskNumber $Partition.DiskNumber -PartitionNumber $Partition.PartitionNumber -AccessPath "$candidate`:\" -ErrorAction Stop
                }
                catch {
                    try {
                        Invoke-DiskPart -Lines @(
                            "select disk $($Partition.DiskNumber)",
                            "select partition $($Partition.PartitionNumber)",
                            "remove letter=$candidate noerr"
                        )
                    }
                    catch {}
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
        Write-Log "Removing temporary drive letter $Letter`: from Disk $($Partition.DiskNumber) Partition $($Partition.PartitionNumber)."
        Remove-PartitionAccessPath `
            -DiskNumber $Partition.DiskNumber `
            -PartitionNumber $Partition.PartitionNumber `
            -AccessPath "$Letter`:\" `
            -ErrorAction Stop
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
        catch {
            Write-Log "Unable to remove temporary letter $Letter`: $($_.Exception.Message)" 'WARN'
        }
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
            Write-Log "Staged Winre.wim from Disk $($Partition.DiskNumber) Partition $($Partition.PartitionNumber) to $StagedWinRE."
            return $true
        }
    }
    finally {
        if ($access) {
            Remove-TemporaryRecoveryAccessPath -Partition $Partition -Letter $access.Letter -Added $access.Added
        }
    }

    return $false
}

function Stage-WinREImage {
    param(
        [Parameter(Mandatory)]$WinREState,
        [Parameter(Mandatory)][int]$OsDiskNumber,
        [Parameter(Mandatory)][string]$Letter
    )

    # Prefer the currently registered WinRE image. This avoids using a stale local copy when a valid
    # Recovery image exists on disk.
    if ($null -ne $WinREState.DiskNumber -and $null -ne $WinREState.PartitionNumber -and $WinREState.DiskNumber -eq $OsDiskNumber) {
        try {
            $registered = Get-Partition -DiskNumber $WinREState.DiskNumber -PartitionNumber $WinREState.PartitionNumber -ErrorAction Stop
            if ((Test-IsRecoveryPartition -Partition $registered) -and (Copy-WinREFromPartitionToStage -Partition $registered -Letter $Letter)) {
                return $StagedWinRE
            }
        }
        catch {
            Write-Log "Registered WinRE partition could not be staged: $($_.Exception.Message)" 'WARN'
        }
    }

    foreach ($localPath in @(
        "$env:WINDIR\System32\Recovery\Winre.wim",
        "$env:SystemDrive\Recovery\WindowsRE\Winre.wim"
    )) {
        if (Test-WimFile -Path $localPath) {
            Copy-Item -LiteralPath $localPath -Destination $StagedWinRE -Force
            Write-Log "Staged Winre.wim from local path $localPath."
            return $StagedWinRE
        }
    }

    # Search every Recovery partition on the OS disk. This covers front-of-disk SCCM layouts and
    # partial runs where ReAgentC registration is no longer valid.
    foreach ($partition in @(Get-RecoveryPartitions -DiskNumber $OsDiskNumber | Sort-Object Offset -Descending)) {
        try {
            if (Copy-WinREFromPartitionToStage -Partition $partition -Letter $Letter) {
                return $StagedWinRE
            }
        }
        catch {
            Write-Log "Could not inspect Recovery partition $($partition.PartitionNumber): $($_.Exception.Message)" 'WARN'
        }
    }

    # Persistent stage is deliberately the final fallback. It may be from a previous partial run,
    # which is exactly what makes this workflow recoverable after an old Recovery partition was deleted.
    if (Test-WimFile -Path $StagedWinRE) {
        Write-Log "Using previously staged Winre.wim from $StagedWinRE." 'WARN'
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
        if ($access) {
            Remove-TemporaryRecoveryAccessPath -Partition $Partition -Letter $access.Letter -Added $access.Added
        }
    }
}

function Invoke-ReAgentSetAndEnable {
    param(
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][string]$Letter,
        [string]$SourceWinRE
    )

    $access = $null
    try {
        $access = Add-TemporaryRecoveryAccessPath -Partition $Partition -Letter $Letter
        $winreDirectory = "$($access.Letter):\Recovery\WindowsRE"
        $winrePath = Join-Path $winreDirectory 'Winre.wim'
        New-Item -Path $winreDirectory -ItemType Directory -Force | Out-Null

        if (-not (Test-WimFile -Path $winrePath)) {
            if ([string]::IsNullOrWhiteSpace($SourceWinRE) -or -not (Test-WimFile -Path $SourceWinRE)) {
                throw 'The target Recovery partition has no valid Winre.wim and no staged source is available.'
            }

            $requiredBytes = (Get-Item -LiteralPath $SourceWinRE -Force -ErrorAction Stop).Length + ($MinimumRecoveryFreeSpaceMB * 1MB)
            $volume = Get-Volume -DriveLetter $access.Letter -ErrorAction Stop
            if ($volume.SizeRemaining -lt $requiredBytes) {
                throw "The existing Recovery partition does not have enough free space for Winre.wim plus $MinimumRecoveryFreeSpaceMB MB reserve."
            }

            Copy-Item -LiteralPath $SourceWinRE -Destination $winrePath -Force
            Write-Log "Copied staged Winre.wim into $winreDirectory."
        }

        # ReAgentC converts the drive-letter path into its device/partition registration. We remove
        # the temporary drive letter only after verifying the registered partition number.
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/setreimage','/path',$winreDirectory) -SuccessCodes @(0)
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/enable') -SuccessCodes @(0)

        $state = Get-WinREState
        if (-not $state.Enabled) {
            throw 'WinRE did not report Enabled after registration.'
        }
        if ($state.DiskNumber -ne $Partition.DiskNumber -or $state.PartitionNumber -ne $Partition.PartitionNumber) {
            throw "WinRE enabled but registered Disk/Partition is $($state.DiskNumber)/$($state.PartitionNumber), expected $($Partition.DiskNumber)/$($Partition.PartitionNumber)."
        }

        # The target partition is already mounted through $access. Validate it in place rather than
        # assigning a second temporary drive letter. This avoids duplicate access paths during a rerun.
        $volume = Get-Volume -DriveLetter $access.Letter -ErrorAction Stop
        $sizeMB = [math]::Floor($Partition.Size / 1MB)
        $freeMB = [math]::Floor($volume.SizeRemaining / 1MB)
        $wimValid = Test-WimFile -Path $winrePath
        $healthy = ($sizeMB -ge $MinimumRecoveryPartitionSizeMB -and $freeMB -ge $MinimumRecoveryFreeSpaceMB -and $wimValid)
        Write-Log "Recovery health after registration: Size=$sizeMB MB, Free=$freeMB MB, WimValid=$wimValid, Healthy=$healthy."
        if (-not $healthy) {
            throw 'WinRE is enabled but the Recovery partition does not meet the configured health thresholds.'
        }

        return $true
    }
    finally {
        if ($access) {
            Remove-TemporaryRecoveryAccessPath -Partition $Partition -Letter $access.Letter -Added $access.Added
        }
    }
}

function Suspend-OSBitLocker {
    if (-not (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue)) {
        Write-Log 'Get-BitLockerVolume is unavailable; using manage-bde on the OS volume.' 'WARN'
        $nativeStatus = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-status',$env:SystemDrive)
        $statusText = $nativeStatus.Text
        Write-Log $statusText
        if ($statusText -match 'Protection Status:\s+Protection On') {
            $nativeDisable = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-disable',$env:SystemDrive,'-RebootCount','0')
            $code = $nativeDisable.ExitCode
            Write-Log $nativeDisable.Text
            if ($code -ne 0) { throw "manage-bde failed with exit code $code." }
            return $true
        }
        return $false
    }

    $volume = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    Write-Log "BitLocker OS volume: VolumeStatus=$($volume.VolumeStatus), ProtectionStatus=$($volume.ProtectionStatus)."
    if ($volume.ProtectionStatus.ToString() -notin @('On','1')) { return $false }

    try {
        Suspend-BitLocker -MountPoint $env:SystemDrive -RebootCount 0 -ErrorAction Stop | Out-Null
    }
    catch {
        Write-Log "Suspend-BitLocker failed; using manage-bde fallback. Error: $($_.Exception.Message)" 'WARN'
        $nativeDisable = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-disable',$env:SystemDrive,'-RebootCount','0')
        $code = $nativeDisable.ExitCode
        Write-Log $nativeDisable.Text
        if ($code -ne 0) { throw "manage-bde failed with exit code $code." }
    }

    $check = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
    if ($check.ProtectionStatus.ToString() -in @('On','1')) {
        throw 'BitLocker protection is still enabled on the OS volume.'
    }
    return $true
}

function Resume-OSBitLockerBestEffort {
    if (-not $BitLockerWasSuspendedByScript) { return }

    try {
        Write-Log 'Resuming BitLocker protection on the OS volume.'
        if (Get-Command Resume-BitLocker -ErrorAction SilentlyContinue) {
            Resume-BitLocker -MountPoint $env:SystemDrive -ErrorAction Stop | Out-Null
        }
        else {
            $nativeEnable = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-enable',$env:SystemDrive)
            Write-Log $nativeEnable.Text
        }
    }
    catch {
        Write-Log "Failed to resume BitLocker protection: $($_.Exception.Message)" 'WARN'
    }
    finally {
        $script:BitLockerWasSuspendedByScript = $false
    }
}

function Get-GapAfterOSBytes {
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)]$OsPartition
    )

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
    param(
        [Parameter(Mandatory)]$Disk,
        [Parameter(Mandatory)]$OsPartition
    )

    $osEnd = [int64]($OsPartition.Offset + $OsPartition.Size)
    return Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop |
        Where-Object { $_.Offset -ge $osEnd } |
        Sort-Object Offset |
        Select-Object -First 1
}

function Remove-RecoveryPartition {
    param([Parameter(Mandatory)]$Partition)

    Write-Log "Deleting Recovery partition Disk $($Partition.DiskNumber) Partition $($Partition.PartitionNumber), Size=$([math]::Round($Partition.Size/1MB,0)) MB."
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
    Write-Log "Current contiguous gap after OS: $([math]::Floor($currentGap/1MB)) MB; Recovery size required: $([math]::Ceiling($RequiredGapBytes/1MB)) MB; alignment padding: $($alignment.PaddingBytes) bytes; total required: $([math]::Ceiling($effectiveRequiredGapBytes/1MB)) MB."
    if ($currentGap -ge $effectiveRequiredGapBytes) {
        Write-Log 'Existing free space is sufficient after alignment; C: will not be shrunk again.'
        return
    }

    # Add a small reserve beyond the exact aligned requirement. The script recalculates the gap
    # after Resize-Partition and will fail safely if the requested extent still cannot be created.
    $additionalBytes = $effectiveRequiredGapBytes - $currentGap + (16MB)
    $additionalMB = [math]::Ceiling($additionalBytes / 1MB)
    $shrinkBytes = [int64]($additionalMB * 1MB)

    $supported = Get-PartitionSupportedSize -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
    $newSize = [int64]($OsPartition.Size - $shrinkBytes)
    Write-Log "Calculated OS shrink: $additionalMB MB. Current=$([math]::Round($OsPartition.Size/1MB,0)) MB, Target=$([math]::Round($newSize/1MB,0)) MB, MinimumSupported=$([math]::Round($supported.SizeMin/1MB,0)) MB."

    if ($newSize -lt $supported.SizeMin) {
        throw "C: cannot be safely shrunk by $additionalMB MB."
    }

    Resize-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -Size $newSize -ErrorAction Stop
    Update-StorageView -DiskNumber $Disk.Number

    $osNow = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
    $diskNow = Get-Disk -Number $Disk.Number -ErrorAction Stop
    $gapNow = Get-GapAfterOSBytes -Disk $diskNow -OsPartition $osNow
    $postAlignment = Get-RecoveryStartAlignment -OsPartition $osNow
    $postRequiredGapBytes = [int64]($RequiredGapBytes + $postAlignment.PaddingBytes)
    Write-Log "Gap after shrink: $([math]::Floor($gapNow/1MB)) MB; aligned requirement: $([math]::Ceiling($postRequiredGapBytes/1MB)) MB."
    if ($gapNow -lt $postRequiredGapBytes) {
        throw 'The contiguous free extent after C: is still smaller than the aligned Recovery requirement after the shrink operation.'
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
        throw "The free extent after C: is too small for a $SizeMB MB Recovery partition after alignment. Available=$availableGap bytes; Required=$requiredWithPadding bytes."
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
    $osNow = Get-Partition -DriveLetter $env:SystemDrive.TrimEnd(':') -ErrorAction Stop
    $osNowEnd = $osNow.Offset + $osNow.Size
    $newPartition = Get-Partition -DiskNumber $Disk.Number -ErrorAction Stop |
        Where-Object { (Test-IsRecoveryPartition -Partition $_) -and [int64]$_.Offset -eq [int64]$alignment.StartBytes } |
        Select-Object -First 1

    if (-not $newPartition) {
        throw 'The newly-created Recovery partition could not be identified.'
    }
    $leadingGap = [int64]($newPartition.Offset - $osNowEnd)
    if ($leadingGap -lt 0 -or $leadingGap -gt 1MB) {
        throw "The newly-created Recovery partition is not immediately after C:. Leading gap=$leadingGap bytes."
    }
    Write-Log "New Recovery partition begins $leadingGap bytes after C:."

    # Do not rely on Get-Partition.DriveLetter after applying the Recovery GPT type and
    # GPT_BASIC_DATA_ATTRIBUTE_NO_DRIVE_LETTER. Windows can drop/suppress the temporary
    # drive letter during the storage refresh even when DiskPart reported the assignment
    # as successful. Reuse the same explicit access-path helper used for existing Recovery
    # partitions and verify that the requested path is actually accessible.
    $access = Add-TemporaryRecoveryAccessPath -Partition $newPartition -Letter $Letter
    if (-not $access -or -not (Test-Path "$($access.Letter):\")) {
        throw 'The newly-created Recovery partition could not be mounted temporarily.'
    }
    Write-Log "Temporary Recovery access path $($access.Letter): is accessible after partition creation."

    $freshPartition = Get-Partition -DiskNumber $newPartition.DiskNumber -PartitionNumber $newPartition.PartitionNumber -ErrorAction Stop
    $freshPartition | Add-Member -NotePropertyName TemporaryLetter -NotePropertyValue $access.Letter -Force
    return $freshPartition
}

function Test-SccmFrontRecoveryLayout {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [Parameter(Mandatory)]$CandidateFrontRecovery,
        [Parameter(Mandatory)]$OsPartition
    )

    $parts = @(Get-Partition -DiskNumber $DiskNumber -ErrorAction Stop | Sort-Object PartitionNumber)
    if ($CandidateFrontRecovery.PartitionNumber -ne 1) { return $false }
    if ($CandidateFrontRecovery.Offset -ge $OsPartition.Offset) { return $false }

    $efi = $parts | Where-Object { $_.GptType -and $_.GptType.ToString().ToLowerInvariant() -eq $EfiGptType } | Select-Object -First 1
    $msr = $parts | Where-Object { $_.GptType -and $_.GptType.ToString().ToLowerInvariant() -eq $MsrGptType } | Select-Object -First 1

    return ($efi -and $msr -and $CandidateFrontRecovery.Offset -lt $efi.Offset -and $efi.Offset -lt $msr.Offset -and $msr.Offset -lt $OsPartition.Offset)
}

function Remove-OldFrontRecoveryBestEffort {
    param(
        [Parameter(Mandatory)][int]$DiskNumber,
        [AllowNull()]$OldFrontRecovery = $null,
        [Parameter(Mandatory)]$OsPartition,
        [Parameter(Mandatory)][int]$NewRecoveryPartitionNumber
    )

    # OldFrontRecovery is optional. Standard Windows GPT layouts normally have no front Recovery
    # partition, so a null value is an expected no-op rather than a parameter-binding failure.
    if (-not $OldFrontRecovery) {
        Write-Log 'No obsolete front Recovery partition requires cleanup.'
        return
    }
    if ($OldFrontRecovery.PartitionNumber -eq $NewRecoveryPartitionNumber) { return }
    if (-not (Test-SccmFrontRecoveryLayout -DiskNumber $DiskNumber -CandidateFrontRecovery $OldFrontRecovery -OsPartition $OsPartition)) {
        Write-Log "Old Recovery partition $($OldFrontRecovery.PartitionNumber) was not deleted because it does not match the known SCCM front-Recovery layout." 'WARN'
        return
    }

    try {
        Write-Log "New WinRE is healthy. Removing obsolete SCCM front Recovery partition $($OldFrontRecovery.PartitionNumber) as best-effort cleanup."
        Remove-RecoveryPartition -Partition $OldFrontRecovery
    }
    catch {
        Write-Log "Could not delete old front Recovery partition. New WinRE remains enabled; continuing. Error: $($_.Exception.Message)" 'WARN'
    }
}

try {
    Write-Log '=== Starting WinRE repair/repartition workflow ==='
    Write-Log "Log file: $LogFile"
    Write-Log "TargetRecoverySizeMB=$TargetRecoverySizeMB; MinimumRecoveryPartitionSizeMB=$MinimumRecoveryPartitionSizeMB; MinimumRecoveryFreeSpaceMB=$MinimumRecoveryFreeSpaceMB"

    if (-not (Test-IsAdministrator)) {
        Exit-WithCode -Code 1 -Message 'This script must run elevated or as Local System.'
    }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-Log "OS: $($os.Caption) $($os.Version), build $($os.BuildNumber); 64BitProcess=$([Environment]::Is64BitProcess); PowerShell=$($PSVersionTable.PSVersion)"

    $osDrive = $env:SystemDrive.TrimEnd(':')
    $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $disk = Get-Disk -Number $osPartition.DiskNumber -ErrorAction Stop
    if ($disk.PartitionStyle -ne 'GPT') {
        Exit-WithCode -Code 2 -Message 'Only GPT OS disks are supported by this enterprise repair script.'
    }

    Write-Log "OS Disk=$($disk.Number), Partition=$($osPartition.PartitionNumber), Size=$([math]::Round($osPartition.Size/1GB,2)) GB."
    foreach ($partition in @(Get-Partition -DiskNumber $disk.Number -ErrorAction Stop | Sort-Object Offset)) {
        Write-Log ("Partition {0}: Offset={1}, SizeMB={2}, Drive={3}, Type={4}, GptType={5}" -f `
            $partition.PartitionNumber, $partition.Offset, [math]::Round($partition.Size/1MB,0), $partition.DriveLetter, $partition.Type, $partition.GptType)
    }

    $TemporaryLetter = Get-SafeTemporaryDriveLetter
    Write-Log "Selected temporary Recovery drive letter: $TemporaryLetter`:"

    $winREState = Get-WinREState
    $recoveryPartitions = @(Get-RecoveryPartitions -DiskNumber $disk.Number)
    $registeredPartition = $null
    if ($null -ne $winREState.DiskNumber -and $null -ne $winREState.PartitionNumber -and $winREState.DiskNumber -eq $disk.Number) {
        try {
            $candidate = Get-Partition -DiskNumber $winREState.DiskNumber -PartitionNumber $winREState.PartitionNumber -ErrorAction Stop
            if (Test-IsRecoveryPartition -Partition $candidate) { $registeredPartition = $candidate }
        }
        catch {
            Write-Log "ReAgentC points to a partition that cannot be read: $($_.Exception.Message)" 'WARN'
        }
    }

    # If the currently registered partition is healthy and WinRE is enabled, no disk changes are needed.
    if ($registeredPartition -and $winREState.Enabled) {
        try {
            $health = Get-RecoveryPartitionHealth -Partition $registeredPartition -Letter $TemporaryLetter
            Write-Log "Registered Recovery health: Size=$($health.SizeMB) MB, Free=$($health.FreeMB) MB, WimValid=$($health.WimValid), Healthy=$($health.Healthy)."
            if ($health.Healthy) {
                # A stale persistent stage can remain after an interrupted run that nevertheless
                # completed WinRE registration. Once the registered partition itself validates,
                # that stage is no longer needed.
                Remove-Item -LiteralPath $StagedWinRE -Force -ErrorAction SilentlyContinue
                Exit-WithCode -Code 0 -Message 'SUCCESS: WinRE is enabled and the registered Recovery partition is healthy.'
            }
        }
        catch {
            Write-Log "Registered Recovery health validation could not be completed: $($_.Exception.Message)" 'ERROR'
            Exit-WithCode -Code 7 -Message 'WinRE is enabled and registered to a Recovery partition, but its health could not be validated. No destructive partition changes were attempted.'
        }
    }

    $staged = Stage-WinREImage -WinREState $winREState -OsDiskNumber $disk.Number -Letter $TemporaryLetter
    if (-not $staged) {
        Exit-WithCode -Code 4 -Message 'No valid Winre.wim could be located or recovered from the persistent staging directory.'
    }
    # Winre.wim normally carries Hidden/System attributes; -Force is required for reliable metadata reads in Windows PowerShell 5.1.
    $stagedWimSizeMB = [math]::Ceiling((Get-Item -LiteralPath $staged -Force -ErrorAction Stop).Length / 1MB)
    Write-Log "Staged Winre.wim size: $stagedWimSizeMB MB."

    # A previous partial run may already have created a sufficiently large trailing Recovery
    # partition but failed before copying/registering WinRE. Reuse it before considering repartitioning.
    $osEnd = $osPartition.Offset + $osPartition.Size
    $trailingCandidates = @($recoveryPartitions | Where-Object { $_.Offset -ge $osEnd } | Sort-Object Offset -Descending)
    foreach ($candidate in $trailingCandidates) {
        $candidateSizeMB = [math]::Floor($candidate.Size / 1MB)
        if ($candidateSizeMB -lt $MinimumRecoveryPartitionSizeMB) { continue }

        $reuseSucceeded = $false
        try {
            Write-Log "Attempting to reuse existing trailing Recovery partition $($candidate.PartitionNumber), size $candidateSizeMB MB."
            $reuseSucceeded = [bool](Invoke-ReAgentSetAndEnable -Partition $candidate -Letter $TemporaryLetter -SourceWinRE $staged)
        }
        catch {
            Write-Log "Existing trailing Recovery partition $($candidate.PartitionNumber) could not be reused: $($_.Exception.Message)" 'WARN'
            continue
        }

        if ($reuseSucceeded) {
            # Once WinRE is enabled, registered to this partition and health-validated, the reuse
            # operation is terminal success. Optional legacy-front-partition cleanup must never be
            # allowed to fall through into destructive repartitioning.
            try {
                $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
                $oldFront = $recoveryPartitions | Where-Object { $_.Offset -lt $osPartition.Offset } | Sort-Object Offset | Select-Object -First 1
                Remove-OldFrontRecoveryBestEffort -DiskNumber $disk.Number -OldFrontRecovery $oldFront -OsPartition $osPartition -NewRecoveryPartitionNumber $candidate.PartitionNumber
            }
            catch {
                Write-Log "Post-reuse legacy Recovery cleanup warning: $($_.Exception.Message)" 'WARN'
            }

            Remove-Item -LiteralPath $StagedWinRE -Force -ErrorAction SilentlyContinue
            Exit-WithCode -Code 0 -Message "SUCCESS: Existing trailing Recovery partition $($candidate.PartitionNumber) was repaired/re-registered and WinRE is enabled."
        }
    }

    # An adequately sized trailing Recovery partition is never deleted merely because a repair/reuse
    # attempt failed. That condition is ambiguous and therefore fails closed before BitLocker or disk changes.
    $currentOsForGate = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $currentDiskForGate = Get-Disk -Number $disk.Number -ErrorAction Stop
    $nextForGate = Get-PartitionImmediatelyAfterOS -Disk $currentDiskForGate -OsPartition $currentOsForGate
    if ($nextForGate -and (Test-IsRecoveryPartition -Partition $nextForGate)) {
        $nextForGateSizeMB = [math]::Floor($nextForGate.Size / 1MB)
        if ($nextForGateSizeMB -ge $MinimumRecoveryPartitionSizeMB) {
            Exit-WithCode -Code 7 -Message "An adequately sized Recovery partition ($nextForGateSizeMB MB) exists immediately after C: but could not be safely validated/reused. No destructive partition changes were attempted."
        }
    }

    if ((Test-PendingReboot) -and -not $IgnorePendingReboot) {
        Exit-WithCode -Code 3010 -Message 'A pending reboot was detected. Reboot before repartitioning WinRE, then rerun this script.'
    }

    # Repartitioning begins here. Capture a front Recovery candidate for post-success cleanup before
    # any partition numbers change.
    $oldFrontRecovery = $recoveryPartitions |
        Where-Object { $_.Offset -lt $osPartition.Offset } |
        Sort-Object Offset |
        Select-Object -First 1

    try {
        $BitLockerWasSuspendedByScript = Suspend-OSBitLocker
    }
    catch {
        Write-Log "BitLocker suspension failed: $($_.Exception.Message)" 'ERROR'
        Exit-WithCode -Code 3 -Message 'Unable to suspend BitLocker safely for partition maintenance.'
    }

    # Disable WinRE before changing its backing partition. Failure is tolerated only when ReAgentC
    # already reports it disabled; other errors are meaningful.
    $disableNative = Invoke-NativeCapture -FilePath 'reagentc.exe' -Arguments @('/disable')
    $disableCode = $disableNative.ExitCode
    $disableText = $disableNative.Text
    Write-Log $disableText
    Write-Log "reagentc /disable exit code: $disableCode"
    if ($disableCode -ne 0 -and $disableText -notmatch '(?i)already disabled') {
        throw 'reagentc /disable failed before repartitioning.'
    }

    Update-StorageView -DiskNumber $disk.Number
    $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $disk = Get-Disk -Number $disk.Number -ErrorAction Stop

    # If the partition directly after C: is an undersized Recovery partition, remove only that
    # Recovery partition. Non-Recovery partitions are never deleted by this script.
    $nextPartition = Get-PartitionImmediatelyAfterOS -Disk $disk -OsPartition $osPartition
    if ($nextPartition -and (Test-IsRecoveryPartition -Partition $nextPartition)) {
        $nextSizeMB = [math]::Floor($nextPartition.Size / 1MB)
        if ($nextSizeMB -lt $MinimumRecoveryPartitionSizeMB) {
            Write-Log "The partition immediately after C: is undersized Recovery partition $($nextPartition.PartitionNumber), size $nextSizeMB MB. It will be replaced."
            Remove-RecoveryPartition -Partition $nextPartition
            Update-StorageView -DiskNumber $disk.Number
            $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
            $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
        }
        else {
            Exit-WithCode -Code 7 -Message "Recovery partition $($nextPartition.PartitionNumber) is already $nextSizeMB MB. It will not be deleted automatically after a failed validation/reuse attempt."
        }
    }

    # Ensure the new partition is large enough for the staged WIM plus the configured free-space
    # reserve, even if that exceeds the nominal 2536 MB target.
    $minimumFromWimMB = $stagedWimSizeMB + $MinimumRecoveryFreeSpaceMB + 64
    $newRecoverySizeMB = [int][math]::Max($TargetRecoverySizeMB, $minimumFromWimMB)
    Write-Log "Calculated new Recovery partition size: $newRecoverySizeMB MB."

    Resize-OSForRecoveryGap -Disk $disk -OsPartition $osPartition -RequiredGapBytes ([int64]($newRecoverySizeMB * 1MB))

    $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $disk = Get-Disk -Number $disk.Number -ErrorAction Stop
    $newRecovery = New-RecoveryPartitionAfterOS -Disk $disk -OsPartition $osPartition -SizeMB $newRecoverySizeMB -Letter $TemporaryLetter
    $activeTemporaryLetter = if ($newRecovery.PSObject.Properties['TemporaryLetter']) { [string]$newRecovery.TemporaryLetter } else { $TemporaryLetter }

    $newWinREDirectory = "$activeTemporaryLetter`:\Recovery\WindowsRE"
    New-Item -Path $newWinREDirectory -ItemType Directory -Force | Out-Null
    $newWinREPath = Join-Path $newWinREDirectory 'Winre.wim'
    Copy-Item -LiteralPath $staged -Destination $newWinREPath -Force
    Write-Log "Copied staged Winre.wim to $newWinREPath."

    Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/setreimage','/path',$newWinREDirectory) -SuccessCodes @(0)
    Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/enable') -SuccessCodes @(0)

    $finalState = Get-WinREState
    if (-not $finalState.Enabled) {
        Exit-WithCode -Code 6 -Message 'WinRE did not report Enabled after the new Recovery partition was registered.'
    }
    if ($finalState.DiskNumber -ne $newRecovery.DiskNumber -or $finalState.PartitionNumber -ne $newRecovery.PartitionNumber) {
        Exit-WithCode -Code 6 -Message "WinRE registered to unexpected Disk/Partition $($finalState.DiskNumber)/$($finalState.PartitionNumber); expected $($newRecovery.DiskNumber)/$($newRecovery.PartitionNumber)."
    }

    # Remove the temporary access path before health validation through a fresh mount. This proves
    # that the Recovery partition remains usable after returning to its normal hidden state.
    try {
        Remove-PartitionAccessPath -DiskNumber $newRecovery.DiskNumber -PartitionNumber $newRecovery.PartitionNumber -AccessPath "$activeTemporaryLetter`:\" -ErrorAction Stop
    }
    catch {
        Write-Log "Could not remove temporary Recovery letter with Remove-PartitionAccessPath; using DiskPart. Error: $($_.Exception.Message)" 'WARN'
        Invoke-DiskPart -Lines @(
            "select disk $($newRecovery.DiskNumber)",
            "select partition $($newRecovery.PartitionNumber)",
            "remove letter=$activeTemporaryLetter noerr"
        )
    }

    $newRecovery = Get-Partition -DiskNumber $newRecovery.DiskNumber -PartitionNumber $newRecovery.PartitionNumber -ErrorAction Stop
    $validationLetter = Get-SafeTemporaryDriveLetter
    $finalHealth = Get-RecoveryPartitionHealth -Partition $newRecovery -Letter $validationLetter
    Write-Log "Final Recovery health: Size=$($finalHealth.SizeMB) MB, Free=$($finalHealth.FreeMB) MB, WimValid=$($finalHealth.WimValid), Healthy=$($finalHealth.Healthy)."
    if (-not $finalHealth.Healthy) {
        Exit-WithCode -Code 6 -Message 'The new Recovery partition failed final health validation.'
    }

    # The new WinRE has already passed final health validation. Cleanup of an obsolete front
    # Recovery partition is optional and must not turn a successful repair into a failed run.
    try {
        $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
        Remove-OldFrontRecoveryBestEffort -DiskNumber $disk.Number -OldFrontRecovery $oldFrontRecovery -OsPartition $osPartition -NewRecoveryPartitionNumber $newRecovery.PartitionNumber
    }
    catch {
        Write-Log "Post-rebuild legacy Recovery cleanup warning: $($_.Exception.Message)" 'WARN'
    }

    Remove-Item -LiteralPath $StagedWinRE -Force -ErrorAction SilentlyContinue
    Resume-OSBitLockerBestEffort
    Exit-WithCode -Code 0 -Message 'SUCCESS: WinRE partition repair/rebuild completed and WinRE is enabled.'
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    Write-Log ($_ | Out-String) 'ERROR'
    Resume-OSBitLockerBestEffort

    if ($_.Exception.Message -match 'DiskPart|Resize-Partition|partition|contiguous free extent|shrink') {
        Exit-WithCode -Code 5 -Message 'Partition operation failed. The persistent Winre.wim stage is retained so a rerun can continue.'
    }
    if ($_.Exception.Message -match '(?i)reagentc|registration|registered|setreimage|enable operation') {
        Exit-WithCode -Code 6 -Message 'WinRE registration or enable operation failed. A rerun will reassess the current disk state.'
    }

    Exit-WithCode -Code 1 -Message 'Generic failure. The workflow is designed to reassess and continue safely on the next run.'
}
finally {
    Resume-OSBitLockerBestEffort
}
