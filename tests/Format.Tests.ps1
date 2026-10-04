#Requires -Module Pester
BeforeAll {
    # Dot-source the pure formatting functions (no WPF assemblies needed for these)
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Config.ps1')   # needed for $script:AppDir etc.
    . (Join-Path $root 'src\Format.ps1')   # defines Format-Reset, Fmt-Tok, Fmt-Money, Remaining-Color
    $script:ResetPattern = [regex]::Escape([string][char]0x21BA)
}

Describe 'Format-Reset' {
    It 'returns empty string for null/empty input' {
        Format-Reset $null  | Should -Be ''
        Format-Reset ''     | Should -Be ''
    }
    It 'returns "now" for a past date' {
        $past = (Get-Date).AddMinutes(-5) | Get-Date -Format 'o'
        Format-Reset $past | Should -Be 'now'
    }
    It 'returns minutes format for < 1 hour' {
        $future = (Get-Date).AddMinutes(15) | Get-Date -Format 'o'
        Format-Reset $future | Should -Match "^$script:ResetPattern \d+m$"
    }
    It 'returns hours+minutes format for 1-24 hours' {
        $future = (Get-Date).AddHours(2).AddMinutes(30) | Get-Date -Format 'o'
        Format-Reset $future | Should -Match "^$script:ResetPattern \d+h\d{2}m$"
    }
    It 'floors the hours component (does not round up)' {
        # 1h40m remaining must show 1h, not 2h - guards against [int] banker-rounding
        $future = (Get-Date).AddHours(1).AddMinutes(40) | Get-Date -Format 'o'
        Format-Reset $future | Should -Match "^$script:ResetPattern 1h\d{2}m$"
    }
    It 'returns days+hours format for >= 1 day' {
        $future = (Get-Date).AddDays(2).AddHours(3) | Get-Date -Format 'o'
        Format-Reset $future | Should -Match "^$script:ResetPattern \d+d \d+h$"
    }
    It 'floors the days component (does not round up)' {
        # 2d18h remaining must show 2d, not 3d
        $future = (Get-Date).AddDays(2).AddHours(18) | Get-Date -Format 'o'
        Format-Reset $future | Should -Match "^$script:ResetPattern 2d \d+h$"
    }
    It 'returns empty string for invalid ISO string' {
        Format-Reset 'not-a-date' | Should -Be ''
    }
}

Describe 'Fmt-Tok' {
    It 'formats numbers below 1000 as integer' {
        Fmt-Tok 0   | Should -Be '0'
        Fmt-Tok 999 | Should -Be '999'
    }
    It 'formats thousands with k suffix' {
        Fmt-Tok 1000    | Should -Be '1.0k'
        Fmt-Tok 1500    | Should -Be '1.5k'
        Fmt-Tok 500000  | Should -Be '500.0k'
    }
    It 'formats millions with M suffix' {
        Fmt-Tok 1000000   | Should -Be '1.0M'
        Fmt-Tok 1500000   | Should -Be '1.5M'
    }
}

Describe 'Fmt-Money' {
    It 'formats with dollar sign and no decimal' {
        Fmt-Money 0      | Should -Be '$0'
        Fmt-Money 1234   | Should -Be '$1,234'
        Fmt-Money 1234.9 | Should -Be '$1,235'
    }
}

Describe 'Remaining-Color' {
    It 'returns red for <= 5% remaining' {
        Remaining-Color 0 | Should -Be '#F87171'
        Remaining-Color 5 | Should -Be '#F87171'
    }
    It 'returns amber for 6-20% remaining' {
        Remaining-Color 6  | Should -Be '#FBBF24'
        Remaining-Color 20 | Should -Be '#FBBF24'
    }
    It 'returns white for > 20% remaining' {
        Remaining-Color 21  | Should -Be '#F1F5F9'
        Remaining-Color 100 | Should -Be '#F1F5F9'
    }
}

Describe 'Format-CodexCreditsRemaining' {
    It 'rounds a decimal balance the way Settings shows it' {
        Format-CodexCreditsRemaining '61119.6042005000' $false | Should -Be '61,120 remaining'
        Format-CodexCreditsRemaining 61902.7572305 $false | Should -Be '61,903 remaining'
    }

    It 'shows unlimited instead of a number' {
        Format-CodexCreditsRemaining 0 $true | Should -Be 'unlimited'
    }

    It 'stays blank when the balance was not sent' {
        Format-CodexCreditsRemaining $null $false | Should -Be '--'
        Format-CodexCreditsRemaining 'not-a-balance' $false | Should -Be '--'
    }
}
