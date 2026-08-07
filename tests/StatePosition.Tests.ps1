#Requires -Module Pester

Describe 'Unified state positioning' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Cfg = @{}
        . (Join-Path $root 'src\UnifiedState.ps1')
        function Save-UnifiedState { }
    }

    BeforeEach {
        $script:window = [pscustomobject]@{
            Left         = 100.0
            Top          = 50.0
            ActualWidth  = 0.0
            ActualHeight = 0.0
            Width        = [double]::NaN
            Height       = [double]::NaN
            RenderSize   = [pscustomobject]@{ Width = 280.0; Height = 160.0 }
            DesiredSize  = [pscustomobject]@{ Width = 260.0; Height = 140.0 }
        }
    }

    It 'converts monitor work area from the window screen origin, not virtual desktop zero' {
        $area = [pscustomobject]@{
            Left = 3000.0; Top = 600.0; Right = 4600.0; Bottom = 1500.0; Width = 1600.0; Height = 900.0
        }
        $transform = [pscustomobject]@{ M11 = 0.5; M22 = 0.5 }
        $origin = [pscustomobject]@{ X = 3000.0; Y = 600.0 }

        $result = ConvertFrom-ScreenWorkArea $area $transform $origin

        $result.Left   | Should -Be 100.0
        $result.Top    | Should -Be 50.0
        $result.Right  | Should -Be 900.0
        $result.Bottom | Should -Be 500.0
    }

    It 'snaps bottom-right using rendered size when actual and explicit sizes are not usable' {
        function Get-WorkArea { @{ Left = 0.0; Top = 0.0; Right = 1000.0; Bottom = 800.0 } }

        Snap-ToCorner 'BR'

        $script:window.Left | Should -Be 704.0
        $script:window.Top  | Should -Be 624.0
    }

    It 'maps each menu corner key to the matching work-area corner' {
        function Get-WorkArea { @{ Left = 10.0; Top = 20.0; Right = 1010.0; Bottom = 820.0 } }
        $script:window.ActualWidth = 200.0
        $script:window.ActualHeight = 100.0

        Snap-ToCorner 'TR'
        $script:window.Left | Should -Be 794.0
        $script:window.Top  | Should -Be 36.0

        Snap-ToCorner 'TL'
        $script:window.Left | Should -Be 26.0
        $script:window.Top  | Should -Be 36.0

        Snap-ToCorner 'BR'
        $script:window.Left | Should -Be 794.0
        $script:window.Top  | Should -Be 704.0

        Snap-ToCorner 'BL'
        $script:window.Left | Should -Be 26.0
        $script:window.Top  | Should -Be 704.0
    }
}

Describe 'Off-screen recovery' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Cfg = @{}
        . (Join-Path $root 'src\UnifiedState.ps1')
        function Save-UnifiedState { }
    }

    BeforeEach {
        $script:Positioned = $false
        $script:window = [pscustomobject]@{
            Left         = 100.0
            Top          = 50.0
            ActualWidth  = 300.0
            ActualHeight = 400.0
            Width        = [double]::NaN
            Height       = [double]::NaN
            RenderSize   = [pscustomobject]@{ Width = 300.0; Height = 400.0 }
            DesiredSize  = [pscustomobject]@{ Width = 300.0; Height = 400.0 }
        }
        function Resize-ToContent { }
    }

    Context 'Test-RectOnAnyScreen geometry' {
        BeforeEach {
            $single = @( @{ Left = 0.0; Top = 0.0; Right = 3440.0; Bottom = 1392.0 } )
        }

        It 'accepts a rectangle fully inside a monitor' {
            Test-RectOnAnyScreen -Left 100 -Top 50 -Width 300 -Height 400 -Screens $single | Should -BeTrue
        }

        It 'rejects a rectangle stranded off all monitors (disconnected left monitor)' {
            Test-RectOnAnyScreen -Left -2428 -Top 323 -Width 300 -Height 400 -Screens $single | Should -BeFalse
        }

        It 'accepts a rectangle that lives on a secondary monitor in the list' {
            $two = @(
                @{ Left = 0.0;     Top = 0.0; Right = 3440.0; Bottom = 1392.0 },
                @{ Left = -2560.0; Top = 0.0; Right = 0.0;    Bottom = 1440.0 }
            )
            Test-RectOnAnyScreen -Left -2428 -Top 323 -Width 300 -Height 400 -Screens $two | Should -BeTrue
        }

        It 'rejects when only a sliver overlaps (below the min-visible threshold)' {
            # window sits so only 10px pokes onto the monitor
            Test-RectOnAnyScreen -Left -290 -Top 50 -Width 300 -Height 400 -Screens $single | Should -BeFalse
        }
    }

    Context 'Position-Window recovery' {
        It 'snaps to a corner when the saved position is off every monitor' {
            $script:Cfg = @{ Left = -2428.0; Top = 323.0 }
            function Get-ScreenWorkAreas { @( @{ Left = 0.0; Top = 0.0; Right = 3440.0; Bottom = 1392.0 } ) }
            function Get-DeviceScale { @{ X = 1.0; Y = 1.0 } }
            function Get-WorkArea { @{ Left = 0.0; Top = 0.0; Right = 3440.0; Bottom = 1392.0 } }

            Position-Window

            # TR corner: Left = Right - width - 16 = 3440 - 300 - 16 = 3124; Top = 16
            $script:window.Left | Should -Be 3124.0
            $script:window.Top  | Should -Be 16.0
        }

        It 'honours a saved position that is still on a connected monitor' {
            $script:Cfg = @{ Left = 200.0; Top = 120.0 }
            function Get-ScreenWorkAreas { @( @{ Left = 0.0; Top = 0.0; Right = 3440.0; Bottom = 1392.0 } ) }
            function Get-DeviceScale { @{ X = 1.0; Y = 1.0 } }
            function Get-WorkArea { @{ Left = 0.0; Top = 0.0; Right = 3440.0; Bottom = 1392.0 } }

            Position-Window

            $script:window.Left | Should -Be 200.0
            $script:window.Top  | Should -Be 120.0
        }
    }
}

