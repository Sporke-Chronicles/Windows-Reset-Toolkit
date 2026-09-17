<#
.SYNOPSIS
  Intune Remediations detection script for Windows Recovery Environment (WinRE) wipe readiness.

.DESCRIPTION
  Performs a non-destructive readiness assessment for the local prerequisites that Windows/Intune
  relies on when a full device wipe must transition into WinRE.

  The script does NOT invoke RemoteWipe and does NOT reset the device.

  It validates:
    - SYSTEM execution context (required for the MDM WMI Bridge device scope).
    - WinRE configuration using ReAgent.xml plus ReAgentC cross-checking.
    - Registered Recovery partition presence, type, file system, capacity and free-space reserve.
    - Presence and basic integrity of Winre.wim.
    - Ability to mount the registered WinRE image with ReAgentC.
    - Offline WinRE component-store health using DISM /CheckHealth.
    - Coverage of active third-party boot/storage-controller drivers inside WinRE.
    - Presence of the MDM_RemoteWipe WMI Bridge class, instance and doWipeMethod without invoking it.
    - BitLocker state for telemetry only; BitLocker being enabled is not itself an unhealthy result.

  Detection output is intentionally compact so it can be viewed/exported from Intune Remediations.

  Compatibility hardening:
  - Avoids a Windows PowerShell 5.1 Generic.List/array-subexpression runtime binder defect.
  - Releases the workflow mutex before telemetry finalization so reporting failures cannot strand it.
  - Recovers safely from an abandoned workflow mutex left by a terminated prior process.
  Full details are also written locally as JSON and log files.

  Exit 0 = WinRE is wipe-ready according to the checks performed.
  Exit 1 = One or more readiness requirements failed and remediation should run.

  IMPORTANT
  This validates local wipe prerequisites. It cannot guarantee a future remote wipe will be delivered:
  the device must still be powered, functional, enrolled, and able to receive an Intune/MDM command.

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
param(
    [ValidateRange(100,4096)]
    [int]$MinimumRecoveryFreeSpaceMB = 250,

    [ValidateRange(500,32768)]
    [int]$MinimumRecoveryPartitionSizeMB = 750,

    [ValidatePattern('^[A-Z]$')]
    [string]$PreferredRecoveryLetter = 'R',

    [bool]$PerformComponentStoreCheck = $true
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

# ---------------------------------------------------------------------------
# 64-bit process correction.
# Intune should be configured for 64-bit PowerShell, but self-correct if not.
# ---------------------------------------------------------------------------
if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
    $nativePowerShell = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
    if (Test-Path -LiteralPath $nativePowerShell) {
        & $nativePowerShell -NoLogo -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath `
            -MinimumRecoveryFreeSpaceMB $MinimumRecoveryFreeSpaceMB `
            -MinimumRecoveryPartitionSizeMB $MinimumRecoveryPartitionSizeMB `
            -PreferredRecoveryLetter $PreferredRecoveryLetter `
            -PerformComponentStoreCheck:$PerformComponentStoreCheck
        exit $LASTEXITCODE
    }
}

# ---------------------------------------------------------------------------
# Configuration and persistent telemetry paths.
# ---------------------------------------------------------------------------
$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$RecoveryMbrType = 39 # 0x27 - Windows Recovery / hidden NTFS on MBR systems.

$WorkingRoot = Join-Path $env:ProgramData 'WinREReadiness'
$MountDirectory = Join-Path $WorkingRoot 'WinREMount'
$DriverExportRoot = Join-Path $WorkingRoot 'DriverAudit'
$JsonPath = Join-Path $WorkingRoot 'WinRE-Readiness.json'
$StatePath = 'HKLM:\SOFTWARE\WinREReadiness'
$LogDirectory = Join-Path $env:ProgramData 'Microsoft\IntuneManagementExtension\Logs\WinREReadiness'
$LogFile = Join-Path $LogDirectory ('Detect-WinREReadiness-{0}.log' -f (Get-Date -Format 'yyyyMMdd-HHmmss'))

New-Item -Path $WorkingRoot -ItemType Directory -Force | Out-Null
New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

$script:IssueList = New-Object System.Collections.Generic.List[object]
$script:WarningList = New-Object System.Collections.Generic.List[object]
$script:WinREMounted = $false
$script:Mutex = $null
$script:MutexOwned = $false

