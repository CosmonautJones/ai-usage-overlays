# ProviderPicker.Tests.ps1 - first-run defaults + picker wiring
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:UnifiedSectionKeys = @('claude', 'codex', 'cursor', 'grok')
    . (Join-Path $root 'src\ProviderPicker.ps1')
    . (Join-Path $root 'src\UnifiedState.ps1')
}

Describe 'Get-DefaultUnifiedSections' {
    It 'hides Claude and shows Codex/Cursor/Grok for new installs' {
        $d = Get-DefaultUnifiedSections
        $d.claude | Should -BeFalse
        $d.codex | Should -BeTrue
        $d.cursor | Should -BeTrue
        $d.grok | Should -BeTrue
    }
}

Describe 'ConvertTo-UnifiedSectionsMap defaults' {
    It 'uses demo defaults when value is null' {
        $m = ConvertTo-UnifiedSectionsMap $null
        $m.claude | Should -BeFalse
        $m.codex | Should -BeTrue
    }

    It 'preserves an explicit Claude-on choice' {
        $m = ConvertTo-UnifiedSectionsMap @{ claude = $true; codex = $true; cursor = $true; grok = $false }
        $m.claude | Should -BeTrue
        $m.grok | Should -BeFalse
    }
}

Describe 'Test-UnifiedFirstRun' {
    It 'is true when state file is missing' {
        $script:StatePath = Join-Path $TestDrive 'no-such-unified-state.json'
        Test-UnifiedFirstRun | Should -BeTrue
    }

    It 'is false when state file exists' {
        $p = Join-Path $TestDrive 'unified-overlay-state.json'
        '{}' | Set-Content -LiteralPath $p
        $script:StatePath = $p
        Test-UnifiedFirstRun | Should -BeFalse
    }
}

Describe 'Picker wiring' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Tray = Get-Content (Join-Path $root 'src\UnifiedTray.ps1') -Raw -Encoding UTF8
        $script:Entry = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
    }

    It 'loads ProviderPicker and exposes tray Choose providers' {
        $script:Entry | Should -Match 'ProviderPicker\.ps1'
        $script:Entry | Should -Match 'Invoke-FirstRunProviderPickerIfNeeded'
        $script:Tray | Should -Match 'Choose providers'
        $script:Tray | Should -Match 'Invoke-ProviderPickerFromTray'
        $script:Tray | Should -Match 'BeginInvoke'
        $script:Tray | Should -Match "Providers"
    }
}
