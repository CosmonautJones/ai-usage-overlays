BeforeAll {
    $root = Split-Path $PSScriptRoot -Parent
    $script:AppDir = $TestDrive
    . "$root/src/Config.ps1"
    function Get-WslHomeRoots { @() }
    . "$root/src/Data.ps1"
    . "$root/src/Pricing.ps1"
    . "$root/src/CodexData.ps1"
    . "$root/src/CursorData.ps1"
    . "$root/src/GrokData.ps1"
    . "$root/src/Export.ps1"
    . "$root/src/History.ps1"
}

Describe 'Provider failure boundaries' {
    It 'parses all primary scripts in the current PowerShell runtime' {
        foreach ($file in @(Get-ChildItem "$root/src/*.ps1") + @(Get-Item "$root/unified-overlay.ps1")) {
            $tokens = $null; $parseErrors = $null
            [void][System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors)
            @($parseErrors).Count | Should -Be 0 -Because $file.Name
        }
    }
    It 'ships no script pinned to one Windows user profile' {
        # src\*.ps1 is copied wholesale into every install, so a literal
        # C:\Users\<name>\ path points each installer at someone else's machine.
        foreach ($file in @(Get-ChildItem "$root/src/*.ps1") + @(Get-Item "$root/unified-overlay.ps1")) {
            $hits = @(Select-String -LiteralPath $file.FullName -Pattern '[A-Za-z]:\\Users\\' |
                ForEach-Object { '{0}:{1}' -f $_.Filename, $_.LineNumber })
            $hits | Should -BeNullOrEmpty -Because $file.Name
        }
    }
    BeforeEach {
        $script:authFile = Join-Path $TestDrive 'auth.json'
        '{"access_token":"secret-value"}' | Set-Content $script:authFile
        $script:ErrLog = Join-Path $TestDrive ('failures-' + [guid]::NewGuid().ToString('N') + '.log')
    }
    It 'rejects an unrecognized successful Codex response' {
        Mock Invoke-RestMethod { [pscustomobject]@{} }
        Get-CodexLiveUsage -AuthPath $script:authFile | Should -BeNullOrEmpty
        $script:CodexAuthState | Should -Be 'stale'
    }
    It 'rejects an unrecognized successful Grok response' {
        Mock Invoke-RestMethod { [pscustomobject]@{} }
        Get-GrokLiveUsage -AuthPath $script:authFile | Should -BeNullOrEmpty
        $script:GrokAuthState | Should -Be 'stale'
    }
    It 'does not echo bearer material from exceptions into diagnostics' {
        Mock Invoke-RestMethod { throw 'request failed: Bearer secret-value' }
        $null = Get-GrokLiveUsage -AuthPath $script:authFile
        $null = Get-CodexLiveUsage -AuthPath $script:authFile
        $script:GrokErrMsg | Should -Not -Match 'secret-value'
        $script:CodexErrMsg | Should -Not -Match 'secret-value'
        (Get-Content $script:ErrLog -Raw) | Should -Not -Match 'secret-value'
    }
    It 'does not expose credential JSON in malformed-file diagnostics' {
        '{"access_token":"secret-value",BROKEN}' | Set-Content $script:authFile
        $null = Get-GrokLiveUsage -AuthPath $script:authFile
        $null = Get-CodexLiveUsage -AuthPath $script:authFile
        (Get-Content $script:ErrLog -Raw) | Should -Not -Match 'secret-value'
    }
    It 'preserves stale status in JSON even when local stats exist' {
        $source = Get-Content "$root/unified-overlay.ps1" -Raw
        $start = $source.IndexOf('$providers = [ordered]@{')
        $end = $source.IndexOf('$snapshot = New-UnifiedSnapshotDocument', $start)
        $selectedProviders = @{claude=$false;cursor=$false;codex=$true;grok=$true}
        $script:CodexAuthState='stale'; $script:CodexStats=@{InTokens=100}
        $script:GrokAuthState='stale'; $script:GrokUsage=@{WeekPct=50}
        . ([scriptblock]::Create($source.Substring($start, $end - $start)))
        $providers.codex.status | Should -Be 'stale'
        $providers.grok.status | Should -Be 'stale'
    }
}

