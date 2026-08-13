# CodexData.ps1 - Codex session parsing and usage cost estimation

function Get-CodexSessionDirCandidates {
    param([string[]]$WslHomeRoots = @(Get-WslHomeRoots))

    $candidates = [System.Collections.Generic.List[string]]::new()

    foreach ($root in @($env:CODEX_HOME)) {
        if ($root) {
            try {
                [void]$candidates.Add((Join-Path $root 'sessions'))
            } catch { }
        }
    }

    foreach ($root in @($env:USERPROFILE, $env:HOME)) {
        if ($root) {
            try {
                [void]$candidates.Add((Join-Path (Join-Path $root '.codex') 'sessions'))
            } catch { }
        }
    }

    foreach ($root in @($env:LOCALAPPDATA, $env:APPDATA)) {
        if ($root) {
            try {
                [void]$candidates.Add((Join-Path $root 'OpenAI\Codex\sessions'))
            } catch { }
        }
    }

    foreach ($root in @($WslHomeRoots)) {
        if ($root) {
            try {
                [void]$candidates.Add((Join-Path $root '.codex\sessions'))
            } catch { }
        }
    }

    return @($candidates | Select-Object -Unique)
}

function Resolve-CodexSessionsDir {
    param([string]$PreferredDir = $script:CodexSessionsDir)

    $candidates = [System.Collections.Generic.List[string]]::new()
    if ($PreferredDir) { [void]$candidates.Add($PreferredDir) }
    foreach ($dir in Get-CodexSessionDirCandidates) {
        if ($dir) { [void]$candidates.Add($dir) }
    }

    foreach ($dir in @($candidates | Select-Object -Unique)) {
        if ($dir -and (Test-Path -LiteralPath $dir -PathType Container -ErrorAction SilentlyContinue)) { return $dir }
    }

    return @($candidates | Select-Object -First 1)
}

if (-not $script:CodexSessionsDir) {
    $script:CodexSessionsDir = Resolve-CodexSessionsDir
}

$script:CodexStats = $null
$script:CodexStatsFileCache = @{}

# Mirrors Cursor's contract (see Test-ProviderAuthFailed in Config.ps1) so both
# providers report auth trouble the same way instead of failing silently.
$script:CodexAuthState = 'init'
$script:CodexErrMsg    = ''

function Set-CodexAuthState {
    param([string]$State, [string]$Message = '')

    $script:CodexAuthState = $State
    $script:CodexErrMsg    = $Message
}

function Convert-CodexCacheDate {
    param($Value)

    if (-not $Value) { return $null }
    if ($Value -is [datetime]) { return $Value }

    try {
        return [System.DateTimeOffset]::Parse([string]$Value).LocalDateTime
    } catch {
        return $null
    }
}

function Convert-CodexCacheRecords {
    param($Records)

    $converted = [System.Collections.Generic.List[object]]::new()
    if (-not $Records) { return $converted }

    foreach ($r in @($Records)) {
        $date = Convert-CodexCacheDate $r.Date
        if (-not $date) { continue }

        $msgDates = @()
        if ($r.MessageDates) {
            foreach ($d in @($r.MessageDates)) {
                $cd = Convert-CodexCacheDate $d
                if ($cd) { $msgDates += $cd }
            }
        }

        $converted.Add(@{
            Model        = [string]$r.Model
            Date         = $date
            In           = [long]$r.In
            CachedIn     = [long]$r.CachedIn
            Out          = [long]$r.Out
            SessionId    = [string]$r.SessionId
            MessageDates = $msgDates
        })
    }

    return $converted
}

function Import-CodexStatsFileCache {
    param([string]$CachePath)

    if (-not $CachePath -or -not (Test-Path $CachePath)) { return }

    try {
        $raw = Get-Content $CachePath -Raw -Encoding UTF8 -ErrorAction Stop
        if (-not $raw) { return }

        $json = $raw | ConvertFrom-Json -ErrorAction Stop
        $loaded = @{}

        foreach ($prop in $json.PSObject.Properties) {
            $entry = $prop.Value
            if (-not $entry -or -not $entry.Stamp -or $entry.CacheVersion -ne 2) { continue }

            $loaded[$prop.Name] = @{
                Stamp         = [string]$entry.Stamp
                Records       = Convert-CodexCacheRecords $entry.Records
                LastTokenDate = Convert-CodexCacheDate $entry.LastTokenDate
                RateLimits    = $entry.RateLimits
            }
        }

        $script:CodexStatsFileCache = $loaded
    } catch {
        Write-CodexLog "Get-CodexStats: failed to load cache $CachePath - $($_.Exception.Message)"
    }
}

