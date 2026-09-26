# Metrics.ps1 - local usage ledger and the rollups copied from it.
# Estimated API value is not an invoice. Cumulative counters that jump backward
# are treated as a reset, not as negative spend.

$script:UsageLedgerProviders = @('claude', 'codex', 'cursor', 'grok')

function Get-LedgerNote($Obj, [string]$Name) {
    if ($null -eq $Obj -or -not $Name) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] }
        foreach ($k in @($Obj.Keys)) {
            if ([string]$k -eq $Name) { return $Obj[$k] }
        }
        return $null
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function ConvertTo-LedgerDouble($Value) {
    if ($null -eq $Value -or $Value -eq '') { return $null }
    try {
        $n = [double]$Value
        if ([double]::IsNaN($n) -or [double]::IsInfinity($n)) { return $null }
        return $n
    } catch {
        return $null
    }
}

function New-UsageLedgerRow {
    param(
        [string]$ObservedAt,
        [string]$Provider,
        $WeeklyPct = $null,
        $FiveHourPct = $null,
        $InTokens = $null,
        $OutTokens = $null,
        $EstUsd = $null,
        $Messages = $null,
        $Sessions = $null,
        $TodayTokens = $null,
        $TodayMessages = $null,
        $OnDemandUsd = $null
    )

    $row = [ordered]@{
        observed_at    = $ObservedAt
        provider       = $Provider
        weekly_pct     = ConvertTo-LedgerDouble $WeeklyPct
        five_hour_pct  = ConvertTo-LedgerDouble $FiveHourPct
        in_tokens      = ConvertTo-LedgerDouble $InTokens
        out_tokens     = ConvertTo-LedgerDouble $OutTokens
        est_usd        = ConvertTo-LedgerDouble $EstUsd
        messages       = ConvertTo-LedgerDouble $Messages
        sessions       = ConvertTo-LedgerDouble $Sessions
        today_tokens   = ConvertTo-LedgerDouble $TodayTokens
        today_messages = ConvertTo-LedgerDouble $TodayMessages
        on_demand_usd  = ConvertTo-LedgerDouble $OnDemandUsd
    }
    $has = $false
    foreach ($key in @($row.Keys)) {
        if ($key -in @('observed_at', 'provider')) { continue }
        if ($null -ne $row[$key]) { $has = $true }
    }
    if (-not $has) { return $null }
    return $row
}

