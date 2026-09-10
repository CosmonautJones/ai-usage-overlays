#Requires -Module Pester
BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $root
    $script:ErrLog = Join-Path ([System.IO.Path]::GetTempPath()) 'overlay-test-errors.log'
    . (Join-Path $root 'src\Config.ps1')
    function Get-WslHomeRoots { return @() }
    $script:CodexPrices = @{
        'gpt-5.5' = @{ in = 5.00; cachedIn = 0.50; out = 30.00 }
        default   = @{ in = 1.00; cachedIn = 0.10; out = 2.00 }
    }
    . (Join-Path $root 'src\CodexData.ps1')

    function New-CodexTokenEvent {
        param(
            [string]$Timestamp,
            [long]$InputTokens,
            [long]$CachedInputTokens,
            [long]$OutputTokens,
            $RateLimits = $null,
            [switch]$Legacy
        )

        $info = @{
            total_token_usage = @{
                input_tokens            = $InputTokens
                cached_input_tokens     = $CachedInputTokens
                output_tokens           = $OutputTokens
                reasoning_output_tokens = 0
                total_tokens            = $InputTokens + $OutputTokens
            }
            last_token_usage = @{
                input_tokens        = 999999
                cached_input_tokens = 999999
                output_tokens       = 999999
                total_tokens        = 1999998
            }
        }

        $payload = @{
            type                 = 'token_count'
            info                 = $info
            model_context_window = 258400
        }
        if ($RateLimits) {
            $payload.rate_limits = $RateLimits
        }

        if ($Legacy) {
            return @{
                timestamp = $Timestamp
                type      = 'token_count'
                payload   = @{
                    info = $info
                }
            }
        }

        return @{
            timestamp = $Timestamp
            type      = 'event_msg'
            payload   = $payload
        }
    }

    function New-CodexUserMessage {
        param(
            [string]$Timestamp,
            [string]$Message = 'test message'
        )

        return @{
            timestamp = $Timestamp
            type      = 'event_msg'
            payload   = @{
                type    = 'user_message'
                message = $Message
            }
        }
    }

    function New-TestTimestamp {
        param([datetime]$LocalTime)

        $offset = [System.TimeZoneInfo]::Local.GetUtcOffset($LocalTime)
        return ([System.DateTimeOffset]::new($LocalTime, $offset)).ToString('o')
    }

    function Write-CodexFixture {
        param(
            [string]$RelativePath,
            [object[]]$Events
        )

        $target = Join-Path $script:CodexSessionsDir $RelativePath
        $dir = Split-Path $target -Parent
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
        $jsonl = foreach ($event in $Events) {
            $event | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -Path $target -Value $jsonl -Encoding UTF8
        return $target
    }
}

Describe 'Measure-CodexStats' {
    It 'returns zeroed stats for empty input' {
        $s = Measure-CodexStats @() ([datetime]'2026-06-10')
        $s.InTokens  | Should -Be 0
        $s.OutTokens | Should -Be 0
        $s.ValueUSD  | Should -Be 0.0
        $s.Messages  | Should -Be 0
        $s.Sessions  | Should -Be 0
        $s.TodayMsg  | Should -Be 0
        $s.TodayTok  | Should -Be 0
    }

    It 'filters today tokens and messages correctly' {
        $today = [datetime]'2026-06-10'
        $records = @(
            @{ Model='gpt-5.5'; Date=[datetime]'2026-06-09'; In=500L; CachedIn=0L; Out=100L; SessionId='s1' }
            @{ Model='gpt-5.5'; Date=[datetime]'2026-06-10'; In=100L; CachedIn=10L; Out=50L; SessionId='s2' }
            @{ Model='gpt-5.5'; Date=[datetime]'2026-06-10'; In=200L; CachedIn=20L; Out=25L; SessionId='s3' }
        )
        $s = Measure-CodexStats $records $today
        $s.TodayMsg | Should -Be 2
        $s.TodayTok | Should -Be 375
    }

    It 'counts Codex turns separately from session files' {
        $today = [datetime]'2026-06-10'
        $records = @(
            @{
                Model='gpt-5.5'; Date=[datetime]'2026-06-10'; In=500L; CachedIn=0L; Out=100L; SessionId='s1'
                MessageDates=@([datetime]'2026-06-09T23:00:00', [datetime]'2026-06-10T10:00:00', [datetime]'2026-06-10T11:00:00')
            }
        )

        $s = Measure-CodexStats $records $today

        $s.Sessions | Should -Be 1
        $s.Messages | Should -Be 3
        $s.TodayMsg | Should -Be 2
    }
}

