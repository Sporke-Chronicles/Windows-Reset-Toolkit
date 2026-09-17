<#
.SYNOPSIS
  Parses PowerShell scripts and returns non-zero if syntax errors are found.
.DESCRIPTION
  Intended to be run with Windows PowerShell 5.1 for authoritative compatibility checking of this repository.
#>
[CmdletBinding()]
param(
    [Parameter()][string]$Path = (Join-Path $PSScriptRoot '..')
)

$ErrorActionPreference = 'Stop'
$resolved = (Resolve-Path -LiteralPath $Path).Path
$files = if (Test-Path -LiteralPath $resolved -PathType Leaf) {
    @(Get-Item -LiteralPath $resolved)
} else {
    @(Get-ChildItem -LiteralPath $resolved -Filter '*.ps1' -File -Recurse)
}

$failed = $false
foreach ($file in $files) {
    $tokens = $null
    $errors = $null
    [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
    if ($errors.Count -gt 0) {
        $failed = $true
        Write-Host "FAIL  $($file.FullName)" -ForegroundColor Red
        foreach ($error in $errors) {
            Write-Host ("  Line {0}, Column {1}: {2}" -f $error.Extent.StartLineNumber,$error.Extent.StartColumnNumber,$error.Message) -ForegroundColor Red
        }
    } else {
        Write-Host "PASS  $($file.FullName)"
    }
}

if ($failed) {
    Write-Error 'SYNTAX CHECK FAILED.'
    exit 1
}

Write-Host "SYNTAX CHECK PASSED: $($files.Count) PowerShell script(s) parsed successfully."
exit 0
