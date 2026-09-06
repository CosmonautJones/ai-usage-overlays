# PctAccent.Tests.ps1 - primary % bar-hue accents (MS-OVERLAY-ACCENT-20260905)
Describe 'Resolve-PctAccentFg' {
    BeforeAll {
        function Resolve-PctAccentFg($util, [string]$AccentFg) {
            if ($null -eq $util) { return '#F1F5F9' }
            $u = [double]$util
            if ($u -ge $script:CritPct) { return '#F87171' }
            if ($u -ge $script:WarnPct) { return '#FBBF24' }
            if (-not [string]::IsNullOrWhiteSpace($AccentFg)) { return $AccentFg }
            return '#F1F5F9'
        }
        $script:WarnPct = 80
        $script:CritPct = 95
    }

    It 'uses bar accent under warn threshold' {
        Resolve-PctAccentFg 19 '#38BDF8' | Should -Be '#38BDF8'
        Resolve-PctAccentFg 54 '#FDE68A' | Should -Be '#FDE68A'
        Resolve-PctAccentFg 10 '#34D399' | Should -Be '#34D399'
    }

    It 'keeps warn and crit overrides' {
        Resolve-PctAccentFg 85 '#38BDF8' | Should -Be '#FBBF24'
        Resolve-PctAccentFg 96 '#38BDF8' | Should -Be '#F87171'
    }

    It 'falls back to slate when accent missing' {
        Resolve-PctAccentFg 12 $null | Should -Be '#F1F5F9'
        Resolve-PctAccentFg $null '#38BDF8' | Should -Be '#F1F5F9'
    }
}

Describe 'Shell accent wiring' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $script:Config = Get-Content (Join-Path $root 'src\Config.ps1') -Raw -Encoding UTF8
    }

    It 'stashes theme accents and paints primary % + Grok chip %' {
        $script:Config | Should -Match "AccentFiveh\s*=\s*'#38BDF8'"
        $script:Config | Should -Match "AccentWeek\s*=\s*'#FB923C'"
        $script:Config | Should -Match "AccentCursor\s*=\s*'#34D399'"
        $script:Config | Should -Match "AccentGrok\s*=\s*'#FDE68A'"
        $script:Shell | Should -Match 'function Resolve-PctAccentFg'
        $script:Shell | Should -Match 'Set-PctAccentStyle'
        $script:Shell | Should -Match 'Set-GrokProductUsageVisual'
        $script:Shell | Should -Match 'AccentFg \$script:AccentFiveh'
        $script:Shell | Should -Match 'AccentFg \$script:AccentWeek'
        $script:Shell | Should -Match 'AccentFg \$script:AccentGrok'
        $script:Shell | Should -Match 'Set-PctAccentStyle \$rc'
        $script:Shell | Should -Match 'ExtraBold'
        $script:Shell | Should -Match '\$script:AccentCursor'
    }
}