Describe 'Estimate-CodexCost' {
    It 'uses gpt-5 family pricing and default pricing for other models' {
        $v = @{ inputTokens = 1000000; cachedInputTokens = 0; outputTokens = 0 }
        Estimate-CodexCost 'gpt-5.5' $v | Should -Be 5.0
        Estimate-CodexCost 'other-model' $v | Should -Be 1.0
    }

    It 'subtracts cached input tokens before applying uncached input pricing' {
        $v = @{ inputTokens = 1000000; cachedInputTokens = 250000; outputTokens = 100000 }
        Estimate-CodexCost 'gpt-5.5' $v | Should -Be 6.875
    }
}

Describe 'Get-CodexSessionDirCandidates' {
    It 'includes sessions directories from supplied WSL home roots' {
        $wslHome = '\\wsl.localhost\Ubuntu\home\alice'

        $dirs = Get-CodexSessionDirCandidates -WslHomeRoots @($wslHome)

        $dirs | Should -Contain '\\wsl.localhost\Ubuntu\home\alice\.codex\sessions'
    }
}

Describe 'Get-CodexStats' {
    BeforeEach {
        $script:AppDir = $TestDrive
        $script:OriginalCodexEnvironment = @{}
        foreach ($name in @('CODEX_HOME', 'USERPROFILE', 'HOME', 'LOCALAPPDATA', 'APPDATA')) {
            $script:OriginalCodexEnvironment[$name] = [System.Environment]::GetEnvironmentVariable($name, 'Process')
            [System.Environment]::SetEnvironmentVariable($name, $TestDrive, 'Process')
        }
        $script:CodexSessionsDir = Join-Path $TestDrive 'sessions'
        if (Test-Path $script:CodexSessionsDir) {
            Remove-Item -Path $script:CodexSessionsDir -Recurse -Force
        }
        New-Item -ItemType Directory -Path $script:CodexSessionsDir -Force | Out-Null
        $script:CodexStatsFileCache = @{}
        $script:CodexStats = $null
    }

    AfterEach {
        foreach ($name in $script:OriginalCodexEnvironment.Keys) {
            [System.Environment]::SetEnvironmentVariable($name, $script:OriginalCodexEnvironment[$name], 'Process')
        }
    }

    It 'parses real event_msg user messages and the last cumulative token event in each session file' {
        $baseTime = (Get-Date).Date.AddHours(10)
        $tsMeta = New-TestTimestamp $baseTime
        $tsModel = New-TestTimestamp ($baseTime.AddMinutes(1))
        $tsUser1 = New-TestTimestamp ($baseTime.AddMinutes(2))
        $tsUser2 = New-TestTimestamp ($baseTime.AddMinutes(3))
        $tsUser3 = New-TestTimestamp ($baseTime.AddMinutes(4))
        $tsToken1 = New-TestTimestamp ($baseTime.AddMinutes(5))
        $tsToken2 = New-TestTimestamp ($baseTime.AddMinutes(6))
        $rateLimits = @{
            primary = @{ used_percent = 48; resets_at = 1783651392 }
            secondary = @{ used_percent = 8; resets_at = 1784238192 }
        }

        Write-CodexFixture '2026\06\10\rollout-test.jsonl' @(
            @{ timestamp=$tsMeta; type='session_meta'; payload=@{ session_id='s1'; timestamp=$tsMeta } }
            @{ timestamp=$tsModel; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexUserMessage $tsUser1 'first')
            (New-CodexUserMessage $tsUser2 'second')
            (New-CodexUserMessage $tsUser3 'third')
            (New-CodexTokenEvent $tsToken1 100 10 20)
            (New-CodexTokenEvent $tsToken2 300 50 70 $rateLimits)
        ) | Out-Null

        Get-CodexStats

        $script:CodexStats.InTokens  | Should -Be 300
        $script:CodexStats.OutTokens | Should -Be 70
        $script:CodexStats.ValueUSD  | Should -Be 0.003375
        $script:CodexStats.Messages  | Should -Be 3
        $script:CodexStats.Sessions  | Should -Be 1
        $script:CodexStats.TodayMsg  | Should -Be 3
        $script:CodexStats.TodayTok  | Should -Be 370
        $script:CodexStats.ValueUSD  | Should -BeGreaterThan 0
    }

    It 'preserves user message dates when the session file is loaded from cache' {
        $baseTime = (Get-Date).Date.AddHours(12)
        $tsMeta = New-TestTimestamp $baseTime
        $tsModel = New-TestTimestamp ($baseTime.AddMinutes(1))
        $tsUser1 = New-TestTimestamp ($baseTime.AddMinutes(2))
        $tsUser2 = New-TestTimestamp ($baseTime.AddMinutes(3))
        $tsUser3 = New-TestTimestamp ($baseTime.AddMinutes(4))
        $tsToken = New-TestTimestamp ($baseTime.AddMinutes(5))
        $rateLimits = @{
            primary = @{ used_percent = 48; resets_at = 1783651392 }
            secondary = @{ used_percent = 8; resets_at = 1784238192 }
        }

        Write-CodexFixture '2026\06\10\cache-message-test.jsonl' @(
            @{ timestamp=$tsMeta; type='session_meta'; payload=@{ session_id='cache-messages'; timestamp=$tsMeta } }
            @{ timestamp=$tsModel; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexUserMessage $tsUser1 'first')
            (New-CodexUserMessage $tsUser2 'second')
            (New-CodexUserMessage $tsUser3 'third')
            (New-CodexTokenEvent $tsToken 300 50 70 $rateLimits)
        ) | Out-Null

        Get-CodexStats

        $script:CodexStats.Messages | Should -Be 3
        $script:CodexStats.TodayMsg | Should -Be 3

        $script:CodexStatsFileCache = @{}
        $script:CodexStats = $null

        Get-CodexStats

        $script:CodexStats.Messages | Should -Be 3
        $script:CodexStats.TodayMsg | Should -Be 3
    }

    It 'parses rate limits from the real event_msg payload shape' {
        $baseTime = (Get-Date).Date.AddHours(11)
        $tsMeta = New-TestTimestamp $baseTime
        $tsToken1 = New-TestTimestamp ($baseTime.AddMinutes(1))
        $tsToken2 = New-TestTimestamp ($baseTime.AddMinutes(2))
        $fiveHourReset = 1782503136
        $weekReset = 1783089936

        $firstLimits = @{
            limit_id   = 'codex'
            primary    = @{ used_percent = 12.0; window_minutes = 300; resets_at = $fiveHourReset - 60 }
            secondary  = @{ used_percent = 3.0; window_minutes = 10080; resets_at = $weekReset - 60 }
            plan_type  = 'team'
        }
        $lastLimits = @{
            limit_id   = 'codex'
            primary    = @{ used_percent = 33.0; window_minutes = 300; resets_at = $fiveHourReset }
            secondary  = @{ used_percent = 5.0; window_minutes = 10080; resets_at = $weekReset }
            plan_type  = 'team'
        }

        Write-CodexFixture '2026\06\10\rate-limit-test.jsonl' @(
            @{ timestamp=$tsMeta; type='session_meta'; payload=@{ session_id='limits'; timestamp=$tsMeta } }
            (New-CodexTokenEvent $tsToken1 100 10 20 $firstLimits)
            (New-CodexTokenEvent $tsToken2 300 50 70 $lastLimits)
        ) | Out-Null

        Get-CodexStats

        $script:CodexStats.FiveHourPct | Should -Be 33.0
        $script:CodexStats.WeekPct | Should -Be 5.0
        $script:CodexStats.FiveHourResetsAt | Should -Be ([System.DateTimeOffset]::FromUnixTimeSeconds($fiveHourReset).LocalDateTime)
        $script:CodexStats.WeekResetsAt | Should -Be ([System.DateTimeOffset]::FromUnixTimeSeconds($weekReset).LocalDateTime)
    }

    It 'treats the longest-window limit as weekly even when Codex reports it in the primary slot' {
        $baseTime = (Get-Date).Date.AddHours(11)
        $tsMeta  = New-TestTimestamp $baseTime
        $tsToken = New-TestTimestamp ($baseTime.AddMinutes(1))
        $weekReset = 1783425072

        # New Codex format: a single weekly limit, carried in the primary slot.
        $newFormatLimits = @{
            limit_id  = 'codex'
            primary   = @{ used_percent = 94.0; window_minutes = 10080; resets_at = $weekReset }
            plan_type = 'plus'
        }

        Write-CodexFixture '2026\06\11\new-format-test.jsonl' @(
            @{ timestamp=$tsMeta; type='session_meta'; payload=@{ session_id='newfmt'; timestamp=$tsMeta } }
            (New-CodexTokenEvent $tsToken 100 10 20 $newFormatLimits)
        ) | Out-Null

        Get-CodexStats

        $script:CodexStats.WeekPct | Should -Be 94.0
        $script:CodexStats.WeekResetsAt | Should -Be ([System.DateTimeOffset]::FromUnixTimeSeconds($weekReset).LocalDateTime)
        $script:CodexStats.FiveHourPct | Should -BeNullOrEmpty
    }

    It 'still parses legacy top-level token_count events' {
        Write-CodexFixture '2026\06\10\legacy-test.jsonl' @(
            @{ timestamp='2026-06-10T10:00:00Z'; type='session_meta'; payload=@{ session_id='legacy'; timestamp='2026-06-10T10:00:00Z' } }
            @{ timestamp='2026-06-10T10:01:00Z'; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent '2026-06-10T10:02:00Z' 1000 250 100 -Legacy)
        ) | Out-Null

        Get-CodexStats

        $script:CodexStats.InTokens  | Should -Be 1000
        $script:CodexStats.OutTokens | Should -Be 100
        $script:CodexStats.ValueUSD  | Should -Be 0.006875
        $script:CodexStats.Sessions  | Should -Be 1
    }

    It 'counts sessions that have a user message but no token usage yet' {
        $baseTime = (Get-Date).Date.AddHours(9)
        $tsMeta = New-TestTimestamp $baseTime
        $tsTurn = New-TestTimestamp ($baseTime.AddMinutes(1))
        $tsUser = New-TestTimestamp ($baseTime.AddMinutes(2))

        Write-CodexFixture '2026\06\10\no-usage-test.jsonl' @(
            @{ timestamp=$tsMeta; type='session_meta'; payload=@{ session_id='no-usage'; timestamp=$tsMeta } }
            @{ timestamp=$tsTurn; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexUserMessage $tsUser)
        ) | Out-Null

        Get-CodexStats

        $script:CodexStats.Sessions  | Should -Be 1
        $script:CodexStats.Messages  | Should -Be 1
        $script:CodexStats.InTokens  | Should -Be 0
        $script:CodexStats.OutTokens | Should -Be 0
        $script:CodexStats.ValueUSD  | Should -Be 0
    }

    It 'tolerates a missing sessions directory' {
        $script:CodexSessionsDir = Join-Path $TestDrive 'missing'
        Remove-Item -Path (Join-Path $TestDrive 'sessions') -Recurse -Force
        { Get-CodexStats } | Should -Not -Throw
        $script:CodexStats | Should -BeNullOrEmpty
    }

    It 'discovers sessions from CODEX_HOME when the preferred sessions directory is missing' {
        $codexHome = Join-Path $TestDrive 'codex-home'
        $env:CODEX_HOME = $codexHome
        $script:CodexSessionsDir = Join-Path $TestDrive 'missing-default'

        $target = Join-Path $codexHome 'sessions\2026\06\10\codex-home-test.jsonl'
        New-Item -ItemType Directory -Path (Split-Path $target -Parent) -Force | Out-Null
        $events = @(
            @{ timestamp='2026-06-10T10:00:00Z'; type='session_meta'; payload=@{ session_id='codex-home'; timestamp='2026-06-10T10:00:00Z' } }
            @{ timestamp='2026-06-10T10:01:00Z'; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent '2026-06-10T10:02:00Z' 1000 250 100)
        )
        $jsonl = foreach ($event in $events) {
            $event | ConvertTo-Json -Depth 10 -Compress
        }
        Set-Content -Path $target -Value $jsonl -Encoding UTF8

        Get-CodexStats

        $script:CodexSessionsDir | Should -Be (Join-Path $codexHome 'sessions')
        $script:CodexStats.InTokens | Should -Be 1000
        $script:CodexStats.Sessions | Should -Be 1
    }

    It 'merges session records from every existing candidate directory' {
        $additionalDir = Join-Path $TestDrive 'additional-sessions'
        $baseTime = (Get-Date).Date.AddHours(10)
        $timestamp = New-TestTimestamp $baseTime

        Write-CodexFixture 'primary.jsonl' @(
            @{ timestamp=$timestamp; type='session_meta'; payload=@{ session_id='primary'; timestamp=$timestamp } }
            (New-CodexTokenEvent $timestamp 100 0 10)
        ) | Out-Null

        $secondaryFile = Join-Path $additionalDir 'secondary.jsonl'
        New-Item -ItemType Directory -Path $additionalDir -Force | Out-Null
        @(
            @{ timestamp=$timestamp; type='session_meta'; payload=@{ session_id='secondary'; timestamp=$timestamp } }
            (New-CodexTokenEvent $timestamp 200 0 20)
        ) | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress } |
            Set-Content -Path $secondaryFile -Encoding UTF8

        Mock Get-CodexSessionDirCandidates { @($script:CodexSessionsDir, $additionalDir) }

        Get-CodexStats

        $script:CodexStats.InTokens | Should -Be 300
        $script:CodexStats.OutTokens | Should -Be 30
        $script:CodexStats.Sessions | Should -Be 2
    }
}