function Export-CodexStatsFileCache {
    param([string]$CachePath)

    if (-not $CachePath) { return }

    try {
        $script:CodexStatsFileCache |
            ConvertTo-Json -Depth 12 |
            Set-Content -Path $CachePath -Encoding UTF8 -ErrorAction Stop
    } catch {
        Write-CodexLog "Get-CodexStats: failed to save cache $CachePath - $($_.Exception.Message)"
    }
}

function Write-CodexLog {
    param([string]$Message)
    if (Get-Command Write-Log -ErrorAction SilentlyContinue) {
        Write-Log $Message
    }
}

function Convert-CodexTimestamp {
    param($Value)

    if (-not $Value) { return $null }

    try {
        if ($Value -is [string]) {
            return [System.DateTimeOffset]::Parse($Value).LocalDateTime
        }
        return ([datetime]$Value).ToLocalTime()
    } catch {
        return $null
    }
}

function Convert-CodexEpochSeconds {
    param($Value)

    if ($null -eq $Value) { return $null }

    try {
        return [System.DateTimeOffset]::FromUnixTimeSeconds([long][double]$Value).LocalDateTime
    } catch {
        return $null
    }
}

function Test-CodexUsageAfterHours([datetime]$Date) {
    $startHour = if ($null -ne $script:WorkdayStartHour) { [int]$script:WorkdayStartHour } else { 8 }
    $endHour = if ($null -ne $script:WorkdayEndHour) { [int]$script:WorkdayEndHour } else { 18 }
    if ($Date.DayOfWeek -in @([System.DayOfWeek]::Saturday, [System.DayOfWeek]::Sunday)) { return $true }
    return ($Date.Hour -lt $startHour -or $Date.Hour -ge $endHour)
}

function Estimate-CodexCost([string]$model, $v) {
    if (-not $script:CodexPrices) { throw 'Estimate-CodexCost: $script:CodexPrices not loaded - dot-source Config.ps1 first.' }

    if ($model -eq 'default') {
        $tier = 'default'
    } elseif ($model -match '^gpt-5') {
        if ($script:CodexPrices.ContainsKey($model)) {
            $tier = $model
        } else {
            $tier = 'gpt-5.5'
        }
    } else {
        $tier = 'default'
        if ($model -and (Get-Command Write-Log -ErrorAction SilentlyContinue)) {
            Write-Log "Unknown Codex model '$model' - falling back to default pricing (verify prices)"
        }
    }

    if (-not $script:CodexPrices.ContainsKey($tier)) {
        $tier = 'default'
    }

    $p = $script:CodexPrices[$tier]
    $inputTokens = [double]$v.inputTokens
    $cachedInputTokens = [double]$v.cachedInputTokens
    $outputTokens = [double]$v.outputTokens
    $uncachedInputTokens = [Math]::Max(0.0, $inputTokens - $cachedInputTokens)

    return ($uncachedInputTokens / 1e6 * $p.in) +
           ($cachedInputTokens   / 1e6 * $p.cachedIn) +
           ($outputTokens        / 1e6 * $p.out)
}

