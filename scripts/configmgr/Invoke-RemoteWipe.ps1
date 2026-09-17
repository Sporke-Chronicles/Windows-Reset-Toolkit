<#
.SYNOPSIS
  Initiates a local Windows RemoteWipe through the MDM WMI Bridge Provider.

.DESCRIPTION
  Designed for the final step of an SCCM/ConfigMgr carve-out task sequence after WinRE has been
  repaired and any required storage drivers have been injected.

  Safety and compatibility features:
  - Enforces Local System, as required by the MDM WMI Bridge for device-scoped methods.
  - Relaunches itself in 64-bit Windows PowerShell when invoked from a 32-bit host on x64 Windows.
  - Verifies the MDM_RemoteWipe instance before changing BitLocker state.
  - Requires WinRE to be enabled by default. This prevents knowingly starting a reset against a
    broken recovery environment. Use -AllowWipeWithWinREDisabled only for a deliberate exception.
  - Suspends protected BitLocker volumes immediately before the wipe.
  - If the wipe invocation fails, attempts to resume any BitLocker volumes this script suspended.
  - Uses Microsoft's documented MDM_RemoteWipe method invocation pattern.
  - Is idempotent up to the actual wipe call: all preflight and BitLocker operations tolerate reruns.
  - Captures native reagentc/manage-bde output under a controlled ErrorActionPreference scope so
    Windows PowerShell 5.1 native stderr cannot bypass explicit exit-code handling.
  - Provides -PreflightOnly to validate SYSTEM context, RemoteWipe capability, WinRE and BitLocker
    telemetry without suspending BitLocker or invoking any wipe method.
  - Enumerates CimClassMethods by method declaration Name rather than using a non-existent .Keys
    property, preserving Windows PowerShell 5.1 StrictMode compatibility.

.PARAMETER Return3010
  Return 3010 after the wipe method is accepted. The device normally begins reset processing on its
  own; this option is retained for task-sequence control logic that explicitly expects 3010.

.PARAMETER UseProtectedWipe
  Uses doWipeProtectedMethod instead of doWipeMethod. Microsoft documents protected wipe primarily
  for lost/stolen-device scenarios and warns that it can leave some device configurations unable to
  boot. Normal doWipeMethod is the recommended default for a planned carve-out migration.

.PARAMETER AllowWipeWithWinREDisabled
  Allows the wipe call even if WinRE cannot be verified as enabled. Not recommended for this workflow.

.PARAMETER PreflightOnly
  Validates Local System context, the requested RemoteWipe method, the WMI Bridge instance, WinRE
  enabled state and BitLocker telemetry. It does not suspend BitLocker and does not invoke RemoteWipe.

.RETURN CODES
  0    = Wipe request accepted.
  1    = Generic failure.
  5    = Not running as Local System.
  6    = RemoteWipe provider/method failure.
  7    = WinRE is not enabled and the override was not supplied.
  8    = Unsupported OS (Windows Server/non-client SKU).
  3010 = Wipe request accepted and Return3010 was requested.

.NOTES
  Project: Windows Reset Toolkit
  Public release: 1.0.0
  Microsoft documentation:
    MDM_RemoteWipe: https://learn.microsoft.com/windows/win32/dmwmibridgeprov/mdm-remotewipe
    WMI Bridge:     https://learn.microsoft.com/windows/client-management/using-powershell-scripting-with-the-wmi-bridge-provider
#>

[CmdletBinding()]
param(
    [switch]$Return3010,
    [switch]$UseProtectedWipe,
    [switch]$AllowWipeWithWinREDisabled,
    [switch]$PreflightOnly
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Restart-In64BitPowerShellIfRequired {
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        $nativePowerShell = Join-Path $env:WINDIR 'SysNative\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $nativePowerShell)) {
            throw "64-bit Windows PowerShell was not found at $nativePowerShell"
        }

        $arguments = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',('"{0}"' -f $PSCommandPath))
        if ($Return3010) { $arguments += '-Return3010' }
        if ($UseProtectedWipe) { $arguments += '-UseProtectedWipe' }
        if ($AllowWipeWithWinREDisabled) { $arguments += '-AllowWipeWithWinREDisabled' }
        if ($PreflightOnly) { $arguments += '-PreflightOnly' }

        $process = Start-Process -FilePath $nativePowerShell -ArgumentList $arguments -Wait -PassThru
        exit $process.ExitCode
    }
}

Restart-In64BitPowerShellIfRequired

