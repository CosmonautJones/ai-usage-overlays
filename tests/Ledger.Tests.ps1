#Requires -Module Pester
BeforeAll {
    $script:root = Split-Path $PSScriptRoot -Parent
    . (Join-Path $script:root 'src\Metrics.ps1')
}

Describe 'ConvertTo-UsageLedgerRows' {
    It 'keeps token totals and weekly quota, and does not invent Grok tokens' {
        $rows = ConvertTo-UsageLedgerRows -ObservedAt '2026-09-25T21:00:00-04:00' -ClaudeStats @{
            InTokens = 1000; OutTokens = 250; ValueUSD = 4.5; Messages = 8; Sessions = 2; TodayTok = 100; TodayMsg = 1
        } -ClaudeUsage @{ seven_day = @{ utilization = 15 }; five_hour = @{ utilization = 18 } } -CodexStats @{
            InTokens = 50; OutTokens = 10; ValueUSD = 1.25; WeekPct = 99; FiveHourPct = 12
        } -CursorPlan @{ BarPercent = 26; OnDemandUsedCents = 150 } -GrokUsage @{ WeekPct = 22 }

        ($rows | Where-Object provider -eq 'claude').in_tokens | Should -Be 1000
        ($rows | Where-Object provider -eq 'claude').weekly_pct | Should -Be 15
        ($rows | Where-Object provider -eq 'claude').five_hour_pct | Should -Be 18
        ($rows | Where-Object provider -eq 'codex').est_usd | Should -Be 1.25
        ($rows | Where-Object provider -eq 'cursor').on_demand_usd | Should -Be 1.5
        ($rows | Where-Object provider -eq 'cursor').weekly_pct | Should -Be 26
        $grok = $rows | Where-Object provider -eq 'grok'
        $grok.weekly_pct | Should -Be 22
        $grok.in_tokens | Should -BeNullOrEmpty
        $grok.est_usd | Should -BeNullOrEmpty
    }
}

Describe 'Usage ledger math' {
    It 'sums only forward movement and skips a counter reset' {
        $delta = Get-ForwardCounterDelta @(100, 140, 20, 35)
        $delta.Added | Should -Be 55
        $delta.Latest | Should -Be 35
        $delta.Breaks | Should -Be 1
    }

    It 'turns a series into burn, blend, and share without treating a drop as spend' {
        $rows = @(
            @{ provider = 'claude'; observed_at = '2026-09-24T12:00:00-04:00'; in_tokens = 1000; out_tokens = 200; est_usd = 10; weekly_pct = 10 }
            @{ provider = 'claude'; observed_at = '2026-09-25T12:00:00-04:00'; in_tokens = 500; out_tokens = 50; est_usd = 4; weekly_pct = 40 }
            @{ provider = 'claude'; observed_at = '2026-09-26T12:00:00-04:00'; in_tokens = 800; out_tokens = 100; est_usd = 7; weekly_pct = 15 }
            @{ provider = 'codex'; observed_at = '2026-09-24T12:00:00-04:00'; in_tokens = 100; out_tokens = 100; est_usd = 2; weekly_pct = 90 }
            @{ provider = 'codex'; observed_at = '2026-09-26T12:00:00-04:00'; in_tokens = 300; out_tokens = 100; est_usd = 5; weekly_pct = 99 }
            @{ provider = 'grok'; observed_at = '2026-09-26T12:00:00-04:00'; weekly_pct = 22 }
        )
        $math = Get-UsageLedgerMath $rows
        $math.Providers.claude.LatestUsd | Should -Be 7
        $math.Providers.claude.AddedUsd | Should -Be 3
        $math.Providers.claude.AddedTokens | Should -Be 350
        $math.Providers.claude.Breaks | Should -Be 1
        $math.Providers.claude.UsdPerDay | Should -Be 1.5
        $math.Providers.codex.AddedUsd | Should -Be 3
        $math.Providers.codex.UsdPerMillion | Should -Be 12500
        $math.Combined.LatestUsd | Should -Be 12
        $math.Combined.AddedUsd | Should -Be 6
        [math]::Round($math.Providers.claude.Share, 2) | Should -Be 0.58
        $math.Providers.grok.LatestWeeklyPct | Should -Be 22
        $math.Providers.grok.LatestUsd | Should -BeNullOrEmpty
    }

    It 'does not invent a daily burn from one sample' {
        $math = Get-UsageLedgerMath @(@{
            provider = 'claude'; observed_at = '2026-09-26T12:00:00-04:00'; in_tokens = 10; out_tokens = 10; est_usd = 1
        })
        $math.Providers.claude.LatestUsd | Should -Be 1
        $math.Providers.claude.UsdPerDay | Should -BeNullOrEmpty
        $math.Providers.claude.AddedUsd | Should -Be 0
    }
}

