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
        $root2 = Split-Path $PSScriptRoot -Parent
        $pv = Get-Content (Join-Path $root2 'src\ProviderVersions.ps1') -Raw -Encoding UTF8
        $pv | Should -Match 'Format-ProviderVersionPlanBadge'
        $pv | Should -Match 'Get-ProviderPlanLabel'
        $script:Shell | Should -Match '#5C7A96'
        $script:Entry | Should -Match 'ProviderVersions\.ps1'
    }
}


Describe 'Format-ProviderVersionPlanBadge' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\ProviderVersions.ps1')
    }

    It 'appends plan with middot when present' {
        Format-ProviderVersionPlanBadge -Version '0.146.0' -Plan 'pro' | Should -Be '0.146.0 · Pro'
        Format-ProviderVersionPlanBadge -Version '3.18.25' -Plan 'pro_plus' | Should -Be '3.18.25 · Pro Plus'
    }

    It 'omits plan when missing (no -- plan)' {
        Format-ProviderVersionPlanBadge -Version '1.0.13' -Plan $null | Should -Be '1.0.13'
        Format-ProviderVersionPlanBadge -Version '1.0.13' -Plan '' | Should -Be '1.0.13'
        Format-ProviderVersionPlanBadge -Version '1.0.13' -Plan '--' | Should -Be '1.0.13'
    }
}

Describe 'Get-ProviderPlanLabel sources' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\ProviderVersions.ps1')
    }

    It 'reads Cursor membershipType and Grok/Codex PlanType' {
        $script:SummaryData = [pscustomobject]@{ membershipType = 'pro' }
        Get-ProviderPlanLabel 'cursor' | Should -Be 'Pro'

        $script:GrokUsage = [pscustomobject]@{ PlanType = 'SuperGrok' }
        Get-ProviderPlanLabel 'grok' | Should -Be 'SuperGrok'

        $script:CodexStats = [pscustomobject]@{ PlanType = 'plus' }
        Get-ProviderPlanLabel 'codex' | Should -Be 'Plus'

        $script:ClaudeIdentity = [pscustomobject]@{ Email = 'a@b.c'; Display = 'a@b.c' }
        Get-ProviderPlanLabel 'claude' | Should -BeNullOrEmpty
    }
}
