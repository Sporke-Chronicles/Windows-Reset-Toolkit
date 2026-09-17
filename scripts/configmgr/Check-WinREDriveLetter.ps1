<#
.SYNOPSIS
  Resolves a safe temporary drive letter for WinRE maintenance in a ConfigMgr/SCCM task sequence.

.DESCRIPTION
  Temporary WinRE access must never steal a legitimate drive-letter assignment from an unrelated
  volume. This implementation is deliberately conservative:

  - Prefers R: but never removes a letter from an unrelated data/system volume.
  - If R: is attached to a Recovery partition, treats it as a stale WinRE maintenance assignment
    and removes it before reuse.
  - If R: is legitimately occupied, selects the next available letter from the candidate list.
  - Writes the selected letter to the ConfigMgr task-sequence variable WinRETempDriveLetter when
    the Microsoft.SMS.TSEnvironment COM object is available.
  - Is safe to run repeatedly. A previous successful/partial run does not make the next run fail.

  Downstream scripts in this toolkit also resolve a free temporary letter independently, so the
  task-sequence variable is an optimisation rather than a hard dependency.

.PARAMETER PreferredLetter
  Preferred temporary drive letter. Default: R.

.PARAMETER CandidateLetters
  Ordered list of letters that may be used when the preferred letter is unavailable.

.PARAMETER TaskSequenceVariableName
  ConfigMgr task-sequence variable that receives the selected letter.

.RETURN CODES
  0 = A safe temporary drive letter was resolved.
  1 = Generic failure.
  2 = No candidate drive letter is available.

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Run elevated or as Local System. Designed for Windows 10/11 x64.
#>

[CmdletBinding()]
param(
    [ValidatePattern('^[A-Z]$')]
    [string]$PreferredLetter = 'R',

    [ValidateNotNullOrEmpty()]
    [string[]]$CandidateLetters = @('R','S','T','U','V','W','X','Y','Z'),

    [ValidateNotNullOrEmpty()]
    [string]$TaskSequenceVariableName = 'WinRETempDriveLetter'
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$LogDirectory = Join-Path $env:WINDIR 'Logs\WinRE'
$LogFile = Join-Path $LogDirectory ("Check-WinREDriveLetter-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$RecoveryGptType = '{de94bba4-06d1-4d40-a16a-bfd50179d6ac}'

New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

function Write-Log {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO','WARN','ERROR')][string]$Level = 'INFO'
    )

    $line = '{0} [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'), $Level, $Message
    $line | Out-File -FilePath $LogFile -Append -Encoding utf8
    Write-Output $line
}

