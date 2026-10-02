#Requires -Module Pester
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Config.ps1')
    . (Join-Path $root 'src\Pricing.ps1')
}

Describe 'Estimate-Cost' {
    It 'throws if $script:Prices is not loaded' {
        $savedPrices = $script:Prices
        $script:Prices = $null
        { Estimate-Cost 'claude-sonnet' @{inputTokens=1000000; outputTokens=0; cacheCreationInputTokens=0; cacheReadInputTokens=0} } | Should -Throw
        $script:Prices = $savedPrices
    }
    It 'calculates opus pricing for 1M input tokens' {
        $v = @{inputTokens=1000000; outputTokens=0; cacheCreationInputTokens=0; cacheReadInputTokens=0}
        Estimate-Cost 'claude-opus-4' $v | Should -Be 15.0
    }
    It 'calculates sonnet pricing for 1M input tokens' {
        $v = @{inputTokens=1000000; outputTokens=0; cacheCreationInputTokens=0; cacheReadInputTokens=0}
        Estimate-Cost 'claude-sonnet-4' $v | Should -Be 3.0
    }
    It 'calculates haiku pricing for 1M input tokens' {
        $v = @{inputTokens=1000000; outputTokens=0; cacheCreationInputTokens=0; cacheReadInputTokens=0}
        Estimate-Cost 'claude-haiku-4' $v | Should -Be 1.0
    }
    It 'falls back to sonnet pricing for unknown model names' {
        $v = @{inputTokens=1000000; outputTokens=0; cacheCreationInputTokens=0; cacheReadInputTokens=0}
        # unknown model falls back to sonnet pricing ($3/M)
        Estimate-Cost 'claude-unknown-xyz' $v | Should -Be 3.0
    }
    It 'calculates output token costs' {
        $v = @{inputTokens=0; outputTokens=1000000; cacheCreationInputTokens=0; cacheReadInputTokens=0}
        Estimate-Cost 'claude-opus-4' $v | Should -Be 75.0
    }
    It 'calculates fable pricing for 1M input tokens' {
        $v = @{inputTokens=1000000; outputTokens=0; cacheCreationInputTokens=0; cacheReadInputTokens=0}
        Estimate-Cost 'claude-fable-5' $v | Should -Be 10.0
    }
    It 'returns zero cost for synthetic model' {
        $v = @{inputTokens=1000000; outputTokens=1000000; cacheCreationInputTokens=1000000; cacheReadInputTokens=1000000}
        Estimate-Cost '<synthetic>' $v | Should -Be 0.0
    }
}

Describe 'Estimate-CodexCost against the shipped price table' {
    BeforeAll {
        function Get-WslHomeRoots { return @() }
        . (Join-Path $root 'src\CodexData.ps1')
        $script:CodexPriceLog = [System.Collections.Generic.List[string]]::new()
        function Write-Log { param([string]$Message) $script:CodexPriceLog.Add($Message) }
    }

    # developers.openai.com/api/docs/models/gpt-6-astra, checked 2026-09-21:
    # $10 input, $1 cached input, $50 output per 1M tokens.
    It 'prices gpt-6-astra at its published rates' {
        $v = @{ inputTokens = 1000000; cachedInputTokens = 250000; outputTokens = 100000 }
        Estimate-CodexCost 'gpt-6-astra' $v | Should -Be 12.75
    }

    It 'knows gpt-6-astra, so it never falls back with a warning' {
        $script:CodexPriceLog.Clear()
        [void](Estimate-CodexCost 'gpt-6-astra' @{ inputTokens = 1; cachedInputTokens = 0; outputTokens = 0 })
        $script:CodexPriceLog | Should -BeNullOrEmpty
    }

    It 'leaves gpt-5.5 at its existing rates' {
        $v = @{ inputTokens = 1000000; cachedInputTokens = 250000; outputTokens = 100000 }
        Estimate-CodexCost 'gpt-5.5' $v | Should -Be 6.875
    }
}
