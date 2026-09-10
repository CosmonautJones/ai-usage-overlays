BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $source = Get-Content "$root/unified-overlay.ps1" -Raw
    $tokens = $null; $errors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
    $fn = $ast.Find({param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Sync-ClaudePollTimerInterval'}, $true)
    . ([scriptblock]::Create($fn.Extent.Text))
    function Get-ClaudeAdaptivePollSeconds { param($State) return 1800 }
}

Describe 'Shared provider refresh cadence' {
    BeforeEach {
        $script:PollSeconds = 180
        $script:pollTimer = [pscustomobject]@{Interval=[TimeSpan]::FromSeconds(180)}
    }

    It 'does not delay Codex and other providers during a Claude authentication backoff' {
        Mock Get-ClaudeAdaptivePollSeconds { 1800 }
        Sync-ClaudePollTimerInterval @{Status='auth';Data=$null}
        $script:pollTimer.Interval.TotalSeconds | Should -Be 180
    }

    It 'does not delay other providers when Claude usage is unchanged' {
        Mock Get-ClaudeAdaptivePollSeconds { 900 }
        Sync-ClaudePollTimerInterval @{Status='ok'}
        $script:pollTimer.Interval.TotalSeconds | Should -Be 180
    }

    It 'preserves faster refresh near a Claude limit' {
        Mock Get-ClaudeAdaptivePollSeconds { 60 }
        Sync-ClaudePollTimerInterval @{Status='ok'}
        $script:pollTimer.Interval.TotalSeconds | Should -Be 60
    }
}