Describe 'Format-UsageLedgerReport' {
    It 'labels the figure as an estimate and names providers that have no token ledger' {
        $math = Get-UsageLedgerMath @(
            @{ provider = 'claude'; observed_at = '2026-09-25T12:00:00-04:00'; in_tokens = 1e6; out_tokens = 1e6; est_usd = 20 }
            @{ provider = 'claude'; observed_at = '2026-09-26T12:00:00-04:00'; in_tokens = 2e6; out_tokens = 1e6; est_usd = 30 }
            @{ provider = 'grok'; observed_at = '2026-09-26T12:00:00-04:00'; weekly_pct = 22 }
        )
        $text = (Format-UsageLedgerReport $math) -join "`n"
        $text | Should -Match 'not an invoice'
        $text | Should -Match 'Claude'
        $text | Should -Match '\$10\.00/day'
        $text | Should -Match 'Grok'
        $text | Should -Match 'no token ledger'
        $text | Should -Match '22%'
    }
}

Describe 'Usage history from logs' {
    It 'rolls a day up from message records and scores cache reuse and yield' {
        $records = @(
            @{ Model = 'claude-sonnet'; Date = [datetime]'2026-09-24T12:00:00'; In = 100; Out = 50; CacheW = 0; CacheR = 300; SessionId = 's1'; Cost = 2 }
            @{ Model = 'claude-sonnet'; Date = [datetime]'2026-09-24T20:00:00'; In = 100; Out = 10; CacheW = 0; CacheR = 0; SessionId = 's2'; Cost = 1 }
            @{ Model = 'claude-sonnet'; Date = [datetime]'2026-09-25T12:00:00'; In = 0; Out = 40; CacheW = 0; CacheR = 0; SessionId = 's1'; Cost = 0.5 }
        )
        $rollup = Get-UsageDayRollup -Records $records -Provider 'claude'
        $day = $rollup.Days | Where-Object Day -eq '2026-09-24'
        $day.FreshIn | Should -Be 200
        $day.CacheRead | Should -Be 300
        $day.OutTokens | Should -Be 60
        $day.Messages | Should -Be 2
        $day.Sessions | Should -Be 2
        $day.ReusePct | Should -Be 60
        $day.YieldPer1K | Should -Be 300
        $rollup.Totals.ReusePct | Should -Be 60
        $rollup.Totals.YieldPer1K | Should -Be 500
        [math]::Round($rollup.Totals.UsdPerMessage, 2) | Should -Be 1.17
        $rollup.Totals.AfterHoursShare | Should -BeGreaterThan 0
    }

    It 'treats Codex cached input as reuse and keeps message dates off the token row' {
        $records = @(
            @{ Model = 'gpt-5.4'; Date = [datetime]'2026-09-25T11:00:00'; In = 100; CachedIn = 80; Out = 20; SessionId = 'c1'; Cost = 1; MessageDates = @() }
            @{ Model = 'gpt-5.4'; Date = [datetime]'2026-09-25T11:00:00'; In = 0; CachedIn = 0; Out = 0; SessionId = 'c1'; Cost = 0; MessageDates = @([datetime]'2026-09-25T11:00:00', [datetime]'2026-09-25T11:05:00') }
        )
        $rollup = Get-UsageDayRollup -Records $records -Provider 'codex'
        $rollup.Totals.ReusePct | Should -Be 80
        $rollup.Totals.YieldPer1K | Should -Be 1000
        $rollup.Totals.Messages | Should -Be 2
        $rollup.Days[0].Sessions | Should -Be 1
    }
}