$result = [ordered]@{
    SchemaVersion           = '1.0'
    AssessmentUtc           = (Get-Date).ToUniversalTime().ToString('o')
    Ready                   = $false
    HealthCode              = ''
    OSBuild                 = ''
    PartitionStyle          = ''
    WinREStatus             = 'Unknown'
    WinRELocation           = 'Unknown'
    RecoveryPartitionNumber = $null
    RecoverySizeMB          = $null
    RecoveryFreeMB          = $null
    RecoveryFileSystem      = ''
    WinREWimSizeMB          = $null
    WinREWimValid           = $false
    WinREMount              = 'NotTested'
    ComponentStore          = 'NotTested'
    DriverStatus            = 'NotTested'
    DriverRequired          = 0
    DriverPresent           = 0
    MissingDrivers          = @()
    MDMBridge               = 'Unknown'
    BitLocker               = 'Unknown'
    PendingReboot            = $false
    Issues                  = @()
    Warnings                = @()
}

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )
    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
}

function Add-Issue {
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][string]$Message)
    if (@($script:IssueList | Where-Object { $_.Code -eq $Code }).Count -eq 0) {
        [void]$script:IssueList.Add([pscustomobject]@{ Code = $Code; Message = $Message })
    }
    Write-Log "$Code - $Message" 'ERROR'
}

function Add-Warning {
    param([Parameter(Mandatory)][string]$Code,[Parameter(Mandatory)][string]$Message)
    if (@($script:WarningList | Where-Object { $_.Code -eq $Code }).Count -eq 0) {
        [void]$script:WarningList.Add([pscustomobject]@{ Code = $Code; Message = $Message })
    }
    Write-Log "$Code - $Message" 'WARN'
}

function Test-IsLocalSystem {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        return ($identity.User -and $identity.User.Value -eq 'S-1-5-18')
    }
    catch { return $false }
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

    $scriptPath = Join-Path $env:TEMP ('winre-readiness-diskpart-{0}.txt' -f ([guid]::NewGuid().Guid))
    try {
        $Lines | Out-File -LiteralPath $scriptPath -Encoding ascii -Force
        $output = & diskpart.exe /s $scriptPath 2>&1
        $code = $LASTEXITCODE
        $text = $output | Out-String
        if ($text.Trim()) { Write-Log $text }
        if ($code -ne 0 -or $text -match 'Virtual Disk Service error|DiskPart has encountered an error|The arguments specified for this command are not valid') {
            throw "DiskPart reported a failure (exit code $code)."
        }
    }
    finally { Remove-Item -LiteralPath $scriptPath -Force -ErrorAction SilentlyContinue }
}

