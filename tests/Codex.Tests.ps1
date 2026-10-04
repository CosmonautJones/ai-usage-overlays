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

    It 'uses a listed model price before the gpt-5.5 family fallback' {
        $script:CodexPrices['gpt-5.6-sol'] = @{ in = 4.00; cachedIn = 0.40; out = 20.00 }
        $v = @{ inputTokens = 1000000; cachedInputTokens = 0; outputTokens = 0 }
        Estimate-CodexCost 'gpt-5.6-sol' $v | Should -Be 4.0
        Estimate-CodexCost 'gpt-5.9-unlisted' $v | Should -Be 5.0
    }
}

Describe 'Estimate-CodexCost unknown-model warning' {
    BeforeAll {
        $script:CodexCostLog = [System.Collections.Generic.List[string]]::new()
        $script:CodexUnknownModelsLogged = [System.Collections.Generic.HashSet[string]]::new()
        function Write-Log { param([string]$Message) $script:CodexCostLog.Add($Message) }
    }
    BeforeEach { $script:CodexCostLog.Clear() }

    It 'warns once per unknown model however many records it prices' {
        $records = foreach ($i in 1..5) {
            @{ Model='mystery-model-a'; Date=[datetime]'2026-06-10'; In=100L; CachedIn=0L; Out=10L; SessionId="s$i" }
        }
        [void](Measure-CodexStats -records $records -today ([datetime]'2026-06-10'))
        @($script:CodexCostLog | Where-Object { $_ -match 'mystery-model-a' }).Count | Should -Be 1
    }

    It 'still warns separately for each distinct unknown model' {
        $v = @{ inputTokens = 1; cachedInputTokens = 0; outputTokens = 0 }
        foreach ($m in 'mystery-model-b', 'mystery-model-c', 'mystery-model-b') { [void](Estimate-CodexCost $m $v) }
        @($script:CodexCostLog | Where-Object { $_ -match 'mystery-model-b' }).Count | Should -Be 1
        @($script:CodexCostLog | Where-Object { $_ -match 'mystery-model-c' }).Count | Should -Be 1
    }

    It 'keeps pricing an unknown model at the default rate after the warning' {
        $v = @{ inputTokens = 1000000; cachedInputTokens = 0; outputTokens = 0 }
        Estimate-CodexCost 'mystery-model-d' $v | Should -Be 1.0
        Estimate-CodexCost 'mystery-model-d' $v | Should -Be 1.0
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

    It 'counts a resumed session once when the next file continues the cumulative counter' {
        $baseTime = (Get-Date).Date.AddHours(10)
        $ts = New-TestTimestamp $baseTime
        $ts2 = New-TestTimestamp ($baseTime.AddMinutes(5))
        $ts3 = New-TestTimestamp ($baseTime.AddHours(1))
        $ts4 = New-TestTimestamp ($baseTime.AddHours(1).AddMinutes(5))

        Write-CodexFixture '2026\06\10\rollout-2026-06-10T10-00-00-resume-a.jsonl' @(
            @{ timestamp=$ts; type='session_meta'; payload=@{ session_id='resume-1'; timestamp=$ts } }
            @{ timestamp=$ts; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent $ts 100 10 20)
            (New-CodexTokenEvent $ts2 300 40 50)
        ) | Out-Null
        Write-CodexFixture '2026\06\10\rollout-2026-06-10T11-00-00-resume-b.jsonl' @(
            @{ timestamp=$ts3; type='session_meta'; payload=@{ session_id='resume-1'; timestamp=$ts3 } }
            @{ timestamp=$ts3; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent $ts3 300 40 50)
            (New-CodexTokenEvent $ts4 450 60 80)
        ) | Out-Null

        Get-CodexStats

        $script:CodexStats.InTokens | Should -Be 450
        $script:CodexStats.OutTokens | Should -Be 80
        $script:CodexStats.Sessions | Should -Be 1
    }

    It 'counts fork growth without counting the copied parent snapshot again' {
        $baseTime = (Get-Date).Date.AddHours(10)
        $ts = New-TestTimestamp $baseTime
        $parentLater = New-TestTimestamp ($baseTime.AddMinutes(10))
        $forkA = New-TestTimestamp ($baseTime.AddMinutes(20))
        $forkALater = New-TestTimestamp ($baseTime.AddMinutes(25))
        $forkB = New-TestTimestamp ($baseTime.AddMinutes(30))
        $forkBLater = New-TestTimestamp ($baseTime.AddMinutes(35))

        Write-CodexFixture '2026\06\10\rollout-2026-06-10T10-00-00-parent.jsonl' @(
            @{ timestamp=$ts; type='session_meta'; payload=@{ session_id='fanout'; timestamp=$ts } }
            @{ timestamp=$ts; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent $ts 1000 100 10)
            (New-CodexTokenEvent $parentLater 5000 400 40)
        ) | Out-Null
        Write-CodexFixture '2026\06\10\rollout-2026-06-10T10-20-00-fork-a.jsonl' @(
            @{ timestamp=$forkA; type='session_meta'; payload=@{ session_id='fanout'; timestamp=$forkA } }
            @{ timestamp=$forkA; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent $forkA 5000 400 40)
            (New-CodexTokenEvent $forkALater 5600 450 55)
        ) | Out-Null
        Write-CodexFixture '2026\06\10\rollout-2026-06-10T10-30-00-fork-b.jsonl' @(
            @{ timestamp=$forkB; type='session_meta'; payload=@{ session_id='fanout'; timestamp=$forkB } }
            @{ timestamp=$forkB; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent $forkB 5000 400 40)
            (New-CodexTokenEvent $forkBLater 6200 500 70)
        ) | Out-Null

        Get-CodexStats

        # Parent 5000, plus fork growth 600 and 1200. The copied 5000 is not added twice.
        $script:CodexStats.InTokens | Should -Be 6800
        $script:CodexStats.OutTokens | Should -Be 85
        $script:CodexStats.Sessions | Should -Be 1
    }

    It 'counts sibling files that share an opening snapshot and does not collapse them to the larger one' {
        $baseTime = (Get-Date).Date.AddHours(10)
        $ts = New-TestTimestamp $baseTime
        $aLater = New-TestTimestamp ($baseTime.AddMinutes(5))
        $b = New-TestTimestamp ($baseTime.AddMinutes(10))
        $bLater = New-TestTimestamp ($baseTime.AddMinutes(15))

        Write-CodexFixture '2026\06\10\rollout-2026-06-10T10-00-00-sib-a.jsonl' @(
            @{ timestamp=$ts; type='session_meta'; payload=@{ session_id='siblings'; timestamp=$ts } }
            @{ timestamp=$ts; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent $ts 100 0 5)
            (New-CodexTokenEvent $aLater 400 0 20)
        ) | Out-Null
        Write-CodexFixture '2026\06\10\rollout-2026-06-10T10-10-00-sib-b.jsonl' @(
            @{ timestamp=$b; type='session_meta'; payload=@{ session_id='siblings'; timestamp=$b } }
            @{ timestamp=$b; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent $b 100 0 5)
            (New-CodexTokenEvent $bLater 250 0 12)
        ) | Out-Null

        Get-CodexStats

        # Shared opening 100 once, then growth 300 and 150.
        $script:CodexStats.InTokens | Should -Be 550
        $script:CodexStats.OutTokens | Should -Be 27
        $script:CodexStats.Sessions | Should -Be 1
    }

    It 'counts two identical copies of a session file once' {
        $baseTime = (Get-Date).Date.AddHours(10)
        $ts = New-TestTimestamp $baseTime
        $later = New-TestTimestamp ($baseTime.AddMinutes(5))
        $events = @(
            @{ timestamp=$ts; type='session_meta'; payload=@{ session_id='dup'; timestamp=$ts } }
            @{ timestamp=$ts; type='turn_context'; payload=@{ model='gpt-5.5' } }
            (New-CodexTokenEvent $ts 100 0 5)
            (New-CodexTokenEvent $later 400 0 20)
        )
        Write-CodexFixture '2026\06\10\rollout-2026-06-10T10-00-00-dup-a.jsonl' $events | Out-Null
        Write-CodexFixture '2026\06\10\rollout-2026-06-10T10-00-01-dup-b.jsonl' $events | Out-Null

        Get-CodexStats

        $script:CodexStats.InTokens | Should -Be 400
        $script:CodexStats.OutTokens | Should -Be 20
        $script:CodexStats.Sessions | Should -Be 1
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

    It 'accepts a decimal window length and still rejects a one-day window' {
        $weekly = ConvertFrom-CodexUsageResponse ([pscustomobject]@{
            rate_limit = [pscustomobject]@{
                primary_window = [pscustomobject]@{ used_percent = '12.5'; limit_window_seconds = '604800.0' }
            }
            rate_limit_reset_credits = [pscustomobject]@{ available_count = 2 }
        })
        $weekly.WeekPct | Should -Be 12.5
        $weekly.ResetsAvailable | Should -Be 2

        $oneDay = ConvertFrom-CodexUsageResponse ([pscustomobject]@{
            rate_limit = [pscustomobject]@{
                primary_window = [pscustomobject]@{ used_percent = 50; limit_window_seconds = 86400 }
            }
        })
        $oneDay.WeekPct | Should -BeNullOrEmpty
        $oneDay.FiveHourPct | Should -BeNullOrEmpty
    }

    It 'keeps a weekly used percent of zero and the usage-credit balance' {
        $obj = [pscustomobject]@{
            plan_type = 'pro'
            rate_limit = [pscustomobject]@{
                primary_window = [pscustomobject]@{
                    used_percent = 0
                    limit_window_seconds = 604800
                    reset_at = 1791603188
                }
                secondary_window = $null
            }
            credits = [pscustomobject]@{
                has_credits = $true
                unlimited = $false
                balance = '61119.6042005000'
            }
            rate_limit_reset_credits = [pscustomobject]@{ available_count = 1 }
        }

        $u = ConvertFrom-CodexUsageResponse $obj

        $u.WeekPct | Should -Be 0
        $u.FiveHourPct | Should -BeNullOrEmpty
        $u.ResetsAvailable | Should -Be 1
        $u.PlanType | Should -Be 'pro'
        [math]::Abs($u.CreditBalance - 61119.6042005) | Should -BeLessThan 0.001
        $u.CreditsUnlimited | Should -BeFalse
        [math]::Round([double]$u.CreditBalance, 0, [MidpointRounding]::AwayFromZero) | Should -Be 61120
    }

    It 'leaves the credit balance empty when ChatGPT omits it' {
        $obj = [pscustomobject]@{
            credits = [pscustomobject]@{ has_credits = $false; unlimited = $false; balance = $null }
            rate_limit = [pscustomobject]@{
                primary_window = [pscustomobject]@{ used_percent = 1; limit_window_seconds = 604800; reset_at = 1784488309 }
            }
        }

        $u = ConvertFrom-CodexUsageResponse $obj

        $null -eq $u.CreditBalance | Should -BeTrue
        $u.CreditsUnlimited | Should -BeFalse
        $u.WeekPct | Should -Be 1
    }

    It 'keeps a numeric balance and the unlimited flag' {
        $obj = [pscustomobject]@{
            credits = [pscustomobject]@{ unlimited = $true; balance = 0 }
        }

        $u = ConvertFrom-CodexUsageResponse $obj

        $u.CreditBalance | Should -Be 0
        $u.CreditsUnlimited | Should -BeTrue
    }

    It 'ignores a credit balance that is not a number' {
        $obj = [pscustomobject]@{
            credits = [pscustomobject]@{ balance = 'not-a-balance'; unlimited = $false }
        }

        $u = ConvertFrom-CodexUsageResponse $obj

        $null -eq $u.CreditBalance | Should -BeTrue
    }
}

Describe 'Codex credit display' {
    It 'paints the ChatGPT credit balance on the Codex tile' {
        $shell = Get-Content -LiteralPath (Join-Path $PSScriptRoot '..\src\Shell.ps1') -Raw
        $shell | Should -Match 'x:Name="codexCreditsText"'
        $shell | Should -Match 'Format-CodexCreditsRemaining'
    }
}
