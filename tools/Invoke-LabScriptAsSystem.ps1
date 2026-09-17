<#
.SYNOPSIS
  Executes a PowerShell script once as Local System using a temporary Scheduled Task.
.DESCRIPTION
  Lab convenience helper only. This is useful for reproducing Intune/ConfigMgr SYSTEM context on a disposable Windows VM.
  The helper waits for task completion when possible and reports LastTaskResult. It does not make a script safe to run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string]$ScriptPath,
    [Parameter()][string[]]$ScriptArguments = @(),
    [ValidateRange(10,3600)][int]$TimeoutSeconds = 900,
    [switch]$KeepTask
)

$ErrorActionPreference = 'Stop'
$resolvedScript = (Resolve-Path -LiteralPath $ScriptPath).Path
$identity = [Security.Principal.WindowsIdentity]::GetCurrent()
$principal = New-Object Security.Principal.WindowsPrincipal($identity)
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Run this helper from an elevated PowerShell session.'
}

$taskName = 'WinRE-Lab-' + [guid]::NewGuid().Guid
$powerShell = if ([Environment]::Is64BitOperatingSystem) {
    Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
} else {
    Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
}

function Quote-Arg([string]$Value) {
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '(\\*)"','$1$1\\"' -replace '(\\+)$','$1$1') + '"'
}

$argsList = @('-NoLogo','-NoProfile','-ExecutionPolicy','Bypass','-File',$resolvedScript) + $ScriptArguments
$argumentString = ($argsList | ForEach-Object { Quote-Arg ([string]$_) }) -join ' '

$action = New-ScheduledTaskAction -Execute $powerShell -Argument $argumentString
$principalSpec = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds)
$task = New-ScheduledTask -Action $action -Principal $principalSpec -Settings $settings
Register-ScheduledTask -TaskName $taskName -InputObject $task -Force | Out-Null

try {
    Write-Host "Starting $resolvedScript as NT AUTHORITY\\SYSTEM"
    Write-Host "Task: $taskName"
    Write-Host "Arguments: $argumentString"
    Start-ScheduledTask -TaskName $taskName

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds 1
        $info = Get-ScheduledTaskInfo -TaskName $taskName
        $state = (Get-ScheduledTask -TaskName $taskName).State
        if ($state -ne 'Running' -and $info.LastRunTime -gt [datetime]::MinValue) { break }
    } while ((Get-Date) -lt $deadline)

    $info = Get-ScheduledTaskInfo -TaskName $taskName
    [pscustomobject]@{
        TaskName       = $taskName
        ScriptPath     = $resolvedScript
        LastTaskResult = $info.LastTaskResult
        LastRunTime    = $info.LastRunTime
        NextRunTime    = $info.NextRunTime
    }
}
finally {
    if (-not $KeepTask) {
        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
    }
}
