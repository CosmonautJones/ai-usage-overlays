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

Describe 'Persisted settings round-trip' {
    BeforeEach {
        $script:StatePath = Join-Path $TestDrive ("unified-state-" + [guid]::NewGuid().ToString('N') + '.json')
        $script:window = $null
        $script:Cfg = @{}
        Initialize-UnifiedCfg
    }

    It 'treats a missing state file as first run and does not write one' {
        Test-UnifiedFirstRun | Should -BeTrue
        Load-UnifiedState
        (Test-Path -LiteralPath $script:StatePath) | Should -BeFalse
        $script:Cfg.Sections.claude | Should -BeFalse
        $script:Cfg.Sections.codex | Should -BeTrue
    }

    It 'does not reset an existing state file to first-run defaults' {
        $script:Cfg.Theme = 'Nord'
        $script:Cfg.Opacity = 0.6
        $script:Cfg.Compact = $true
        $script:Cfg.ShowStats = $false
        $script:Cfg.ShowGraph = $true
        $script:Cfg.ShowAlerts = $false
        $script:Cfg.ViewMode = 'Quake'
        $script:Cfg.StartHidden = $true
        $script:Cfg.DropdownHotkey = 'Shift+F12'
        $script:Cfg.DropdownMonitor = 'Active'
        $script:Cfg.DropdownHideOnFocusLoss = $true
        $script:Cfg.Sections = @{ claude = $true; codex = $false; cursor = $true; grok = $true }
        Save-UnifiedState
        (Test-Path -LiteralPath $script:StatePath) | Should -BeTrue

        $script:Cfg = @{}
        Initialize-UnifiedCfg
        Test-UnifiedFirstRun | Should -BeFalse
        Load-UnifiedState

        $script:Cfg.Theme | Should -Be 'Nord'
        [double]$script:Cfg.Opacity | Should -Be 0.6
        [bool]$script:Cfg.Compact | Should -BeTrue
        [bool]$script:Cfg.ShowStats | Should -BeFalse
        [bool]$script:Cfg.ShowGraph | Should -BeTrue
        [bool]$script:Cfg.ShowAlerts | Should -BeFalse
        $script:Cfg.ViewMode | Should -Be 'Quake'
        [bool]$script:Cfg.StartHidden | Should -BeTrue
        $script:Cfg.DropdownHotkey | Should -Be 'Shift+F12'
        $script:Cfg.DropdownMonitor | Should -Be 'Active'
        [bool]$script:Cfg.DropdownHideOnFocusLoss | Should -BeTrue
        [bool]$script:Cfg.Sections.claude | Should -BeTrue
        [bool]$script:Cfg.Sections.codex | Should -BeFalse
        (Get-OverlayPersistedSettingKeys) | Should -Contain 'Theme'
        (Get-OverlayPersistedSettingKeys) | Should -Contain 'ViewMode'
        (Get-OverlayPersistedSettingKeys) | Should -Contain 'StartHidden'
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
