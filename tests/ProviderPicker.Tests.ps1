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

Describe 'New-ProviderPickerForm layout' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing

        function Get-LeafControls($parent) {
            foreach ($c in $parent.Controls) {
                if ($c -is [System.Windows.Forms.TableLayoutPanel] -or $c -is [System.Windows.Forms.FlowLayoutPanel]) {
                    Get-LeafControls $c
                } else { $c }
            }
        }

        function Get-FormRect($form, $c) {
            $p = $form.PointToClient($c.Parent.PointToScreen($c.Location))
            New-Object System.Drawing.Rectangle($p, $c.Size)
        }
    }

    # 10pt is 100% scaling; 20pt approximates a 200% display where fonts grow but fixed pixels do not.
    It 'fits every control without clipping or overlap at <Pt>pt' -TestCases @(
        @{ Pt = 10 }, @{ Pt = 15 }, @{ Pt = 20 }
    ) {
        param($Pt)
        $picker = New-ProviderPickerForm -Initial (Get-DefaultUnifiedSections) -FontSize $Pt
        $form = $picker.Form
        try {
            $form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
            $form.Location = New-Object System.Drawing.Point(-32000, -32000)
            $form.Show()
            $form.PerformLayout()

            $leaves = @(Get-LeafControls $form)
            $leaves.Count | Should -Be 7
            $client = New-Object System.Drawing.Rectangle([System.Drawing.Point]::Empty, $form.ClientSize)
            $rects = @()
            foreach ($c in $leaves) {
                $r = Get-FormRect $form $c
                $client.Contains($r) | Should -BeTrue -Because "$($c.Text) must sit inside the dialog"
                $c.Width | Should -BeGreaterOrEqual $c.PreferredSize.Width -Because "$($c.Text) must not be truncated"
                $c.Height | Should -BeGreaterOrEqual $c.PreferredSize.Height -Because "$($c.Text) must not be clipped vertically"
                $rects += ,@($c.Text, $r)
            }
            for ($i = 0; $i -lt $rects.Count; $i++) {
                for ($j = $i + 1; $j -lt $rects.Count; $j++) {
                    $rects[$i][1].IntersectsWith($rects[$j][1]) | Should -BeFalse -Because "$($rects[$i][0]) overlaps $($rects[$j][0])"
                }
            }
        } finally {
            $form.Close()
            $form.Dispose()
        }
    }

    It 'seeds checkboxes from the initial map' {
        $picker = New-ProviderPickerForm -Initial @{ claude = $true; codex = $false; cursor = $true; grok = $false }
        try {
            $picker.Checks.claude.Checked | Should -BeTrue
            $picker.Checks.codex.Checked | Should -BeFalse
            $picker.Checks.cursor.Checked | Should -BeTrue
            $picker.Checks.grok.Checked | Should -BeFalse
        } finally { $picker.Form.Dispose() }
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
