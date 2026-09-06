# ProviderVersions.Tests.ps1 - HUD provider version badges
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\ProviderLogin.ps1')
    . (Join-Path $root 'src\ProviderVersions.ps1')
}

Describe 'Format-ProviderVersionLabel' {
    It 'extracts semver from CLI banner noise' {
        Format-ProviderVersionLabel "codex-cli 0.144.2`nextra" | Should -Be '0.144.2'
        Format-ProviderVersionLabel 'claude 2.1.0 (Claude Code)' | Should -Be '2.1.0'
    }

    It 'returns -- for empty' {
        Format-ProviderVersionLabel '' | Should -Be '--'
        Format-ProviderVersionLabel $null | Should -Be '--'
    }
}

Describe 'Get-CachedProviderVersion' {
    BeforeEach {
        Clear-ProviderVersionCache
        $script:ProviderVersionTtlSec = 600
    }

    It 'caches resolver output and skips respawn within TTL' {
        $script:calls = 0
        $a = Get-CachedProviderVersion -Key 't:demo' -Resolver { $script:calls++; 'tool 1.2.3' }
        $b = Get-CachedProviderVersion -Key 't:demo' -Resolver { $script:calls++; 'tool 9.9.9' }
        $a | Should -Be '1.2.3'
        $b | Should -Be '1.2.3'
        $script:calls | Should -Be 1
    }

    It 'shows -- when resolver returns nothing' {
        Get-CachedProviderVersion -Key 't:empty' -Resolver { $null } | Should -Be '--'
    }
}

Describe 'Shell version badge wiring' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $script:Entry = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
    }

    It 'adds muted version TextBlocks and paints from Update-AllSections' {
        $script:Shell | Should -Match 'x:Name="claudeVersionText"'
        $script:Shell | Should -Match 'x:Name="codexVersionText"'
        $script:Shell | Should -Match 'x:Name="cursorVersionText"'
        $script:Shell | Should -Match 'x:Name="grokVersionText"'
        $script:Shell | Should -Match 'Update-ProviderVersionLabels'
        $script:Shell | Should -Match '#5C7A96'
        $script:Entry | Should -Match 'ProviderVersions\.ps1'
    }
}
