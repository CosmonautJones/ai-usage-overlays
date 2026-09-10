#Requires -Module Pester

BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $root
    . (Join-Path $root 'src\Config.ps1')
    . (Join-Path $root 'src\Format.ps1')
    . (Join-Path $root 'src\CursorData.ps1')
    . (Join-Path $root 'src\Export.ps1')
}

Describe 'Get-UnifiedExportLines full payloads' {
    BeforeAll {
        $script:at = Get-Date '2026-09-08T15:04:00'
        $script:claudeIdentity = [pscustomobject]@{ Display = 'ada@anthropic.com' }
        $script:claudeUsage = [pscustomobject]@{
            five_hour        = [pscustomobject]@{ utilization = 40; resets_at = '2026-09-08T20:00:00Z' }
            seven_day        = [pscustomobject]@{ utilization = 22; resets_at = '2026-09-14T20:00:00Z' }
            seven_day_fable  = [pscustomobject]@{ utilization = 10; resets_at = '2026-09-14T20:00:00Z' }
            seven_day_opus   = [pscustomobject]@{ utilization = 5;  resets_at = '2026-09-14T20:00:00Z' }
        }
        $script:claudeStats = @{
            ValueUSD = 12
            InTokens = 1500
            OutTokens = 250
            TodayTok = 1500
            TodayMsg = 3
            TodayAfterHoursTok = 100
            TodayAfterHoursMsg = 1
            Sessions = 4
            Messages = 20
        }
        $script:codexStats = @{
            WeekPct = 33
            FiveHourPct = 8
            ResetsAvailable = 2
            ValueUSD = 9
            InTokens = 2000
            OutTokens = 400
            TodayTok = 800
            TodayMsg = 2
            TodayAfterHoursTok = 50
            TodayAfterHoursMsg = 1
            Sessions = 6
            Messages = 30
        }
        $script:cursorSummary = [pscustomobject]@{
            autoModelSelectedDisplayMessage = "You've used 17% of your included total usage"
            namedModelSelectedDisplayMessage = "You've used 90% of your included API usage"
            individualUsage = [pscustomobject]@{
                plan = [pscustomobject]@{ used = 80; limit = 2000; autoPercentUsed = 10; apiPercentUsed = 89 }
                onDemand = [pscustomobject]@{ enabled = $false; used = 0 }
            }
        }
        $script:cursorLocal = [pscustomobject]@{
            edits30d = 120
            editsToday = 7
            topModel = 'claude-4-sonnet'
            topPct = 81
            linesAccepted = 340
        }
        $script:grokUsage = @{
            WeekPct = 55
            WeekResetsAt = '2026-09-14T20:00:00Z'
            PlanType = 'SuperGrok'
            PrepaidBalance = '12.00'
        }

        $script:lines = Get-UnifiedExportLines `
            -GeneratedAt $script:at `
            -AppVersion '0.4.0' `
            -ClaudeIdentity $script:claudeIdentity `
            -ClaudeUsage $script:claudeUsage `
            -ClaudeStats $script:claudeStats `
            -CodexStats $script:codexStats `
            -CursorSummary $script:cursorSummary `
            -CursorLocal $script:cursorLocal `
            -GrokUsage $script:grokUsage
        $script:text = $script:lines -join "`n"
    }

    It 'headers with the shipped app version' {
        $script:lines[0] | Should -Be 'AI Usage Overlay 0.4.0 - 2026-09-08 15:04'
    }

    It 'exports Claude quota, identity, and local facts when present' {
        $script:text | Should -Match 'Claude account: ada@anthropic.com'
        $script:text | Should -Match 'Claude 5-hour: 60% remaining'
        $script:text | Should -Match 'Claude weekly: 78% remaining'
        $script:text | Should -Match 'Claude Fable:'
        $script:text | Should -Match 'Claude Opus:'
        $script:text | Should -Match 'Claude est. API value: ~\$12 all-time'
        $script:text | Should -Match 'Claude tokens: 1\.5k in / 250 out'
        $script:text | Should -Match 'Claude today: 1\.5k tokens / 3 msgs'
        $script:text | Should -Match 'Claude today after-hours: 100 tokens / 1 msgs'
        $script:text | Should -Match 'Claude lifetime: 4 sessions'
    }

    It 'exports Codex weekly, 5-hour, reset credits, and local facts when present' {
        $script:text | Should -Match 'Codex weekly: 33% used'
        $script:text | Should -Match 'Codex 5-hour: 8% used'
        $script:text | Should -Match 'Codex reset credits: 2 available'
        $script:text | Should -Match 'Codex est. API value: ~\$9 all-time'
        $script:text | Should -Match 'Codex tokens: 2\.0k in / 400 out'
        $script:text | Should -Match 'Codex today: 800 tokens / 2 msgs'
        $script:text | Should -Match 'Codex today after-hours: 50 tokens / 1 msgs'
        $script:text | Should -Match 'Codex lifetime: 6 sessions'
    }

    It 'exports Cursor Models, Other Models, on-demand, edits, top model, and AI lines when present' {
        $script:text | Should -Match 'Cursor Models: 17% used'
        $script:text | Should -Match 'Cursor Other Models: 90%'
        $script:text | Should -Match 'Cursor on-demand: Off'
        $script:text | Should -Match 'Cursor edits: 120 \(30d\) / 7 today'
        $script:text | Should -Match 'Cursor top model: claude-4-sonnet 81%'
        $script:text | Should -Match 'Cursor AI lines accepted \(30d\): 340'
    }

    It 'exports Grok weekly, reset, plan, and prepaid when xAI sent them' {
        $script:text | Should -Match 'Grok weekly: 55% used'
        $script:text | Should -Match 'Grok weekly reset:'
        $script:text | Should -Match 'Grok plan: SuperGrok'
        $script:text | Should -Match 'Grok prepaid: 12.00'
    }
}

