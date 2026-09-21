# Layout.Tests.ps1 - vertical-fit math for the pinned overlay.
# Pure arithmetic, no WPF types, so this runs headless under Pester 5.

BeforeAll {
    . (Join-Path $PSScriptRoot '..\src\Layout.ps1')
}

Describe 'Get-FitBudget' {
    It 'reserves the corner inset on both edges' {
        Get-FitBudget -WorkAreaHeight 816 -Inset 16 | Should -Be 784
    }

    It 'defaults to the 16px inset Snap-ToCorner uses' {
        Get-FitBudget -WorkAreaHeight 816 | Should -Be 784
    }

    It 'never returns a negative budget on an absurdly short work area' {
        Get-FitBudget -WorkAreaHeight 10 -Inset 16 | Should -Be 0
    }

    It 'falls back to a usable budget when the work area is not finite' {
        Get-FitBudget -WorkAreaHeight ([double]::NaN) | Should -BeGreaterThan 0
    }
}

Describe 'Get-SectionScrollMaxHeight' {
    It 'returns null when the content already fits, so no clamp is applied' {
        Get-SectionScrollMaxHeight -DesiredTotal 700 -ScrollNatural 560 -Budget 784 |
            Should -BeNullOrEmpty
    }

    It 'returns null when the content exactly fills the budget' {
        Get-SectionScrollMaxHeight -DesiredTotal 784 -ScrollNatural 640 -Budget 784 |
            Should -BeNullOrEmpty
    }

    It 'absorbs the whole overflow out of the scroll region' {
        # 912 desired vs 784 budget = 128 over; scroll gives up exactly that much.
        Get-SectionScrollMaxHeight -DesiredTotal 912 -ScrollNatural 760 -Budget 784 |
            Should -Be 632
    }

    It 'leaves the chrome untouched - only the scroll region shrinks' {
        $chrome = 912 - 760
        $max = Get-SectionScrollMaxHeight -DesiredTotal 912 -ScrollNatural 760 -Budget 784
        ($max + $chrome) | Should -Be 784
    }

    It 'floors the scroll region at MinScroll rather than collapsing it' {
        Get-SectionScrollMaxHeight -DesiredTotal 900 -ScrollNatural 200 -Budget 300 -MinScroll 120 |
            Should -Be 120
    }

    It 'returns null for non-finite measurements instead of clamping to garbage' {
        Get-SectionScrollMaxHeight -DesiredTotal ([double]::NaN) -ScrollNatural 760 -Budget 784 |
            Should -BeNullOrEmpty
        Get-SectionScrollMaxHeight -DesiredTotal 912 -ScrollNatural ([double]::NaN) -Budget 784 |
            Should -BeNullOrEmpty
    }

    It 'returns null when the budget is unusable' {
        Get-SectionScrollMaxHeight -DesiredTotal 912 -ScrollNatural 760 -Budget 0 |
            Should -BeNullOrEmpty
    }
}

Describe 'Get-ClampedWindowHeight' {
    It 'passes content through untouched when it fits' {
        Get-ClampedWindowHeight -DesiredTotal 700 -Budget 784 | Should -Be 700
    }

    It 'caps the window at the budget when content overflows' {
        Get-ClampedWindowHeight -DesiredTotal 912 -Budget 784 | Should -Be 784
    }

    It 'keeps the desired height when the budget is unusable' {
        Get-ClampedWindowHeight -DesiredTotal 912 -Budget 0 | Should -Be 912
    }

    It 'keeps the desired height when it is not finite' {
        # NaN never equals NaN, so assert the property rather than the value.
        [double]::IsNaN((Get-ClampedWindowHeight -DesiredTotal ([double]::NaN) -Budget 784)) |
            Should -BeTrue
    }
}

Describe 'Test-BarSubVisible' {
    It 'hides the row when it would only repeat "used"' {
        Test-BarSubVisible 'used' | Should -BeFalse
    }

    It 'keeps the warn and crit states that carry the actual signal' {
        Test-BarSubVisible 'high'      | Should -BeTrue
        Test-BarSubVisible 'critical!' | Should -BeTrue
    }

    It 'keeps the Cursor request count, which is not a status word' {
        Test-BarSubVisible '284 / 500' | Should -BeTrue
    }

    It 'hides empty or missing text' {
        Test-BarSubVisible ''      | Should -BeFalse
        Test-BarSubVisible $null   | Should -BeFalse
        Test-BarSubVisible '   '   | Should -BeFalse
    }

    It 'ignores surrounding whitespace and case when matching "used"' {
        Test-BarSubVisible ' used ' | Should -BeFalse
        Test-BarSubVisible 'USED'   | Should -BeFalse
    }
}