function Get-WinREState {
    param([Parameter(Mandatory)][int]$OsDiskNumber)

    $reagentOutput = & reagentc.exe /info 2>&1
    $reagentCode = $LASTEXITCODE
    $reagentText = $reagentOutput | Out-String
    Write-Log "reagentc /info exit code: $reagentCode"
    Write-Log $reagentText

    $diskNumber = $null
    $partitionNumber = $null
    $enabledFromXml = $null
    $xmlLocationPath = ''
    $xmlPartitionGuid = ''
    $xmlOffset = $null
    $bcdId = ''

    # The GLOBALROOT device path is language-independent even when ReAgentC labels are localized.
    if ($reagentText -match '(?i)harddisk(\d+)\\partition(\d+)\\Recovery\\WindowsRE') {
        $diskNumber = [int]$matches[1]
        $partitionNumber = [int]$matches[2]
    }

    # ReAgent.xml provides language-independent structured state and location data.
    $xmlPath = Join-Path $env:WINDIR 'System32\Recovery\ReAgent.xml'
    if (Test-Path -LiteralPath $xmlPath) {
        try {
            [xml]$xml = Get-Content -LiteralPath $xmlPath -Raw -ErrorAction Stop
            $root = $xml.WindowsRE
            if ($root) {
                $installState = $null
                if ($root.InstallState -and $root.InstallState.state -ne $null) {
                    $installState = [int]$root.InstallState.state
                }
                if ($root.WinreLocation) {
                    $xmlLocationPath = [string]$root.WinreLocation.path
                    $xmlPartitionGuid = [string]$root.WinreLocation.guid
                    if ([string]$root.WinreLocation.offset -match '^\d+$') {
                        $xmlOffset = [int64]$root.WinreLocation.offset
                    }
                }
                if ($root.WinreBCD) { $bcdId = [string]$root.WinreBCD.id }

                $zeroGuid = '{00000000-0000-0000-0000-000000000000}'
                $enabledFromXml = (
                    $installState -eq 1 -and
                    -not [string]::IsNullOrWhiteSpace($xmlLocationPath) -and
                    -not [string]::IsNullOrWhiteSpace($bcdId) -and
                    $bcdId -ne $zeroGuid
                )
            }
        }
        catch {
            Add-Warning -Code 'REW001' -Message "ReAgent.xml could not be parsed: $($_.Exception.Message)"
        }
    }
    else {
        Add-Warning -Code 'REW002' -Message 'ReAgent.xml was not found; falling back to ReAgentC output.'
    }

    # If the output did not expose disk/partition numbers, resolve the ReAgent.xml location against
    # partition GUID or offset on the OS disk.
    if ($null -eq $partitionNumber) {
        try {
            $parts = @(Get-Partition -DiskNumber $OsDiskNumber -ErrorAction Stop)
            $candidate = $null
            if (-not [string]::IsNullOrWhiteSpace($xmlPartitionGuid) -and $xmlPartitionGuid -ne '{00000000-0000-0000-0000-000000000000}') {
                $candidate = $parts | Where-Object {
                    $_.Guid -and $_.Guid.ToString().Trim('{}').ToLowerInvariant() -eq $xmlPartitionGuid.Trim('{}').ToLowerInvariant()
                } | Select-Object -First 1
            }
            if (-not $candidate -and $null -ne $xmlOffset) {
                $candidate = $parts | Where-Object { [int64]$_.Offset -eq [int64]$xmlOffset } | Select-Object -First 1
            }
            if ($candidate) {
                $diskNumber = $candidate.DiskNumber
                $partitionNumber = $candidate.PartitionNumber
            }
        }
        catch {
            Write-Log "Unable to resolve ReAgent.xml location against OS partitions: $($_.Exception.Message)" 'WARN'
        }
    }

    # English output remains a useful fallback, but XML is preferred when available.
    $enabled = $false
    if ($null -ne $enabledFromXml) {
        $enabled = [bool]$enabledFromXml
    }
    elseif ($reagentText -match '(?i)Windows RE status:\s+Enabled') {
        $enabled = $true
    }

    return [pscustomobject]@{
        Enabled = $enabled
        ReAgentExitCode = $reagentCode
        DiskNumber = $diskNumber
        PartitionNumber = $partitionNumber
        XmlLocationPath = $xmlLocationPath
        XmlPartitionGuid = $xmlPartitionGuid
        XmlOffset = $xmlOffset
        BcdId = $bcdId
        Text = $reagentText
    }
}

function Test-IsRecoveryPartition {
    param([Parameter(Mandatory)]$Partition,[Parameter(Mandatory)]$Disk)

    if ($Disk.PartitionStyle -eq 'GPT') {
        return ($Partition.GptType -and $Partition.GptType.ToString().ToLowerInvariant() -eq $RecoveryGptType)
    }
    if ($Disk.PartitionStyle -eq 'MBR') {
        try { return ([int]$Partition.MbrType -eq $RecoveryMbrType -or $Partition.Type -eq 'Recovery') }
        catch { return ($Partition.Type -eq 'Recovery') }
    }
    return $false
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
    param([Parameter(Mandatory)]$Partition,[Parameter(Mandatory)][string]$Letter,[Parameter(Mandatory)][bool]$Added)
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
        catch { Write-Log "Could not remove temporary Recovery access path $Letter`: $($_.Exception.Message)" 'WARN' }
    }
}

function Test-WimFile {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return $false }
    try {
        [void](Invoke-Native -FilePath 'dism.exe' -Arguments @('/English','/Get-WimInfo',"/WimFile:$Path",'/Index:1') -ReturnOutput)
        return $true
    }
    catch {
        Write-Log "WIM validation failed for ${Path}: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

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
        Write-Log ("Active third-party storage driver: Device='{0}', Provider='{1}', Inf='{2}', Version='{3}'" -f $driver.DeviceName,$driver.DriverProviderName,$driver.InfName,$driver.DriverVersion)
    }
    return $drivers
}