Describe 'Get-UnifiedExportLines missing values stay honest' {
    It 'omits optional Claude Fable/Opus and uses -- for missing Codex 5-hour/Grok extras' {
        $claudeUsage = [pscustomobject]@{
            five_hour = [pscustomobject]@{ utilization = 10; resets_at = '2026-09-08T20:00:00Z' }
            seven_day = [pscustomobject]@{ utilization = 5; resets_at = '2026-09-14T20:00:00Z' }
        }
        $codexStats = @{
            WeekPct = $null
            FiveHourPct = $null
            ResetsAvailable = $null
            ValueUSD = 0
            InTokens = 0
            OutTokens = 0
            TodayTok = 0
            TodayMsg = 0
            TodayAfterHoursTok = 0
            TodayAfterHoursMsg = 0
            Sessions = 0
            Messages = 0
        }
        $cursorSummary = [pscustomobject]@{
            individualUsage = [pscustomobject]@{
                plan = [pscustomobject]@{ used = $null; limit = $null }
                onDemand = [pscustomobject]@{ enabled = $true; used = 150 }
            }
        }
        $cursorLocal = [pscustomobject]@{
            edits30d = 4
            editsToday = 0
            topModel = $null
            topPct = $null
            linesAccepted = $null
        }
        $grokUsage = @{ WeekPct = $null; WeekResetsAt = $null; PlanType = $null; PrepaidBalance = $null }

        $text = (Get-UnifiedExportLines `
            -GeneratedAt (Get-Date '2026-09-08T15:04:00') `
            -AppVersion '0.4.0' `
            -ClaudeUsage $claudeUsage `
            -CodexStats $codexStats `
            -CursorSummary $cursorSummary `
            -CursorLocal $cursorLocal `
            -GrokUsage $grokUsage) -join "`n"

        $text | Should -Not -Match 'Fable'
        $text | Should -Not -Match 'Opus'
        $text | Should -Not -Match 'Codex 5-hour'
        $text | Should -Match 'Codex weekly: --'
        $text | Should -Match 'Codex reset credits: --'
        $text | Should -Match 'Cursor Models: --'
        $text | Should -Match 'Cursor Other Models: --'
        $text | Should -Match 'Cursor on-demand: \$1\.50'
        $text | Should -Not -Match 'Cursor top model'
        $text | Should -Not -Match 'Cursor AI lines'
        $text | Should -Match 'Grok weekly: --'
        $text | Should -Not -Match 'Grok plan'
        $text | Should -Not -Match 'Grok prepaid'
        $text | Should -Not -Match 'Grok weekly reset'
    }

    It 'skips hidden providers on clipboard export' {
        $text = (Get-UnifiedExportLines `
            -ClaudeIdentity ([pscustomobject]@{ Display = 'hidden@example.com' }) `
            -ClaudeUsage ([pscustomobject]@{ five_hour = [pscustomobject]@{ utilization = 1; resets_at = '2026-09-08T20:00:00Z' } }) `
            -CodexStats @{ WeekPct = 9; ValueUSD = 1; InTokens = 1; OutTokens = 1; TodayTok = 1; TodayMsg = 1; TodayAfterHoursTok = 0; TodayAfterHoursMsg = 0; Sessions = 1; Messages = 1 } `
            -Sections @{ claude = $false; codex = $true; cursor = $false; grok = $false }) -join "`n"

        $text | Should -Not -Match 'Claude'
        $text | Should -Match 'Codex weekly: 9% used'
        $text | Should -Not -Match 'Cursor'
        $text | Should -Not -Match 'Grok'
    }
}

Describe 'Snapshot provider objects from in-memory payloads' {
    It 'keeps Claude quota and local facts on the shipped snapshot object' {
        $usage = [pscustomobject]@{
            five_hour = [pscustomobject]@{ utilization = 40 }
            seven_day = [pscustomobject]@{ utilization = 22 }
            seven_day_fable = [pscustomobject]@{ utilization = 10 }
        }
        $stats = @{ ValueUSD = 12; InTokens = 1500; OutTokens = 250; TodayTok = 100; TodayAfterHoursTok = 10; Sessions = 4; Messages = 20 }
        $snap = New-ClaudeProviderSnapshot -Status 'ok' -Message '' -Identity ([pscustomobject]@{ Display = 'ada@anthropic.com' }) -Usage $usage -Stats $stats
        $snap.selected | Should -BeTrue
        $snap.usage.five_hour.utilization | Should -Be 40
        $snap.usage.seven_day.utilization | Should -Be 22
        $snap.usage.seven_day_fable.utilization | Should -Be 10
        $snap.identity.Display | Should -Be 'ada@anthropic.com'
        $snap.stats.ValueUSD | Should -Be 12
        $snap.stats.Sessions | Should -Be 4
        $snap.Contains('message') | Should -BeTrue
    }

    It 'omits optional Claude windows that were not in the payload' {
        $usage = [pscustomobject]@{
            five_hour = [pscustomobject]@{ utilization = 40 }
            seven_day = [pscustomobject]@{ utilization = 22 }
        }
        $snap = New-ClaudeProviderSnapshot -Status 'ok' -Usage $usage
        $snap.usage.PSObject.Properties['seven_day_fable'] | Should -BeNullOrEmpty
        $snap.usage.PSObject.Properties['seven_day_opus'] | Should -BeNullOrEmpty
    }

    It 'keeps Codex weekly, 5-hour, reset credits, and local facts on stats' {
        $stats = @{
            WeekPct = 33; FiveHourPct = 8; ResetsAvailable = 2
            ValueUSD = 9; InTokens = 2000; OutTokens = 400
            TodayTok = 800; TodayAfterHoursTok = 50; Sessions = 6; Messages = 30
        }
        $snap = New-CodexProviderSnapshot -Status 'ok' -Message '' -Stats $stats
        $snap.stats.WeekPct | Should -Be 33
        $snap.stats.FiveHourPct | Should -Be 8
        $snap.stats.ResetsAvailable | Should -Be 2
        $snap.stats.TodayAfterHoursTok | Should -Be 50
        $snap.stats.Sessions | Should -Be 6
    }

    It 'leaves Codex 5-hour omitted when ChatGPT did not return it' {
        $stats = @{ WeekPct = 10; FiveHourPct = $null; ResetsAvailable = $null; Sessions = 1 }
        $snap = New-CodexProviderSnapshot -Status 'ok' -Stats $stats
        $null -eq $snap.stats.FiveHourPct | Should -BeTrue
        $null -eq $snap.stats.ResetsAvailable | Should -BeTrue
        $snap.stats.WeekPct | Should -Be 10
    }

    It 'keeps Cursor Models / Other / on-demand / edits / top model / AI lines on the snapshot' {
        $summary = [pscustomobject]@{
            autoModelSelectedDisplayMessage = "You've used 17% of your included total usage"
            namedModelSelectedDisplayMessage = "You've used 90% of your included API usage"
            individualUsage = [pscustomobject]@{
                plan = [pscustomobject]@{ used = 80; limit = 2000 }
                onDemand = [pscustomobject]@{ enabled = $true; used = 250 }
            }
        }
        $local = [pscustomobject]@{ edits30d = 120; editsToday = 7; topModel = 'claude-4-sonnet'; topPct = 81; linesAccepted = 340 }
        $snap = New-CursorProviderSnapshot -Status 'ok' -Message '' -Summary $summary -Local $local
        $plan = Get-CursorPlanUsageFromSummary $snap.summary
        $plan.BarPercent | Should -Be 17
        $plan.ApiPercent | Should -Be 90
        $plan.OnDemandUsedCents | Should -Be 250
        $snap.local.edits30d | Should -Be 120
        $snap.local.editsToday | Should -Be 7
        $snap.local.topModel | Should -Be 'claude-4-sonnet'
        $snap.local.linesAccepted | Should -Be 340
    }

    It 'omits Cursor analytics extras when local did not return them' {
        $local = [pscustomobject]@{ edits30d = 1; editsToday = 0 }
        $snap = New-CursorProviderSnapshot -Status 'ok' -Local $local
        $snap.local.PSObject.Properties['topModel'] | Should -BeNullOrEmpty
        $snap.local.PSObject.Properties['linesAccepted'] | Should -BeNullOrEmpty
    }

    It 'keeps Grok weekly/reset and only includes plan/prepaid when present' {
        $full = New-GrokProviderSnapshot -Status 'ok' -Usage @{ WeekPct = 55; WeekResetsAt = '2026-09-14T20:00:00Z'; PlanType = 'SuperGrok'; PrepaidBalance = '12.00' }
        $full.usage.WeekPct | Should -Be 55
        $full.usage.WeekResetsAt | Should -Not -BeNullOrEmpty
        $full.usage.PlanType | Should -Be 'SuperGrok'
        $full.usage.PrepaidBalance | Should -Be '12.00'

        $sparse = New-GrokProviderSnapshot -Status 'ok' -Usage @{ WeekPct = 12 }
        $sparse.usage.WeekPct | Should -Be 12
        $sparse.usage.Contains('PlanType') | Should -BeFalse
        $sparse.usage.Contains('PrepaidBalance') | Should -BeFalse
    }

    It 'builds a v1 envelope with all four providers from the shipped document helper' {
        $selected = [ordered]@{ claude = $true; codex = $true; cursor = $true; grok = $true }
        $providers = [ordered]@{
            claude = New-ClaudeProviderSnapshot -Status 'unavailable' -Message 'No credentials file'
            codex  = New-CodexProviderSnapshot -Status 'unavailable' -Message 'No Codex login found - run codex login'
            cursor = New-CursorProviderSnapshot -Status 'unavailable' -Message 'Cannot read Cursor token'
            grok   = New-GrokProviderSnapshot -Status 'unavailable' -Message 'run grok login'
        }
        $doc = New-UnifiedSnapshotDocument -AppVersion '0.4.0' -GeneratedAt (Get-Date '2026-09-08T15:04:00Z') -SelectedProviders $selected -Timeouts @{ claude = 8; cursor = 8; grok = 8 } -Providers $providers
        $doc.schema | Should -Be 'ai-usage.snapshot.v1'
        $doc.appVersion | Should -Be '0.4.0'
        @($doc.request.providers) | Should -Be @('claude', 'codex', 'cursor', 'grok')
        $doc.providers.claude.status | Should -Be 'unavailable'
        $doc.providers.claude.Contains('message') | Should -BeTrue
        $doc.providers.codex.Contains('message') | Should -BeTrue
        $doc.providers.cursor.Contains('message') | Should -BeTrue
        $doc.providers.grok.Contains('message') | Should -BeTrue
    }
}

Describe 'Copy-Stats uses the shipped exporter' {
    It 'delegates clipboard text to Get-UnifiedExportLines' {
        $root = Split-Path $PSScriptRoot -Parent
        $state = Get-Content (Join-Path $root 'src\UnifiedState.ps1') -Raw -Encoding UTF8
        $state | Should -Match 'function Copy-Stats'
        $state | Should -Match 'Get-UnifiedExportLines'
        $state | Should -Match '\[System\.Windows\.Clipboard\]::SetText'
    }
}
