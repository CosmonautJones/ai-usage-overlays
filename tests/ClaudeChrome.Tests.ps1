#Requires -Module Pester
Describe 'Claude-hidden chrome gate (MS-HIDE-CLAUDE-AUTH-CHROME)' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
    }

    It 'gates statusDot and timeText on Sections claude' {
        $script:Shell | Should -Match 'function Test-ClaudeSectionVisible'
        $script:Shell | Should -Match "Contains\('claude'\)"
        $script:Shell | Should -Match 'chromeStatus'
        $script:Shell | Should -Match "'auth', 'error', 'stale'"
        $script:Shell | Should -Match 'Test-ClaudeSectionVisible'
        $script:Shell | Should -Match 'claudeShown'
        $script:Shell | Should -Match 'elseif \(\$claudeShown\)'
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
