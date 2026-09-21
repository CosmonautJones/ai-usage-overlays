# ShellFit.Tests.ps1 - the expanded accordion must fit the monitor.
#
# Fully expanded the four provider sections wanted ~912 DIP, which overflowed a
# 1536x864 work area (816 DIP) and ran off the bottom of the screen. Two things
# fixed it: tighter spacing, and a scroll region that absorbs whatever still
# overflows. Layout.Tests.ps1 covers the arithmetic; this covers the real window.
BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:ShellSource = Get-Content (Join-Path $script:Root 'src\Shell.ps1') -Raw -Encoding UTF8
}

Describe 'Expanded accordion fits the monitor' {
    It 'fits every stubbed work area with all four providers open' {
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -STA -File "$PSScriptRoot/ShellFitProbe.ps1" -Root $script:Root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $output | Should -Contain 'Shell fit passed'
    }
}

Describe 'Shell markup carries the scroll region' {
    It 'wraps the provider sections in a clamped ScrollViewer' {
        $script:ShellSource | Should -Match 'x:Name="sectionScroll"'
        $script:ShellSource | Should -Match 'x:Name="sectionStack"'
        $script:ShellSource | Should -Match 'VerticalScrollBarVisibility="Auto"'
        $script:ShellSource | Should -Match 'HorizontalScrollBarVisibility="Disabled"'
    }

    It 'draws the scrollbar as a thin overlay so the 250px bars do not reflow' {
        $script:ShellSource | Should -Match 'x:Key="OverlayScrollBar"'
        $script:ShellSource | Should -Match 'x:Key="OverlayScrollViewer"'
        # Negative right margin parks it in the panel gutter.
        $script:ShellSource | Should -Match 'Value="0,2,-9,2"'
    }

    It 'routes both resize paths through the fitted measurement' {
        $script:ShellSource | Should -Match 'function Measure-FittedSize'
        $script:ShellSource | Should -Match 'Get-SectionScrollMaxHeight'
        $script:ShellSource | Should -Match 'Get-ClampedWindowHeight'
        # Resize-ToContent and Toggle-Section must both use it, not the raw measure.
        ([regex]::Matches($script:ShellSource, 'Measure-FittedSize')).Count |
            Should -BeGreaterOrEqual 3
    }

    It 'starts every bar sub-label collapsed' {
        foreach ($n in 'fivehSub', 'weekSub', 'fabSub', 'opusSub',
                       'codexFivehSub', 'codexWeekSub', 'reqSub', 'grokWeekSub') {
            $script:ShellSource |
                Should -Match ('x:Name="{0}" Visibility="Collapsed"' -f $n)
        }
    }

    It 'funnels sub-label writes through Set-BarSubText' {
        $script:ShellSource | Should -Match 'function Set-BarSubText'
        # No direct .Text assignment to a sub element should remain.
        $script:ShellSource | Should -Not -Match '\$sb\.Text\s*='
        $script:ShellSource | Should -Not -Match '\$sub\.Text\s*='
    }
}

Describe 'Layout module is wired into startup' {
    It 'dot-sources Layout.ps1 before Shell.ps1' {
        $entry = Get-Content (Join-Path $script:Root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $layout = $entry.IndexOf("src\Layout.ps1")
        $shell = $entry.IndexOf("src\Shell.ps1")
        $layout | Should -BeGreaterThan -1
        $layout | Should -BeLessThan $shell
    }
}