function ConvertTo-UsageLedgerRows {
    param(
        [string]$ObservedAt,
        $ClaudeStats,
        $ClaudeUsage,
        $CodexStats,
        $CursorPlan,
        $GrokUsage
    )

    $rows = [System.Collections.Generic.List[object]]::new()
    $week = Get-LedgerNote $ClaudeUsage 'seven_day'
    $five = Get-LedgerNote $ClaudeUsage 'five_hour'
    $claude = New-UsageLedgerRow -ObservedAt $ObservedAt -Provider 'claude' `
        -WeeklyPct (Get-LedgerNote $week 'utilization') `
        -FiveHourPct (Get-LedgerNote $five 'utilization') `
        -InTokens (Get-LedgerNote $ClaudeStats 'InTokens') `
        -OutTokens (Get-LedgerNote $ClaudeStats 'OutTokens') `
        -EstUsd (Get-LedgerNote $ClaudeStats 'ValueUSD') `
        -Messages (Get-LedgerNote $ClaudeStats 'Messages') `
        -Sessions (Get-LedgerNote $ClaudeStats 'Sessions') `
        -TodayTokens (Get-LedgerNote $ClaudeStats 'TodayTok') `
        -TodayMessages (Get-LedgerNote $ClaudeStats 'TodayMsg')
    if ($claude) { $rows.Add($claude) }

    $codex = New-UsageLedgerRow -ObservedAt $ObservedAt -Provider 'codex' `
        -WeeklyPct (Get-LedgerNote $CodexStats 'WeekPct') `
        -FiveHourPct (Get-LedgerNote $CodexStats 'FiveHourPct') `
        -InTokens (Get-LedgerNote $CodexStats 'InTokens') `
        -OutTokens (Get-LedgerNote $CodexStats 'OutTokens') `
        -EstUsd (Get-LedgerNote $CodexStats 'ValueUSD') `
        -Messages (Get-LedgerNote $CodexStats 'Messages') `
        -Sessions (Get-LedgerNote $CodexStats 'Sessions') `
        -TodayTokens (Get-LedgerNote $CodexStats 'TodayTok') `
        -TodayMessages (Get-LedgerNote $CodexStats 'TodayMsg')
    if ($codex) { $rows.Add($codex) }

    $cents = ConvertTo-LedgerDouble (Get-LedgerNote $CursorPlan 'OnDemandUsedCents')
    $onDemand = if ($null -eq $cents) { $null } else { $cents / 100.0 }
    $cursor = New-UsageLedgerRow -ObservedAt $ObservedAt -Provider 'cursor' `
        -WeeklyPct (Get-LedgerNote $CursorPlan 'BarPercent') `
        -OnDemandUsd $onDemand
    if ($cursor) { $rows.Add($cursor) }

    $grok = New-UsageLedgerRow -ObservedAt $ObservedAt -Provider 'grok' `
        -WeeklyPct (Get-LedgerNote $GrokUsage 'WeekPct')
    if ($grok) { $rows.Add($grok) }

    return @($rows)
}

function Get-ForwardCounterDelta {
    param([object[]]$Values)

    $base = $null
    [double]$added = 0
    $breaks = 0
    $latest = $null
    foreach ($value in @($Values)) {
        $n = ConvertTo-LedgerDouble $value
        if ($null -eq $n) { continue }
        if ($null -eq $base) {
            $base = $n
            $latest = $n
            continue
        }
        if ($n + 1e-9 -lt $base) {
            $breaks++
            $base = $n
            $latest = $n
            continue
        }
        $added += ($n - $base)
        $base = $n
        $latest = $n
    }
    return @{ Added = $added; Latest = $latest; Breaks = $breaks }
}

function Get-UsageLedgerMath {
    param($Rows)

    $grouped = @{}
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        $provider = [string](Get-LedgerNote $row 'provider')
        if (-not $provider) { continue }
        if (-not $grouped.Contains($provider)) { $grouped[$provider] = [System.Collections.Generic.List[object]]::new() }
        $grouped[$provider].Add($row)
    }

    $providers = @{}
    foreach ($provider in @($grouped.Keys)) {
        $series = @($grouped[$provider] | Sort-Object { [datetimeoffset]::Parse([string](Get-LedgerNote $_ 'observed_at')) })
        $inDelta = Get-ForwardCounterDelta @($series | ForEach-Object { Get-LedgerNote $_ 'in_tokens' })
        $outDelta = Get-ForwardCounterDelta @($series | ForEach-Object { Get-LedgerNote $_ 'out_tokens' })
        $usdDelta = Get-ForwardCounterDelta @($series | ForEach-Object { Get-LedgerNote $_ 'est_usd' })
        $breaks = 0
        for ($i = 1; $i -lt $series.Count; $i++) {
            $dropped = $false
            foreach ($field in @('in_tokens', 'out_tokens', 'est_usd')) {
                $before = ConvertTo-LedgerDouble (Get-LedgerNote $series[$i - 1] $field)
                $after = ConvertTo-LedgerDouble (Get-LedgerNote $series[$i] $field)
                if ($null -ne $before -and $null -ne $after -and ($after + 1e-9) -lt $before) { $dropped = $true }
            }
            if ($dropped) { $breaks++ }
        }
        $firstAt = [datetimeoffset]::Parse([string](Get-LedgerNote $series[0] 'observed_at'))
        $lastAt = [datetimeoffset]::Parse([string](Get-LedgerNote $series[-1] 'observed_at'))
        $spanHours = ($lastAt - $firstAt).TotalHours
        $latestTokens = $null
        if ($null -ne $inDelta.Latest -or $null -ne $outDelta.Latest) {
            $latestTokens = [double]($inDelta.Latest) + [double]($outDelta.Latest)
        }
        $usdPerDay = $null
        $tokensPerDay = $null
        if ($series.Count -ge 2 -and $spanHours -ge 1) {
            $usdPerDay = [double]$usdDelta.Added / ($spanHours / 24.0)
            $addedTokens = [double]$inDelta.Added + [double]$outDelta.Added
            $tokensPerDay = $addedTokens / ($spanHours / 24.0)
        }
        $usdPerMillion = $null
        if ($null -ne $usdDelta.Latest -and $latestTokens -gt 0) {
            $usdPerMillion = [double]$usdDelta.Latest / ($latestTokens / 1e6)
        }
        $providers[$provider] = @{
            LatestIn          = $inDelta.Latest
            LatestOut         = $outDelta.Latest
            LatestUsd         = $usdDelta.Latest
            LatestWeeklyPct   = ConvertTo-LedgerDouble (Get-LedgerNote $series[-1] 'weekly_pct')
            LatestFiveHourPct = ConvertTo-LedgerDouble (Get-LedgerNote $series[-1] 'five_hour_pct')
            LatestOnDemandUsd = ConvertTo-LedgerDouble (Get-LedgerNote $series[-1] 'on_demand_usd')
            AddedIn           = [double]$inDelta.Added
            AddedOut          = [double]$outDelta.Added
            AddedTokens       = [double]$inDelta.Added + [double]$outDelta.Added
            AddedUsd          = [double]$usdDelta.Added
            Breaks            = $breaks
            SpanHours         = $spanHours
            UsdPerDay         = $usdPerDay
            TokensPerDay      = $tokensPerDay
            UsdPerMillion     = $usdPerMillion
            Observations      = $series.Count
            FirstAt           = $firstAt
            LastAt            = $lastAt
        }
    }

    $latestUsd = 0.0
    $addedUsd = 0.0
    $haveUsd = $false
    $first = $null
    $last = $null
    $readings = 0
    foreach ($info in @($providers.Values)) {
        $readings += [int]$info.Observations
        if ($null -eq $first -or $info.FirstAt -lt $first) { $first = $info.FirstAt }
        if ($null -eq $last -or $info.LastAt -gt $last) { $last = $info.LastAt }
        if ($null -ne $info.LatestUsd) {
            $haveUsd = $true
            $latestUsd += [double]$info.LatestUsd
            $addedUsd += [double]$info.AddedUsd
        }
    }
    foreach ($provider in @($providers.Keys)) {
        $info = $providers[$provider]
        $share = $null
        if ($haveUsd -and $latestUsd -gt 0 -and $null -ne $info.LatestUsd) {
            $share = [double]$info.LatestUsd / $latestUsd
        }
        $info.Share = $share
        $providers[$provider] = $info
    }
    $spanHours = 0.0
    if ($null -ne $first -and $null -ne $last) { $spanHours = ($last - $first).TotalHours }

    return @{
        Providers = $providers
        Combined  = @{
            LatestUsd    = $(if ($haveUsd) { $latestUsd } else { $null })
            AddedUsd     = $(if ($haveUsd) { $addedUsd } else { $null })
            SpanHours    = $spanHours
            Observations = $readings
            FirstAt      = $first
            LastAt       = $last
        }
    }
}

function Format-LedgerMoney([double]$Value) {
    return '$' + $Value.ToString('N2', [Globalization.CultureInfo]::InvariantCulture)
}

function Format-LedgerTokens([double]$Value) {
    $abs = [math]::Abs($Value)
    if ($abs -ge 1e6) { return ('{0:0.0}M' -f ($Value / 1e6)) }
    if ($abs -ge 1e3) { return ('{0:0.0}k' -f ($Value / 1e3)) }
    return ('{0:0}' -f $Value)
}

function Format-UsageLedgerReport($Math) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Usage ledger - estimated API value, not an invoice')
    if (-not $Math -or -not $Math.Providers -or $Math.Providers.Count -eq 0) {
        $lines.Add('No samples yet. The ledger fills as the overlay polls.')
        return @($lines)
    }

    $combined = $Math.Combined
    if ($combined.FirstAt -and $combined.LastAt) {
        $lines.Add(('Window {0:yyyy-MM-dd HH:mm} to {1:yyyy-MM-dd HH:mm} ({2:0.0} h, {3} readings)' -f $combined.FirstAt.LocalDateTime, $combined.LastAt.LocalDateTime, [double]$combined.SpanHours, [int]$combined.Observations))
    }

    $names = @{ claude = 'Claude'; codex = 'Codex'; cursor = 'Cursor'; grok = 'Grok' }
    foreach ($provider in $script:UsageLedgerProviders) {
        if (-not $Math.Providers.Contains($provider)) { continue }
        $info = $Math.Providers[$provider]
        $label = $names[$provider]
        $noTokens = ($null -eq $info.LatestIn -and $null -eq $info.LatestOut -and $null -eq $info.LatestUsd)
        if ($noTokens) {
            $pct = if ($null -ne $info.LatestWeeklyPct) { ('{0:0}%' -f [double]$info.LatestWeeklyPct) } else { '--' }
            $line = "$label  weekly $pct  no token ledger"
            if ($null -ne $info.LatestOnDemandUsd) { $line += '  on-demand ' + (Format-LedgerMoney $info.LatestOnDemandUsd) }
            $lines.Add($line)
            continue
        }
        $inText = if ($null -ne $info.LatestIn) { Format-LedgerTokens $info.LatestIn } else { '--' }
        $outText = if ($null -ne $info.LatestOut) { Format-LedgerTokens $info.LatestOut } else { '--' }
        $usdText = if ($null -ne $info.LatestUsd) { Format-LedgerMoney $info.LatestUsd } else { '--' }
        $blend = if ($null -ne $info.UsdPerMillion) { (Format-LedgerMoney $info.UsdPerMillion) + '/Mtok' } else { '' }
        $share = if ($null -ne $info.Share) { ('{0:0}% of estimate' -f (100.0 * [double]$info.Share)) } else { '' }
        $bits = @("$label  latest $usdText", "$inText in / $outText out")
        if ($blend) { $bits += $blend }
        if ($share) { $bits += $share }
        if ($null -ne $info.LatestWeeklyPct) { $bits += ('weekly {0:0}%' -f [double]$info.LatestWeeklyPct) }
        $lines.Add(($bits -join '  '))
        if ($null -ne $info.UsdPerDay) {
            $tokDay = if ($null -ne $info.TokensPerDay) { (Format-LedgerTokens $info.TokensPerDay) + ' tok/day' } else { '' }
            $pace = @('  added in window ' + (Format-LedgerMoney $info.AddedUsd), (Format-LedgerMoney $info.UsdPerDay) + '/day')
            if ($tokDay) { $pace += $tokDay }
            if ([int]$info.Breaks -gt 0) { $pace += ('{0} counter reset(s) skipped' -f [int]$info.Breaks) }
            $lines.Add(($pace -join '  '))
        }
    }

    if ($null -ne $combined.LatestUsd) {
        $lines.Add('Combined latest ' + (Format-LedgerMoney $combined.LatestUsd) + '  added in window ' + (Format-LedgerMoney $combined.AddedUsd))
    }
    return @($lines)
}

function Resolve-UsageLedgerSqlite {
    if ($script:UsageLedgerSqlite -and (Test-Path -LiteralPath $script:UsageLedgerSqlite)) {
        return $script:UsageLedgerSqlite
    }
    $dir = if ($script:AppDir) { $script:AppDir } else { $PSScriptRoot }
    foreach ($candidate in @(
        (Join-Path $dir 'sqlite3.exe'),
        (Join-Path (Split-Path $dir -Parent) 'sqlite3.exe')
    )) {
        if ($candidate -and (Test-Path -LiteralPath $candidate)) { return $candidate }
    }
    $cmd = Get-Command sqlite3.exe -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    return $null
}

function ConvertTo-SqliteLiteral($Value) {
    $n = ConvertTo-LedgerDouble $Value
    if ($null -eq $n) { return 'NULL' }
    return $n.ToString('G17', [Globalization.CultureInfo]::InvariantCulture)
}

function ConvertTo-SqliteText([string]$Value) {
    return "'" + ($Value -replace "'", "''") + "'"
}

function Invoke-UsageLedgerSql {
    param(
        [string]$Path,
        [string]$Sql,
        [switch]$Json
    )

    $exe = Resolve-UsageLedgerSqlite
    if (-not $exe) { throw 'sqlite3.exe was not found' }
    $arg = if ($Json) { @('-json', $Path, $Sql) } else { @($Path, $Sql) }
    $output = & $exe @arg 2>&1
    if ($LASTEXITCODE -ne 0) { throw "usage ledger query failed ($LASTEXITCODE)" }
    return $output
}

function Initialize-UsageLedger {
    param([string]$Path)

    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }
    $sql = @'
CREATE TABLE IF NOT EXISTS observation (
  id INTEGER PRIMARY KEY,
  observed_at TEXT NOT NULL,
  provider TEXT NOT NULL,
  weekly_pct REAL,
  five_hour_pct REAL,
  in_tokens INTEGER,
  out_tokens INTEGER,
  est_usd REAL,
  messages INTEGER,
  sessions INTEGER,
  today_tokens INTEGER,
  today_messages INTEGER,
  on_demand_usd REAL
);
CREATE INDEX IF NOT EXISTS ix_observation_provider ON observation(provider, id);
'@
    [void](Invoke-UsageLedgerSql -Path $Path -Sql $sql)
}

function Get-UsageLedgerSignature($Row) {
    $parts = foreach ($field in @(
        'weekly_pct', 'five_hour_pct', 'in_tokens', 'out_tokens', 'est_usd',
        'messages', 'sessions', 'today_tokens', 'today_messages', 'on_demand_usd'
    )) {
        $n = ConvertTo-LedgerDouble (Get-LedgerNote $Row $field)
        if ($null -eq $n) { 'null' } else { $n.ToString('G17', [Globalization.CultureInfo]::InvariantCulture) }
    }
    return ($parts -join '|')
}

function Get-UsageLedgerRows {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) { return @() }
    $sql = 'SELECT observed_at, provider, weekly_pct, five_hour_pct, in_tokens, out_tokens, est_usd, messages, sessions, today_tokens, today_messages, on_demand_usd FROM observation ORDER BY observed_at, id;'
    $raw = Invoke-UsageLedgerSql -Path $Path -Sql $sql -Json
    $text = if ($raw -is [array]) { $raw -join '' } else { [string]$raw }
    if ([string]::IsNullOrWhiteSpace($text)) { return @() }
    return @($text | ConvertFrom-Json)
}

function Add-UsageLedgerRows {
    param(
        [string]$Path,
        $Rows
    )

    if (-not (Resolve-UsageLedgerSqlite)) { return 0 }
    Initialize-UsageLedger -Path $Path
    $existing = @(Get-UsageLedgerRows -Path $Path)
    $last = @{}
    foreach ($row in $existing) {
        $last[[string]$row.provider] = Get-UsageLedgerSignature $row
    }

    $inserts = [System.Collections.Generic.List[string]]::new()
    foreach ($row in @($Rows)) {
        if (-not $row) { continue }
        $provider = [string](Get-LedgerNote $row 'provider')
        if ($provider -notin $script:UsageLedgerProviders) { continue }
        $signature = Get-UsageLedgerSignature $row
        if ($last.Contains($provider) -and $last[$provider] -eq $signature) { continue }
        $observed = [string](Get-LedgerNote $row 'observed_at')
        if ($observed -notmatch '^\d{4}-\d{2}-\d{2}T') { continue }
        $inserts.Add((
            'INSERT INTO observation (observed_at, provider, weekly_pct, five_hour_pct, in_tokens, out_tokens, est_usd, messages, sessions, today_tokens, today_messages, on_demand_usd) VALUES (' +
            ((ConvertTo-SqliteText $observed), (ConvertTo-SqliteText $provider),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'weekly_pct')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'five_hour_pct')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'in_tokens')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'out_tokens')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'est_usd')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'messages')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'sessions')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'today_tokens')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'today_messages')),
             (ConvertTo-SqliteLiteral (Get-LedgerNote $row 'on_demand_usd')) -join ', ') +
            ');'
        ))
        $last[$provider] = $signature
    }
    if ($inserts.Count -eq 0) { return 0 }
    [void](Invoke-UsageLedgerSql -Path $Path -Sql ("BEGIN;`n" + ($inserts -join "`n") + "`nCOMMIT;"))
    return $inserts.Count
}