Describe 'Credential cache hardening' {
    BeforeEach { $script:AppDir = $TestDrive }
    It 'stores a fingerprint instead of a reusable Claude credential' {
        Save-ClaudeProfile -Token 'secret-test-token' -Identity ([pscustomobject]@{ Display = 'test' })
        $raw = Get-Content (Get-ClaudeProfilePath) -Raw
        $raw | Should -Not -Match 'secret-test-token'
        (Get-CachedClaudeProfile).TokenHash | Should -Match '^[a-f0-9]{64}$'
    }
    It 'migrates an existing plaintext profile cache without retaining the token' {
        '{"Token":"old-secret","Identity":{"Display":"test"}}' | Set-Content (Get-ClaudeProfilePath)
        $cached = Get-CachedClaudeProfile
        $cached.Identity.Display | Should -Be 'test'
        (Get-Content (Get-ClaudeProfilePath) -Raw) | Should -Not -Match 'old-secret'
    }
}

Describe 'Cursor refresh truthfulness' {
    BeforeEach {
        $script:SummaryData = [pscustomobject]@{ old = $true }
        $script:LocalData = [pscustomobject]@{ linesAccepted = 42 }
        Mock Get-CursorToken { 'test-token', 'test-user', 'test@example.test' }
        Mock Invoke-RestMethod { [pscustomobject]@{} }
    }
    It 'reports failure of usage-summary even if the legacy request succeeds' {
        Mock Invoke-RestMethod { throw 'summary unavailable' } -ParameterFilter { $Uri -like '*usage-summary' }
        Get-CursorUsage
        $script:AuthState | Should -Be 'stale'
        $script:SummaryData | Should -BeNullOrEmpty
    }
    It 'rejects a successful response with an unrecognized summary schema' {
        Get-CursorUsage
        $script:AuthState | Should -Be 'stale'
        $script:SummaryData | Should -BeNullOrEmpty
    }
    It 'does not convert missing analytics fields into zero' {
        Mock Invoke-RestMethod { [pscustomobject]@{ dailyMetrics = @([pscustomobject]@{ date = 0 }) } }
        Get-CursorLocalStats
        $script:LocalData.linesAccepted | Should -BeNullOrEmpty
        $script:LocalData.edits30d | Should -BeNullOrEmpty
    }
    It 'clears prior analytics when the new fetch fails' {
        Mock Invoke-RestMethod { throw 'offline' }
        Get-CursorLocalStats
        $script:LocalData | Should -BeNullOrEmpty
    }
    It 'does not interpret a remaining percentage as used' {
        Get-CursorDisplayMessagePercent '90% remaining' | Should -BeNullOrEmpty
    }
    It 'renders unavailable numeric analytics as a placeholder' {
        Fmt-Num $null | Should -Be '--'
        Fmt-Num 0 | Should -Be '0'
    }
}