function Test-IsAdministrator {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($identity)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Get-PartitionForDriveLetter {
    param([Parameter(Mandatory)][char]$DriveLetter)

    try {
        return Get-Partition -DriveLetter $DriveLetter -ErrorAction Stop
    }
    catch {
        return $null
    }
}

function Test-IsRecoveryPartition {
    param([Parameter(Mandatory)]$Partition)

    if ($Partition.GptType -and $Partition.GptType.ToString().ToLowerInvariant() -eq $RecoveryGptType) {
        return $true
    }

    if ($Partition.Type -and $Partition.Type.ToString() -eq 'Recovery') {
        return $true
    }

    return $false
}

function Test-LetterInUse {
    param([Parameter(Mandatory)][char]$DriveLetter)

    if (Get-Partition -DriveLetter $DriveLetter -ErrorAction SilentlyContinue) { return $true }
    if (Get-Volume -DriveLetter $DriveLetter -ErrorAction SilentlyContinue) { return $true }
    if (Get-PSDrive -Name $DriveLetter -PSProvider FileSystem -ErrorAction SilentlyContinue) { return $true }
    try { if (Get-CimInstance Win32_LogicalDisk -Filter "DeviceID='$DriveLetter`:'" -ErrorAction Stop) { return $true } } catch {}
    try {
        $mountedNames = @((Get-ItemProperty 'HKLM:\SYSTEM\MountedDevices' -ErrorAction Stop).PSObject.Properties.Name)
        if ($mountedNames -contains "\DosDevices\$DriveLetter`:") { return $true }
    } catch {}

    return $false
}

function Remove-StaleRecoveryDriveLetter {
    param(
        [Parameter(Mandatory)]$Partition,
        [Parameter(Mandatory)][char]$DriveLetter
    )

    Write-Log "Drive $DriveLetter`: is assigned to a Recovery partition. Removing the stale temporary access path."

    try {
        Remove-PartitionAccessPath `
            -DiskNumber $Partition.DiskNumber `
            -PartitionNumber $Partition.PartitionNumber `
            -AccessPath "$DriveLetter`:\" `
            -ErrorAction Stop
    }
    catch {
        Write-Log "Remove-PartitionAccessPath failed; falling back to DiskPart. Error: $($_.Exception.Message)" 'WARN'

        $diskPartFile = Join-Path $env:TEMP ("winre-remove-letter-{0}.txt" -f ([guid]::NewGuid().Guid))
        try {
            @(
                "select disk $($Partition.DiskNumber)",
                "select partition $($Partition.PartitionNumber)",
                "remove letter=$DriveLetter noerr"
            ) | Out-File -FilePath $diskPartFile -Encoding ascii -Force

            $output = & diskpart.exe /s $diskPartFile 2>&1
            $exitCode = $LASTEXITCODE
            Write-Log ($output | Out-String)

            if ($exitCode -ne 0) {
                throw "DiskPart returned exit code $exitCode."
            }
        }
        finally {
            Remove-Item -LiteralPath $diskPartFile -Force -ErrorAction SilentlyContinue
        }
    }

    Start-Sleep -Seconds 1
    if (Test-LetterInUse -DriveLetter $DriveLetter) {
        throw "Drive $DriveLetter`: is still in use after attempting to remove the Recovery partition access path."
    }
}

function Set-TaskSequenceVariable {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Value
    )

    try {
        $tsEnvironment = New-Object -ComObject Microsoft.SMS.TSEnvironment -ErrorAction Stop
        $tsEnvironment.Value($Name) = $Value
        Write-Log "ConfigMgr task-sequence variable '$Name' set to '$Value'."
        return $true
    }
    catch {
        Write-Log "ConfigMgr task-sequence environment is not available. The selected letter will not be persisted as a TS variable. Error: $($_.Exception.Message)" 'WARN'
        return $false
    }
}

try {
    Write-Log '=== Starting WinRE temporary drive-letter preflight ==='
    Write-Log "Log file: $LogFile"

    if (-not (Test-IsAdministrator)) {
        throw 'This script must run elevated or as Local System.'
    }

    # Normalise the candidate list while preserving order and ensuring the preferred letter is first.
    $letters = @($PreferredLetter) + @($CandidateLetters)
    $letters = @($letters | ForEach-Object { $_.ToUpperInvariant() } | Select-Object -Unique)

    foreach ($letterString in $letters) {
        if ($letterString -notmatch '^[A-Z]$') {
            Write-Log "Ignoring invalid candidate drive letter '$letterString'." 'WARN'
            continue
        }

        $letter = [char]$letterString
        $partition = Get-PartitionForDriveLetter -DriveLetter $letter

        if ($partition -and (Test-IsRecoveryPartition -Partition $partition)) {
            Remove-StaleRecoveryDriveLetter -Partition $partition -DriveLetter $letter
        }

        if (-not (Test-LetterInUse -DriveLetter $letter)) {
            Write-Log "Selected temporary WinRE drive letter: $letter`:"
            [void](Set-TaskSequenceVariable -Name $TaskSequenceVariableName -Value $letter)
            Write-Log 'SUCCESS: An apparently free WinRE temporary drive letter is available. Downstream scripts still verify assignment at the storage layer and can retry another candidate.'
            exit 0
        }

        $volume = Get-Volume -DriveLetter $letter -ErrorAction SilentlyContinue
        if ($volume) {
            Write-Log ("Drive {0}: is in legitimate use. Label='{1}', FileSystem='{2}', DriveType='{3}', SizeGB='{4}'. It will not be modified." -f `
                $letter, $volume.FileSystemLabel, $volume.FileSystem, $volume.DriveType, [math]::Round($volume.Size / 1GB, 2)) 'WARN'
        }
        else {
            Write-Log "Drive $letter`: is in use by a filesystem PSDrive or another object and will not be modified." 'WARN'
        }
    }

    Write-Log "ERROR: None of the candidate letters are available: $($letters -join ', ')." 'ERROR'
    exit 2
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    Write-Log ($_ | Out-String) 'ERROR'
    exit 1
}