Describe 'ConvertFrom-CodexUsageResponse' {
    It 'parses the new single weekly window and reset-credit count' {
        $resetAt = 1784488309
        $obj = [pscustomobject]@{
            plan_type = 'plus'
            rate_limit = [pscustomobject]@{
                primary_window = [pscustomobject]@{
                    used_percent = 94
                    limit_window_seconds = 604800
                    reset_at = $resetAt
                }
                secondary_window = $null
            }
            rate_limit_reset_credits = [pscustomobject]@{ available_count = 2 }
        }

        $u = ConvertFrom-CodexUsageResponse $obj

        $u.WeekPct | Should -Be 94
        $u.WeekResetsAt | Should -Be ([System.DateTimeOffset]::FromUnixTimeSeconds($resetAt).LocalDateTime)
        $u.ResetsAvailable | Should -Be 2
        $u.PlanType | Should -Be 'plus'
        $u.FiveHourPct | Should -BeNullOrEmpty
    }

    It 'picks the longest window as weekly when both windows are present' {
        $obj = [pscustomobject]@{
            rate_limit = [pscustomobject]@{
                primary_window   = [pscustomobject]@{ used_percent = 40; limit_window_seconds = 18000;  reset_at = 1784000000 }
                secondary_window = [pscustomobject]@{ used_percent = 12; limit_window_seconds = 604800; reset_at = 1784488309 }
            }
        }

        $u = ConvertFrom-CodexUsageResponse $obj

        $u.WeekPct | Should -Be 12
        $u.FiveHourPct | Should -Be 40
        $u.ResetsAvailable | Should -BeNullOrEmpty
    }

    It 'returns null for an empty response' {
        ConvertFrom-CodexUsageResponse $null | Should -BeNullOrEmpty
    }
}
