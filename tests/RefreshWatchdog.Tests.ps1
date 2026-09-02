#Requires -Module Pester

Describe 'Refresh job watchdog' {
    BeforeAll {
        $root = Split-Path $PSScriptRoot -Parent
        $source = Get-Content (Join-Path $root 'unified-overlay.ps1') -Raw -Encoding UTF8
        $start = $source.IndexOf('function Start-AllRefreshJobs {')
        $end = $source.IndexOf("`nfunction Complete-RefreshJobs {", $start)

        if ($start -lt 0 -or $end -lt 0) {
            throw 'Could not load Start-AllRefreshJobs from unified-overlay.ps1.'
        }

        . ([scriptblock]::Create($source.Substring($start, $end - $start)))

        function Write-Log {
            param([string]$Message)
        }

        function Start-OverlayBackgroundJob {
            param(
                [Parameter(Mandatory = $true)][scriptblock]$ScriptBlock,
                [object[]]$ArgumentList = @()
            )
        }
    }

    BeforeEach {
        $script:pollJobs = @{}
        $script:pollJobStartedAt = @{}
        $script:ClaudeUsageScript = {}
        $script:ClaudeStatsScript = {}
        $script:CodexStatsScript = {}
        $script:GrokUsageScript = {}
        $script:AppDir = 'C:\overlay'
        $script:CredPath = 'C:\overlay\credentials.json'
        $script:ErrLog = 'C:\overlay\errors.log'
        $script:nextJobId = 0

        Mock Start-OverlayBackgroundJob {
            $script:nextJobId++
            [pscustomobject]@{
                State = 'Running'
                Id    = $script:nextJobId
            }
        }
        Mock Stop-Job {}
        Mock Remove-Job {}
        Mock Write-Log {}
        Mock Get-Command { $null }
    }

    It 'reaps a running job past the timeout ceiling and starts a replacement' {
        $oldJob = [pscustomobject]@{ State = 'Running'; Id = 0 }
        $script:pollJobs['ClaudeUsage'] = $oldJob
        $script:pollJobStartedAt['ClaudeUsage'] = (Get-Date).AddSeconds(-61)

        Start-AllRefreshJobs -UsageTimeoutSec 20

        Assert-MockCalled Stop-Job -Times 1 -Exactly
        Assert-MockCalled Remove-Job -Times 1 -Exactly
        Assert-MockCalled Start-OverlayBackgroundJob -Times 4 -Exactly
        Assert-MockCalled Write-Log -Times 1 -Exactly -ParameterFilter {
            $Message -match 'hung > 60 seconds; reaping and restarting\.'
        }
        $script:pollJobs['ClaudeUsage'].Id | Should -Be 1
        $script:pollJobStartedAt.ContainsKey('ClaudeUsage') | Should -BeTrue
    }

    It 'keeps a running job within the timeout ceiling' {
        $oldJob = [pscustomobject]@{ State = 'Running'; Id = 0 }
        $script:pollJobs['ClaudeUsage'] = $oldJob
        $script:pollJobStartedAt['ClaudeUsage'] = (Get-Date).AddSeconds(-30)

        Start-AllRefreshJobs -UsageTimeoutSec 20

        Assert-MockCalled Stop-Job -Times 0 -Exactly
        Assert-MockCalled Remove-Job -Times 0 -Exactly
        Assert-MockCalled Start-OverlayBackgroundJob -Times 3 -Exactly
        $script:pollJobs['ClaudeUsage'].Id | Should -Be 0
    }
}

Describe 'Resolve-ClaudeUsageState' {
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

    It 'preserves known data while adopting an empty result status and message' {
        $knownData = @{ five_hour = @{ utilization = 42 } }
        $previous = @{ Data = $knownData; Status = 'ok'; Message = ''; LastFetch = 'old' }
        $incoming = @{ Data = $null; Status = 'backoff'; Message = 'retry later'; LastFetch = 'new' }

        $result = Resolve-ClaudeUsageState $previous $incoming

        $result.Data | Should -Be $knownData
        $result.Status | Should -Be 'backoff'
        $result.Message | Should -Be 'retry later'
        $result.LastFetch | Should -Be 'new'
    }

    It 'uses fresh incoming data when it is available' {
        $previous = @{ Data = @{ five_hour = @{ utilization = 42 } } }
        $freshData = @{ five_hour = @{ utilization = 55 } }
        $incoming = @{ Data = $freshData; Status = 'ok' }

        $result = Resolve-ClaudeUsageState $previous $incoming

        $result.Data | Should -Be $freshData
    }

    It 'handles null previous and incoming values' {
        { Resolve-ClaudeUsageState $null $null } | Should -Not -Throw

        $incoming = @{ Data = $null; Status = 'auth' }
        { Resolve-ClaudeUsageState $null $incoming } | Should -Not -Throw
        (Resolve-ClaudeUsageState $null $null) | Should -BeNullOrEmpty
        (Resolve-ClaudeUsageState $null $incoming).Data | Should -BeNullOrEmpty
    }
}