function Measure-CodexStats([object[]]$records, [datetime]$today, $rateLimits = $null) {
    $val = 0.0; $tin = 0L; $tout = 0L
    $sessions = [System.Collections.Generic.HashSet[string]]::new()
    $msgCount = 0; $tMsg = 0; $tTok = 0L; $afterHoursMsg = 0; $afterHoursTok = 0L
    $fiveHourPct = $null
    $fiveHourResetsAt = $null
    $weekPct = $null
    $weekResetsAt = $null
    $currentModel = $null
    $latestModelDate = $null

    foreach ($r in $records) {
        $v = @{
            inputTokens       = [long]$r.In
            cachedInputTokens = [long]$r.CachedIn
            outputTokens      = [long]$r.Out
        }
        $val  += Estimate-CodexCost $r.Model $v
        $tin  += [long]$r.In
        $tout += [long]$r.Out
        [void]$sessions.Add([string]$r.SessionId)

        $messageDates = if ($null -eq $r.MessageDates) { @() } else { @($r.MessageDates) }
        if ($messageDates.Count -eq 0) {
            $messageDates = @($r.Date)
        }
        $msgCount += $messageDates.Count
        foreach ($messageDate in $messageDates) {
            if ($messageDate.Date -eq $today.Date) {
                $tMsg++
                if (Test-CodexUsageAfterHours $messageDate) { $afterHoursMsg++ }
            }
        }

        if ($r.Date.Date -eq $today.Date) {
            $tTok += [long]$r.In + [long]$r.Out
            if (Test-CodexUsageAfterHours $r.Date) { $afterHoursTok += [long]$r.In + [long]$r.Out }
        }

        # Current model = the model of the most recent session that named one
        # ('default' is the fallback for sessions with no turn_context).
        if ($r.Model -and $r.Model -ne 'default' -and ((-not $latestModelDate) -or ($r.Date -gt $latestModelDate))) {
            $latestModelDate = $r.Date
            $currentModel = $r.Model
        }
    }

    if ($rateLimits) {
        # Codex reports one or two rate-limit windows. Historically the short
        # (5-hour) window was 'primary' and the weekly window was 'secondary',
        # but newer Codex plans surface only the weekly limit and carry it in
        # the 'primary' slot. Classify by window_minutes when present (weekly =
        # the longest window) and fall back to the legacy slot convention when
        # Codex omits the window metadata.
        $fiveHour = $null
        $weekly   = $null

        $candidates = @()
        if ($rateLimits.primary)   { $candidates += $rateLimits.primary }
        if ($rateLimits.secondary) { $candidates += $rateLimits.secondary }

        $withWindows = @($candidates | Where-Object {
            ($null -ne $_.window_minutes) -and ($null -ne $_.used_percent)
        })

        if ($withWindows.Count -ge 2) {
            $sorted   = @($withWindows | Sort-Object { [double]$_.window_minutes })
            $fiveHour = $sorted[0]
            $weekly   = $sorted[-1]
        } elseif ($withWindows.Count -eq 1) {
            # A single reported window: a day or longer is the weekly limit.
            if ([double]$withWindows[0].window_minutes -ge 1440) {
                $weekly = $withWindows[0]
            } else {
                $fiveHour = $withWindows[0]
            }
        } else {
            $fiveHour = $rateLimits.primary
            $weekly   = $rateLimits.secondary
        }

        if ($fiveHour) {
            if ($null -ne $fiveHour.used_percent) { $fiveHourPct = [double]$fiveHour.used_percent }
            if ($null -ne $fiveHour.resets_at)    { $fiveHourResetsAt = Convert-CodexEpochSeconds $fiveHour.resets_at }
        }
        if ($weekly) {
            if ($null -ne $weekly.used_percent) { $weekPct = [double]$weekly.used_percent }
            if ($null -ne $weekly.resets_at)    { $weekResetsAt = Convert-CodexEpochSeconds $weekly.resets_at }
        }
    }

    return @{
        ValueUSD         = $val
        InTokens         = $tin
        OutTokens        = $tout
        Sessions         = $sessions.Count
        Messages         = $msgCount
        TodayMsg         = $tMsg
        TodayTok         = $tTok
        TodayAfterHoursMsg = $afterHoursMsg
        TodayAfterHoursTok = $afterHoursTok
        FiveHourPct      = $fiveHourPct
        FiveHourResetsAt = $fiveHourResetsAt
        WeekPct          = $weekPct
        WeekResetsAt     = $weekResetsAt
        ResetsAvailable  = $null
        PlanType         = $null
        Model            = $currentModel
        LastComputed     = (Get-Date -Format 'yyyy-MM-dd HH:mm')
    }
}