Describe 'Format-UsageHistoryReport' {
    It 'explains the scales and does not invent a Grok token history' {
        $rollup = Get-UsageDayRollup -Records @(
            @{ Date = [datetime]'2026-09-25T12:00:00'; In = 1000; Out = 250; CacheR = 3000; CacheW = 0; SessionId = 's'; Cost = 4 }
        ) -Provider 'claude'
        $text = (Format-UsageHistoryReport @{ claude = $rollup; grok = $null }) -join "`n"
        $text | Should -Match 'not an invoice'
        $text | Should -Match 'reuse'
        $text | Should -Match 'per 1k fresh'
        $text | Should -Match '2026-09-25'
        $text | Should -Match 'Grok'
        $text | Should -Match 'no per-message token log'
    }
}

Describe 'SQLite usage ledger' {
    BeforeAll {
        $script:sqlite = Join-Path $script:root 'sqlite3.exe'
    }
    BeforeEach {
        $script:db = Join-Path ([System.IO.Path]::GetTempPath()) ('ledger-' + [guid]::NewGuid().ToString('N') + '.sqlite')
        $script:UsageLedgerSqlite = $script:sqlite
    }
    AfterEach {
        Remove-Item -LiteralPath $script:db -Force -ErrorAction SilentlyContinue
        $script:UsageLedgerSqlite = $null
    }

    It 'stores a changed reading and does not duplicate an unchanged one' {
        if (-not (Test-Path -LiteralPath $script:sqlite)) { Set-ItResult -Skipped -Because 'sqlite3.exe is not in the repo'; return }
        $first = ConvertTo-UsageLedgerRows -ObservedAt '2026-09-25T21:00:00-04:00' -ClaudeStats @{ InTokens = 10; OutTokens = 4; ValueUSD = 1.5 } -GrokUsage @{ WeekPct = 22 }
        Add-UsageLedgerRows -Path $script:db -Rows $first | Should -Be 2
        Add-UsageLedgerRows -Path $script:db -Rows $first | Should -Be 0
        $second = ConvertTo-UsageLedgerRows -ObservedAt '2026-09-25T21:30:00-04:00' -ClaudeStats @{ InTokens = 12; OutTokens = 4; ValueUSD = 1.8 } -GrokUsage @{ WeekPct = 22 }
        Add-UsageLedgerRows -Path $script:db -Rows $second | Should -Be 1
        $stored = @(Get-UsageLedgerRows -Path $script:db)
        $stored.Count | Should -Be 3
        @($stored | Where-Object provider -eq 'claude').Count | Should -Be 2
        @($stored | Where-Object provider -eq 'grok').Count | Should -Be 1
    }

    It 'rebuilds a provider day from usage instead of stacking polls' {
        if (-not (Test-Path -LiteralPath $script:sqlite)) { Set-ItResult -Skipped -Because 'sqlite3.exe is not in the repo'; return }
        $first = Get-UsageDayRollup -Records @(
            @{ Date = [datetime]'2026-09-25T12:00:00'; In = 100; Out = 40; CacheR = 60; CacheW = 0; SessionId = 's'; Cost = 1 }
        ) -Provider 'claude'
        Save-UsageDayHistory -Path $script:db -Rollup $first
        $second = Get-UsageDayRollup -Records @(
            @{ Date = [datetime]'2026-09-25T12:00:00'; In = 100; Out = 40; CacheR = 60; CacheW = 0; SessionId = 's'; Cost = 1 }
            @{ Date = [datetime]'2026-09-25T13:00:00'; In = 50; Out = 10; CacheR = 0; CacheW = 0; SessionId = 's2'; Cost = 0.5 }
        ) -Provider 'claude'
        Save-UsageDayHistory -Path $script:db -Rollup $second
        $loaded = Get-StoredUsageHistory -Path $script:db
        $loaded.claude.Totals.Messages | Should -Be 2
        $loaded.claude.Totals.EstUsd | Should -Be 1.5
        $loaded.claude.Days.Count | Should -Be 1
    }
}
