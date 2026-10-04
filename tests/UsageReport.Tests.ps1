#Requires -Module Pester

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $root
    . (Join-Path $root 'src\Config.ps1')
    . (Join-Path $root 'src\Format.ps1')
    . (Join-Path $root 'src\Pricing.ps1')
    . (Join-Path $root 'src\Data.ps1')
    . (Join-Path $root 'src\CodexData.ps1')
    . (Join-Path $root 'src\Export.ps1')
    . (Join-Path $root 'src\UsageReport.ps1')
}

Describe 'Lifetime model rollup' {
    It 'ranks Claude models by context and counts cache-read against input plus cache write' {
        $records = @(
            @{ Model='claude-opus-4-8'; Date=[datetime]'2026-06-10'; In=100L; Out=50L; CacheW=0L; CacheR=900L; SessionId='a'; Key='a' }
            @{ Model='claude-sonnet-4-6'; Date=[datetime]'2026-06-10'; In=100L; Out=10L; CacheW=0L; CacheR=0L; SessionId='b'; Key='b' }
        )
        $s = Measure-Stats $records ([datetime]'2026-06-10')
        @($s.Models).Count | Should -Be 2
        $s.Models[0].Name | Should -Be 'claude-opus-4-8'
        $s.Models[0].Cached | Should -Be 900
        $s.Models[0].CacheBase | Should -Be 1000
        Format-TopModelLine $s | Should -Be 'claude-opus-4-8  90% cache'
        Format-TopModelTooltip $s | Should -Match '91% of input'
        Format-TopModelTooltip $s | Should -Match '0\.05 out per input'
        $sum = 0.0
        foreach ($row in @($s.Models)) { $sum += [double]$row.Cost }
        [math]::Abs($sum - [double]$s.ValueUSD) | Should -BeLessThan 0.001
    }

    It 'ranks Codex models by input and treats cached input as part of input' {
        $records = @(
            @{ Model='gpt-5.4'; Date=[datetime]'2026-06-10'; In=100L; CachedIn=0L; Out=10L; SessionId='a' }
            @{ Model='gpt-5.5'; Date=[datetime]'2026-06-10'; In=1000L; CachedIn=940L; Out=10L; SessionId='b' }
        )
        $s = Measure-CodexStats $records ([datetime]'2026-06-10')
        $s.Models[0].Name | Should -Be 'gpt-5.5'
        $s.Models[0].CacheBase | Should -Be 1000
        Format-TopModelLine $s | Should -Be 'gpt-5.5  94% cache'
        $lines = @(Get-CodexExportLines -Stats $s -ModelDetailLimit 8)
        ($lines -join "`n") | Should -Match 'Codex top model: gpt-5\.5  94% cache'
        ($lines -join "`n") | Should -Match '91% of input'
    }

    It 'returns no model rows for an empty log' {
        $s = Measure-Stats @() ([datetime]'2026-06-10')
        @($s.Models).Count | Should -Be 0
        Format-TopModelLine $s | Should -BeNullOrEmpty
    }

    It 'caps clipboard model lines and keeps every model in the report file' {
        $rows = foreach ($i in 1..9) {
            [pscustomobject]@{ Name = "model-$i"; In = [long]($i * 10); Out = 1L; Cached = 0L; CacheBase = [long]($i * 10); Cost = 1.0; Turns = 1 }
        }
        $stats = @{ Models = $rows }
        $capped = @(Get-ModelUsageExportLines -Stats $stats -Label 'Claude' -Limit 8)
        $capped.Count | Should -Be 9
        $capped[-1] | Should -Be 'Claude models: 1 more in usage-report.txt'

        $script:AppDir = $TestDrive
        $script:AppVersion = '0.4.3'
        $script:State = $null
        $script:Stats = $stats
        $script:CodexStats = $null
        $script:ClaudeIdentity = $null
        $script:SummaryData = $null
        $script:LocalData = $null
        $script:GrokUsage = $null
        $script:Cfg = @{ Sections = @{ claude = $true; codex = $true; cursor = $true; grok = $true } }
        Write-UsageReport
        $path = Join-Path $TestDrive 'usage-report.txt'
        $text = Get-Content -LiteralPath $path -Raw
        $text | Should -Match 'model-9'
        $text | Should -Match 'model-1'
        $text | Should -Not -Match 'more in usage-report'
        $text | Should -Match 'Grok lifetime tokens: not logged'
        $text | Should -Match 'not the subscription bill'
        $text | Should -Match 'Codex cache is cached input'

        Set-Content -LiteralPath $path -Value 'stale' -Encoding utf8
        Write-UsageReport
        (Get-Content -LiteralPath $path -Raw) | Should -Not -Match '^stale'
    }
}