function Export-StorageDriverPackagesForAudit {
    param([Parameter(Mandatory)][object[]]$Drivers)

    if (Test-Path -LiteralPath $DriverExportRoot) { Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue }
    New-Item -Path $DriverExportRoot -ItemType Directory -Force | Out-Null
    $packages = New-Object System.Collections.Generic.List[object]

    foreach ($driver in $Drivers) {
        $safeInf = ($driver.InfName -replace '[^A-Za-z0-9_.-]','_')
        $target = Join-Path $DriverExportRoot ([IO.Path]::GetFileNameWithoutExtension($safeInf))
        New-Item -Path $target -ItemType Directory -Force | Out-Null
        try {
            Invoke-Native -FilePath 'pnputil.exe' -Arguments @('/export-driver',$driver.InfName,$target)
            $infs = @(Get-ChildItem -LiteralPath $target -Filter '*.inf' -File -Recurse -ErrorAction Stop)
            if ($infs.Count -eq 0) { throw 'No INF was exported.' }
            [void]$packages.Add([pscustomobject]@{
                DeviceName = [string]$driver.DeviceName
                PublishedInf = [string]$driver.InfName
                LiveVersion = [string]$driver.DriverVersion
                OriginalInfNames = @($infs | ForEach-Object { $_.Name.ToLowerInvariant() } | Select-Object -Unique)
            })
        }
        catch {
            Add-Issue -Code 'DRV001' -Message "Active storage driver $($driver.InfName) could not be exported for verification."
        }
    }
    # Windows PowerShell 5.1 can throw 'Argument types do not match' when @() wraps a Generic.List directly.
    return $packages.ToArray()
}

