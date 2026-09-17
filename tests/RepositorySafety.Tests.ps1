BeforeAll {
    $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
    $ScriptRoot = Join-Path $RepoRoot 'scripts'
    $AllScripts = @(Get-ChildItem -Path $ScriptRoot -Filter '*.ps1' -File -Recurse)
    function Read-Raw([string]$Path) { Get-Content -LiteralPath $Path -Raw }
}

Describe 'Repository safety invariants' {
    It 'has no hard-coded local lab path in production scripts' {
        foreach ($file in $AllScripts) {
            (Read-Raw $file.FullName) | Should -Not -Match 'C:\\Lab\\WinRE'
        }
    }

    It 'keeps direct CIM InvokeMethod calls only in the two destructive reset scripts' {
        $allowed = @('Remediate-CarveOutFullReset.ps1','Invoke-RemoteWipe.ps1')
        foreach ($file in $AllScripts) {
            if ((Read-Raw $file.FullName) -match '\.InvokeMethod\s*\(') {
                $file.Name | Should -BeIn $allowed
            }
        }
    }

    It 'keeps readiness remediation free of direct wipe invocation' {
        $path = Join-Path $ScriptRoot 'intune\readiness\Remediate-WinREWipeReadiness.ps1'
        $text = Read-Raw $path
        $text | Should -Not -Match '\.InvokeMethod\s*\('
        $text | Should -Not -Match '(?i)systemreset\.exe'
    }

    It 'uses the same authorization identifier across Arm, Detect, and Full Reset remediation' {
        $paths = @(
            (Join-Path $ScriptRoot 'intune\carveout-reset\Arm-CarveOutReset.ps1'),
            (Join-Path $ScriptRoot 'intune\carveout-reset\Detect-CarveOutFullReset.ps1'),
            (Join-Path $ScriptRoot 'intune\carveout-reset\Remediate-CarveOutFullReset.ps1')
        )
        $ids = foreach ($path in $paths) {
            $m = [regex]::Match((Read-Raw $path), '(?m)^\$AuthorizationId\s*=\s*''([^'']+)''', 'IgnoreCase')
            $m.Success | Should -BeTrue
            $m.Groups[1].Value
        }
        @($ids | Select-Object -Unique).Count | Should -Be 1
    }

    It 'preserves the full-reset final authorization revalidation before wipe-specific suspension' {
        $path = Join-Path $ScriptRoot 'intune\carveout-reset\Remediate-CarveOutFullReset.ps1'
        $text = Read-Raw $path
        ([regex]::Matches($text,'Test-ResetAuthorization').Count) | Should -BeGreaterOrEqual 2
        $text | Should -Match 'Reset authorization was revoked or expired before RemoteWipe'
    }
}