function Get-UsageLedgerClipboardMath {
    if (-not $script:AppDir) { return $null }
    $path = Join-Path $script:AppDir 'usage-ledger.sqlite'
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    return Get-UsageLedgerMath (Get-UsageLedgerRows -Path $path)
}

function Test-LedgerHasNote($Obj, [string]$Name) {
    if ($null -eq $Obj -or -not $Name) { return $false }
    if ($Obj -is [System.Collections.IDictionary]) { return $Obj.Contains($Name) }
    return $null -ne $Obj.PSObject.Properties[$Name]
}

function Test-LedgerAfterHours([datetime]$Date) {
    if (Get-Command Test-UsageAfterHours -ErrorAction SilentlyContinue) {
        return [bool](Test-UsageAfterHours $Date)
    }
    if ($Date.DayOfWeek -eq [DayOfWeek]::Saturday -or $Date.DayOfWeek -eq [DayOfWeek]::Sunday) { return $true }
    return ($Date.Hour -lt 8 -or $Date.Hour -ge 18)
}

function Get-UsageRecordParts($Record) {
    $inTokens = ConvertTo-LedgerDouble (Get-LedgerNote $Record 'In')
    if ($null -eq $inTokens) { $inTokens = 0 }
    $outTokens = ConvertTo-LedgerDouble (Get-LedgerNote $Record 'Out')
    if ($null -eq $outTokens) { $outTokens = 0 }
    $cachedIn = ConvertTo-LedgerDouble (Get-LedgerNote $Record 'CachedIn')
    if ($null -ne $cachedIn) {
        $fresh = [Math]::Max(0, $inTokens - $cachedIn)
        $cacheRead = [Math]::Max(0, $cachedIn)
        $cacheWrite = 0
    } else {
        $fresh = [Math]::Max(0, $inTokens)
        $cacheReadValue = ConvertTo-LedgerDouble (Get-LedgerNote $Record 'CacheR')
        $cacheWriteValue = ConvertTo-LedgerDouble (Get-LedgerNote $Record 'CacheW')
        $cacheRead = if ($null -eq $cacheReadValue) { 0 } else { [Math]::Max(0, $cacheReadValue) }
        $cacheWrite = if ($null -eq $cacheWriteValue) { 0 } else { [Math]::Max(0, $cacheWriteValue) }
    }
    $cost = ConvertTo-LedgerDouble (Get-LedgerNote $Record 'Cost')
    if ($null -eq $cost) {
        try {
            if ($null -ne $cachedIn -and (Get-Command Estimate-CodexCost -ErrorAction SilentlyContinue)) {
                $cost = [double](Estimate-CodexCost (Get-LedgerNote $Record 'Model') @{
                    inputTokens = $inTokens; cachedInputTokens = $cachedIn; outputTokens = $outTokens
                })
            } elseif (Get-Command Estimate-Cost -ErrorAction SilentlyContinue) {
                $cost = [double](Estimate-Cost ([string](Get-LedgerNote $Record 'Model')) @{
                    inputTokens = $fresh
                    outputTokens = $outTokens
                    cacheCreationInputTokens = $cacheWrite
                    cacheReadInputTokens = $cacheRead
                })
            }
        } catch { $cost = $null }
    }
    return @{
        In = $inTokens; Out = $outTokens; Fresh = $fresh
        CacheRead = $cacheRead; CacheWrite = $cacheWrite; Cost = $cost
    }
}