Describe 'Codex data integrity' {
    BeforeEach {
        $script:AppDir = $TestDrive
        $script:CodexSessionsDir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:CodexStats = $null
        Mock Get-CodexSessionDirCandidates { @($script:CodexSessionsDir) }
        Mock Get-CodexLiveUsage { $null }
    }
    It 'fetches live quota on a machine with no local sessions' {
        Mock Get-CodexLiveUsage { @{ WeekPct = 42; PlanType = 'pro' } }
        Get-CodexStats
        $script:CodexStats.WeekPct | Should -Be 42
        Should -Invoke Get-CodexLiveUsage -Times 1 -Exactly
    }
    It 'attributes incremental usage to its event day and model and survives cache reload' {
        New-Item -ItemType Directory $script:CodexSessionsDir | Out-Null
        $yesterday = (Get-Date).Date.AddDays(-1).AddHours(10).ToString('o')
        $today = (Get-Date).Date.AddHours(11).ToString('o')
        $events = @(
            @{ type='session_meta'; timestamp=$yesterday; payload=@{ id='session-one' } }
            @{ type='turn_context'; payload=@{ model='gpt-5.5' } }
            @{ type='event_msg'; timestamp=$yesterday; payload=@{ type='user_message' } }
            @{ type='event_msg'; timestamp=$yesterday; payload=@{ type='token_count'; info=@{ total_token_usage=@{ input_tokens=100; cached_input_tokens=0; output_tokens=10 } } } }
            @{ type='turn_context'; payload=@{ model='default' } }
            @{ type='event_msg'; timestamp=$today; payload=@{ type='user_message' } }
            @{ type='event_msg'; timestamp=$today; payload=@{ type='token_count'; info=@{ total_token_usage=@{ input_tokens=300; cached_input_tokens=0; output_tokens=30 } } } }
        )
        $events | ForEach-Object { $_ | ConvertTo-Json -Depth 10 -Compress } | Set-Content (Join-Path $script:CodexSessionsDir 'test.jsonl')
        $script:CodexPrices = @{ 'gpt-5.5'=@{in=5;cachedIn=0.5;out=30}; default=@{in=1;cachedIn=0.1;out=2} }
        foreach ($pass in 1..2) {
            Get-CodexStats
            $script:CodexStats.TodayTok | Should -Be 220
            $script:CodexStats.Messages | Should -Be 2
            $script:CodexStats.Sessions | Should -Be 1
            $script:CodexStats.ValueUSD | Should -Be 0.00104
        }
    }
    It 'does not label a daily quota as weekly' {
        $s = ConvertFrom-CodexUsageResponse ([pscustomobject]@{ rate_limit = @{ primary_window = @{ used_percent=50; limit_window_seconds=86400 } } })
        $s.WeekPct | Should -BeNullOrEmpty
        $s.FiveHourPct | Should -BeNullOrEmpty
    }
    It 'clears old log windows when live data no longer provides them' {
        New-Item -ItemType Directory $script:CodexSessionsDir | Out-Null
        $event = @{type='event_msg';timestamp=(Get-Date).ToString('o');payload=@{type='token_count';info=@{total_token_usage=@{input_tokens=1}};rate_limits=@{primary=@{window_minutes=300;used_percent=90}}}}
        $event | ConvertTo-Json -Depth 10 -Compress | Set-Content (Join-Path $script:CodexSessionsDir 'test.jsonl')
        Mock Get-CodexLiveUsage { @{ WeekPct=42; FiveHourPct=$null; FiveHourResetsAt=$null } }
        Get-CodexStats
        $script:CodexStats.FiveHourPct | Should -BeNullOrEmpty
    }
}

Describe 'History freshness' {
    It 'does not record failed provider polls as new observations' {
        $script:History = [System.Collections.Generic.List[object]]::new()
        $script:State = @{Status='stale';Data=[pscustomobject]@{five_hour=[pscustomobject]@{utilization=50}}}
        $script:CodexAuthState = 'stale'; $script:CodexStats = @{WeekPct=50}
        $script:GrokAuthState = 'auth'; $script:GrokUsage = @{WeekPct=50}
        $script:AuthState = 'stale'; $script:SummaryData = [pscustomobject]@{individualUsage=@{plan=@{autoPercentUsed=50}}}
        Mock Save-History { }
        Complete-UnifiedHistoryPoll
        $sample = $script:History[0]
        $sample.five_hour | Should -BeNullOrEmpty
        $sample.codex_seven_day | Should -BeNullOrEmpty
        $sample.grok_seven_day | Should -BeNullOrEmpty
        $sample.cursor_requests | Should -BeNullOrEmpty
    }
}