function Cleanup-StaleWinREMount {
    if (-not (Test-Path -LiteralPath $MountDirectory)) {
        New-Item -Path $MountDirectory -ItemType Directory -Force | Out-Null
        return
    }

    if (@(Get-ChildItem -LiteralPath $MountDirectory -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Log 'Dedicated WinRE mount directory is not empty; attempting targeted stale-mount cleanup.' 'WARN'
        try { Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/unmountre','/path',$MountDirectory,'/discard') }
        catch {
            try { Invoke-Native -FilePath 'dism.exe' -Arguments @('/Unmount-Image',"/MountDir:$MountDirectory",'/Discard') -SuccessCodes @(0,2,50) }
            catch { Add-Warning -Code 'MNTW001' -Message 'A stale WinRE mount could not be cleanly discarded.' }
        }
        try { Invoke-Native -FilePath 'dism.exe' -Arguments @('/Cleanup-Wim') -SuccessCodes @(0,2) } catch {}
        Remove-Item -LiteralPath $MountDirectory -Recurse -Force -ErrorAction SilentlyContinue
        New-Item -Path $MountDirectory -ItemType Directory -Force | Out-Null
    }
}

function Mount-RegisteredWinREForAudit {
    Cleanup-StaleWinREMount
    Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/mountre','/path',$MountDirectory)
    $script:WinREMounted = $true
}

function Unmount-RegisteredWinREForAudit {
    if (-not $script:WinREMounted) { return }
    try { Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/unmountre','/path',$MountDirectory,'/discard') }
    catch {
        try { Invoke-Native -FilePath 'dism.exe' -Arguments @('/Unmount-Image',"/MountDir:$MountDirectory",'/Discard') -SuccessCodes @(0,2,50) }
        catch { Write-Log "Unable to discard WinRE audit mount: $($_.Exception.Message)" 'WARN' }
    }
    $script:WinREMounted = $false
    Remove-Item -LiteralPath $MountDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

function Convert-ToVersionSafe {
    param([string]$Value)
    try { return [version]$Value } catch { return [version]'0.0.0.0' }
}

function Test-PackagePresentInWinRE {
    param([Parameter(Mandatory)]$Package,[Parameter(Mandatory)][object[]]$OfflineDrivers)

    $liveVersion = Convert-ToVersionSafe $Package.LiveVersion
    foreach ($offline in $OfflineDrivers) {
        if (-not $offline.OriginalFileName) { continue }
        $original = [IO.Path]::GetFileName([string]$offline.OriginalFileName).ToLowerInvariant()
        if ($Package.OriginalInfNames -notcontains $original) { continue }
        $offlineVersion = Convert-ToVersionSafe ([string]$offline.Version)
        Write-Log "Driver comparison: $original WinRE=$offlineVersion ActiveOS=$liveVersion"
        if ($offlineVersion -ge $liveVersion) { return $true }
    }
    return $false
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

function Test-MDMRemoteWipeBridge {
    try {
        $namespace = 'root\cimv2\mdm\dmmap'
        $class = Get-CimClass -Namespace $namespace -ClassName 'MDM_RemoteWipe' -ErrorAction Stop
        if ($null -eq $class.CimClassMethods['doWipeMethod']) {
            Add-Issue -Code 'MDM002' -Message 'MDM_RemoteWipe exists but doWipeMethod is not exposed.'
            return 'MethodMissing'
        }
        $instance = Get-CimInstance -Namespace $namespace -ClassName 'MDM_RemoteWipe' -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" -ErrorAction Stop
        if (-not $instance) {
            Add-Issue -Code 'MDM001' -Message 'MDM_RemoteWipe instance is not available in the device-scoped WMI Bridge.'
            return 'InstanceMissing'
        }
        return 'OK'
    }
    catch {
        Add-Issue -Code 'MDM001' -Message "MDM_RemoteWipe WMI Bridge validation failed: $($_.Exception.Message)"
        return 'Unavailable'
    }
}

function Get-BitLockerTelemetry {
    try {
        if (Get-Command Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            $bl = Get-BitLockerVolume -MountPoint $env:SystemDrive -ErrorAction Stop
            return ('{0}/{1}' -f $bl.VolumeStatus,$bl.ProtectionStatus)
        }
        $text = (& manage-bde.exe -status $env:SystemDrive 2>&1 | Out-String)
        if ($text -match 'Protection Status:\s+Protection On') { return 'ProtectionOn' }
        if ($text -match 'Protection Status:\s+Protection Off') { return 'ProtectionOff' }
        return 'Unknown'
    }
    catch {
        Add-Warning -Code 'BLW001' -Message 'BitLocker state could not be read for telemetry.'
        return 'Unknown'
    }
}

function Save-Assessment {
    # Avoid the Windows PowerShell 5.1 Generic.List + array-subexpression binder bug.
    $result.Issues = [object[]]$script:IssueList.ToArray()
    $result.Warnings = [object[]]$script:WarningList.ToArray()
    $result.Ready = ($script:IssueList.Count -eq 0)
    $result.HealthCode = if ($result.Ready) { 'H000' } else { (@($script:IssueList | ForEach-Object { $_.Code }) -join ',') }

    try {
        $result | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $JsonPath -Encoding UTF8 -Force
    }
    catch { Write-Log "Unable to write JSON telemetry: $($_.Exception.Message)" 'WARN' }

    try {
        New-Item -Path $StatePath -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'LastAssessmentUtc' -PropertyType String -Value $result.AssessmentUtc -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'Ready' -PropertyType DWord -Value ([int]$result.Ready) -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'HealthCode' -PropertyType String -Value $result.HealthCode -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'WinREStatus' -PropertyType String -Value ([string]$result.WinREStatus) -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'DriverStatus' -PropertyType String -Value ([string]$result.DriverStatus) -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'MDMBridge' -PropertyType String -Value ([string]$result.MDMBridge) -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'RecoverySizeMB' -PropertyType String -Value ([string]$result.RecoverySizeMB) -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'RecoveryFreeMB' -PropertyType String -Value ([string]$result.RecoveryFreeMB) -Force | Out-Null
        New-ItemProperty -Path $StatePath -Name 'MissingDrivers' -PropertyType String -Value ((@($result.MissingDrivers) -join '|')) -Force | Out-Null
    }
    catch { Write-Log "Unable to write registry telemetry: $($_.Exception.Message)" 'WARN' }
}

function Write-CompactResult {
    $part = if ($null -ne $result.RecoverySizeMB) { "$($result.RecoverySizeMB)MB/$($result.RecoveryFreeMB)MBfree" } else { 'Unknown' }
    $drivers = "$($result.DriverStatus)($($result.DriverPresent)/$($result.DriverRequired))"
    $issues = if ($script:IssueList.Count -eq 0) { 'H000' } else { (@($script:IssueList | ForEach-Object { $_.Code }) -join ',') }
    $text = "Ready=$($result.Ready);Code=$issues;WinRE=$($result.WinREStatus);Part=$part;WIM=$($result.WinREWimValid);Mount=$($result.WinREMount);Component=$($result.ComponentStore);Drivers=$drivers;MDM=$($result.MDMBridge);BL=$($result.BitLocker);Reboot=$($result.PendingReboot)"
    if (@($result.MissingDrivers).Count -gt 0) { $text += ';Missing=' + (@($result.MissingDrivers) -join '|') }
    if ($text.Length -gt 1900) { $text = $text.Substring(0,1900) }
    Write-Output $text
}

try {
    Write-Log '=== Starting WinRE wipe-readiness detection ==='

    $script:Mutex = New-Object System.Threading.Mutex($false,'Global\WinREReadinessWorkflow')
    $acquired = $false
    try {
        $acquired = $script:Mutex.WaitOne([TimeSpan]::FromSeconds(60),$false)
    }
    catch [System.Threading.AbandonedMutexException] {
        # The prior owner terminated without releasing the mutex. Windows grants ownership to this
        # thread when AbandonedMutexException is raised, so it is safe to continue after recording it.
        $acquired = $true
        Add-Warning -Code 'CTXW001' -Message 'A previous WinRE readiness process abandoned the workflow mutex; ownership was recovered.'
    }
    if (-not $acquired) {
        Add-Issue -Code 'CTX002' -Message 'Another WinRE readiness workflow is already running.'
        throw 'Could not obtain WinRE readiness workflow lock.'
    }
    $script:MutexOwned = $true

    if (-not (Test-IsLocalSystem)) {
        Add-Issue -Code 'CTX001' -Message 'Detection must run as Local System for device-scoped MDM WMI Bridge validation.'
        throw 'Incorrect Intune execution context.'
    }

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    $result.OSBuild = [string]$os.BuildNumber
    if ([int]$os.ProductType -ne 1) { Add-Issue -Code 'OS001' -Message 'Windows Server is not supported by this readiness package.' }

    $osDrive = $env:SystemDrive.TrimEnd(':')
    $osPartition = Get-Partition -DriveLetter $osDrive -ErrorAction Stop
    $disk = Get-Disk -Number $osPartition.DiskNumber -ErrorAction Stop
    $result.PartitionStyle = [string]$disk.PartitionStyle

    $winre = Get-WinREState -OsDiskNumber $disk.Number
    $result.WinREStatus = if ($winre.Enabled) { 'Enabled' } else { 'Disabled' }
    if ($winre.ReAgentExitCode -ne 0) { Add-Issue -Code 'RE001' -Message "ReAgentC /info returned exit code $($winre.ReAgentExitCode)." }
    if (-not $winre.Enabled) { Add-Issue -Code 'RE002' -Message 'WinRE is not enabled according to ReAgent state.' }
    if ($null -eq $winre.DiskNumber -or $null -eq $winre.PartitionNumber) {
        Add-Issue -Code 'RE003' -Message 'The registered WinRE partition could not be resolved.'
    }

    $registeredPartition = $null
    if ($null -ne $winre.DiskNumber -and $null -ne $winre.PartitionNumber) {
        $result.WinRELocation = "Disk$($winre.DiskNumber)/Part$($winre.PartitionNumber)"
        try {
            $registeredPartition = Get-Partition -DiskNumber $winre.DiskNumber -PartitionNumber $winre.PartitionNumber -ErrorAction Stop
            $result.RecoveryPartitionNumber = $registeredPartition.PartitionNumber
        }
        catch { Add-Issue -Code 'PART001' -Message 'The partition registered for WinRE does not exist.' }
    }

    if ($registeredPartition) {
        if ($registeredPartition.DiskNumber -ne $disk.Number) {
            Add-Issue -Code 'PART002' -Message 'WinRE is registered on a different disk from the Windows OS partition.'
        }
        if (-not (Test-IsRecoveryPartition -Partition $registeredPartition -Disk $disk)) {
            Add-Issue -Code 'PART003' -Message 'The registered WinRE partition is not marked as a Windows Recovery partition.'
        }
        if ($disk.PartitionStyle -eq 'GPT' -and -not $registeredPartition.NoDefaultDriveLetter) {
            Add-Warning -Code 'PARTW001' -Message 'The Recovery partition does not have NoDefaultDriveLetter set.'
        }
        if ($registeredPartition.DriveLetter) {
            Add-Warning -Code 'PARTW002' -Message "The Recovery partition has drive letter $($registeredPartition.DriveLetter): assigned."
        }

        $access = $null
        try {
            $letter = Get-SafeTemporaryDriveLetter
            $access = Add-TemporaryRecoveryAccessPath -Partition $registeredPartition -Letter $letter
            $volume = Get-Volume -DriveLetter $access.Letter -ErrorAction Stop
            $result.RecoverySizeMB = [math]::Floor($registeredPartition.Size / 1MB)
            $result.RecoveryFreeMB = [math]::Floor($volume.SizeRemaining / 1MB)
            $result.RecoveryFileSystem = [string]$volume.FileSystem

            if ($volume.FileSystem -ne 'NTFS') { Add-Issue -Code 'PART004' -Message "Recovery file system is '$($volume.FileSystem)', expected NTFS." }
            if ($result.RecoverySizeMB -lt $MinimumRecoveryPartitionSizeMB) { Add-Issue -Code 'PART005' -Message "Recovery partition is smaller than the configured $MinimumRecoveryPartitionSizeMB MB floor." }
            if ($result.RecoveryFreeMB -lt $MinimumRecoveryFreeSpaceMB) { Add-Issue -Code 'PART006' -Message "Recovery partition has less than $MinimumRecoveryFreeSpaceMB MB free space." }

            $winreWim = "$($access.Letter):\Recovery\WindowsRE\Winre.wim"
            if (-not (Test-Path -LiteralPath $winreWim)) {
                Add-Issue -Code 'WIM001' -Message 'Winre.wim is missing from the registered Recovery partition.'
            }
            else {
                # Winre.wim normally carries Hidden/System attributes; use -Force for reliable metadata reads.
                $result.WinREWimSizeMB = [math]::Ceiling((Get-Item -LiteralPath $winreWim -Force -ErrorAction Stop).Length / 1MB)
                $result.WinREWimValid = Test-WimFile -Path $winreWim
                if (-not $result.WinREWimValid) { Add-Issue -Code 'WIM002' -Message 'Winre.wim exists but DISM could not read index 1.' }
                if ($result.RecoverySizeMB -lt ($result.WinREWimSizeMB + $MinimumRecoveryFreeSpaceMB)) {
                    Add-Issue -Code 'PART007' -Message 'Recovery partition is smaller than Winre.wim plus the required servicing reserve.'
                }
            }
        }
        catch { Add-Issue -Code 'PART008' -Message "Recovery partition inspection failed: $($_.Exception.Message)" }
        finally {
            if ($access) { Remove-TemporaryRecoveryAccessPath -Partition $registeredPartition -Letter $access.Letter -Added $access.Added }
        }
    }

    $result.MDMBridge = Test-MDMRemoteWipeBridge
    $result.BitLocker = Get-BitLockerTelemetry
    $result.PendingReboot = Test-PendingReboot
    if ($result.PendingReboot) {
        Add-Warning -Code 'SYSW001' -Message 'A pending reboot is present. If repartitioning is required, remediation will wait for a reboot rather than force one.'
    }

    # Deep validation only makes sense if WinRE is currently enabled and a readable WIM was found.
    if ($winre.Enabled -and $registeredPartition -and $result.WinREWimValid) {
        $activeDrivers = @()
        $packages = @()
        try {
            $activeDrivers = @(Get-ActiveThirdPartyStorageDrivers)
            $result.DriverRequired = $activeDrivers.Count
            if ($activeDrivers.Count -gt 0) {
                $packages = @(Export-StorageDriverPackagesForAudit -Drivers $activeDrivers)
            }

            Mount-RegisteredWinREForAudit
            $result.WinREMount = 'OK'

            if ($PerformComponentStoreCheck) {
                try {
                    $component = Invoke-Native -FilePath 'dism.exe' -Arguments @('/English',"/Image:$MountDirectory",'/Cleanup-Image','/CheckHealth') -ReturnOutput
                    if ($component -match '(?i)No component store corruption detected') {
                        $result.ComponentStore = 'OK'
                    }
                    elseif ($component -match '(?i)component store.*repairable|component store corruption|cannot be repaired') {
                        $result.ComponentStore = 'Corrupt'
                        Add-Issue -Code 'WIM004' -Message 'DISM reports component-store corruption in WinRE.'
                    }
                    else {
                        $result.ComponentStore = 'Unknown'
                        Add-Issue -Code 'WIM005' -Message 'WinRE mounted, but DISM component health could not be conclusively interpreted.'
                    }
                }
                catch {
                    $result.ComponentStore = 'Failed'
                    Add-Issue -Code 'WIM004' -Message "WinRE component health check failed: $($_.Exception.Message)"
                }
            }
            else { $result.ComponentStore = 'Skipped' }

            if ($activeDrivers.Count -eq 0) {
                $result.DriverStatus = 'InboxOrNA'
                $result.DriverPresent = 0
            }
            else {
                if ($packages.Count -lt $activeDrivers.Count) {
                    Add-Issue -Code 'DRV001' -Message 'One or more active third-party storage driver packages could not be exported for validation.'
                }

                if (-not (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue)) {
                    $result.DriverStatus = 'Unknown'
                    Add-Issue -Code 'DRV003' -Message 'Get-WindowsDriver is unavailable, so WinRE storage-driver coverage cannot be verified.'
                }
                else {
                    $offlineDrivers = @(Get-WindowsDriver -Path $MountDirectory -All -ErrorAction Stop)
                    if ($offlineDrivers.Count -eq 0) {
                        $result.DriverStatus = 'Unknown'
                        Add-Issue -Code 'DRV003' -Message 'No offline driver inventory could be read from mounted WinRE.'
                    }
                    else {
                        $presentCount = 0
                        $missing = New-Object System.Collections.Generic.List[string]
                        foreach ($package in $packages) {
                            if (Test-PackagePresentInWinRE -Package $package -OfflineDrivers $offlineDrivers) {
                                $presentCount++
                            }
                            else {
                                [void]$missing.Add($package.PublishedInf)
                            }
                        }
                        $result.DriverPresent = $presentCount
                        $result.MissingDrivers = [string[]]$missing.ToArray()
                        if ($missing.Count -gt 0) {
                            $result.DriverStatus = 'Missing'
                            Add-Issue -Code 'DRV002' -Message "WinRE is missing or has an older version of $($missing.Count) required storage driver package(s)."
                        }
                        elseif ($packages.Count -eq $activeDrivers.Count) {
                            $result.DriverStatus = 'OK'
                        }
                    }
                }
            }
        }
        catch {
            $result.WinREMount = if ($script:WinREMounted) { 'OK' } else { 'Failed' }
            Add-Issue -Code 'WIM003' -Message "Registered WinRE could not complete deep mount/driver validation: $($_.Exception.Message)"
        }
        finally {
            try { Unmount-RegisteredWinREForAudit } catch {}
            Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    else {
        if ($result.WinREMount -eq 'NotTested') { $result.WinREMount = 'Blocked' }
        if ($result.DriverStatus -eq 'NotTested') { $result.DriverStatus = 'Blocked' }
    }
}
catch {
    Write-Log "Unhandled detection error: $($_.Exception.Message)" 'ERROR'
    if ($script:IssueList.Count -eq 0) {
        Add-Issue -Code 'DET999' -Message 'An unexpected error prevented a complete readiness assessment.'
    }
}
finally {
    try { Unmount-RegisteredWinREForAudit } catch {}
    Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue

    # Release the workflow lock before telemetry/output work. A reporting failure must never leave a
    # long-lived PowerShell host holding the machine-wide mutex and blocking subsequent SYSTEM runs.
    if ($script:Mutex) {
        if ($script:MutexOwned) {
            try { $script:Mutex.ReleaseMutex() } catch { Write-Log "Unable to release workflow mutex: $($_.Exception.Message)" 'WARN' }
        }
        try { $script:Mutex.Dispose() } catch {}
        $script:Mutex = $null
        $script:MutexOwned = $false
    }

    try { Save-Assessment }
    catch { Write-Log "Assessment telemetry finalization failed: $($_.Exception.Message)" 'ERROR' }

    try { Write-CompactResult }
    catch { Write-Output "Ready=False;Code=DET999;OutputError=$($_.Exception.Message)" }
}

if ($result.Ready) { exit 0 }
exit 1