function Complete-UsageHistoryTotals($Days) {
    $fresh = 0.0; $cache = 0.0; $cacheWrite = 0.0; $out = 0.0; $in = 0.0
    $cost = 0.0; $messages = 0; $sessions = 0; $after = 0.0; $haveCost = $false
    foreach ($day in @($Days)) {
        $fresh += [double]$day.FreshIn
        $cache += [double]$day.CacheRead
        $cacheWrite += [double]$day.CacheWrite
        $out += [double]$day.OutTokens
        $in += [double]$day.InTokens
        $messages += [int]$day.Messages
        $sessions += [int]$day.Sessions
        $after += [double]$day.AfterHoursTokens
        if ($null -ne $day.EstUsd) { $haveCost = $true; $cost += [double]$day.EstUsd }
    }
    $context = $fresh + $cacheWrite + $cache
    $reuse = if ($context -gt 0) { 100.0 * $cache / $context } else { $null }
    $yield = if ($fresh -gt 0) { 1000.0 * $out / $fresh } else { $null }
    $perMsg = if ($haveCost -and $messages -gt 0) { $cost / $messages } else { $null }
    $moved = $in + $out
    $afterShare = if ($moved -gt 0) { 100.0 * $after / $moved } else { $null }
    return @{
        InTokens = $in; OutTokens = $out; FreshIn = $fresh; CacheRead = $cache
        EstUsd = $(if ($haveCost) { $cost } else { $null })
        Messages = $messages; Sessions = $sessions
        ReusePct = $reuse; YieldPer1K = $yield
        UsdPerMessage = $perMsg; AfterHoursShare = $afterShare
    }
}

