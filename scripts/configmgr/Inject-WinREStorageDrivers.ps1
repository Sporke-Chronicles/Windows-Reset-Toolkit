<#
.SYNOPSIS
  Injects active third-party boot/storage-controller drivers into the registered Windows Recovery Environment.

.DESCRIPTION
  Designed for SCCM/ConfigMgr task-sequence use after the WinRE partition repair step.

  Storage-driver readiness model:
  - Detects active third-party storage-controller drivers instead of relying only on product-name
    keywords. This covers Intel RST/VMD, AMD RAID and vendor NVMe/storage drivers while avoiding
    unnecessary injection of Microsoft inbox drivers that WinRE already contains.
  - Uses Microsoft's ReAgentC /mountre and /unmountre workflow to service the registered WinRE image
    on a running PC, avoiding manual Recovery-partition drive-letter management for normal servicing.
  - Compares exported INF names and driver versions with the drivers already present in WinRE when
    Get-WindowsDriver is available, so reruns can skip packages that are already present at the same
    or a newer version.
  - Creates an exact Winre.wim backup before servicing and retains only a small rolling set.
  - Cleans a stale dedicated mount directory before use and discards the mount if servicing fails.
  - After commit, cycles ReAgentC disable/enable and verifies WinRE is enabled, matching Microsoft's
    guidance for a serviced WinRE image on BitLocker/device-encrypted PCs.

.PARAMETER ForceInject
  Includes matching storage devices even when the driver provider is Microsoft. Exporting inbox
  Microsoft drivers may not be possible with PnPUtil, so this switch is intended for troubleshooting.

.PARAMETER MountDirectory
  Dedicated directory used by ReAgentC /mountre.

.PARAMETER DriverExportRoot
  Temporary directory used to export active driver packages.

.PARAMETER PreferredRecoveryLetter
  Temporary letter used only to back up the registered Winre.wim before servicing.

.RETURN CODES
  0 = Success, no third-party injection required, or required drivers already present.
  1 = Generic failure.
  2 = Registered WinRE image/partition could not be located.
  3 = Required active storage drivers could not be exported.
  4 = WinRE mount/driver servicing/commit failed.
  5 = ReAgentC post-service validation failed.

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Microsoft WinRE servicing guidance:
  https://learn.microsoft.com/windows-hardware/manufacture/desktop/add-update-to-winre
#>

[CmdletBinding()]
param(
    [switch]$ForceInject,
    [string]$MountDirectory = 'C:\Windows\Temp\CarveOut-WinREMount',
    [string]$DriverExportRoot = 'C:\Windows\Temp\CarveOut-WinREStorageDrivers',
    [ValidatePattern('^[A-Z]$')]
    [string]$PreferredRecoveryLetter = 'R'
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
            '-MountDirectory',('"{0}"' -f $MountDirectory),
            '-DriverExportRoot',('"{0}"' -f $DriverExportRoot),
            '-PreferredRecoveryLetter',$PreferredRecoveryLetter
        )
        if ($ForceInject) { $arguments += '-ForceInject' }

        $process = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
}

Restart-In64BitPowerShellIfRequired

