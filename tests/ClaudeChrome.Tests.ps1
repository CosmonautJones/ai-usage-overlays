#Requires -Module Pester
Describe 'Claude-hidden chrome gate (MS-HIDE-CLAUDE-AUTH-CHROME)' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $script:StatusSrc = Get-Content (Join-Path $root 'src\Status.ps1') -Raw -Encoding UTF8
        . (Join-Path $root 'src\Config.ps1')
        . (Join-Path $root 'src\Status.ps1')
    }

    # The gate used to be a Claude-only branch in Update-AllSections. It is now
    # the general rule that disabled providers never reach the chrome, so these
    # assert the rule itself rather than the old claudeShown branch.
    It 'gates statusDot and timeText on Sections claude' {
        $script:Shell | Should -Match 'function Test-ClaudeSectionVisible'
        $script:Shell | Should -Match "Contains\('claude'\)"
        $script:Shell | Should -Match 'chromeStatus'
        $script:Shell | Should -Match 'Get-WorstProviderStatus'
        $script:Shell | Should -Match 'Cfg\.Sections'
        $script:StatusSrc | Should -Match "'auth', 'error', 'stale'"
    }

    It 'keeps a hidden Claude auth/error/stale out of the chrome' {
        $enabled = @{ claude = $false; codex = $true; cursor = $true; grok = $true }
        foreach ($bad in 'auth', 'error', 'stale') {
            $s = @{ claude = $bad; codex = 'ok'; cursor = 'ok'; grok = 'ok' }
            $r = Get-WorstProviderStatus -Status $s -Enabled $enabled
            $r.Status | Should -Be 'ok'
            Get-ChromeStatusText -Status $r.Status -Provider $r.Provider -LastFetch '09:15' |
                Should -Be '09:15'
        }
    }

    It 'still surfaces Claude trouble when Claude is shown' {
        $enabled = @{ claude = $true; codex = $true; cursor = $true; grok = $true }
        $s = @{ claude = 'auth'; codex = 'ok'; cursor = 'ok'; grok = 'ok' }
        $r = Get-WorstProviderStatus -Status $s -Enabled $enabled
        $r.Status | Should -Be 'auth'
        Get-ChromeStatusText -Status $r.Status -Provider $r.Provider -LastFetch '09:15' |
            Should -Be 'CLAUDE auth'
    }

    It 'does not clear auth State itself — only chrome surfacing' {
        $root = Split-Path $PSScriptRoot -Parent
        $data = Get-Content (Join-Path $root 'src\Data.ps1') -Raw -Encoding UTF8
        $data | Should -Match 'Auth expired'
        $data | Should -Match "Status = 'auth'"
    }
}

Describe 'Test-ClaudeSectionVisible' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $src = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $start = $src.IndexOf('function Test-ClaudeSectionVisible {')
        $end = $src.IndexOf("`nfunction Update-AllSections {", $start)
        $fn = $src.Substring($start, $end - $start)
        . ([scriptblock]::Create($fn))
    }

    It 'defaults to visible when Cfg/Sections missing' {
        $script:Cfg = $null
        Test-ClaudeSectionVisible | Should -Be $true
    }

    It 'returns false when Sections claude is off' {
        $script:Cfg = @{ Sections = @{ claude = $false; codex = $true; cursor = $true; grok = $true } }
        Test-ClaudeSectionVisible | Should -Be $false
    }

    It 'returns true when Sections claude is on' {
        $script:Cfg = @{ Sections = @{ claude = $true } }
        Test-ClaudeSectionVisible | Should -Be $true
    }
}