$LogDirectory = Join-Path $env:WINDIR 'Logs\Reset'
$LogFile = Join-Path $LogDirectory ("Reset-RemoteWipe-{0}.log" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
New-Item -Path $LogDirectory -ItemType Directory -Force | Out-Null

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
    if ($Message) { Write-Log $Message $(if ($Code -eq 0 -or $Code -eq 3010) { 'INFO' } else { 'ERROR' }) }
    Write-Log "Exiting with code $Code."
    exit $Code
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
        # Windows PowerShell 5.1 may surface native stderr as NativeCommandError when the caller has
        # ErrorActionPreference=Stop. Capture under Continue and let callers decide which exit codes
        # are acceptable.
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

function Get-WinREInfoText {
    $native = Invoke-NativeCapture -FilePath 'reagentc.exe' -Arguments @('/info')
    Write-Log "reagentc /info exit code: $($native.ExitCode)"
    if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
    if ($native.ExitCode -ne 0) {
        throw "reagentc /info failed with exit code $($native.ExitCode)."
    }
    return $native.Text
}

function Test-WinREEnabled {
    return ((Get-WinREInfoText) -match 'Windows RE status:\s+Enabled')
}

function Try-EnableWinRE {
    if (Test-WinREEnabled) {
        return $true
    }

    Write-Log 'WinRE is not enabled. Attempting reagentc /enable.' 'WARN'
    $native = Invoke-NativeCapture -FilePath 'reagentc.exe' -Arguments @('/enable')
    if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
    Write-Log "reagentc /enable exit code: $($native.ExitCode)"
    Start-Sleep -Seconds 2

    return (Test-WinREEnabled)
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

    # CimClassMethods is a CimReadOnlyKeyedCollection<CimMethodDeclaration>. On Windows PowerShell
    # 5.1 it does not expose a PowerShell-visible .Keys property. Under StrictMode, attempting to
    # read .Keys throws PropertyNotFoundStrict. Enumerate the declarations and compare Name instead.
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
    $namespaceName = 'root\cimv2\mdm\dmmap'
    $className = 'MDM_RemoteWipe'

    Write-Log 'Validating the MDM RemoteWipe WMI Bridge instance.'
    $instance = Get-CimInstance `
        -Namespace $namespaceName `
        -ClassName $className `
        -Filter "ParentID='./Vendor/MSFT' and InstanceID='RemoteWipe'" `
        -ErrorAction Stop

    if (-not $instance) {
        throw 'MDM_RemoteWipe instance was not returned by the WMI Bridge Provider.'
    }

    return $instance
}

function Test-BitLockerProtectionOn {
    param($ProtectionStatus)
    if ($null -eq $ProtectionStatus) { return $false }
    return ($ProtectionStatus.ToString() -in @('On','1'))
}

function Suspend-BitLockerForReset {
    # Return only mount points that THIS invocation changed from protected to suspended. They can be
    # resumed if the wipe call fails, reducing the security impact of a failed reset attempt.
    $changed = New-Object System.Collections.Generic.List[string]

    if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
        $volumes = @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.MountPoint })

        foreach ($volume in $volumes) {
            Write-Log ("BitLocker {0}: VolumeType={1}, VolumeStatus={2}, ProtectionStatus={3}" -f `
                $volume.MountPoint, $volume.VolumeType, $volume.VolumeStatus, $volume.ProtectionStatus)

            if (-not (Test-BitLockerProtectionOn -ProtectionStatus $volume.ProtectionStatus)) {
                continue
            }

            Write-Log "Suspending BitLocker protectors on $($volume.MountPoint) with RebootCount 0."
            try {
                Suspend-BitLocker -MountPoint $volume.MountPoint -RebootCount 0 -ErrorAction Stop | Out-Null
            }
            catch {
                Write-Log "Suspend-BitLocker failed on $($volume.MountPoint); trying manage-bde. Error: $($_.Exception.Message)" 'WARN'
                $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-disable',$volume.MountPoint,'-RebootCount','0')
                if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
                if ($native.ExitCode -ne 0) {
                    throw "Unable to suspend BitLocker on $($volume.MountPoint); manage-bde exit code $($native.ExitCode)."
                }
            }

            $check = Get-BitLockerVolume -MountPoint $volume.MountPoint -ErrorAction Stop
            if (Test-BitLockerProtectionOn -ProtectionStatus $check.ProtectionStatus) {
                throw "BitLocker protection is still enabled on $($volume.MountPoint)."
            }

            [void]$changed.Add($volume.MountPoint)
        }

        return $changed.ToArray()
    }

    # Fallback when the BitLocker PowerShell module is not available. Only the OS volume is changed
    # because manage-bde output is less convenient to enumerate and validate safely.
    Write-Log 'Get-BitLockerVolume is unavailable. Falling back to the OS volume with manage-bde.' 'WARN'
    $status = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-status',$env:SystemDrive)
    if (-not [string]::IsNullOrWhiteSpace($status.Text)) { Write-Log $status.Text }
    if ($status.ExitCode -ne 0) {
        throw "manage-bde status failed for $env:SystemDrive. Exit code $($status.ExitCode)."
    }

    if ($status.Text -match 'Protection Status:\s+Protection On') {
        $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-disable',$env:SystemDrive,'-RebootCount','0')
        if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
        if ($native.ExitCode -ne 0) {
            throw "manage-bde could not suspend BitLocker on $env:SystemDrive. Exit code $($native.ExitCode)."
        }
        [void]$changed.Add($env:SystemDrive)
    }

    return $changed.ToArray()
}

function Resume-BitLockerBestEffort {
    param([string[]]$MountPoints)

    foreach ($mountPoint in @($MountPoints)) {
        if ([string]::IsNullOrWhiteSpace($mountPoint)) { continue }

        try {
            Write-Log "Wipe was not accepted. Resuming BitLocker protection on $mountPoint." 'WARN'
            if (Get-Command -Name Resume-BitLocker -ErrorAction SilentlyContinue) {
                Resume-BitLocker -MountPoint $mountPoint -ErrorAction Stop | Out-Null
            }
            else {
                $native = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-protectors','-enable',$mountPoint)
                if (-not [string]::IsNullOrWhiteSpace($native.Text)) { Write-Log $native.Text }
                if ($native.ExitCode -ne 0) {
                    throw "manage-bde could not resume BitLocker on $mountPoint. Exit code $($native.ExitCode)."
                }
            }
        }
        catch {
            Write-Log "Failed to resume BitLocker on $mountPoint. Error: $($_.Exception.Message)" 'WARN'
        }
    }
}

function Invoke-RemoteWipeMethod {
    param(
        [Parameter(Mandatory)][ValidateSet('doWipeMethod','doWipeProtectedMethod')][string]$MethodName,
        [Parameter(Mandatory)]$Instance
    )

    $namespaceName = 'root\cimv2\mdm\dmmap'
    $session = $null

    try {
        $session = New-CimSession
        $parameters = New-Object Microsoft.Management.Infrastructure.CimMethodParametersCollection
        $parameter = [Microsoft.Management.Infrastructure.CimMethodParameter]::Create('param', '', 'String', 'In')
        [void]$parameters.Add($parameter)

        Write-Log "Invoking MDM_RemoteWipe.$MethodName."
        $result = $session.InvokeMethod($namespaceName, $Instance, $MethodName, $parameters)
        Write-Log ($result | Out-String)

        # Different Windows builds expose ReturnValue slightly differently. Accept only a parsed 0
        # or, if ReturnValue is absent, a method call that completed without throwing.
        $returnValue = $null
        if ($result -and $result.PSObject.Properties.Name -contains 'ReturnValue') {
            if ($result.ReturnValue -is [ValueType]) {
                $returnValue = [int]$result.ReturnValue
            }
            elseif ($result.ReturnValue -and $result.ReturnValue.PSObject.Properties.Name -contains 'Value') {
                $returnValue = [int]$result.ReturnValue.Value
            }
            else {
                $returnText = $result.ReturnValue | Out-String
                if ($returnText -match 'ReturnValue\s*=\s*(\d+)') {
                    $returnValue = [int]$matches[1]
                }
            }
        }

        Write-Log "Parsed RemoteWipe ReturnValue: $returnValue"
        if ($null -ne $returnValue -and $returnValue -ne 0) {
            throw "RemoteWipe returned non-zero ReturnValue $returnValue."
        }

        if ($null -eq $returnValue) {
            Write-Log 'RemoteWipe did not expose a parseable ReturnValue, but the method returned without exception.' 'WARN'
        }
    }
    finally {
        if ($session) {
            Remove-CimSession -CimSession $session -ErrorAction SilentlyContinue
        }
    }
}

$bitLockerChanged = @()
$wipeAccepted = $false

try {
    Write-Log '=== Starting local RemoteWipe reset ==='
    Write-Log "Log file: $LogFile"

    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log "Running as $($identity.Name); SID=$($identity.User.Value); 64BitProcess=$([Environment]::Is64BitProcess); PS=$($PSVersionTable.PSVersion)"

    $os = Get-CimInstance Win32_OperatingSystem -ErrorAction Stop
    Write-Log "OS: $($os.Caption) $($os.Version), build $($os.BuildNumber), ProductType=$($os.ProductType)"

    # MDM_RemoteWipe is a Windows client capability. Fail closed if this task sequence is ever
    # assigned to a server or other non-client OS by mistake.
    if ([int]$os.ProductType -ne 1) {
        Exit-WithCode -Code 8 -Message 'RemoteWipe is supported by this toolkit on Windows client operating systems only.'
    }

    if (-not (Test-IsLocalSystem)) {
        Exit-WithCode -Code 5 -Message 'The MDM WMI Bridge device method must run as Local System.'
    }

    $methodName = if ($UseProtectedWipe) { 'doWipeProtectedMethod' } else { 'doWipeMethod' }

    if ($UseProtectedWipe) {
        Write-Log 'Protected wipe was selected. Microsoft warns that this method can leave some devices unable to boot.' 'WARN'
    }

    # Validate both the class method and provider instance before any BitLocker state change.
    Assert-RemoteWipeMethodAvailable -MethodName $methodName
    $remoteWipeInstance = Get-RemoteWipeInstance

    if ($PreflightOnly) {
        $winREEnabled = Test-WinREEnabled
        if (-not $winREEnabled -and -not $AllowWipeWithWinREDisabled) {
            Exit-WithCode -Code 7 -Message 'Preflight failed: WinRE is not enabled.'
        }
        elseif (-not $winREEnabled) {
            Write-Log 'Preflight: WinRE is disabled, but the explicit override was supplied.' 'WARN'
        }

        if (Get-Command -Name Get-BitLockerVolume -ErrorAction SilentlyContinue) {
            foreach ($volume in @(Get-BitLockerVolume -ErrorAction Stop | Where-Object { $_.MountPoint })) {
                Write-Log ("Preflight BitLocker {0}: VolumeType={1}, VolumeStatus={2}, ProtectionStatus={3}" -f `
                    $volume.MountPoint, $volume.VolumeType, $volume.VolumeStatus, $volume.ProtectionStatus)
            }
        }
        else {
            $status = Invoke-NativeCapture -FilePath 'manage-bde.exe' -Arguments @('-status',$env:SystemDrive)
            if (-not [string]::IsNullOrWhiteSpace($status.Text)) { Write-Log $status.Text }
            if ($status.ExitCode -ne 0) {
                throw "Preflight manage-bde status failed with exit code $($status.ExitCode)."
            }
        }

        Exit-WithCode -Code 0 -Message "PRECHECK SUCCESS: Local System, $methodName, RemoteWipe provider, WinRE and BitLocker telemetry validated. No wipe was invoked and BitLocker was not suspended."
    }

    $winREEnabled = Try-EnableWinRE
    if (-not $winREEnabled -and -not $AllowWipeWithWinREDisabled) {
        Exit-WithCode -Code 7 -Message 'WinRE is not enabled. Refusing to start the wipe without -AllowWipeWithWinREDisabled.'
    }
    elseif (-not $winREEnabled) {
        Write-Log 'WinRE is not enabled, but the explicit override allows the wipe to continue.' 'WARN'
    }

    $bitLockerChanged = @(Suspend-BitLockerForReset)

    Invoke-RemoteWipeMethod -MethodName $methodName -Instance $remoteWipeInstance
    $wipeAccepted = $true

    if ($Return3010) {
        Exit-WithCode -Code 3010 -Message 'RemoteWipe request accepted. Returning 3010 as requested.'
    }

    Exit-WithCode -Code 0 -Message 'RemoteWipe request accepted. The device should begin the Windows reset workflow.'
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)" 'ERROR'
    Write-Log ($_ | Out-String) 'ERROR'

    if (-not $wipeAccepted -and $bitLockerChanged.Count -gt 0) {
        Resume-BitLockerBestEffort -MountPoints $bitLockerChanged
    }

    if ($_.Exception.Message -match 'RemoteWipe|MDM_RemoteWipe|WMI Bridge|dmmap|CIM') {
        Exit-WithCode -Code 6 -Message 'RemoteWipe provider or method invocation failed.'
    }

    Exit-WithCode -Code 1 -Message 'Generic failure while preparing or invoking RemoteWipe.'
}