# Parse the Codex live usage endpoint (chatgpt.com/backend-api/wham/usage)
# response into overlay fields. Weekly = the longest limit window; the reset
# credit count backs the "N resets available" line. Pure so it can be tested
# without a network call.
function ConvertFrom-CodexUsageResponse($obj) {
    if (-not $obj) { return $null }

    $weekPct = $null; $weekResetsAt = $null
    $fiveHourPct = $null; $fiveHourResetsAt = $null

    $rl = $obj.rate_limit
    if ($rl) {
        $windows = @()
        if ($rl.primary_window)   { $windows += $rl.primary_window }
        if ($rl.secondary_window) { $windows += $rl.secondary_window }

        $withSecs = @($windows | Where-Object {
            ($null -ne $_.limit_window_seconds) -and ($null -ne $_.used_percent)
        })

        $weekly = $null; $fiveHour = $null
        if ($withSecs.Count -ge 2) {
            $sorted   = @($withSecs | Sort-Object { [double]$_.limit_window_seconds })
            $fiveHour = $sorted[0]
            $weekly   = $sorted[-1]
        } elseif ($withSecs.Count -eq 1) {
            # A day or longer is the weekly window.
            if ([double]$withSecs[0].limit_window_seconds -ge 86400) {
                $weekly = $withSecs[0]
            } else {
                $fiveHour = $withSecs[0]
            }
        }

        if ($weekly) {
            if ($null -ne $weekly.used_percent) { $weekPct = [double]$weekly.used_percent }
            if ($null -ne $weekly.reset_at)     { $weekResetsAt = Convert-CodexEpochSeconds $weekly.reset_at }
        }
        if ($fiveHour) {
            if ($null -ne $fiveHour.used_percent) { $fiveHourPct = [double]$fiveHour.used_percent }
            if ($null -ne $fiveHour.reset_at)     { $fiveHourResetsAt = Convert-CodexEpochSeconds $fiveHour.reset_at }
        }
    }

    $resetsAvailable = $null
    if ($obj.rate_limit_reset_credits -and ($null -ne $obj.rate_limit_reset_credits.available_count)) {
        $resetsAvailable = [int]$obj.rate_limit_reset_credits.available_count
    }

    return @{
        WeekPct          = $weekPct
        WeekResetsAt     = $weekResetsAt
        FiveHourPct      = $fiveHourPct
        FiveHourResetsAt = $fiveHourResetsAt
        ResetsAvailable  = $resetsAvailable
        PlanType         = $obj.plan_type
    }
}