function Get-UsageDayRollup {
    param($Records, [string]$Provider)

    $days = @{}
    foreach ($record in @($Records)) {
        if (-not $record) { continue }
        $when = Get-LedgerNote $record 'Date'
        if (-not $when) { continue }
        $stamp = ([datetime]$when)
        $key = $stamp.ToString('yyyy-MM-dd')
        if (-not $days.Contains($key)) {
            $days[$key] = @{
                Day = $key; InTokens = 0.0; OutTokens = 0.0; FreshIn = 0.0
                CacheRead = 0.0; CacheWrite = 0.0; EstUsd = $null
                Messages = 0; Sessions = [System.Collections.Generic.HashSet[string]]::new()
                AfterHoursTokens = 0.0
            }
        }
        $bucket = $days[$key]
        $parts = Get-UsageRecordParts $record
        $bucket.InTokens += $parts.In
        $bucket.OutTokens += $parts.Out
        $bucket.FreshIn += $parts.Fresh
        $bucket.CacheRead += $parts.CacheRead
        $bucket.CacheWrite += $parts.CacheWrite
        if ($null -ne $parts.Cost) {
            if ($null -eq $bucket.EstUsd) { $bucket.EstUsd = 0.0 }
            $bucket.EstUsd += [double]$parts.Cost
        }
        if (Test-LedgerAfterHours $stamp) { $bucket.AfterHoursTokens += ($parts.In + $parts.Out) }
        $session = [string](Get-LedgerNote $record 'SessionId')
        if ($session) { [void]$bucket.Sessions.Add($session) }
        if (Test-LedgerHasNote $record 'MessageDates') {
            foreach ($messageDate in @((Get-LedgerNote $record 'MessageDates'))) {
                if (-not $messageDate) { continue }
                $messageKey = ([datetime]$messageDate).ToString('yyyy-MM-dd')
                if (-not $days.Contains($messageKey)) {
                    $days[$messageKey] = @{
                        Day = $messageKey; InTokens = 0.0; OutTokens = 0.0; FreshIn = 0.0
                        CacheRead = 0.0; CacheWrite = 0.0; EstUsd = $null
                        Messages = 0; Sessions = [System.Collections.Generic.HashSet[string]]::new()
                        AfterHoursTokens = 0.0
                    }
                }
                $days[$messageKey].Messages += 1
                if ($session) { [void]$days[$messageKey].Sessions.Add($session) }
            }
        } else {
            $bucket.Messages += 1
        }
    }

    $listed = foreach ($key in @($days.Keys | Sort-Object)) {
        $bucket = $days[$key]
        $context = [double]$bucket.FreshIn + [double]$bucket.CacheWrite + [double]$bucket.CacheRead
        $bucket.Sessions = $bucket.Sessions.Count
        $bucket.ReusePct = if ($context -gt 0) { 100.0 * [double]$bucket.CacheRead / $context } else { $null }
        $bucket.YieldPer1K = if ([double]$bucket.FreshIn -gt 0) { 1000.0 * [double]$bucket.OutTokens / [double]$bucket.FreshIn } else { $null }
        $bucket
    }
    return @{
        Provider = $Provider
        Days = @($listed)
        Totals = Complete-UsageHistoryTotals @($listed)
    }
}

