#Requires -Module Pester

Describe 'Quake extra usage' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\QuakeView.ps1')
    }

    It 'converts the existing Claude extra usage fields to display dollars' {
        $display = ConvertTo-QuakeExtraUsage ([pscustomobject]@{
            is_enabled    = $true
            used_credits  = 1234
            monthly_limit = 5000
            currency      = 'USD'
        })

        $display.Used  | Should -Be 12.34
        $display.Limit | Should -Be 50.0
        $display.Symbol | Should -Be '$'
    }

    It 'returns no display data when extra usage is disabled' {
        ConvertTo-QuakeExtraUsage ([pscustomobject]@{
            is_enabled    = $false
            used_credits  = 1234
            monthly_limit = 5000
            currency      = 'USD'
        }) | Should -BeNullOrEmpty
    }
}

Describe 'Quake monitor selection' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $root = Split-Path $PSScriptRoot -Parent
        function Write-Log { param([string]$Message) }
        . (Join-Path $root 'src\Dropdown.ps1')
    }

    BeforeEach {
        $script:Cfg = @{ ViewMode = 'Quake'; DropdownMonitor = 'Primary' }
        $script:DropdownShown = $true
        $script:DropdownAnimating = $true
        $script:window = [pscustomobject]@{ Left = 0.0; Top = 0.0 }
        $script:window | Add-Member ScriptMethod BeginAnimation { param($Property, $Animation) }
        $script:window | Add-Member ScriptMethod UpdateLayout { }
    }

    It 'resizes the visible strip after changing monitors' {
        Mock Resize-QuakeToContent {}
        Mock Get-DropdownGeometry { @{ Left = 1920.0; ShownTop = 0.0 } }

        Set-DropdownMonitor 'DISPLAY2'

        Should -Invoke Resize-QuakeToContent -Times 1 -Exactly
        $script:window.Left | Should -Be 1920.0
        $script:DropdownAnimating | Should -BeFalse
    }
}

Describe 'Quake pinned geometry persistence' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        function Write-Log { param([string]$Message) }
        . (Join-Path $root 'src\UnifiedState.ps1')
    }

    BeforeEach {
        $script:Cfg = @{ Left = 111.0; Top = 222.0; ViewMode = 'Quake' }
        $script:StatePath = Join-Path $TestDrive 'unified-overlay-state.json'
        $script:window = [pscustomobject]@{ Left = 5.0; Top = 6.0 }
        Initialize-UnifiedCfg
    }

    It 'keeps pinned coordinates when saving while Quake is active' {
        Save-UnifiedState

        $saved = Get-Content $script:StatePath -Raw | ConvertFrom-Json
        $saved.Left | Should -Be 111.0
        $saved.Top  | Should -Be 222.0
    }

    It 'initializes the in-memory pinned position from persisted state' {
        $script:PinnedLeft = $null
        $script:PinnedTop = $null

        Initialize-DropdownPinnedPosition

        $script:PinnedLeft | Should -Be 111.0
        $script:PinnedTop  | Should -Be 222.0
    }
}
Describe 'Dropdown assembly references' {
    BeforeAll {
        Add-Type -AssemblyName System.Windows.Forms, System.Drawing
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\Dropdown.ps1')
    }

    It 'returns existing absolute assembly paths for PowerShell 7 compilation' {
        $references = @(Get-DropdownReferencedAssemblies)

        $references.Count | Should -BeGreaterThan 0
        foreach ($reference in $references) {
            [System.IO.Path]::IsPathRooted([string]$reference) | Should -BeTrue
            Test-Path -LiteralPath $reference -PathType Leaf | Should -BeTrue
        }
    }
}
