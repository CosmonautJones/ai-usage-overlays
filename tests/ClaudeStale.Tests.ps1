#Requires -Module Pester
#
# Carrying the last good Claude numbers forward is right - they are still the
# most recent real reading. Presenting them as live is not: the overlay drew 32%
# with a reset time already in the past while the API was returning 8%. These
# cover the flag Resolve-ClaudeUsageState raises and the way Shell.ps1 draws it.
BeforeAll {
    $script:Root = Split-Path $PSScriptRoot -Parent
    $script:ShellSource = Get-Content (Join-Path $script:Root 'src\Shell.ps1') -Raw -Encoding UTF8
}

Describe 'Resolve-ClaudeUsageState marks carried-forward data' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $source = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $start = $source.IndexOf('function Resolve-ClaudeUsageState {')
        $end = $source.IndexOf("`nfunction Complete-RefreshJobs {", $start)

        if ($start -lt 0 -or $end -lt 0) {
            throw 'Could not load Resolve-ClaudeUsageState from unified-overlay.ps1.'
        }

        . ([scriptblock]::Create($source.Substring($start, $end - $start)))
    }

    It 'flags carried-forward data and keeps the fetch time it came from' {
        $knownData = @{ five_hour = @{ utilization = 32 } }
        $previous = @{ Data = $knownData; Status = 'ok'; Message = ''; LastFetch = '19:12' }
        $incoming = @{ Data = $null; Status = 'auth'; Message = 'Auth expired'; LastFetch = '' }

        $result = Resolve-ClaudeUsageState $previous $incoming

        $result.Data | Should -Be $knownData
        $result.Stale | Should -BeTrue
        $result.DataAsOf | Should -Be '19:12'
    }

    It 'keeps the original fetch time across a run of failed polls' {
        $knownData = @{ five_hour = @{ utilization = 32 } }
        $previous = @{ Data = $knownData; Status = 'auth'; Message = 'Auth expired'; LastFetch = ''; Stale = $true; DataAsOf = '19:12' }
        $incoming = @{ Data = $null; Status = 'auth'; Message = 'Auth expired'; LastFetch = '' }

        $result = Resolve-ClaudeUsageState $previous $incoming

        $result.Stale | Should -BeTrue
        $result.DataAsOf | Should -Be '19:12'
    }

    It 'clears the flag when a poll brings fresh data back' {
        $previous = @{ Data = @{ five_hour = @{ utilization = 32 } }; Status = 'auth'; Stale = $true; DataAsOf = '19:12' }
        $freshData = @{ five_hour = @{ utilization = 8 } }
        $incoming = @{ Data = $freshData; Status = 'ok'; Message = ''; LastFetch = '19:40' }

        $result = Resolve-ClaudeUsageState $previous $incoming

        $result.Data | Should -Be $freshData
        $result.Stale | Should -BeFalse
        $result.DataAsOf | Should -Be '19:40'
    }

    It 'leaves a first-ever empty result unflagged' {
        $incoming = @{ Data = $null; Status = 'auth'; Message = 'Auth expired'; LastFetch = '' }

        $result = Resolve-ClaudeUsageState $null $incoming

        $result.Data | Should -BeNullOrEmpty
        $result.Stale | Should -BeFalse
    }
}

Describe 'Shell renders stale Claude data honestly' {
    It 'dims the section and swaps countdowns for the fetch time' {
        $shell = (Get-Process -Id $PID).Path
        $output = & $shell -NoProfile -STA -File "$PSScriptRoot/ClaudeStaleProbe.ps1" -Root $script:Root 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        $output | Should -Contain 'Claude stale render passed'
    }

    It 'routes the stale countdown through one formatter' {
        $script:ShellSource | Should -Match 'function Format-ClaudeStaleReset'
        $script:ShellSource | Should -Match '\$ResetOverride'
    }
}