function Format-UsageHistoryReport($Histories) {
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add('Usage history calculated from local logs - estimated API value, not an invoice')
    $lines.Add('Reuse = share of input served from cache. Yield = output tokens per 1k fresh input.')
    $names = @{ claude = 'Claude'; codex = 'Codex'; cursor = 'Cursor'; grok = 'Grok' }
    foreach ($provider in @('claude', 'codex')) {
        $rollup = Get-LedgerNote $Histories $provider
        $label = $names[$provider]
        if (-not $rollup -or -not $rollup.Days -or @($rollup.Days).Count -eq 0) {
            $lines.Add("$label  no local usage records yet")
            continue
        }
        $totals = $rollup.Totals
        $bits = @($label)
        if ($null -ne $totals.ReusePct) { $bits += ('reuse {0:0}%' -f [double]$totals.ReusePct) }
        if ($null -ne $totals.YieldPer1K) { $bits += ('yield {0:0} per 1k fresh' -f [double]$totals.YieldPer1K) }
        if ($null -ne $totals.UsdPerMessage) { $bits += ((Format-LedgerMoney $totals.UsdPerMessage) + '/msg') }
        if ($null -ne $totals.AfterHoursShare) { $bits += ('{0:0}% of tokens after hours' -f [double]$totals.AfterHoursShare) }
        $lines.Add(($bits -join '  '))
        $recent = @($rollup.Days | Sort-Object Day -Descending | Select-Object -First 14)
        foreach ($day in $recent) {
            $reuse = if ($null -ne $day.ReusePct) { ('reuse {0:0}%' -f [double]$day.ReusePct) } else { 'reuse --' }
            $usd = if ($null -ne $day.EstUsd) { Format-LedgerMoney $day.EstUsd } else { '--' }
            $lines.Add(('  {0}  {1} in  {2} out  {3}  {4}  {5} sessions' -f $day.Day, (Format-LedgerTokens $day.InTokens), (Format-LedgerTokens $day.OutTokens), $usd, $reuse, [int]$day.Sessions))
        }
    }
    $lines.Add('Grok  no per-message token log. The weekly percent is a quota, not a usage history.')
    $lines.Add('Cursor  plan percent and on-demand dollars only. Local edits are not token usage.')
    return @($lines)
}