Describe 'Legacy state positioning' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        . (Join-Path $root 'src\State.ps1')
        function Save-State { }
    }

    BeforeEach {
        $script:window = [pscustomobject]@{
            Left         = 100.0
            Top          = 50.0
            ActualWidth  = 0.0
            ActualHeight = 0.0
            Width        = [double]::NaN
            Height       = [double]::NaN
            RenderSize   = [pscustomobject]@{ Width = 280.0; Height = 160.0 }
            DesiredSize  = [pscustomobject]@{ Width = 260.0; Height = 140.0 }
        }
    }

    It 'converts monitor work area from the window screen origin, not virtual desktop zero' {
        $area = [pscustomobject]@{
            Left = 3000.0; Top = 600.0; Right = 4600.0; Bottom = 1500.0; Width = 1600.0; Height = 900.0
        }
        $transform = [pscustomobject]@{ M11 = 0.5; M22 = 0.5 }
        $origin = [pscustomobject]@{ X = 3000.0; Y = 600.0 }

        $result = ConvertFrom-ScreenWorkArea $area $transform $origin

        $result.Left   | Should -Be 100.0
        $result.Top    | Should -Be 50.0
        $result.Right  | Should -Be 900.0
        $result.Bottom | Should -Be 500.0
    }

    It 'snaps bottom-right using rendered size when actual and explicit sizes are not usable' {
        function Get-WorkArea { @{ Left = 0.0; Top = 0.0; Right = 1000.0; Bottom = 800.0 } }

        Snap-ToCorner 'BR'

        $script:window.Left | Should -Be 704.0
        $script:window.Top  | Should -Be 624.0
    }
}
Describe 'Unified state persistence repair' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        function Write-Log { param([string]$Message) }
        . (Join-Path $root 'src\UnifiedState.ps1')
    }

    BeforeEach {
        $script:Cfg = @{}
        $script:window = $null
        $script:StatePath = Join-Path $TestDrive 'unified-overlay-state.json'
        $script:UnifiedStateNeedsRepair = $false
        Initialize-UnifiedCfg
    }

    It 'normalizes legacy timestamp objects before saving' {
        [pscustomobject]@{
            LastUpdateCheckAt = [pscustomobject]@{ value = '2026-07-01T12:34:56.0000000Z' }
        } | ConvertTo-Json | Set-Content -Path $script:StatePath -Encoding UTF8

        Load-UnifiedState

        $script:Cfg.LastUpdateCheckAt | Should -BeOfType [datetime]
        $script:UnifiedStateNeedsRepair | Should -BeTrue

        Save-UnifiedState

        $saved = Get-Content $script:StatePath -Raw | ConvertFrom-Json
        $saved.LastUpdateCheckAt | Should -BeOfType [string]
    }

    It 'marks corrupt state for repair during hidden startup' {
        Set-Content -Path $script:StatePath -Value '{not valid json' -Encoding UTF8

        Load-UnifiedState

        $script:UnifiedStateNeedsRepair | Should -BeTrue
        Save-UnifiedState
        { Get-Content $script:StatePath -Raw | ConvertFrom-Json } | Should -Not -Throw
    }
}