# Fetch live Codex usage from the ChatGPT backend using the local Codex OAuth
# token. The new Codex no longer records rate limits in session logs, so this
# authenticated call is the only source for the weekly bar and reset credits.
# Returns $null on any failure (missing/expired token, network error) so the
# overlay falls back to whatever it already has instead of breaking.
function Get-CodexLiveUsage {
    param(
        [int]$TimeoutSec = 15,
        [string]$AuthPath
    )

    $authPath = if ($AuthPath) { $AuthPath } else { Join-Path $env:USERPROFILE '.codex\auth.json' }
    if (-not (Test-Path -LiteralPath $authPath)) {
        Set-CodexAuthState 'notoken' 'No Codex login found - run codex login'
        return $null
    }

    try {
        $auth = Get-Content -LiteralPath $authPath -Raw | ConvertFrom-Json
    } catch {
        Write-CodexLog "Get-CodexLiveUsage: cannot read auth.json - $($_.Exception.Message)"
        Set-CodexAuthState 'notoken' 'Cannot read Codex auth.json - run codex login'
        return $null
    }

    $token = $null
    if ($auth.tokens -and $auth.tokens.access_token) { $token = $auth.tokens.access_token }
    elseif ($auth.access_token) { $token = $auth.access_token }
    if (-not $token) {
        Set-CodexAuthState 'notoken' 'No Codex access token - run codex login'
        return $null
    }

    $acct = $auth.account_id
    if (-not $acct -and $auth.tokens) { $acct = $auth.tokens.account_id }

    $headers = @{
        'Authorization' = "Bearer $token"
        'originator'    = 'codex_cli_rs'
        'User-Agent'    = 'codex_cli_rs/0.144.2 (ai-usage-overlay)'
        'Accept'        = 'application/json'
    }
    if ($acct) { $headers['chatgpt-account-id'] = "$acct" }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $resp = Invoke-RestMethod -Uri 'https://chatgpt.com/backend-api/wham/usage' `
            -Headers $headers -Method GET -TimeoutSec $TimeoutSec
        Set-CodexAuthState 'ok' ''
        return ConvertFrom-CodexUsageResponse $resp
    } catch {
        $message = $_.Exception.Message
        Write-CodexLog "Get-CodexLiveUsage: request failed - $message"

        # Both the access token AND the refresh token expire, and once the
        # refresh token is gone no code path can recover it - only an interactive
        # `codex login`. Name that remedy instead of echoing a bare 401.
        $code = $null
        if ($_.Exception.Response) { try { $code = [int]$_.Exception.Response.StatusCode } catch { } }
        if ($code -eq 401 -or $message -match '\b401\b') {
            Set-CodexAuthState 'auth' 'Codex login expired - run codex login'
        } else {
            Set-CodexAuthState 'stale' $message
        }
        return $null
    }
}

function Get-CodexStats {
    $cachePath = Join-Path $script:AppDir 'codex-cache.json'
    Import-CodexStatsFileCache $cachePath
    $sessionsDir = Resolve-CodexSessionsDir
    if ($sessionsDir) {
        $script:CodexSessionsDir = $sessionsDir
    }

    $candidateDirs = [System.Collections.Generic.List[string]]::new()
    if ($script:CodexSessionsDir) { [void]$candidateDirs.Add($script:CodexSessionsDir) }
    foreach ($dir in Get-CodexSessionDirCandidates) {
        if ($dir) { [void]$candidateDirs.Add($dir) }
    }

    $sessionDirs = [System.Collections.Generic.List[string]]::new()
    foreach ($dir in @($candidateDirs | Select-Object -Unique)) {
        try {
            if (Test-Path -LiteralPath $dir -PathType Container -ErrorAction SilentlyContinue) {
                [void]$sessionDirs.Add($dir)
            }
        } catch { }
    }

    if ($sessionDirs.Count -eq 0) {
        $candidateText = (@($candidateDirs | Select-Object -Unique)) -join '; '
        Write-CodexLog "Get-CodexStats: Codex sessions directory not found - checked: $candidateText"
        return
    }

    $files = [System.Collections.Generic.List[object]]::new()
    foreach ($dir in $sessionDirs) {
        try {
            foreach ($file in @(Get-ChildItem -LiteralPath $dir -Recurse -Filter '*.jsonl' -File -ErrorAction Stop)) {
                [void]$files.Add($file)
            }
        } catch {
            Write-CodexLog "Get-CodexStats: failed to enumerate sessions in $dir - $($_.Exception.Message)"
        }
    }

    $allRecords = [System.Collections.Generic.List[object]]::new()
    $latestRateLimits = $null
    $latestTokenDate = $null
    $activeCache = @{}

    foreach ($file in $files) {
        $stamp = "$($file.LastWriteTimeUtc.Ticks):$($file.Length)"
        $cached = $script:CodexStatsFileCache[$file.FullName]

        if ($cached -and $cached.Stamp -eq $stamp) {
            $activeCache[$file.FullName] = $cached
            foreach ($r in $cached.Records) {
                $allRecords.Add($r)
            }
            if ($cached.LastTokenDate -and ((-not $latestTokenDate) -or ($cached.LastTokenDate -gt $latestTokenDate))) {
                $latestTokenDate = $cached.LastTokenDate
                $latestRateLimits = $cached.RateLimits
            }
            continue
        }

        $fileRecords = [System.Collections.Generic.List[object]]::new()
        try {
            $lines = Get-Content $file.FullName -Encoding UTF8 -ErrorAction Stop
        } catch {
            Write-CodexLog "Get-CodexStats: skipping unreadable file $($file.FullName) - $($_.Exception.Message)"
            continue
        }

        $lastUsage = $null
        $lastModel = $null
        $sessionId = $null
        $sessionDate = $null
        $messageDates = [System.Collections.Generic.List[datetime]]::new()
        $lastTokenDate = $null
        $lastRateLimits = $null

        foreach ($line in $lines) {
            if (-not $line) { continue }

            try {
                $o = $line | ConvertFrom-Json -ErrorAction Stop
            } catch {
                continue
            }

            if ($o.type -eq 'session_meta') {
                if ($o.payload.session_id) {
                    $sessionId = [string]$o.payload.session_id
                }
                $metaDate = Convert-CodexTimestamp $o.payload.timestamp
                if (-not $metaDate) {
                    $metaDate = Convert-CodexTimestamp $o.timestamp
                }
                if ($metaDate) {
                    $sessionDate = $metaDate
                }
            } elseif ($o.type -eq 'turn_context') {
                if ($o.payload.model) {
                    $lastModel = [string]$o.payload.model
                }
            } elseif (($o.type -eq 'token_count') -or
                      (($o.type -eq 'event_msg') -and ($o.payload.type -eq 'token_count'))) {
                $usage = $o.payload.info.total_token_usage
                $limits = $o.payload.rate_limits
                if (-not $limits) {
                    $limits = $o.rate_limits
                }
                if ($usage) {
                    $lastUsage = $usage
                    $lastRateLimits = $limits
                    $tokenDate = Convert-CodexTimestamp $o.timestamp
                    if ($tokenDate) {
                        $lastTokenDate = $tokenDate
                    }
                }
            } elseif (($o.type -eq 'event_msg') -and ($o.payload.type -eq 'user_message')) {
                $msgDate = Convert-CodexTimestamp $o.timestamp
                if ($msgDate) { [void]$messageDates.Add($msgDate) }
            }
        }

        if ($lastUsage -or $sessionId -or $messageDates.Count -gt 0) {
            $recordDate = $sessionDate
            if (-not $recordDate) { $recordDate = $lastTokenDate }
            if (-not $recordDate) { $recordDate = $file.LastWriteTime }

            $modelName = $lastModel
            if (-not $modelName) { $modelName = 'default' }

            $sessionName = $sessionId
            if (-not $sessionName) { $sessionName = $file.BaseName }

            $inputTokens = 0L
            $cachedInputTokens = 0L
            $outputTokens = 0L
            if ($lastUsage) {
                $inputTokens = [long]$lastUsage.input_tokens
                $cachedInputTokens = [long]$lastUsage.cached_input_tokens
                $outputTokens = [long]$lastUsage.output_tokens
            }

            $fileRecords.Add(@{
                Model     = $modelName
                Date      = $recordDate
                In        = $inputTokens
                CachedIn  = $cachedInputTokens
                Out       = $outputTokens
                SessionId = [string]$sessionName
                MessageDates = $messageDates.ToArray()
            })
        }

        $fileTokenDate = $lastTokenDate
        if ($lastUsage) {
            if (-not $fileTokenDate) { $fileTokenDate = $sessionDate }
            if (-not $fileTokenDate) { $fileTokenDate = $file.LastWriteTime }

            if ((-not $latestTokenDate) -or ($fileTokenDate -gt $latestTokenDate)) {
                $latestTokenDate = $fileTokenDate
                $latestRateLimits = $lastRateLimits
            }
        }

        $activeCache[$file.FullName] = @{
            CacheVersion  = 2
            Stamp         = $stamp
            Records       = $fileRecords
            LastTokenDate = $fileTokenDate
            RateLimits    = $lastRateLimits
        }

        foreach ($r in $fileRecords) {
            $allRecords.Add($r)
        }
    }

    $script:CodexStatsFileCache = $activeCache
    Export-CodexStatsFileCache $cachePath

    try {
        $script:CodexStats = Measure-CodexStats $allRecords.ToArray() (Get-Date) $latestRateLimits
    } catch {
        Write-CodexLog "Get-CodexStats: Measure-CodexStats failed - $($_.Exception.Message)"
    }

    # The current Codex no longer persists rate limits to session logs, so the
    # weekly bar and reset-credit count come from the live usage endpoint. Prefer
    # live values when available; otherwise keep whatever the logs provided.
    try {
        $live = Get-CodexLiveUsage
        if ($live) {
            if (-not $script:CodexStats) {
                $script:CodexStats = Measure-CodexStats @() (Get-Date)
            }
            if ($null -ne $live.WeekPct)          { $script:CodexStats.WeekPct = $live.WeekPct }
            if ($null -ne $live.WeekResetsAt)     { $script:CodexStats.WeekResetsAt = $live.WeekResetsAt }
            if ($null -ne $live.FiveHourPct)      { $script:CodexStats.FiveHourPct = $live.FiveHourPct }
            if ($null -ne $live.FiveHourResetsAt) { $script:CodexStats.FiveHourResetsAt = $live.FiveHourResetsAt }
            $script:CodexStats.ResetsAvailable = $live.ResetsAvailable
            if ($live.PlanType) { $script:CodexStats.PlanType = $live.PlanType }
        }
    } catch {
        Write-CodexLog "Get-CodexStats: live usage merge failed - $($_.Exception.Message)"
    }
}
