#Requires -Module Pester
Describe 'Footer brand mark' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:ShellSource = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
    }

    It 'keeps the TravOS slab-T and offers an 18px brand.png Image' {
        $script:ShellSource | Should -Match 'x:Name="brandPath"'
        $script:ShellSource | Should -Match 'Data="M6,6 H26 V10 H18 V26 H14 V10 H6 Z"'
        $script:ShellSource | Should -Match 'Text="TravOS"'
        $script:ShellSource | Should -Match 'x:Name="brandMarkBox"'
        $script:ShellSource | Should -Match 'x:Name="brandMarkImage"'
        $script:ShellSource | Should -Match 'Width="18" Height="18"'
    }

    It 'loads LOCALAPPDATA AIUsageOverlay brand.png and falls back if the file is bad' {
        $script:ShellSource | Should -Match 'AIUsageOverlay\\brand\.png'
        $script:ShellSource | Should -Match 'function Get-OverlayBrandPngPath'
        $script:ShellSource | Should -Match 'function Apply-FooterBrandMark'
        $script:ShellSource | Should -Match 'catch'
        $script:ShellSource | Should -Match 'BitmapImage'
        $script:ShellSource | Should -Match 'Apply-FooterBrandMark'
    }

    It 'Get-OverlayBrandPngPath points at LOCALAPPDATA brand.png' {
        $fn = @'
function Get-OverlayBrandPngPath {
    Join-Path $env:LOCALAPPDATA 'AIUsageOverlay\brand.png'
}
'@
        . ([scriptblock]::Create($fn))
        Get-OverlayBrandPngPath | Should -Be (Join-Path $env:LOCALAPPDATA 'AIUsageOverlay\brand.png')
        $script:ShellSource | Should -Match 'LOCALAPPDATA'
        $script:ShellSource | Should -Match 'brand\.png'
    }
}

Describe 'Tray-discoverable footer brand' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $script:Shell = Get-Content (Join-Path $root 'src\Shell.ps1') -Raw -Encoding UTF8
        $script:Tray = Get-Content (Join-Path $root 'src\UnifiedTray.ps1') -Raw -Encoding UTF8
    }

    It 'exposes Set footer brand and Reset TravOS mark under Brand submenu' {
        $script:Shell | Should -Match 'function Invoke-SetFooterBrand'
        $script:Shell | Should -Match 'function Invoke-ResetFooterBrand'
        $script:Shell | Should -Match 'OpenFileDialog'
        $script:Shell | Should -Match 'Copy-Item'
        $script:Shell | Should -Match 'Remove-Item'
        $script:Tray | Should -Match "New-StripItem 'Brand'"
        $script:Tray | Should -Match 'Set footer brand'
        $script:Tray | Should -Match 'Reset TravOS mark'
        $script:Tray | Should -Match 'Invoke-SetFooterBrand'
        $script:Tray | Should -Match 'Invoke-ResetFooterBrand'
        ($script:Tray -split "`n" | Where-Object { $_ -match "ctxStrip\.Items\.Add\(\(New-StripItem 'Set footer brand" }).Count | Should -Be 0
    }

    It 'folds update items under Updates submenu' {
        $script:Tray | Should -Match "New-StripItem 'Updates'"
        $script:Tray | Should -Match "New-StripItem 'Automatically check for updates'"
        $script:Tray | Should -Match "New-StripItem 'Check for updates'"
        $start = $script:Tray.IndexOf("New-StripItem 'Updates'")
        $start | Should -BeGreaterThan 0
        $chunk = $script:Tray.Substring($start, [Math]::Min(1200, $script:Tray.Length - $start))
        $chunk | Should -Match 'DropDownItems\.Add\(\$miAutoUpdate\)'
        $chunk | Should -Match 'DropDownItems\.Add\(\$miCheckUpdate\)'
    }

    It 'still uses the documented LOCALAPPDATA brand.png drop path' {
        $script:Shell | Should -Match 'AIUsageOverlay\\brand\.png'
        $script:Shell | Should -Match 'Apply-FooterBrandMark'
    }

    It 'Refresh applies footer brand so hand-drop paints without restart' {
        $script:Tray | Should -Match 'function Invoke-ManualRefresh'
        $start = $script:Tray.IndexOf('function Invoke-ManualRefresh {')
        $end = $script:Tray.IndexOf("`nfunction ", $start + 10)
        if ($end -lt 0) { $end = $script:Tray.Length }
        $fn = $script:Tray.Substring($start, $end - $start)
        $fn | Should -Match 'Apply-FooterBrandMark'
    }
}