function Initialize-UsageDayTable {
    param([string]$Path)
    $sql = @'
CREATE TABLE IF NOT EXISTS usage_day (
  provider TEXT NOT NULL,
  day TEXT NOT NULL,
  in_tokens REAL,
  out_tokens REAL,
  fresh_in REAL,
  cache_read REAL,
  cache_write REAL,
  est_usd REAL,
  messages INTEGER,
  sessions INTEGER,
  after_hours_tokens REAL,
  PRIMARY KEY (provider, day)
);
'@
    [void](Invoke-UsageLedgerSql -Path $Path -Sql $sql)
}

function Save-UsageDayHistory {
    param([string]$Path, $Rollup)
    if (-not $Rollup -or -not $Rollup.Days -or @($Rollup.Days).Count -eq 0) { return 0 }
    if (-not (Resolve-UsageLedgerSqlite)) { return 0 }
    if (-not $Path) {
        if (-not $script:AppDir) { return 0 }
        $Path = Join-Path $script:AppDir 'usage-ledger.sqlite'
    }
    Initialize-UsageLedger -Path $Path
    Initialize-UsageDayTable -Path $Path
    $provider = [string]$Rollup.Provider
    if ($provider -notin $script:UsageLedgerProviders) { return 0 }
    $inserts = [System.Collections.Generic.List[string]]::new()
    foreach ($day in @($Rollup.Days)) {
        $inserts.Add((
            'INSERT INTO usage_day (provider, day, in_tokens, out_tokens, fresh_in, cache_read, cache_write, est_usd, messages, sessions, after_hours_tokens) VALUES (' +
            ((ConvertTo-SqliteText $provider), (ConvertTo-SqliteText ([string]$day.Day)),
             (ConvertTo-SqliteLiteral $day.InTokens), (ConvertTo-SqliteLiteral $day.OutTokens),
             (ConvertTo-SqliteLiteral $day.FreshIn), (ConvertTo-SqliteLiteral $day.CacheRead),
             (ConvertTo-SqliteLiteral $day.CacheWrite), (ConvertTo-SqliteLiteral $day.EstUsd),
             (ConvertTo-SqliteLiteral $day.Messages), (ConvertTo-SqliteLiteral $day.Sessions),
             (ConvertTo-SqliteLiteral $day.AfterHoursTokens) -join ', ') + ');'
        ))
    }
    $sql = "BEGIN;`nDELETE FROM usage_day WHERE provider = $(ConvertTo-SqliteText $provider);`n" + ($inserts -join "`n") + "`nCOMMIT;"
    [void](Invoke-UsageLedgerSql -Path $Path -Sql $sql)
    return $inserts.Count
}