$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'
$LogDirectory = Join-Path $env:WINDIR 'Logs\WinRE'
$LogFile = Join-Path $LogDirectory ("Inject-WinRE-StorageDrivers-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$BackupDirectory = Join-Path $LogDirectory 'Backups'
$WinREMounted = $false

New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null
New-Item -Path $BackupDirectory -ItemType Directory -Force | Out-Null

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
        $level = if ($Code -eq 0) { 'INFO' } else { 'ERROR' }
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

function Get-WinREState {
    $output = & reagentc.exe /info 2>&1
    $code = $LASTEXITCODE
    $text = $output | Out-String
    Write-Log "reagentc /info exit code: $code"
    Write-Log $text

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

function Add-TemporaryAccessPath {
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

function Remove-TemporaryAccessPath {
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
        Write-Log "Failed to remove temporary Recovery access path $Letter`: $($_.Exception.Message)" 'WARN'
    }
}

function Backup-RegisteredWinRE {
    param([Parameter(Mandatory)]$WinREState)

    if ($null -eq $WinREState.DiskNumber -or $null -eq $WinREState.PartitionNumber) {
        throw 'ReAgentC does not expose a registered WinRE disk/partition.'
    }

    $partition = Get-Partition -DiskNumber $WinREState.DiskNumber -PartitionNumber $WinREState.PartitionNumber -ErrorAction Stop
    if (-not (Test-IsRecoveryPartition -Partition $partition)) {
        throw 'The registered WinRE location is not a Recovery partition.'
    }

    $letter = Get-SafeTemporaryDriveLetter
    $access = $null
    try {
        $access = Add-TemporaryAccessPath -Partition $partition -Letter $letter
        $source = "$($access.Letter):\Recovery\WindowsRE\Winre.wim"
        if (-not (Test-Path -LiteralPath $source)) {
            throw "Winre.wim was not found at the registered Recovery location $source."
        }

        $backupPath = Join-Path $BackupDirectory ("Winre.wim.bak-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        Copy-Item -LiteralPath $source -Destination $backupPath -Force
        Write-Log "Backed up registered Winre.wim to $backupPath."

        # Keep the most recent three backups to avoid unbounded disk use over repeated remediation runs.
        Get-ChildItem -Path $BackupDirectory -Filter 'Winre.wim.bak-*' -File -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -Skip 3 |
            Remove-Item -Force -ErrorAction SilentlyContinue

        return $backupPath
    }
    finally {
        if ($access) {
            Remove-TemporaryAccessPath -Partition $partition -Letter $access.Letter -Added $access.Added
        }
    }
}

function Get-ActiveStorageDrivers {
    Write-Log 'Enumerating active storage-controller driver packages.'

    $allDrivers = @(Get-CimInstance Win32_PnPSignedDriver -ErrorAction Stop | Where-Object {
        $_.InfName -and (
            $_.DeviceClass -in @('SCSIAdapter','HDC') -or
            ($_.DeviceClass -eq 'System' -and $_.DeviceName -match '(?i)VMD|Volume Management Device')
        ) -and (
            $_.DeviceName -match '(?i)RAID|RST|Rapid Storage|VMD|Volume Management Device|SATA|AHCI|NVMe|Storage|Controller|iaStor' -or
            $_.InfName -match '(?i)iaStor|vmd|rst|raid|nvme|sata'
        )
    })

    foreach ($driver in $allDrivers) {
        Write-Log ("Storage candidate: Device='{0}', Class='{1}', Provider='{2}', Inf='{3}', Version='{4}'" -f `
            $driver.DeviceName, $driver.DeviceClass, $driver.DriverProviderName, $driver.InfName, $driver.DriverVersion)
    }

    $selected = @($allDrivers | Where-Object {
        $ForceInject -or ($_.DriverProviderName -and $_.DriverProviderName -notmatch '(?i)^Microsoft')
    } | Sort-Object InfName -Unique)

    foreach ($driver in $selected) {
        Write-Log "Selected active storage package: $($driver.InfName) ($($driver.DriverProviderName) $($driver.DriverVersion))."
    }

    return $selected
}

function Export-StorageDriverPackages {
    param([Parameter(Mandatory)][object[]]$Drivers)

    if (Test-Path -LiteralPath $DriverExportRoot) {
        Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
    New-Item -Path $DriverExportRoot -ItemType Directory -Force | Out-Null

    $packages = New-Object System.Collections.Generic.List[object]

    foreach ($driver in $Drivers) {
        $safeInf = ($driver.InfName -replace '[^A-Za-z0-9_.-]', '_')
        $target = Join-Path $DriverExportRoot ([IO.Path]::GetFileNameWithoutExtension($safeInf))
        New-Item -Path $target -ItemType Directory -Force | Out-Null

        try {
            Invoke-Native -FilePath 'pnputil.exe' -Arguments @('/export-driver',$driver.InfName,$target) -SuccessCodes @(0)
            $infFiles = @(Get-ChildItem -LiteralPath $target -Filter '*.inf' -File -Recurse -ErrorAction Stop)
            if ($infFiles.Count -eq 0) {
                throw 'PnPUtil returned success but no INF file was exported.'
            }

            [void]$packages.Add([pscustomobject]@{
                LiveInf = $driver.InfName
                LiveVersion = $driver.DriverVersion
                Provider = $driver.DriverProviderName
                DeviceName = $driver.DeviceName
                ExportPath = $target
                OriginalInfNames = @($infFiles | ForEach-Object { $_.Name.ToLowerInvariant() } | Select-Object -Unique)
            })
        }
        catch {
            Write-Log "Unable to export $($driver.InfName): $($_.Exception.Message)" 'WARN'
        }
    }

    # Avoid a Windows PowerShell 5.1 Generic.List/array-subexpression binder defect.
    return $packages.ToArray()
}

function Cleanup-StaleWinREMount {
    if (-not (Test-Path -LiteralPath $MountDirectory)) {
        New-Item -Path $MountDirectory -ItemType Directory -Force | Out-Null
        return
    }

    if (@(Get-ChildItem -LiteralPath $MountDirectory -Force -ErrorAction SilentlyContinue).Count -gt 0) {
        Write-Log "Dedicated WinRE mount directory is not empty. Attempting to discard a stale mount." 'WARN'
        try {
            Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/unmountre','/path',$MountDirectory,'/discard') -SuccessCodes @(0)
        }
        catch {
            try {
                Invoke-Native -FilePath 'dism.exe' -Arguments @('/Unmount-Image',"/MountDir:$MountDirectory",'/Discard') -SuccessCodes @(0,2,50)
            }
            catch {
                Write-Log "Targeted stale-mount cleanup did not complete: $($_.Exception.Message)" 'WARN'
            }
        }

        try { Invoke-Native -FilePath 'dism.exe' -Arguments @('/Cleanup-Wim') -SuccessCodes @(0,2) } catch {}
        Remove-Item -LiteralPath $MountDirectory -Recurse -Force -ErrorAction SilentlyContinue
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
        try {
            Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/unmountre','/path',$MountDirectory,'/discard') -SuccessCodes @(0)
        }
        catch {
            Invoke-Native -FilePath 'dism.exe' -Arguments @('/Unmount-Image',"/MountDir:$MountDirectory",'/Discard') -SuccessCodes @(0,2,50)
        }
    }

    $script:WinREMounted = $false
    Remove-Item -LiteralPath $MountDirectory -Recurse -Force -ErrorAction SilentlyContinue
}

function Get-OfflineWinREDrivers {
    if (Get-Command Get-WindowsDriver -ErrorAction SilentlyContinue) {
        try {
            return @(Get-WindowsDriver -Path $MountDirectory -All -ErrorAction Stop)
        }
        catch {
            Write-Log "Get-WindowsDriver failed; the script will fall back to injecting exported packages. Error: $($_.Exception.Message)" 'WARN'
        }
    }
    return @()
}

function Convert-ToVersionSafe {
    param([string]$Value)
    try { return [version]$Value } catch { return [version]'0.0.0.0' }
}

function Test-PackageAlreadyPresent {
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)][object[]]$OfflineDrivers
    )

    if ($OfflineDrivers.Count -eq 0) { return $false }
    $liveVersion = Convert-ToVersionSafe -Value $Package.LiveVersion

    foreach ($offline in $OfflineDrivers) {
        $originalName = $null
        if ($offline.OriginalFileName) {
            $originalName = [IO.Path]::GetFileName($offline.OriginalFileName).ToLowerInvariant()
        }
        if (-not $originalName -or $Package.OriginalInfNames -notcontains $originalName) { continue }

        $offlineVersion = Convert-ToVersionSafe -Value $offline.Version
        Write-Log "WinRE already contains $originalName version $offlineVersion; active OS version is $liveVersion."
        if ($offlineVersion -ge $liveVersion) { return $true }
    }

    return $false
}

try {
    Write-Log '=== Starting WinRE storage-driver injection ==='
    Write-Log "Log file: $LogFile"

    if (-not (Test-IsAdministrator)) {
        Exit-WithCode -Code 1 -Message 'This script must run elevated or as Local System.'
    }

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-Log "Running as $($identity.Name); OS=$($os.Caption) $($os.Version) build $($os.BuildNumber); 64BitProcess=$([Environment]::Is64BitProcess); PS=$($PSVersionTable.PSVersion)"

    $winREState = Get-WinREState
    if (-not $winREState.Enabled -or $null -eq $winREState.DiskNumber -or $null -eq $winREState.PartitionNumber) {
        Exit-WithCode -Code 2 -Message 'WinRE must be enabled and registered before storage-driver injection. Run the WinRE repair step first.'
    }

    $activeDrivers = @(Get-ActiveStorageDrivers)
    if ($activeDrivers.Count -eq 0) {
        Exit-WithCode -Code 0 -Message 'SUCCESS: No active third-party storage-controller driver requires WinRE injection.'
    }

    $packages = @(Export-StorageDriverPackages -Drivers $activeDrivers)
    if ($packages.Count -eq 0) {
        Exit-WithCode -Code 3 -Message 'Active storage drivers were detected, but no package could be exported.'
    }

    [void](Backup-RegisteredWinRE -WinREState $winREState)

    try {
        Mount-RegisteredWinRE
        $offlineDrivers = @(Get-OfflineWinREDrivers)
        $packagesToInject = @($packages | Where-Object { -not (Test-PackageAlreadyPresent -Package $_ -OfflineDrivers $offlineDrivers) })

        if ($packagesToInject.Count -eq 0) {
            Write-Log 'All selected active storage drivers are already present in WinRE at the same or a newer version.'
            Unmount-RegisteredWinRE
            Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
            Exit-WithCode -Code 0 -Message 'SUCCESS: WinRE storage drivers are already current; no image change was required.'
        }

        foreach ($package in $packagesToInject) {
            Write-Log "Injecting storage driver package for $($package.DeviceName) from $($package.ExportPath)."
            Invoke-Native -FilePath 'dism.exe' -Arguments @(
                "/Image:$MountDirectory",
                '/Add-Driver',
                "/Driver:$($package.ExportPath)",
                '/Recurse'
            ) -SuccessCodes @(0)
        }

        # Validate the mounted image after injection when the DISM PowerShell cmdlets are available.
        $postDrivers = @(Get-OfflineWinREDrivers)
        if ($postDrivers.Count -gt 0) {
            foreach ($package in $packagesToInject) {
                if (-not (Test-PackageAlreadyPresent -Package $package -OfflineDrivers $postDrivers)) {
                    throw "Post-injection verification could not find the expected driver package for $($package.DeviceName)."
                }
            }
        }

        Unmount-RegisteredWinRE -Commit
    }
    catch {
        Write-Log "Driver servicing error: $($_.Exception.Message)" 'ERROR'
        try { Unmount-RegisteredWinRE } catch { Write-Log "Failed to discard the WinRE mount: $($_.Exception.Message)" 'WARN' }
        Exit-WithCode -Code 4 -Message 'WinRE driver servicing or commit failed. The original WIM backup has been retained.'
    }

    # Microsoft recommends cycling WinRE after servicing on BitLocker/device-encrypted machines.
    try {
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/disable') -SuccessCodes @(0)
        Invoke-Native -FilePath 'reagentc.exe' -Arguments @('/enable') -SuccessCodes @(0)
    }
    catch {
        Exit-WithCode -Code 5 -Message 'The WinRE image was serviced, but ReAgentC disable/enable validation failed.'
    }

    $finalState = Get-WinREState
    if (-not $finalState.Enabled) {
        Exit-WithCode -Code 5 -Message 'WinRE did not report Enabled after storage-driver injection.'
    }

    Remove-Item -LiteralPath $DriverExportRoot -Recurse -Force -ErrorAction SilentlyContinue
    Exit-WithCode -Code 0 -Message 'SUCCESS: Required active storage drivers are present in WinRE and WinRE is enabled.'
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    Write-Log ($_ | Out-String) 'ERROR'
    try { Unmount-RegisteredWinRE } catch {}
    Exit-WithCode -Code 1 -Message 'Generic failure during WinRE storage-driver injection.'
}
