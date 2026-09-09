BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    function Get-ContextMenuScreenPoint { [pscustomobject]@{X=10250;Y=1250} }
}

Describe 'Panel menu screen coordinates' {
    It 'keeps native menu coordinates aligned after WPF startup in <Entry>' -ForEach @(
        @{Entry='unified-overlay.ps1'}, @{Entry='overlay.ps1'}, @{Entry='cursor-overlay.ps1'}
    ) {
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -STA -File "$PSScriptRoot/MenuDpiProbe.ps1" -EntryPoint "$root/$Entry" 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $output | Should -Contain 'Menu DPI placement passed'
    }

    It 'uses the menu coordinate space in <File> without converting WPF coordinates' -ForEach @(
        @{File='UnifiedTray.ps1'}, @{File='Tray.ps1'}
    ) {
        $source = Get-Content "$root/src/$File" -Raw
        $tokens=$null; $errors=$null
        $ast=[System.Management.Automation.Language.Parser]::ParseInput($source,[ref]$tokens,[ref]$errors)
        $fn=$ast.Find({param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Show-ContextMenuAtWpfPointer'},$true)
        . ([scriptblock]::Create($fn.Extent.Text))
        $script:window=[pscustomobject]@{}
        $script:window | Add-Member ScriptMethod PointToScreen {param($p) [pscustomobject]@{X=4100;Y=500}}
        $evt=[pscustomobject]@{Handled=$false}
        $evt | Add-Member ScriptMethod GetPosition {param($window) [pscustomobject]@{X=50;Y=300}}
        $script:ctxStrip=[pscustomobject]@{ShownAt=$null}
        $script:ctxStrip | Add-Member ScriptMethod Show {param($x,$y)
            if ($null -eq $y) {$this.ShownAt=$x} else {$this.ShownAt=[pscustomobject]@{X=$x;Y=$y}}
        }
        Mock Get-ContextMenuScreenPoint { [pscustomobject]@{X=10250;Y=1250} }
        Show-ContextMenuAtWpfPointer $evt
        $script:ctxStrip.ShownAt.X | Should -Be 10250
        $script:ctxStrip.ShownAt.Y | Should -Be 1250
        $evt.Handled | Should -BeTrue
    }
}