function Get-StoredUsageHistory {
    param([string]$Path)
    if (-not $Path) {
        if (-not $script:AppDir) { return @{} }
        $Path = Join-Path $script:AppDir 'usage-ledger.sqlite'
    }
    if (-not (Test-Path -LiteralPath $Path)) { return @{} }
    Initialize-UsageDayTable -Path $Path
    $raw = Invoke-UsageLedgerSql -Path $Path -Sql 'SELECT provider, day, in_tokens, out_tokens, fresh_in, cache_read, cache_write, est_usd, messages, sessions, after_hours_tokens FROM usage_day ORDER BY day;' -Json
    $text = if ($raw -is [array]) { $raw -join '' } else { [string]$raw }
    if ([string]::IsNullOrWhiteSpace($text)) { return @{} }
    $grouped = @{}
    foreach ($row in @($text | ConvertFrom-Json)) {
        $provider = [string]$row.provider
        if (-not $grouped.Contains($provider)) { $grouped[$provider] = [System.Collections.Generic.List[object]]::new() }
        $fresh = ConvertTo-LedgerDouble $row.fresh_in
        $cache = ConvertTo-LedgerDouble $row.cache_read
        $write = ConvertTo-LedgerDouble $row.cache_write
        $out = ConvertTo-LedgerDouble $row.out_tokens
        if ($null -eq $fresh) { $fresh = 0 }
        if ($null -eq $cache) { $cache = 0 }
        if ($null -eq $write) { $write = 0 }
        if ($null -eq $out) { $out = 0 }
        $context = $fresh + $write + $cache
        $grouped[$provider].Add(@{
            Day = [string]$row.day
            InTokens = $(if ($null -eq (ConvertTo-LedgerDouble $row.in_tokens)) { 0 } else { ConvertTo-LedgerDouble $row.in_tokens })
            OutTokens = $out
            FreshIn = $fresh
            CacheRead = $cache
            CacheWrite = $write
            EstUsd = ConvertTo-LedgerDouble $row.est_usd
            Messages = [int](ConvertTo-LedgerDouble $row.messages)
            Sessions = [int](ConvertTo-LedgerDouble $row.sessions)
            AfterHoursTokens = $(if ($null -eq (ConvertTo-LedgerDouble $row.after_hours_tokens)) { 0 } else { ConvertTo-LedgerDouble $row.after_hours_tokens })
            ReusePct = $(if ($context -gt 0) { 100.0 * $cache / $context } else { $null })
            YieldPer1K = $(if ($fresh -gt 0) { 1000.0 * $out / $fresh } else { $null })
        })
    }
    $history = @{}
    foreach ($provider in @($grouped.Keys)) {
        $days = @($grouped[$provider])
        $history[$provider] = @{ Provider = $provider; Days = $days; Totals = Complete-UsageHistoryTotals $days }
    }
    return $history
}

function Add-UsageLedgerPoll {
    if (-not $script:AppDir) { return 0 }
    $plan = $null
    if (Get-Command Get-CursorPlanUsageFromSummary -ErrorAction SilentlyContinue) {
        $plan = Get-CursorPlanUsageFromSummary $script:SummaryData
    }
    $usage = $null
    if ($script:State) { $usage = Get-LedgerNote $script:State 'Data' }
    $rows = ConvertTo-UsageLedgerRows -ObservedAt (Get-Date).ToString('o') `
        -ClaudeStats $script:Stats `
        -ClaudeUsage $usage `
        -CodexStats $script:CodexStats `
        -CursorPlan $plan `
        -GrokUsage $script:GrokUsage
    return Add-UsageLedgerRows -Path (Join-Path $script:AppDir 'usage-ledger.sqlite') -Rows $rows
}
