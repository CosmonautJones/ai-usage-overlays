#Requires -Module Pester
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $root 'src\Config.ps1')
    . (Join-Path $root 'src\CodexData.ps1')
}

Describe 'Codex published prices' {
    It 'prices gpt-6.1-sol at the short-context standard rate' {
        $v = @{ inputTokens = 1000000; cachedInputTokens = 0; outputTokens = 0 }
        Estimate-CodexCost 'gpt-6.1-sol' $v | Should -Be 2
    }

    It 'prices gpt-5.6-sol below the old gpt-5.5 fallback' {
        $v = @{ inputTokens = 1000000; cachedInputTokens = 250000; outputTokens = 100000 }
        # 750k * $4 + 250k * $0.40 + 100k * $20
        Estimate-CodexCost 'gpt-5.6-sol' $v | Should -Be 5.1
    }

    It 'prices the other recorded Codex models from the same table' {
        $inputOnly = @{ inputTokens = 1000000; cachedInputTokens = 0; outputTokens = 0 }
        Estimate-CodexCost 'gpt-5.6-terra' $inputOnly | Should -Be 2
        Estimate-CodexCost 'gpt-5.6-luna' $inputOnly | Should -Be 0.2
        Estimate-CodexCost 'gpt-5.4' $inputOnly | Should -Be 2.5
        Estimate-CodexCost 'gpt-5.4-mini' $inputOnly | Should -Be 0.75
        Estimate-CodexCost 'gpt-6-astra' $inputOnly | Should -Be 10
        Estimate-CodexCost 'gpt-6-sol' $inputOnly | Should -Be 2
        Estimate-CodexCost 'gpt-6-luna' $inputOnly | Should -Be 0.1
    }

    It 'keeps an unlisted gpt-5 model on the gpt-5.5 rate and other models on the default' {
        $v = @{ inputTokens = 1000000; cachedInputTokens = 0; outputTokens = 0 }
        Estimate-CodexCost 'gpt-5.9-unlisted' $v | Should -Be 5
        Estimate-CodexCost 'codex-auto-review' $v | Should -Be 5
    }
}
